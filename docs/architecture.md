# Global architecture

This document describes the complete working principle of fingerprint support on
the Sony Xperia 10 V (`pdx235`, `XQ-DC72`) under Sailfish OS 5.1.0.11 with a
LineageOS 22.2 / Android 15 vendor base.

The important idea is that **nothing in the Android side was replaced**. The
phone already had a working sensor, driver, vendor HAL and Android AIDL service.
Sailfish was missing the userspace pieces, and the community fpd daemon only knew
how to speak HIDL 2.1. The solution is a small AIDL bridge plus the official
devicelock fpd plugin.

---

## 1. Layer map

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 4. Sailfish UI                                                          │
│    Settings → Device Lock → Fingerprint        Lockscreen / mce        │
│                       │                              │                 │
│                       ▼                              │                 │
│    lipstick devicelock plugin: encsfa-fpd            │                 │
│    (loads the official Jolla fpd plugin)             │                 │
│                       │                              │                 │
│                       ▼                              │                 │
│    sailfish-devicelock-encsfa-fpd                    │                 │
│    org.nemomobile.devicelock                         │                 │
│    • device lock / authentication                    │                 │
│    • fingerprint service (enroll/identify/remove)    │                 │
└───────────────────────┼──────────────────────────────┼─────────────────┘
                        │ D-Bus                        │ D-Bus
                        │ org.sailfishos.fingerprint1   │
                        ▼                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 3. sailfish-fpd-community (GPL, /usr/bin/sailfish-fpd-community)        │
│    • D-Bus API and policy: org.sailfishos.fingerprint1                  │
│    • state machine: IDLE / ENROLLING / IDENTIFYING / VERIFYING / ...    │
│    • finger map: HAL fid ↔ display name                                 │
│    • android_dlopen("libbiometry_fp_api.so") via libhybris              │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ C ABI u_hardware_biometry_*
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. libbiometry_fp_api.so (bionic, built in the Lineage tree)            │
│    • binder thread pool (ABinderProcess_startThreadPool)                │
│    • IFingerprint / ISession AIDL V4 client                             │
│    • gatekeeper 1.0 → HardwareAuthToken                                 │
│    • C ABI expected by sailfish-fpd-community                           │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ AIDL / IBInder
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. android.hardware.biometrics.fingerprint-service.lineage              │
│    • android.hardware.biometrics.fingerprint.IFingerprint/default        │
│    • AIDL V4 Session, legacy fingerprint_device_t translation          │
└───────────────────────────────┬─────────────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 0. /vendor/lib64/hw/fingerprint.default.so                              │
│    • legacy fingerprint HAL 2.1                                         │
│    • Egis HIDL 4.0 IBiometricsFingerprintBix/Rbs                        │
│    • /dev/esfp0 (EGISFP kernel driver, soc:fp_egistec)                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Why each layer exists

### 0. EgisTec sensor and vendor HAL

`/dev/esfp0` is created by the `fp_egistec` platform driver. The vendor HAL is
`/vendor/lib64/hw/fingerprint.default.so`; it implements the legacy
`fingerprint_device_t` API (HAL module version 2.1) and internally talks to the
Egis HIDL 4.0 service (`vendor.egistec.hardware.fingerprint@4.0`). The AIDL
service opens it with `hw_get_module(FINGERPRINT_HARDWARE_MODULE_ID)`.

### 1. Lineage AIDL V4 service

`android.hardware.biometrics.fingerprint-service.lineage` is a normal Android
service that:

* implements `IFingerprint` / `ISession` AIDL V4;
* opens the legacy HAL and translates AIDL calls to `pre_enroll`, `enroll`,
  `authenticate`, `enumerate`, `remove`, `get_authenticator_id`;
* sets the active group to `/data/vendor_de/<userId>/fpdata/`;
* forwards HAL `notify()` events to the AIDL `ISessionCallback`.

It is registered as `android.hardware.biometrics.fingerprint.IFingerprint/default`
on the **framework** binder (`/dev/binder`).

### 2. AIDL bridge (`libbiometry_fp_api.so`)

The community daemon expects the Ubuntu Touch `libbiometry_fp_api` C ABI:

```c
UHardwareBiometry u_hardware_biometry_new();
uint64_t u_hardware_biometry_setNotify(...);
uint64_t u_hardware_biometry_preEnroll(...);
UHardwareBiometryRequestStatus u_hardware_biometry_enroll(...);
...
```

