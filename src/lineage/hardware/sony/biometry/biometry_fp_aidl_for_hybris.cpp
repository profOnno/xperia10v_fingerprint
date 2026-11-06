/*
 * Copyright (C) 2026 The LineageOS Project
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sailfish OS libbiometry_fp_api shim for the LineageOS AIDL V4
 * fingerprint HAL (android.hardware.biometrics.fingerprint.IFingerprint).
 *
 * The Sailfish community fpd daemon dlopen()s libbiometry_fp_api.so through
 * libhybris and expects the C ABI in biometry.h.  This implementation talks
 * to the already-running AIDL service instead of a HIDL 2.1 service, and uses
 * gatekeeper 1.0 to mint the HardwareAuthToken required for enrollment.
 */

#include "biometry.h"

#include <aidl/android/hardware/biometrics/common/ICancellationSignal.h>
#include <aidl/android/hardware/biometrics/fingerprint/AcquiredInfo.h>
#include <aidl/android/hardware/biometrics/fingerprint/BnSessionCallback.h>
#include <aidl/android/hardware/biometrics/fingerprint/Error.h>
#include <aidl/android/hardware/biometrics/fingerprint/IFingerprint.h>
#include <aidl/android/hardware/biometrics/fingerprint/ISession.h>
#include <aidl/android/hardware/biometrics/fingerprint/ISessionCallback.h>
#include <aidl/android/hardware/biometrics/fingerprint/SensorProps.h>
#include <aidl/android/hardware/keymaster/HardwareAuthToken.h>
#include <aidl/android/hardware/keymaster/HardwareAuthenticatorType.h>

#include <android-base/logging.h>
#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <hardware/hw_auth_token.h>
#include <utils/Log.h>

#include <android/hardware/gatekeeper/1.0/IGatekeeper.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using aidl::android::hardware::biometrics::common::ICancellationSignal;
using aidl::android::hardware::biometrics::fingerprint::AcquiredInfo;
using aidl::android::hardware::biometrics::fingerprint::BnSessionCallback;
using aidl::android::hardware::biometrics::fingerprint::Error;
using aidl::android::hardware::biometrics::fingerprint::IFingerprint;
using aidl::android::hardware::biometrics::fingerprint::ISession;
using aidl::android::hardware::biometrics::fingerprint::ISessionCallback;
using aidl::android::hardware::biometrics::fingerprint::SensorProps;
using aidl::android::hardware::keymaster::HardwareAuthenticatorType;
using aidl::android::hardware::keymaster::HardwareAuthToken;

using android::hardware::Return;
using android::hardware::Void;
using android::hardware::gatekeeper::V1_0::GatekeeperResponse;
using android::hardware::gatekeeper::V1_0::GatekeeperStatusCode;
using android::hardware::gatekeeper::V1_0::IGatekeeper;
using android::hardware::hidl_vec;
using android::sp;

namespace {

constexpr char kFpService[] =
        "android.hardware.biometrics.fingerprint.IFingerprint/default";
constexpr char kGatekeeperHandlePath[] = "/var/lib/sailfish-fpd/gatekeeper_handle";
constexpr char kSyntheticPassword[] = "default_password";
constexpr uint64_t kDeviceId = 1;
constexpr int32_t kDefaultUserId = 100000;

}  // namespace

