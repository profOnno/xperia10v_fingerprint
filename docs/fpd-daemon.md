# `sailfish-fpd-community` — daemon reference

Source: `src/sailfish-fpd-community/`
Upstream: <https://github.com/sailfishos-open/sailfish-fpd-community> (GPL-3.0)
Installed: `/usr/bin/sailfish-fpd-community`,
`/usr/lib/systemd/system/sailfish-fpd-community.service`,
`/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf`.

The community daemon merges two roles that Jolla splits between `sailfish-fpd`
and `sailfish-fpd-slave`:

1. the D-Bus API and state machine (`FPDCommunity`);
2. the hardware bridge (`AndroidFP` + `libbiometry_fp_api.so`).

It **provides `sailfish-fpd`**, so the mce module, the
`wait_for_keymaster.service` ordering and the official devicelock fpd plugin all
find the expected service name.

---

## Files

| File | Role |
|---|---|
| `src/sailfish-fpd-community.cpp` | `main()`, `QCoreApplication`, starts `FPDCommunity` |
| `src/fpdcommunity.cpp` | D-Bus object, state machine, finger map, enroll/identify/verify |
| `src/fpdcommunity.h` | `FPDCommunity` class, states, reply enums |
| `src/androidfp.cpp` | `AndroidFP` wrapper over the `u_hardware_biometry_*` ABI |
| `src/hardware/biometry_fp_api.cpp` | `DLSYM` trampolines for the bridge |
| `src/hardware/android_hw_module.h` | selects `libbiometry_fp_api.so` and libhybris |
| `src/bridge/*` | generic libhybris bridge (dlopen/dlsym) |
| `rpm/*.spec` | `droid-biometry-fp` and `sailfish-fpd-community` packaging |

---

## D-Bus API

* Service: `org.sailfishos.fingerprint1`
* Object: `/org/sailfishos/fingerprint1`
* Interface: `org.sailfishos.fingerprint1`
* Policy: `org.sailfishos.fingerprint1.conf` — root owns the name; default
  context may call the interface.

### Methods

| Method | Signature | Notes |
|---|---|---|
| `SetUser` | `uint32` | root only; switches the active user (the daemon calls `setUser(100000)` itself) |
| `Enroll` | `string` | display name, e.g. `finger1`; returns `FPREPLY_*` |
| `Identify` | — | authentication for the lockscreen/mce; emits `Identified` |
| `Verify` | — | authentication in `FPSTATE_VERIFYING`; emits `Verified` |
| `Abort` | — | cancel the current operation |
| `Remove` | `string` | remove one finger by display name |
| `Clear` | — | remove-all request |
| `GetState` | — | returns the state string |
| `GetAll` | — | returns `QStringList` of finger names |

### Signals

| Signal | Meaning |
|---|---|
| `EnrollProgressChanged(int)` | 0–100 |
| `Identified()` | an `Identify` matched |
| `Verified()` | a `Verify` matched |
| `Succeeded()` / `Failed(string)` / `Aborted()` | generic completion |

The exact enums are in `src/fpdcommunity.h`
(`FPREPLY_*`, `FPSTATE_*`, `FPRESULT_*`).

---

## State machine

```
FPSTATE_IDLE
  ├─ Enroll()  → FPSTATE_ENROLLING
  ├─ Identify()→ FPSTATE_IDENTIFYING
  ├─ Verify()  → FPSTATE_VERIFYING
  ├─ Remove()  → FPSTATE_REMOVING
  └─ Clear()   → FPSTATE_REMOVING

ENROLLING   ← onEnrollmentProgress(remaining) … remaining==0 → IDLE
IDENTIFYING ← onAuthenticationSucceeded → IDLE
VERIFYING   ← onAuthenticationSucceeded → IDLE
REMOVING    ← onEnrollmentsRemoved → IDLE
```

`Abort()`/the 120 s timer transitions identifying/verifying back to `IDLE` and
calls `u_hardware_biometry_cancel()`.