The bridge implements those symbols on top of the AIDL service instead of
HIDL 2.1. It is a **bionic** shared library, loaded into the glibc daemon by
libhybris's `android_dlopen()`.

Two non-obvious requirements:

1. **Binder thread pool.** `ISessionCallback` methods are synchronous binder
   calls. The HAL's REE worker thread calls `onAcquired` and waits for the client
   to process it. If the bridge has no binder thread pool, the client has no
   thread to receive the callback while the main thread is idle and the HAL
   stalls after `ISession::enroll started`. `ABinderProcess_startThreadPool()`
   in `init()` fixes this.
2. **Gatekeeper HAT.** AIDL V4 `ISession::enroll()` requires a
   `HardwareAuthToken` tied to the `generateChallenge()` challenge. The bridge
   obtains it from `android.hardware.gatekeeper@1.0` using a synthetic
   `default_password` credential and stores the password handle in
   `/var/lib/sailfish-fpd/gatekeeper_handle` so later enrollments can re-enroll.

### 3. `sailfish-fpd-community`

The community daemon implements Jolla's `org.sailfishos.fingerprint1` API. It
owns the enroll/identify/verify state machine, the D-Bus policy, the finger
name↔HAL id map and the bridge loading. It runs as root and writes:

* `/var/lib/sailfish-fpd-community/<uid>/fingerprints.db` — name↔id map;
* `/data/vendor_de/<uid>/fpdata/` — the path handed to the HAL
  (`system:system`, created by `makePath`);
* `/var/lib/sailfish-fpd/gatekeeper_handle` — gatekeeper credential handle
  (written by the bridge).

Local changes (see `patches/`):

* identify timeout 30 s → 120 s;
* `Verify` calls `authenticate()` (upstream called `enroll()`);
* unit ordering after `wait_for_keymaster.service`.

### 4. mce and the devicelock/lipstick plugin

Two independent consumers:

* **mce** loads `/usr/lib64/mce/modules/fingerprint.so`. It listens to the
  display/keyguard/device-lock datapipes and uses the fingerprint for
  **screen-off wakeup** when `/system/osso/dsm/fingerprint/mode` is `1`
  (`always`), `2` (`proximity`) or `0` (`never`). The mode is set by
  `/etc/mce/60-fingerprint-sensor.conf` and can be changed with
  `mcetool --set-fingerprint-wakeup-mode=...`.
* **lipstick** loads the device-lock plugin named in
  `/usr/share/lipstick/devicelock/devicelock.conf`. The port's default was
  `encpartition` (no fingerprint). The official Jolla `encsfa-fpd` plugin adds
  the fingerprint unlock UI and talks to the devicelock daemon.

The devicelock daemon is the official `sailfish-devicelock-encsfa-fpd`
(`/usr/lib64/qt5/plugins/devicelock/encsfa-fpd --daemon`). It provides
`org.nemomobile.devicelock`, including the fingerprint service. The port's old
`jolla-devicelock-encsfa` daemon has no fingerprint backend and is disabled.

The official `sailfish-devicelock-fpd` RPM conflicts with the port's
`jolla-devicelock-plugin-encsfa`, so the binary/library/config are installed as
an **overlay** instead of via zypper. See `overlay/README.md`.

---

## 3. Enrollment sequence

```
UI / devicelock daemon
  → org.sailfishos.fingerprint1.Enroll("fingerN")
      → fpd daemon state = ENROLLING
      → bridge ensureSession(100000)
      → AIDL IFingerprint.createSession(sensor=0, user=100000)
           AIDL service sets active group /data/vendor_de/100000/fpdata/
      → ISession.generateChallenge()
           legacy HAL pre_enroll() → challenge
      → bridge getHardwareAuthToken(uid, challenge)
           gatekeeper.enroll(uid, handle?, "default_password")
           gatekeeper.verify(uid, challenge, handle, "default_password")
           → 69-byte hw_auth_token_t → AIDL HardwareAuthToken
      → ISession.enroll(HAT)
           AIDL service translates HAT → legacy HAL enroll()
      → HAL captures samples
           onAcquired / onEnrollmentProgress → bridge callbacks
      → daemon updates progress
      → remaining == 0
           onEnrollmentProgress(fid, 0)
           daemon stores fid ↔ "fingerN"
```

