# `libbiometry_fp_api.so` — AIDL bridge reference

File: `src/lineage/hardware/sony/biometry/biometry_fp_aidl_for_hybris.cpp`
Header: `src/lineage/hardware/sony/biometry/biometry.h`
Build: `src/lineage/hardware/sony/biometry/Android.bp` (`cc_library_shared`,
`vendor: true`, installed to `/vendor/lib64` and copied to
`/usr/libexec/droid-hybris/system/lib64/`).

The library is loaded by `sailfish-fpd-community` through libhybris:

```cpp
android_dlopen("libbiometry_fp_api.so", RTLD_LAZY)
android_dlsym(handle, "u_hardware_biometry_new")
```

It is **bionic** code running inside a glibc process. All Android libraries it
links (`libbinder_ndk`, the AIDL V4 libs, `libhidlbase`, gatekeeper) are loaded
by libhybris's linker.

---

## ABI

`biometry.h` (LGPL-3.0, from the Ubuntu Touch/community fpd project) defines:

* `UHardwareBiometry` — opaque handle;
* `UHardwareBiometryParams` — six callbacks:
  `enrollresult_cb`, `acquired_cb`, `authenticated_cb`, `error_cb`,
  `removed_cb`, `enumerate_cb`, plus a `context` pointer;
* enums for acquired info, errors and request status;
* the eleven `u_hardware_biometry_*` functions.

The daemon resolves these symbols lazily in
`src/hardware/android_hw_module.h` (`DLSYM`).

---

## `UHardwareBiometry_`

The bridge's state object. Important members:

| Member | Purpose |
|---|---|
| `mFingerprint` | `std::shared_ptr<IFingerprint>` |
| `mSession` | current `std::shared_ptr<ISession>` |
| `mCallback` | our `AidlCallback` (kept alive for the session) |
| `mCancellation` | last `ICancellationSignal` (for `cancel`) |
| `mParams` / `mHasParams` | daemon callback table |
| `mSensorId` | from `getSensorProps().commonProps.sensorId` |
| `mUserId` | current Android user (`100000`) |
| `mSessionCreated` / `mSessionClosed` | session lifecycle |
| `mChallenge` / `mChallengeReady` | `generateChallenge` rendezvous |
| `mAuthenticatorId` / `mAuthenticatorIdReady` | `getAuthenticatorId` rendezvous |
| `mLock` / `mCond` | protects the above; callbacks run on binder threads |

### `init`

```cpp
ABinderProcess_setThreadPoolMaxThreadCount(4);
ABinderProcess_startThreadPool();
```

This is the **most important line in the port**. `ISessionCallback` methods are
synchronous binder calls from the HAL/REE worker thread. Without a client thread
pool, `onAcquired` blocks the HAL worker and the enrollment never progresses.

Then:

```cpp
AServiceManager_waitForService("android.hardware.biometrics.fingerprint.IFingerprint/default")
IFingerprint::fromBinder(...)
getSensorProps(&props)
mSensorId = props[0].commonProps.sensorId
```

`AServiceManager_waitForService` tolerates the AIDL service starting later than
the daemon.

### `ensureSession(uid)`

* Returns immediately if a session for `uid` is open and not closed.
* Otherwise closes the old session and waits up to 2 s for
  `onSessionClosed` (the AIDL service refuses `createSession` while a session is
  alive).
* Creates a fresh `AidlCallback` and calls
  `createSession(mSensorId, uid, callback, &session)`.
* Stores `mUserId`, `mSession`, `mCallback`, resets challenge/auth-id state.

The AIDL service's `Session` constructor sets the HAL active group to
`/data/vendor_de/<uid>/fpdata/`. The daemon's `makePath()` creates and chowns
that directory before `setActiveGroup` is called.

### `generateChallenge`

Calls `ISession::generateChallenge()` and waits up to 5 s for
`onChallengeGenerated(challenge)`. The AIDL service implements this as the
legacy `pre_enroll()` call and reports the result through the callback.

### `getHardwareAuthToken(uid, challenge, out)`

Enrollment requires a `HardwareAuthToken` whose `challenge` matches the value
returned by `generateChallenge`. The bridge obtains one from gatekeeper 1.0:

1. Read `/var/lib/sailfish-fpd/gatekeeper_handle` (if any).
2. `IGatekeeper::enroll(uid, currentHandle, currentPassword, newPassword)`.
   * First run: empty handle + empty current password, new password
     `default_password`.
   * Later runs: stored handle + `default_password` as current password.
   * If a credential exists but the handle was lost, call `deleteUser(uid)` and
     retry once (uid is Sailfish-specific, so this is safe).