static void logMsg(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

struct UHardwareBiometry_;

class AidlCallback : public BnSessionCallback {
  public:
    explicit AidlCallback(UHardwareBiometry_* owner) : mOwner(owner) {}

    ndk::ScopedAStatus onChallengeGenerated(int64_t challenge) override;
    ndk::ScopedAStatus onChallengeRevoked(int64_t challenge) override;
    ndk::ScopedAStatus onAcquired(AcquiredInfo info, int32_t vendorCode) override;
    ndk::ScopedAStatus onError(Error error, int32_t vendorCode) override;
    ndk::ScopedAStatus onEnrollmentProgress(int32_t enrollmentId, int32_t remaining) override;
    ndk::ScopedAStatus onAuthenticationSucceeded(
            int32_t enrollmentId, const HardwareAuthToken& hat) override;
    ndk::ScopedAStatus onAuthenticationFailed() override;
    ndk::ScopedAStatus onLockoutTimed(int64_t durationMillis) override;
    ndk::ScopedAStatus onLockoutPermanent() override;
    ndk::ScopedAStatus onLockoutCleared() override;
    ndk::ScopedAStatus onInteractionDetected() override;
    ndk::ScopedAStatus onEnrollmentsEnumerated(
            const std::vector<int32_t>& enrollmentIds) override;
    ndk::ScopedAStatus onEnrollmentsRemoved(
            const std::vector<int32_t>& enrollmentIds) override;
    ndk::ScopedAStatus onAuthenticatorIdRetrieved(int64_t authenticatorId) override;
    ndk::ScopedAStatus onAuthenticatorIdInvalidated(int64_t newAuthenticatorId) override;
    ndk::ScopedAStatus onSessionClosed() override;

  private:
    UHardwareBiometry_* mOwner;
};

struct UHardwareBiometry_ {
    bool init();

    bool ensureSession(int32_t uid);
    bool generateChallenge(int64_t* out);
    bool getHardwareAuthToken(uint32_t uid, uint64_t challenge, HardwareAuthToken* out);

    void handleChallengeGenerated(int64_t challenge);
    void handleChallengeRevoked(int64_t challenge);
    void handleAcquired(AcquiredInfo info, int32_t vendorCode);
    void handleError(Error error, int32_t vendorCode);
    void handleEnrollmentProgress(int32_t enrollmentId, int32_t remaining);
    void handleAuthenticationSucceeded(int32_t enrollmentId);
    void handleAuthenticationFailed();
    void handleLockout();
    void handleLockoutCleared();
    void handleInteractionDetected();
    void handleEnrollmentsEnumerated(const std::vector<int32_t>& enrollmentIds);
    void handleEnrollmentsRemoved(const std::vector<int32_t>& enrollmentIds);
    void handleAuthenticatorIdRetrieved(int64_t authenticatorId);
    void handleSessionClosed();

    UHardwareBiometryParams getParams(bool* valid);

    std::mutex mLock;
    std::condition_variable mCond;
    std::shared_ptr<IFingerprint> mFingerprint;
    std::shared_ptr<ISession> mSession;
    std::shared_ptr<AidlCallback> mCallback;
    std::shared_ptr<ICancellationSignal> mCancellation;

    UHardwareBiometryParams mParams{};
    bool mHasParams = false;

    int32_t mSensorId = 0;
    int32_t mUserId = kDefaultUserId;
    bool mSessionCreated = false;
    bool mSessionClosed = true;

    int64_t mChallenge = 0;
    bool mChallengeReady = false;

    int64_t mAuthenticatorId = 0;
    bool mAuthenticatorIdReady = false;
};

namespace {

static int32_t parseUserId(const char* path) {
    if (path == nullptr) return kDefaultUserId;
    const char* prefix = "/data/vendor_de/";
    const char* p = strstr(path, prefix);
    if (p == nullptr) return kDefaultUserId;
    p += strlen(prefix);
    char* end = nullptr;
    long value = strtol(p, &end, 10);
    if (end == p || value <= 0) return kDefaultUserId;
    return static_cast<int32_t>(value);
}

static bool readHandle(std::vector<uint8_t>* out) {
    std::ifstream file(kGatekeeperHandlePath, std::ios::binary);
    if (!file) return false;
    out->assign(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    return !out->empty();
}

static void writeHandle(const std::vector<uint8_t>& data) {
    ::mkdir("/var/lib/sailfish-fpd", 0700);
    std::ofstream file(kGatekeeperHandlePath, std::ios::binary | std::ios::trunc);
    if (!file) {
        ALOGE("unable to store gatekeeper handle at %s", kGatekeeperHandlePath);
        return;
    }
    file.write(reinterpret_cast<const char*>(data.data()), data.size());
}

static void translateHat(const hw_auth_token_t& hat, HardwareAuthToken* out) {
    out->challenge = hat.challenge;
    out->userId = hat.user_id;
    out->authenticatorId = hat.authenticator_id;
    out->authenticatorType = static_cast<HardwareAuthenticatorType>(
            be32toh(static_cast<uint32_t>(hat.authenticator_type)));
    out->timestamp.milliSeconds = static_cast<int64_t>(be64toh(hat.timestamp));
    out->mac.assign(std::begin(hat.hmac), std::end(hat.hmac));
}

static int mapAcquired(AcquiredInfo info) {
    switch (info) {
        case AcquiredInfo::GOOD:
            return ACQUIRED_GOOD;
        case AcquiredInfo::PARTIAL:
            return ACQUIRED_PARTIAL;
        case AcquiredInfo::INSUFFICIENT:
            return ACQUIRED_INSUFFICIENT;
        case AcquiredInfo::SENSOR_DIRTY:
            return ACQUIRED_IMAGER_DIRTY;
        case AcquiredInfo::TOO_SLOW:
            return ACQUIRED_TOO_SLOW;
        case AcquiredInfo::TOO_FAST:
            return ACQUIRED_TOO_FAST;
        case AcquiredInfo::VENDOR:
            return ACQUIRED_VENDOR;
        default:
            return ACQUIRED_GOOD;
    }
}

static int mapError(Error error) {
    switch (error) {
        case Error::HW_UNAVAILABLE:
            return ERROR_HW_UNAVAILABLE;
        case Error::UNABLE_TO_PROCESS:
            return ERROR_UNABLE_TO_PROCESS;
        case Error::TIMEOUT:
            return ERROR_TIMEOUT;
        case Error::NO_SPACE:
            return ERROR_NO_SPACE;
        case Error::CANCELED:
            return ERROR_CANCELED;
        case Error::UNABLE_TO_REMOVE:
            return ERROR_UNABLE_TO_REMOVE;
        case Error::VENDOR:
            return ERROR_VENDOR;
        default:
            return ERROR_NO_ERROR;
    }
}

}  // namespace

bool UHardwareBiometry_::init() {
    // The AIDL HAL invokes ISessionCallback synchronously from its worker
    // threads; without a binder thread pool those calls block and the
    // enrollment never makes progress.
    ABinderProcess_setThreadPoolMaxThreadCount(4);
    ABinderProcess_startThreadPool();

    ndk::SpAIBinder binder(AServiceManager_waitForService(kFpService));
    if (binder.get() == nullptr) {
        ALOGE("fingerprint AIDL service %s not found", kFpService);
        logMsg("[biometry] init: service not found");
        return false;
    }

    mFingerprint = IFingerprint::fromBinder(binder);
    if (mFingerprint == nullptr) {
        ALOGE("unable to obtain IFingerprint interface");
        logMsg("[biometry] init: no IFingerprint");
        return false;
    }

    std::vector<SensorProps> props;
    auto status = mFingerprint->getSensorProps(&props);
    if (!status.isOk() || props.empty()) {
        ALOGE("getSensorProps failed: %s", status.getDescription().c_str());
        logMsg("[biometry] init: getSensorProps failed: %s",
               status.getDescription().c_str());
        return false;
    }

    mSensorId = props.front().commonProps.sensorId;
    ALOGI("fingerprint sensor id %d (%zu sensor(s))", mSensorId, props.size());
    logMsg("[biometry] init: sensor=%d props=%zu", mSensorId, props.size());
    return true;
}

bool UHardwareBiometry_::ensureSession(int32_t uid) {
    logMsg("[biometry] ensureSession uid=%d", uid);
    std::shared_ptr<ISession> oldSession;
    bool alreadyOpen = false;
    {
        std::lock_guard<std::mutex> lock(mLock);
        if (mSessionCreated && !mSessionClosed && mUserId == uid && mSession != nullptr) {
            alreadyOpen = true;
        } else {
            oldSession = mSession;
        }
    }

    if (alreadyOpen) {
        logMsg("[biometry] session already open uid=%d", uid);
        return true;
    }

    if (oldSession != nullptr) {
        logMsg("[biometry] closing old session");
        oldSession->close();
        std::unique_lock<std::mutex> lock(mLock);
        mCond.wait_for(lock, std::chrono::seconds(2), [this] { return mSessionClosed; });
        mSession.reset();
        mCallback.reset();
        mSessionCreated = false;
    }

    auto callback = ndk::SharedRefBase::make<AidlCallback>(this);
    std::shared_ptr<ISession> session;
    auto status = mFingerprint->createSession(mSensorId, uid, callback, &session);
    if (!status.isOk() || session == nullptr) {
        ALOGE("createSession(%d) failed: %s", uid, status.getDescription().c_str());
        logMsg("[biometry] createSession failed: %s", status.getDescription().c_str());
        return false;
    }
    logMsg("[biometry] session created uid=%d", uid);

    {
        std::lock_guard<std::mutex> lock(mLock);
        mUserId = uid;
        mSession = session;
        mCallback = callback;
        mSessionCreated = true;
        mSessionClosed = false;
        mChallengeReady = false;
        mAuthenticatorIdReady = false;
    }
    return true;
}

bool UHardwareBiometry_::generateChallenge(int64_t* out) {
    logMsg("[biometry] generateChallenge");
    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(mLock);
        session = mSession;
        mChallengeReady = false;
    }
    if (session == nullptr) {
        logMsg("[biometry] generateChallenge: no session");
        return false;
    }

    auto status = session->generateChallenge();
    if (!status.isOk()) {
        ALOGE("generateChallenge failed: %s", status.getDescription().c_str());
        logMsg("[biometry] generateChallenge call failed: %s",
               status.getDescription().c_str());
        return false;
    }

    std::unique_lock<std::mutex> lock(mLock);
    if (!mCond.wait_for(lock, std::chrono::seconds(5), [this] { return mChallengeReady; })) {
        ALOGE("timed out waiting for onChallengeGenerated");
        logMsg("[biometry] generateChallenge timed out");
        return false;
    }
    *out = mChallenge;
    logMsg("[biometry] challenge=%lld", static_cast<long long>(mChallenge));
    return true;
}

bool UHardwareBiometry_::getHardwareAuthToken(uint32_t uid, uint64_t challenge,
                                              HardwareAuthToken* out) {
    logMsg("[biometry] getHAT uid=%u challenge=%llu", uid,
           static_cast<unsigned long long>(challenge));
    sp<IGatekeeper> gatekeeper = IGatekeeper::getService();
    if (gatekeeper == nullptr) {
        ALOGE("gatekeeper 1.0 service not available");
        logMsg("[biometry] gatekeeper unavailable");
        return false;
    }

    const std::vector<uint8_t> password(kSyntheticPassword,
                                        kSyntheticPassword + strlen(kSyntheticPassword));
    std::vector<uint8_t> handle;
    readHandle(&handle);

    hidl_vec<uint8_t> currentHandle(handle);
    hidl_vec<uint8_t> cachedPassword;
    if (!handle.empty()) {
        cachedPassword = hidl_vec<uint8_t>(password);
    }
    hidl_vec<uint8_t> desiredPassword(password);

    GatekeeperResponse enrollResponse;
    bool done = false;
    auto ret = gatekeeper->enroll(
            uid, currentHandle, cachedPassword, desiredPassword,
            [&](const GatekeeperResponse& response) {
                enrollResponse = response;
                done = true;
            });

    if (!ret.isOk() || !done) {
        ALOGE("gatekeeper enroll call failed");
        logMsg("[biometry] gk enroll call failed");
        return false;
    }
    logMsg("[biometry] gk enroll code=%d data=%zu",
           static_cast<int>(enrollResponse.code), enrollResponse.data.size());

    if (enrollResponse.code != GatekeeperStatusCode::STATUS_OK &&
        enrollResponse.code != GatekeeperStatusCode::STATUS_REENROLL) {
        if (handle.empty() && uid != 0) {
            // We lost the handle but gatekeeper still has a credential for this uid.
            // The uid is Sailfish-specific, so deleting and re-enrolling is safe.
            GatekeeperResponse deleteResponse;
            bool deleteDone = false;
            gatekeeper->deleteUser(uid, [&](const GatekeeperResponse& response) {
                deleteResponse = response;
                deleteDone = true;
            });
            (void)deleteDone;

            done = false;
            hidl_vec<uint8_t> empty;
            ret = gatekeeper->enroll(
                    uid, empty, empty, desiredPassword,
                    [&](const GatekeeperResponse& response) {
                        enrollResponse = response;
                        done = true;
                    });
            if (!ret.isOk() || !done ||
                (enrollResponse.code != GatekeeperStatusCode::STATUS_OK &&
                 enrollResponse.code != GatekeeperStatusCode::STATUS_REENROLL)) {
                ALOGE("gatekeeper re-enroll failed (%d)", static_cast<int>(enrollResponse.code));
                return false;
            }
        } else {
            ALOGE("gatekeeper enroll failed (%d)", static_cast<int>(enrollResponse.code));
            return false;
        }
    }

    if (enrollResponse.data.size() == 0) {
        ALOGE("gatekeeper returned an empty password handle");
        logMsg("[biometry] gk empty handle");
        return false;
    }
    writeHandle(std::vector<uint8_t>(enrollResponse.data.begin(), enrollResponse.data.end()));
    logMsg("[biometry] gk handle stored (%zu bytes)", enrollResponse.data.size());

    GatekeeperResponse verifyResponse;
    done = false;
    hidl_vec<uint8_t> verifyHandle(enrollResponse.data);
    ret = gatekeeper->verify(
            uid, challenge, verifyHandle, desiredPassword,
            [&](const GatekeeperResponse& response) {
                verifyResponse = response;
                done = true;
            });

    if (!ret.isOk() || !done) {
        ALOGE("gatekeeper verify call failed");
        logMsg("[biometry] gk verify call failed");
        return false;
    }
    logMsg("[biometry] gk verify code=%d data=%zu",
           static_cast<int>(verifyResponse.code), verifyResponse.data.size());

    if (verifyResponse.code != GatekeeperStatusCode::STATUS_OK &&
        verifyResponse.code != GatekeeperStatusCode::STATUS_REENROLL) {
        ALOGE("gatekeeper verify failed (%d)", static_cast<int>(verifyResponse.code));
        return false;
    }
    if (verifyResponse.data.size() < sizeof(hw_auth_token_t)) {
        ALOGE("gatekeeper returned a short HAT (%zu bytes)", verifyResponse.data.size());
        return false;
    }

    hw_auth_token_t hat{};
    memcpy(&hat, verifyResponse.data.data(), sizeof(hat));
    translateHat(hat, out);
    logMsg("[biometry] HAT ok (challenge=%llu, type=0x%x)",
           static_cast<unsigned long long>(hat.challenge), hat.authenticator_type);
    return true;
}

UHardwareBiometryParams UHardwareBiometry_::getParams(bool* valid) {
    std::lock_guard<std::mutex> lock(mLock);
    *valid = mHasParams;
    return mParams;
}

void UHardwareBiometry_::handleChallengeGenerated(int64_t challenge) {
    std::lock_guard<std::mutex> lock(mLock);
    mChallenge = challenge;
    mChallengeReady = true;
    mCond.notify_all();
}

void UHardwareBiometry_::handleChallengeRevoked(int64_t) {}

void UHardwareBiometry_::handleAcquired(AcquiredInfo info, int32_t vendorCode) {
    logMsg("[biometry] acquired info=%d vendor=%d", static_cast<int>(info), vendorCode);
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.acquired_cb == nullptr) return;
    params.acquired_cb(kDeviceId, mapAcquired(info), vendorCode, params.context);
}

