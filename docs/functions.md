# Function and script index

This is the quick lookup table. The detailed explanations are in the linked
documents.

---

## 1. AIDL bridge C ABI

File: `src/lineage/hardware/sony/biometry/biometry_fp_aidl_for_hybris.cpp`
Header: `src/lineage/hardware/sony/biometry/biometry.h`

These are the symbols `sailfish-fpd-community` resolves through libhybris.

| Function | What it does | Details |
|---|---|---|
| `u_hardware_biometry_new()` | Creates the bridge object, starts the binder thread pool, connects to `IFingerprint/default`, reads `sensorId` | [link](biometry-bridge.md#u_hardware_biometry_new) |
| `u_hardware_biometry_setNotify()` | Stores the daemon's callback table (enroll/acquired/auth/error/removed/enumerate) | [link](biometry-bridge.md#u_hardware_biometry_setnotify) |
| `u_hardware_biometry_preEnroll()` | Asks the HAL for a `pre_enroll()` challenge, returns it | [link](biometry-bridge.md#u_hardware_biometry_preenroll) |
| `u_hardware_biometry_enroll()` | Creates/reuses the session, gets a challenge + gatekeeper HAT, calls `ISession::enroll()` | [link](biometry-bridge.md#u_hardware_biometry_enroll) |
| `u_hardware_biometry_postEnroll()` | Revokes the last challenge (`ISession::revokeChallenge`) | [link](biometry-bridge.md#u_hardware_biometry_postenroll) |
| `u_hardware_biometry_getAuthenticatorId()` | Calls `getAuthenticatorId()` and waits for the callback | [link](biometry-bridge.md#u_hardware_biometry_getauthenticatorid) |
| `u_hardware_biometry_cancel()` | Calls `ICancellationSignal::cancel()` on the last enroll/auth operation | [link](biometry-bridge.md#u_hardware_biometry_cancel) |
| `u_hardware_biometry_enumerate()` | Calls `ISession::enumerateEnrollments()` | [link](biometry-bridge.md#u_hardware_biometry_enumerate) |
| `u_hardware_biometry_remove()` | Removes one enrollment id; `fid == 0` currently only re-enumerates | [link](biometry-bridge.md#u_hardware_biometry_remove) |
| `u_hardware_biometry_setActiveGroup()` | Parses `/data/vendor_de/<uid>/fpdata` and creates the AIDL session for that user | [link](biometry-bridge.md#u_hardware_biometry_setactivegroup) |
| `u_hardware_biometry_authenticate()` | Calls `ISession::authenticate(operationId)` for identify/verify | [link](biometry-bridge.md#u_hardware_biometry_authenticate) |

---

## 2. Bridge internals

| Function | What it does | Details |
|---|---|---|
| `UHardwareBiometry_::init()` | Starts `ABinderProcess` thread pool, waits for the AIDL service, gets `IFingerprint`, queries `getSensorProps` | [link](biometry-bridge.md#init) |
| `UHardwareBiometry_::ensureSession(uid)` | Closes an old session if needed, calls `IFingerprint::createSession`, stores the callback | [link](biometry-bridge.md#ensuresession) |
| `UHardwareBiometry_::generateChallenge()` | Calls `ISession::generateChallenge()` and waits up to 5 s for `onChallengeGenerated` | [link](biometry-bridge.md#generatechallenge) |
| `UHardwareBiometry_::getHardwareAuthToken()` | Gatekeeper enroll/verify → 69-byte HAT → AIDL `HardwareAuthToken`; persists the handle | [link](biometry-bridge.md#gethardwareauthtoken) |
| `UHardwareBiometry_::getParams()` | Copies the callback table under the mutex | [link](biometry-bridge.md#getparams) |
| `UHardwareBiometry_::handle*()` | Maps AIDL callbacks to the daemon's C callbacks | [link](biometry-bridge.md#callback-handlers) |
| `AidlCallback::on*()` | Thin `ISessionCallback` implementation that forwards to `UHardwareBiometry_` | [link](biometry-bridge.md#aidlcallback) |
| `parseUserId()` | Extracts `100000` from `/data/vendor_de/100000/fpdata` | [link](biometry-bridge.md#helpers) |
| `readHandle()` / `writeHandle()` | Reads/writes `/var/lib/sailfish-fpd/gatekeeper_handle` | [link](biometry-bridge.md#helpers) |
| `translateHat()` | `hw_auth_token_t` → AIDL `HardwareAuthToken` (network-order fields) | [link](biometry-bridge.md#helpers) |
| `mapAcquired()` / `mapError()` | AIDL enums → `UHardwareBiometry*` enums | [link](biometry-bridge.md#helpers) |

---

## 3. sailfish-fpd-community

File: `src/sailfish-fpd-community/src/fpdcommunity.cpp`,
`src/sailfish-fpd-community/src/androidfp.cpp`

| Function | What it does | Details |
|---|---|---|
| `FPDCommunity::FPDCommunity()` | Sets the 120 s cancel timer and calls `setUser(100000)` | [link](fpd-daemon.md) |
| `FPDCommunity::setUser(uid)` | Creates the HAL store path and the local finger-map dir; calls `setGroup(0, path)` and `enumerate()` | [link](fpd-daemon.md) |
| `FPDCommunity::Enroll(finger)` | Starts an enrollment and records the D-Bus caller | [link](fpd-daemon.md) |
| `FPDCommunity::Identify()` | Starts authentication for the lockscreen/mce | [link](fpd-daemon.md) |
| `FPDCommunity::Verify()` | Starts authentication for the verify path (patched; upstream used enroll) | [link](fpd-daemon.md) |
| `FPDCommunity::Abort()` | Cancels the current operation (only from the same D-Bus caller) | [link](fpd-daemon.md) |
| `FPDCommunity::Remove(finger)` | Maps the name to the HAL fid and removes it | [link](fpd-daemon.md) |
| `FPDCommunity::GetState()` / `GetAll()` | Exposes the state and finger names | [link](fpd-daemon.md) |
| `FPDCommunity::slot_*()` | State-machine callbacks for acquired, progress, success, failure, enumeration | [link](fpd-daemon.md) |
| `AndroidFP::*` | C++ wrapper around the `u_hardware_biometry_*` C ABI | [link](fpd-daemon.md) |

Patched lines:

| Change | Location |
|---|---|
| 30 s → 120 s identify timeout | `m_cancelTimer.setInterval(120000)` |
| `Verify` now authenticates | `m_androidFP.authenticate()` |
| start after keymaster | `sailfish-fpd-community.service` |

---

## 4. Scripts

| Script | What it does | Details |
|---|---|---|
| `build-android-bridge.sh` | `lunch lineage_pdx235-ap4a-userdebug` + `m libbiometry_fp_api` | [link](scripts.md) |
| `build-bridge-rpm.sh` | Stages the `.so`, builds `droid-biometry-fp` with `mb2` | [link](scripts.md) |
| `build-daemon-rpm.sh` | Builds `sailfish-fpd-community` with `mb2` | [link](scripts.md) |
| `install-fpd.sh` | Installs both RPMs and creates `/data/vendor_de/100000/fpdata` | [link](scripts.md) |
| `setup-ssh-key.sh` | Installs an SSH key on the phone for passwordless later runs | [link](scripts.md) |
| `prepare-phone.sh` | Downloads/verifies Jolla RPMs and copies everything to the phone | [link](scripts.md) |
| `extract-jolla-overlay.sh` | Extracts the Jolla plugin/library from the official RPMs | [link](scripts.md) |
| `install-devicelock-overlay.sh` | Installs the official devicelock fpd overlay and switches lipstick | [link](scripts.md) |
| `test-fpd.sh` | D-Bus state/GetAll/Enroll/Identify and journal output | [link](scripts.md) |
| `deploy.sh` | Calls `install-fpd.sh` + `install-devicelock-overlay.sh` | [link](scripts.md) |
| `build-meta-rpm.sh` | Builds the single `xperia10v-fingerprint` RPM + `dist/install.sh` | [link](scripts.md) |
| `installer/install.sh` | Phone-side validation/warning/confirmation wrapper (not host) | [link](meta-rpm.md) |

---

## 5. D-Bus surface

`org.sailfishos.fingerprint1` at `/org/sailfishos/fingerprint1`:

| Method / signal | Meaning |
|---|---|
| `SetUser(uint32)` | Root-only; switch the active user |
| `Enroll(string)` | Start enrollment; returns `FPREPLY_*` |
| `Identify()` | Start authentication; emits `Identified` on match |
| `Verify()` | Start authentication in `FPSTATE_VERIFYING`; emits `Verified` |
| `Abort()` | Cancel the current operation |
| `Remove(string)` | Remove a finger by display name |
| `Clear()` | Remove-all request (see bridge limitation) |
| `GetState()` | `FPSTATE_IDLE`, `FPSTATE_ENROLLING`, `FPSTATE_IDENTIFYING`, ... |
| `GetAll()` | `QStringList` of finger names |
| `EnrollProgressChanged(int)` | 0–100 progress |
| `Identified()` / `Verified()` / `Failed()` / `Aborted()` | Result signals |

The complete method/state description is in
[`fpd-daemon.md`](fpd-daemon.md).