3. Persist the returned password handle.
4. `IGatekeeper::verify(uid, challenge, newHandle, default_password)`.
5. Copy the 69-byte `hw_auth_token_t` and translate it to the AIDL type:
   * `challenge`, `userId`, `authenticatorId` are machine order;
   * `authenticatorType` and `timestamp` are network order (`be32toh`/`be64toh`);
   * `mac` = 32-byte HMAC.

The log lines worth remembering:

```
[biometry] gk enroll code=0 data=58
[biometry] gk verify code=0 data=69
[biometry] HAT ok (challenge=..., type=0x1000000)
```

`0x1000000` is `HW_AUTH_PASSWORD` in network order. That is the normal
Android enrollment HAT (the user authenticated with the device credential).

### `getParams`

Copies the daemon's callback table under `mLock` and tells the caller whether
`setNotify` has been called. All handlers use this rather than reading the
fields directly.

---

## Callback handlers

| Handler | Action |
|---|---|
| `handleChallengeGenerated(c)` | stores `mChallenge`, sets `mChallengeReady`, wakes `mCond` |
| `handleChallengeRevoked(c)` | no-op |
| `handleAcquired(info, vendor)` | maps `AcquiredInfo` and calls `params.acquired_cb` |
| `handleError(error, vendor)` | maps `Error` and calls `params.error_cb` |
| `handleEnrollmentProgress(id, remaining)` | calls `params.enrollresult_cb`; `remaining == 0` means success |
| `handleAuthenticationSucceeded(id)` | calls `params.authenticated_cb` |
| `handleAuthenticationFailed()` | no-op; the HAL keeps scanning, which is the desired behavior |
| `handleLockout()` | calls `params.error_cb(ERROR_LOCKOUT)` for timed/permanent lockout |
| `handleLockoutCleared()` | no-op |
| `handleInteractionDetected()` | no-op |
| `handleEnrollmentsEnumerated(ids)` | one `params.enumerate_cb` per id |
| `handleEnrollmentsRemoved(ids)` | one `params.removed_cb` per id |
| `handleAuthenticatorIdRetrieved(id)` | stores id, sets `mAuthenticatorIdReady`, wakes `mCond` |
| `handleSessionClosed()` | sets `mSessionClosed`, wakes `mCond` |

### `AidlCallback`

`class AidlCallback : public BnSessionCallback` implements every
`ISessionCallback` method. Each method is a thin forwarder:

```cpp
ndk::ScopedAStatus onAcquired(AcquiredInfo info, int32_t vendorCode) override {
    mOwner->handleAcquired(info, vendorCode);
    return ndk::ScopedAStatus::ok();
}
```

The full set: `onChallengeGenerated`, `onChallengeRevoked`, `onAcquired`,
`onError`, `onEnrollmentProgress`, `onAuthenticationSucceeded`,
`onAuthenticationFailed`, `onLockoutTimed`, `onLockoutPermanent`,
`onLockoutCleared`, `onInteractionDetected`, `onEnrollmentsEnumerated`,
`onEnrollmentsRemoved`, `onAuthenticatorIdRetrieved`,
`onAuthenticatorIdInvalidated`, `onSessionClosed`.

---

## C ABI functions

### `u_hardware_biometry_new`

Allocates `UHardwareBiometry_`, calls `init()`, returns `nullptr` on failure.

### `u_hardware_biometry_setNotify`

Copies `UHardwareBiometryParams` into the object and returns a dummy device id
(`1`). Called by the daemon's `AndroidFP` constructor before any session exists.

### `u_hardware_biometry_preEnroll`

Calls `generateChallenge`; returns the challenge as `uint64_t` or `0`.

### `u_hardware_biometry_enroll`

1. `ensureSession(uid)`.
2. `generateChallenge(&challenge)`.
3. `getHardwareAuthToken(uid, challenge, &hat)`.
4. `mSession->enroll(hat, &cancellation)`.
5. Stores the cancellation signal for `cancel()`.

The AIDL service hard-codes a 60 s enrollment timeout and user id
`mUserId`; the daemon's `gid` argument is ignored.

### `u_hardware_biometry_postEnroll`

Calls `ISession::revokeChallenge(mChallenge)` if a challenge exists.

### `u_hardware_biometry_getAuthenticatorId`

Calls `ISession::getAuthenticatorId()`, waits up to 2 s for
`onAuthenticatorIdRetrieved`, returns the id (0 on timeout).