The HAL's enrollment timeout is 60 s (hard-coded in the Lineage service). Each
good touch reduces `remaining` by one; typically 14 samples are needed. Shifting
the fingertip between touches produces a useful template; repeated identical
placements are reported as `BIX_FTX_REDUNDANT` and yield a narrow template.

## 4. Authentication / unlock sequences

### Screen on, lockscreen

```
lipstick devicelock plugin
  → org.sailfishos.fingerprint1.Identify
      → bridge ISession.authenticate(0)
      → HAL captures, compares, sends onAuthenticationSucceeded(fid)
      → bridge auth ok callback
      → daemon emits Identified
      → lipstick unlocks
```

The lipstick plugin is what makes the native lockscreen work. It only exists
after `devicelock.conf` points to `encsfa-fpd` **and** lipstick has been
restarted with the new plugin.

### Screen off / wakeup

```
sensor touch
  → mce fingerprint module
      fpwakeup_evaluate_allowed():
        system_state == USER
        fpd_service_state == RUNNING
        enrolled fingerprints exist
        wakeup mode != never
        powerkey_pressed == false
        lid open
        display OFF/LPM_OFF (or ON/DIM with unlocked + tklock)
  → Identify
  → match → display wakes
```

Do not press the power key while using screen-off wakeup: `powerkey_pressed`
disables the path.

---

## 5. Data paths

| Path | Purpose |
|---|---|
| `/dev/esfp0` | sensor character device (`system:system`, 0660) |
| `/vendor/lib64/hw/fingerprint.default.so` | vendor legacy HAL |
| `/data/vendor_de/100000/fpdata/` | HAL per-user template/cache directory (`system:system`) |
| `/var/lib/sailfish-fpd-community/100000/fingerprints.db` | fpd name↔id map |
| `/var/lib/sailfish-fpd/gatekeeper_handle` | gatekeeper password handle for enrollment HAT |
| `/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so` | AIDL bridge, loaded via libhybris |
| `/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf` | D-Bus policy from the community daemon |
| `/etc/mce/60-fingerprint-sensor.conf` | `mode=1` (wakeup always) |
| `/usr/share/lipstick/devicelock/devicelock.conf` | `pluginName=.../encsfa-fpd` |

---

## 6. Boot order

```
droid-hal-init / Android late_start
  └─ vendor.fingerprint-default (AIDL V4 service)
       ▲
       │ waits for service
wait_for_keymaster.service
  └─ sailfish-fpd-community.service
       ▲
       │ After/Wants
sailfish-devicelock-encsfa-fpd.service
  └─ org.nemomobile.devicelock + fingerprint service
       ▲
       │ user session
lipstick.service (loads encsfa-fpd plugin)
  └─ Settings + lockscreen
```

The community unit has `After=wait_for_keymaster.service`; the devicelock fpd
unit has `After/Wants=sailfish-fpd-community.service`. The AIDL bridge calls
`AServiceManager_waitForService()` so a late AIDL service is tolerated.

---

## 7. Failure modes and why the workarounds exist

| Symptom | Root cause | Fix |
|---|---|---|
| HAL logs `onAcquired(1,0)` then stalls | AIDL callback is synchronous; the daemon had only its main thread | `ABinderProcess_startThreadPool()` in the bridge |
| `Enroll` stays `ENROLLING` | identify/enroll callbacks never delivered | same thread-pool fix |
| `ISession::enroll` returns but no progress | gatekeeper HAT invalid or challenge mismatch | gatekeeper enroll/verify logging; handle persistence |
| `BIX_FTM_NOT_MATCH`, `score=0` | template too narrow (redundant enrollment samples) | re-enroll with varied fingertip positions |
| `Identify` times out at 30 s | community daemon timer too short | 120 s |
| Native Settings/lockscreen absent | port's devicelock plugin is `encpartition` (no fingerprint) | install the official `encsfa-fpd` overlay + config + lipstick restart |
| devicelock fpd starts but offers no fingerprint | started before fpd exists | `After/Wants=sailfish-fpd-community` |
| Touch wakes then blanks | user pressed power key / display timeout | don't press power key; use screen-off wakeup or keep screen on |