---

## Functions

### `FPDCommunity::FPDCommunity`

* Sets `m_cancelTimer` to **120000 ms** (patched from 30 s).
* Connects the timer to `slot_cancelIdentify`.
* Calls `setUser(100000)` (the Sailfish `defaultuser`).
* Registers the D-Bus service.

### `setUser(uid)`

1. Computes the HAL store path via
   `AndroidFP::getDefaultGroupPath(uid)`:
   * API level > 27 → `/data/vendor_de/<uid>/fpdata`
   * older → `/data/system/users/<uid>/fpdata`
2. `makePath(path, "system", "system")` — recursively creates the directory,
   sets 0700 and `system:system`. The daemon runs as root and has
   `CAP_DAC_OVERRIDE`/`CAP_CHOWN` in its unit.
3. Creates `/var/lib/sailfish-fpd-community/<uid>/`.
4. `m_androidFP.setGroup(0, path)` → the bridge parses `<uid>` and opens the AIDL
   session.
5. `enumerate()` — loads the finger map from the HAL and the local DB.

### `makePath`

Recursive `mkdir` + permissions + optional `chown`. The official AIDL service
runs as `system`, so the `fpdata` directory must be writable by `system`.

### `Enroll(finger)`

* Rejects if another D-Bus caller owns the operation (`FPREPLY_ALREADY_BUSY`).
* Rejects duplicate names (`FPREPLY_KEY_ALREADY_EXISTS`).
* Sets `FPSTATE_ENROLLING`, stores `m_addingFinger` and the caller, calls
  `m_androidFP.enroll(100000)`.
* Progress arrives via `enrollresult_cb` → `slot_enrollProgress`.
* On `remaining == 0`, `slot_succeeded(fid)` stores
  `m_fingerMap[fid] = m_addingFinger` and `saveFingers()`.

### `Identify()`

* Requires at least one finger (`FPREPLY_NO_KEYS_AVAILABLE`).
* Sets `FPSTATE_IDENTIFYING`, starts the 120 s timer, calls
  `m_androidFP.authenticate()`.
* On a match, `authenticated_cb` → `slot_authenticated(fid)` emits `Identified`
  and returns to `IDLE`.

### `Verify()`

* Patched: sets `FPSTATE_VERIFYING` and calls
  `m_androidFP.authenticate()`.
* Upstream called `m_androidFP.enroll(100000)`, which started a new enrollment
  instead of verifying.
* On a match, `slot_authenticated` emits `Verified`.

### `Abort()`

* Only accepted from the same D-Bus caller that started the operation.
* Calls `abort()` → `m_androidFP.cancel()`, stops the timer, sets `IDLE`.

Because `dbus-send` exits after the call, its unique name disappears and a later
`Abort` from a new connection is rejected as "already idle". For CLI testing,
restart the daemon to clear a stuck operation; the native UI keeps a persistent
connection and can abort normally.

### `Remove(finger)`

* Looks up `m_fingerMap.key(finger)` → HAL fid.
* Calls `m_androidFP.remove(fid)` → `ISession::removeEnrollments({fid})`.
* On `onEnrollmentsRemoved`, deletes the entry and saves the map.

### `Clear()`

* Calls `m_androidFP.clear()` → `u_hardware_biometry_remove(self, 0, 0)`.
* The bridge currently re-enumerates on `fid == 0` rather than removing all ids
  (see the bridge limitation). Individual removals from Settings work.

### `GetState` / `GetAll`

* `GetState` returns the `FPSTATE_*` string.
* `GetAll` returns `m_fingerMap.values()` — the display names.

### Slots