void UHardwareBiometry_::handleError(Error error, int32_t vendorCode) {
    logMsg("[biometry] error=%d vendor=%d", static_cast<int>(error), vendorCode);
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.error_cb == nullptr) return;
    params.error_cb(kDeviceId, mapError(error), vendorCode, params.context);
}

void UHardwareBiometry_::handleEnrollmentProgress(int32_t enrollmentId, int32_t remaining) {
    logMsg("[biometry] progress id=%d remaining=%d", enrollmentId, remaining);
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.enrollresult_cb == nullptr) return;
    params.enrollresult_cb(kDeviceId, static_cast<uint32_t>(enrollmentId),
                           static_cast<uint32_t>(mUserId), static_cast<uint32_t>(remaining),
                           params.context);
}

void UHardwareBiometry_::handleAuthenticationSucceeded(int32_t enrollmentId) {
    logMsg("[biometry] auth ok id=%d", enrollmentId);
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.authenticated_cb == nullptr) return;
    params.authenticated_cb(kDeviceId, static_cast<uint32_t>(enrollmentId),
                            static_cast<uint32_t>(mUserId), params.context);
}

void UHardwareBiometry_::handleAuthenticationFailed() {}

void UHardwareBiometry_::handleLockout() {
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.error_cb == nullptr) return;
    params.error_cb(kDeviceId, ERROR_LOCKOUT, 0, params.context);
}