### `u_hardware_biometry_cancel`

Calls `ICancellationSignal::cancel()` on the last enroll/authenticate signal.
The AIDL service responds with `onError(Error::CANCELED)`; the daemon maps that
to `ERROR_CANCELED`.

### `u_hardware_biometry_enumerate`

Calls `ISession::enumerateEnrollments()`. Results arrive asynchronously through
`onEnrollmentsEnumerated` → `params.enumerate_cb`.

### `u_hardware_biometry_remove`

* `fid != 0`: `mSession->removeEnrollments({fid})`.
* `fid == 0`: currently just calls `enumerateEnrollments()` and returns. This is
  the daemon's "clear all" request; a future improvement is to remember the
  enumerated ids and remove them explicitly. The Settings UI removes individual
  fingers, so this does not affect normal use.

### `u_hardware_biometry_setActiveGroup`

The daemon passes `gid=0` and a path such as
`/data/vendor_de/100000/fpdata`. The bridge parses `100000` with
`parseUserId()` and calls `ensureSession(100000)`. The AIDL service sets the
active group itself from the session's `userId`, so the path argument is used
only to derive the user.

### `u_hardware_biometry_authenticate`

Uses the current `mUserId`, calls `ISession::authenticate(operationId, ...)`,
and stores the cancellation signal. A match produces
`onAuthenticationSucceeded(fid)`; a non-match produces
`onAuthenticationFailed()` (ignored, the HAL continues).

---

## Helpers

### `parseUserId`

Finds `/data/vendor_de/` in the store path, parses the following decimal number.
Falls back to `100000`.

### `readHandle` / `writeHandle`

Read/write `/var/lib/sailfish-fpd/gatekeeper_handle`. `writeHandle` also creates
`/var/lib/sailfish-fpd` (0700) if needed. The daemon runs as root, so this works
under `ProtectSystem=full` (the path is on the writable `/var`).

### `translateHat`

```cpp
out->challenge = hat.challenge;
out->userId = hat.user_id;
out->authenticatorId = hat.authenticator_id;
out->authenticatorType = be32toh(hat.authenticator_type);
out->timestamp.milliSeconds = be64toh(hat.timestamp);
out->mac.assign(hat.hmac, hat.hmac + 32);
```

### `mapAcquired`

AIDL `AcquiredInfo` → `UHardwareBiometryFingerprintAcquiredInfo`:
`GOOD`, `PARTIAL`, `INSUFFICIENT`, `SENSOR_DIRTY`→`ACQUIRED_IMAGER_DIRTY`,
`TOO_SLOW`, `TOO_FAST`, `VENDOR`. Unknown/`START`/`TOO_DARK`/`TOO_BRIGHT` →
`ACQUIRED_GOOD`.

### `mapError`

AIDL `Error` → `UHardwareBiometryFingerprintError`:
`HW_UNAVAILABLE`, `UNABLE_TO_PROCESS`, `TIMEOUT`, `NO_SPACE`, `CANCELED`,
`UNABLE_TO_REMOVE`, `VENDOR`. Unknown/`BAD_CALIBRATION`/`POWER_PRESS` →
`ERROR_NO_ERROR`.

---

## Threading rules

* AIDL calls are made **outside** `mLock`; the lock only protects the state
  fields and callback table.
* `mCond` is used for the challenge and authenticator-id rendezvous.
* `ensureSession` closes the old session without holding the lock, then waits
  for `onSessionClosed` with the lock held by `wait_for`.
* Callbacks run on the binder thread pool; they must never call back into the
  AIDL service synchronously (they only invoke the daemon's C callbacks).
* The daemon's callbacks (`AndroidFP::*`) are simple Qt signal emitters /
  `qDebug`, so they do not block.

---

## Logging

`logMsg()` writes `[biometry] ...` lines to `stderr`, which systemd captures in
`journalctl -u sailfish-fpd-community`. It is intentionally independent of
`ALOG*`, because the Android `logcat` binary is unreliable in this Sailfish
environment (bionic linker TLS issue when not run with `env -i`).

Useful lines:

```
[biometry] init: sensor=0 props=1
[biometry] session created uid=100000
[biometry] generateChallenge
[biometry] challenge=...
[biometry] gk enroll code=0 data=58
[biometry] gk verify code=0 data=69
[biometry] HAT ok (challenge=..., type=0x1000000)
[biometry] ISession::enroll started
[biometry] acquired info=1 vendor=0
[biometry] progress id=... remaining=13
[biometry] auth ok id=...
```