| Slot | Action |
|---|---|
| `slot_enrollProgress(float)` | emits `EnrollProgressChanged(pc*100)`; in `VERIFYING` it treats progress as a match (upstream behavior) |
| `slot_succeeded(fid)` | enrollment success; stores the name↔fid mapping |
| `slot_authenticated(fid)` | emits `Verified` or `Identified` based on state; sets `IDLE` |
| `slot_failed(QString)` | emits `Failed`, sets `IDLE` |
| `slot_acquired(int)` | emits the acquired guidance signal |
| `slot_cancelIdentify()` | 120 s timeout; cancels and returns to `IDLE` |
| `slot_enumerated()` | loads the finger map after enumeration |

---

## `AndroidFP` (hardware wrapper)

`AndroidFP` is a thin Qt wrapper around the C ABI:

| Method | C call |
|---|---|
| `setGroup(gid, path)` | `u_hardware_biometry_setActiveGroup` |
| `enroll(uid)` | `u_hardware_biometry_enroll(gid=0, timeout=60, uid)` |
| `authenticate()` | `u_hardware_biometry_authenticate(0, gid=0)` |
| `cancel()` | `u_hardware_biometry_cancel` |
| `enumerate()` | `u_hardware_biometry_enumerate` |
| `remove(fid)` | `u_hardware_biometry_remove(gid=0, fid)` |
| `clear()` | `u_hardware_biometry_remove(gid=0, fid=0)` |
| `fingerprints()` | returns the ids collected by `enumerate_cb` |

The callbacks (`enrollresult_cb`, `acquired_cb`, `authenticated_cb`,
`error_cb`, `removed_cb`, `enumerate_cb`) translate the C structures into Qt
signals (`enrollCallback`, `acquiredCallback`, `authenticated`, `failed`,
`removed`, `enumerated`).

---

## Loading the bridge

`src/hardware/android_hw_module.h`:

```cpp
static const char* path() { return "libbiometry_fp_api.so"; }
```

`src/bridge/bridge.h` calls `android_dlopen(path, RTLD_LAZY)` from
`libhybris-common`. The library is installed at:

```
/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so
```

which is in libhybris's search path. The bridge then links the vendor AIDL
libraries from `/vendor/lib64` (`android.hardware.biometrics.fingerprint-V4-ndk`,
`...common-V4-ndk`, `...keymaster-V4-ndk`, gatekeeper 1.0) and the system
libraries from `/system/lib64` (`libbinder_ndk`, `liblog`).

`DLSYM` resolves the `u_hardware_biometry_*` symbols lazily; a missing symbol
would crash the daemon, so the bridge RPM must be installed before the daemon
starts. The dependency is expressed in the spec
(`Requires: droid-biometry-fp`).

---

## Local patches (see `patches/`)

| Patch | Why |
|---|---|
| `m_cancelTimer.setInterval(120000)` | 30 s was too short for the lockscreen identify, especially while the screen was waking |
| `Verify` → `authenticate()` | upstream started an enrollment, so the CSD `Verify`/Settings verify path never authenticated |
| `After=wait_for_keymaster.service` | the daemon needs gatekeeper/keymaster for the enrollment HAT |
| spec fixes | `libhybris-devel`/`desktop-file-utils` are not in the target; the bridge spec's `%build` must clear its extracted tree before re-extracting |

---

## Service unit

`/usr/lib/systemd/system/sailfish-fpd-community.service`:

```ini
[Unit]
Description=Community Fingerprint Daemon
DefaultDependencies=no
Requires=dbus.socket
After=dbus.socket local-fs.target droid-hal-init.service
After=droid-late-start.service wait_for_keymaster.service
Conflicts=shutdown.target

[Service]
Type=dbus
BusName=org.sailfishos.fingerprint1
ExecStartPre=/bin/sh -c '/usr/bin/test -f /run/systemd/boot-status/init-done || sleep 5 || :'
ExecStart=/usr/bin/sailfish-fpd-community
Restart=always
CapabilityBoundingSet=CAP_BLOCK_SUSPEND CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_IPC_LOCK
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
```

`ProtectSystem=full` makes `/usr`, `/boot`, `/etc` read-only; `/var` and `/data`
remain writable, which is where the daemon and bridge store their data.