void UHardwareBiometry_::handleLockoutCleared() {}

void UHardwareBiometry_::handleInteractionDetected() {}

void UHardwareBiometry_::handleEnrollmentsEnumerated(
        const std::vector<int32_t>& enrollmentIds) {
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.enumerate_cb == nullptr) return;
    for (int32_t id : enrollmentIds) {
        params.enumerate_cb(kDeviceId, static_cast<uint32_t>(id),
                            static_cast<uint32_t>(mUserId), 0, params.context);
    }
}

void UHardwareBiometry_::handleEnrollmentsRemoved(const std::vector<int32_t>& enrollmentIds) {
    bool valid = false;
    auto params = getParams(&valid);
    if (!valid || params.removed_cb == nullptr) return;
    for (int32_t id : enrollmentIds) {
        params.removed_cb(kDeviceId, static_cast<uint32_t>(id),
                          static_cast<uint32_t>(mUserId), 0, params.context);
    }
}

void UHardwareBiometry_::handleAuthenticatorIdRetrieved(int64_t authenticatorId) {
    std::lock_guard<std::mutex> lock(mLock);
    mAuthenticatorId = authenticatorId;
    mAuthenticatorIdReady = true;
    mCond.notify_all();
}

void UHardwareBiometry_::handleSessionClosed() {
    logMsg("[biometry] session closed");
    std::lock_guard<std::mutex> lock(mLock);
    mSessionClosed = true;
    mCond.notify_all();
}

// ---------------------------------------------------------------------------
// AidlCallback
// ---------------------------------------------------------------------------

ndk::ScopedAStatus AidlCallback::onChallengeGenerated(int64_t challenge) {
    mOwner->handleChallengeGenerated(challenge);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onChallengeRevoked(int64_t challenge) {
    mOwner->handleChallengeRevoked(challenge);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onAcquired(AcquiredInfo info, int32_t vendorCode) {
    mOwner->handleAcquired(info, vendorCode);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onError(Error error, int32_t vendorCode) {
    mOwner->handleError(error, vendorCode);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onEnrollmentProgress(int32_t enrollmentId, int32_t remaining) {
    mOwner->handleEnrollmentProgress(enrollmentId, remaining);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onAuthenticationSucceeded(
        int32_t enrollmentId, const HardwareAuthToken&) {
    mOwner->handleAuthenticationSucceeded(enrollmentId);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onAuthenticationFailed() {
    mOwner->handleAuthenticationFailed();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onLockoutTimed(int64_t) {
    mOwner->handleLockout();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onLockoutPermanent() {
    mOwner->handleLockout();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onLockoutCleared() {
    mOwner->handleLockoutCleared();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onInteractionDetected() {
    mOwner->handleInteractionDetected();
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onEnrollmentsEnumerated(
        const std::vector<int32_t>& enrollmentIds) {
    mOwner->handleEnrollmentsEnumerated(enrollmentIds);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onEnrollmentsRemoved(
        const std::vector<int32_t>& enrollmentIds) {
    mOwner->handleEnrollmentsRemoved(enrollmentIds);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onAuthenticatorIdRetrieved(int64_t authenticatorId) {
    mOwner->handleAuthenticatorIdRetrieved(authenticatorId);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onAuthenticatorIdInvalidated(int64_t newAuthenticatorId) {
    mOwner->handleAuthenticatorIdRetrieved(newAuthenticatorId);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus AidlCallback::onSessionClosed() {
    mOwner->handleSessionClosed();
    return ndk::ScopedAStatus::ok();
}

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

extern "C" {

UHardwareBiometry u_hardware_biometry_new() {
    auto* instance = new UHardwareBiometry_();
    if (!instance->init()) {
        delete instance;
        return nullptr;
    }
    return instance;
}

uint64_t u_hardware_biometry_setNotify(UHardwareBiometry self,
                                       UHardwareBiometryParams* params) {
    if (self == nullptr || params == nullptr) return 0;
    std::lock_guard<std::mutex> lock(self->mLock);
    self->mParams = *params;
    self->mHasParams = true;
    return kDeviceId;
}

uint64_t u_hardware_biometry_preEnroll(UHardwareBiometry self) {
    if (self == nullptr) return 0;
    int64_t challenge = 0;
    if (!self->generateChallenge(&challenge)) return 0;
    return static_cast<uint64_t>(challenge);
}

UHardwareBiometryRequestStatus u_hardware_biometry_enroll(UHardwareBiometry self, uint32_t,
                                                           uint32_t, uint32_t uid) {
    if (self == nullptr) return SYS_UNKNOWN;
    logMsg("[biometry] enroll uid=%u", uid);
    if (!self->ensureSession(static_cast<int32_t>(uid))) return SYS_UNKNOWN;

    int64_t challenge = 0;
    if (!self->generateChallenge(&challenge)) return SYS_UNKNOWN;

    HardwareAuthToken hat;
    if (!self->getHardwareAuthToken(uid, static_cast<uint64_t>(challenge), &hat)) {
        logMsg("[biometry] enroll: no HAT");
        return SYS_UNKNOWN;
    }
    logMsg("[biometry] enroll: calling ISession::enroll");

    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
    }
    if (session == nullptr) return SYS_UNKNOWN;

    std::shared_ptr<ICancellationSignal> cancellation;
    auto status = session->enroll(hat, &cancellation);
    if (!status.isOk()) {
        ALOGE("enroll failed: %s", status.getDescription().c_str());
        logMsg("[biometry] ISession::enroll failed: %s", status.getDescription().c_str());
        return SYS_UNKNOWN;
    }
    logMsg("[biometry] ISession::enroll started");

    {
        std::lock_guard<std::mutex> lock(self->mLock);
        self->mCancellation = cancellation;
    }
    return SYS_OK;
}

UHardwareBiometryRequestStatus u_hardware_biometry_postEnroll(UHardwareBiometry self) {
    if (self == nullptr) return SYS_UNKNOWN;
    std::shared_ptr<ISession> session;
    int64_t challenge = 0;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
        challenge = self->mChallenge;
    }
    if (session == nullptr) return SYS_UNKNOWN;
    if (challenge != 0) {
        session->revokeChallenge(challenge);
    }
    return SYS_OK;
}

uint64_t u_hardware_biometry_getAuthenticatorId(UHardwareBiometry self) {
    if (self == nullptr) return 0;
    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
        self->mAuthenticatorIdReady = false;
    }
    if (session == nullptr) return 0;

    auto status = session->getAuthenticatorId();
    if (!status.isOk()) return 0;

    std::unique_lock<std::mutex> lock(self->mLock);
    if (!self->mCond.wait_for(lock, std::chrono::seconds(2),
                              [self] { return self->mAuthenticatorIdReady; })) {
        return 0;
    }
    return static_cast<uint64_t>(self->mAuthenticatorId);
}

UHardwareBiometryRequestStatus u_hardware_biometry_cancel(UHardwareBiometry self) {
    if (self == nullptr) return SYS_UNKNOWN;
    logMsg("[biometry] cancel");
    std::shared_ptr<ICancellationSignal> cancellation;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        cancellation = self->mCancellation;
    }
    if (cancellation == nullptr) return SYS_OK;
    auto status = cancellation->cancel();
    return status.isOk() ? SYS_OK : SYS_UNKNOWN;
}

UHardwareBiometryRequestStatus u_hardware_biometry_enumerate(UHardwareBiometry self) {
    if (self == nullptr) return SYS_UNKNOWN;
    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
    }
    if (session == nullptr) return SYS_UNKNOWN;
    auto status = session->enumerateEnrollments();
    return status.isOk() ? SYS_OK : SYS_UNKNOWN;
}

UHardwareBiometryRequestStatus u_hardware_biometry_remove(UHardwareBiometry self, uint32_t,
                                                           uint32_t fid) {
    if (self == nullptr) return SYS_UNKNOWN;
    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
    }
    if (session == nullptr) return SYS_UNKNOWN;

    std::vector<int32_t> ids{static_cast<int32_t>(fid)};
    if (fid == 0) {
        // Remove-all is expressed by the daemon as fid == 0; enumerate first so we
        // can pass the real list to the AIDL HAL.
        session->enumerateEnrollments();
        return SYS_OK;
    }
    auto status = session->removeEnrollments(ids);
    return status.isOk() ? SYS_OK : SYS_UNKNOWN;
}

UHardwareBiometryRequestStatus u_hardware_biometry_setActiveGroup(UHardwareBiometry self,
                                                                   uint32_t, char* storePath) {
    if (self == nullptr) return SYS_UNKNOWN;
    return self->ensureSession(parseUserId(storePath)) ? SYS_OK : SYS_UNKNOWN;
}

UHardwareBiometryRequestStatus u_hardware_biometry_authenticate(UHardwareBiometry self,
                                                                 uint64_t operationId,
                                                                 uint32_t) {
    if (self == nullptr) return SYS_UNKNOWN;
    logMsg("[biometry] authenticate op=%llu", static_cast<unsigned long long>(operationId));

    int32_t uid = 0;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        uid = self->mUserId;
    }
    if (!self->ensureSession(uid)) return SYS_UNKNOWN;

    std::shared_ptr<ISession> session;
    {
        std::lock_guard<std::mutex> lock(self->mLock);
        session = self->mSession;
    }
    if (session == nullptr) return SYS_UNKNOWN;

    std::shared_ptr<ICancellationSignal> cancellation;
    auto status = session->authenticate(static_cast<int64_t>(operationId), &cancellation);
    if (!status.isOk()) {
        ALOGE("authenticate failed: %s", status.getDescription().c_str());
        return SYS_UNKNOWN;
    }

    {
        std::lock_guard<std::mutex> lock(self->mLock);
        self->mCancellation = cancellation;
    }
    return SYS_OK;
}

}  // extern "C"
