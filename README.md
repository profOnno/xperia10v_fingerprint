# Xperia 10 V — fingerprint unlock for Sailfish OS

Working fingerprint **enrollment** and **lockscreen unlock** on the Sony Xperia 10 V
(`XQ-DC72` / `pdx235`) running the Sailfish OS **5.1.0.11** community port on top of
**LineageOS 22.2 / Android 15**.

> Unofficial community project. Not affiliated with Jolla, Sony or EgisTec.
> Jolla's proprietary devicelock binaries are not included; see
> [Licenses / provenance](#licenses--provenance).

| | |
|---|---|
| Device | Sony Xperia 10 V, `XQ-DC72`, `pdx235`, Sailfish model `xqdc72 / community` |
| Sailfish | 5.1.0.11 (Pispala), aarch64 |
| Android base | LineageOS 22.2 / Android 15 (`ro.build.version.sdk=35`) |
| Sensor | EgisTec side sensor, `/dev/esfp0` (`soc:fp_egistec`) |
| Vendor HAL | `/vendor/lib64/hw/fingerprint.default.so` (legacy HAL 2.1) |
| Android service | Lineage AIDL V4 `android.hardware.biometrics.fingerprint.IFingerprint/default` |
| Keymaster/Gatekeeper | keymaster 4.1 + gatekeeper 1.0 |
| Status | enrollment, identify, native lockscreen unlock and screen-off wakeup verified |

---

## The problem

The phone hardware and the complete Android fingerprint stack were already working.
Sailfish OS, however, had no fingerprint daemon and no breadcrumb for the port:

* `sailfish-fpd.service` was `not-found`
* no `org.sailfishos.fingerprint1` on the D-Bus system bus
* the Settings → Device Lock fingerprint page was hidden
* the lockscreen had no fingerprint provider

Jolla's closed `sailfish-fpd` needs a device-specific closed `sailfish-fpd-slave`,
which does not exist for this community port. The community daemon
[`sailfish-fpd-community`](https://github.com/sailfishos-open/sailfish-fpd-community)
implements the Jolla D-Bus API, but its hardware bridge targets **HIDL 2.1**.
This phone only exposes the newer **AIDL V4** service, so a new bridge was needed.

---

## Global working principle

```
 ┌──────────────────────────────────────────────────────────────────┐
 │ Sailfish UI                                                      │
 │  Settings → Device Lock → Fingerprint      Lockscreen            │
 │            │                                   │                 │
 │            └──────────────┬────────────────────┘                 │
 │                           ▼                                      │
 │        lipstick devicelock plugin (encsfa-fpd)                   │
 │                           │                                      │
 │                           ▼                                      │
 │        sailfish-devicelock-encsfa-fpd  ← official devicelock     │
 │        (org.nemomobile.devicelock)        daemon, fingerprint    │
 │                           │                service               │
 └───────────────────────────┼──────────────────────────────────────┘
                             │ D-Bus org.sailfishos.fingerprint1
                             ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ sailfish-fpd-community                                           │
 │  • D-Bus API: Enroll / Identify / Verify / Abort / Remove / ...  │
 │  • enroll/identify state machine, finger map                     │
 │  • android_dlopen("libbiometry_fp_api.so") via libhybris         │
 └───────────────────────────┬──────────────────────────────────────┘
                             │ C ABI u_hardware_biometry_*
                             ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ libbiometry_fp_api.so  (bionic, built in the Lineage tree)       │
 │  • binder thread pool                                            │
 │  • IFingerprint / ISession AIDL V4 client                        │
 │  • gatekeeper 1.0 → HardwareAuthToken for enrollment             │
 └───────────────────────────┬──────────────────────────────────────┘
                             │ AIDL / IBInder
                             ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ android.hardware.biometrics.fingerprint-service.lineage          │
 │  • IFingerprint/default   (AIDL V4)                              │
 │  • legacy fingerprint_device_t API                               │
 └───────────────────────────┬──────────────────────────────────────┘
                             ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ /vendor/lib64/hw/fingerprint.default.so                          │
 │  Egis HIDL 4.0 (IBiometricsFingerprintBix/Rbs)                   │
 │                           │                                      │
 │                           ▼                                      │
 │                    /dev/esfp0  (EGISFP kernel driver)            │
 └──────────────────────────────────────────────────────────────────┘
```

A second, independent path is used for **screen-off wakeup**:

```
mce  ── D-Bus org.sailfishos.fingerprint1 ──► sailfish-fpd-community
```

mce reads `/system/osso/dsm/fingerprint/mode=1` (wakeup mode `always`). When the
display is off, a sensor touch makes mce issue `Identify`; a match wakes the
device. On-screen lockscreen unlock is handled by the lipstick/devicelock path
above.

### Enrollment

1. `lipstick`/Settings asks the devicelock daemon to enroll.
2. The devicelock daemon calls `org.sailfishos.fingerprint1.Enroll("fingerN")`.
3. `sailfish-fpd-community` opens an AIDL session for user `100000` and calls
   `ISession.generateChallenge()`.
4. The service returns a `pre_enroll()` challenge.
5. The bridge gets a **HardwareAuthToken** for that challenge from
   `android.hardware.gatekeeper@1.0` (using a stored synthetic credential handle).
6. The bridge calls `ISession.enroll(HAT)`.
7. The AIDL service forwards the token to the legacy Egis HAL.
8. The HAL captures finger images and sends `onAcquired` / `onEnrollmentProgress`.
9. The bridge forwards them over the C ABI; the daemon updates progress and, at
   `remaining=0`, records the fingerprint id/name in
   `/var/lib/sailfish-fpd-community/100000/fingerprints.db`.

The critical detail is that the AIDL callback is a **synchronous binder call from
the HAL's worker thread**. The bridge must run a binder thread pool or the DAemon
has no thread to receive the callback and the HAL blocks after the first
`onAcquired`.

### Unlocking (screen on)

1. The lockscreen (lipstick devicelock plugin) calls `Identify`.
2. The daemon calls `ISession.authenticate(0)`.
3. The HAL captures and compares against the enrolled templates.
4. On a match the service sends `onAuthenticationSucceeded(id)`, the bridge maps
   it to the C callback, and the daemon emits `Identified`.
5. The lipstick plugin unlocks the device.

### Unlocking (screen off)

1. mce sees a sensor touch while `display_state` is `OFF`/`LPM_OFF`.
2. `fpwakeup_evaluate_allowed()` requires: user mode, fpd running, enrolled
   fingerprints, wakeup mode not `never`, power key **not** pressed, lid open.
3. mce calls `Identify`; a match wakes the display. The lockscreen then uses the
   normal screen-on path if needed.

> Important: do not press the power key while relying on screen-off wakeup.
> `powerkey_pressed == true` disables mce's fingerprint wakeup path.

---

## Repository layout

```
.
├── README.md
├── dist/                         # single RPM + split RPMs + bridge .so + install.sh
├── docs/
│   ├── README.md                 # documentation index
│   ├── file-map.md               # every repository file + installed path
│   ├── architecture.md           # detailed global principle and data paths
│   ├── functions.md              # function/script index
│   ├── biometry-bridge.md        # function-by-function AIDL bridge reference
│   ├── fpd-daemon.md             # community daemon API and patches
│   ├── scripts.md                # every script explained
│   ├── meta-rpm.md               # single-RPM installer and validation
│   ├── system-integration.md     # units, config, overlay, boot order
│   └── troubleshooting.md        # the failures we hit and their fixes
├── installer/install.sh          # phone-side single-RPM validation/warning wrapper
├── packaging/xperia10v-fingerprint.spec
├── overlay/                      # devicelock unit/config (Jolla binaries not tracked)
│   ├── encsfa-fpd
│   ├── libsailfishdevicelock.so.1.2.0
│   ├── devicelock.conf
│   ├── sailfish-devicelock-encsfa-fpd.service
│   └── README.md
├── patches/
│   ├── sailfish-fpd-community.patch
│   └── README.md
├── scripts/
│   ├── build-android-bridge.sh
│   ├── build-bridge-rpm.sh
│   ├── build-daemon-rpm.sh
│   ├── build-meta-rpm.sh
│   ├── install-fpd.sh
│   ├── install-devicelock-overlay.sh
│   ├── test-fpd.sh
│   └── deploy.sh
└── src/
    ├── lineage/hardware/sony/biometry/   # new Android module
    │   ├── Android.bp
    │   ├── biometry.h
    │   └── biometry_fp_aidl_for_hybris.cpp
    └── sailfish-fpd-community/           # modified GPL daemon source
```

---

## End-user install (single RPM)

Download the end-user files from the GitHub release, or build them (see
[Build from source](#build-from-source)):

```text
xperia10v-fingerprint-1.0-8.aarch64.rpm
install.sh
```

You also need two **official Jolla packages** (Jolla proprietary; they are not
redistributed with this project):

```text
sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
```

Download them from the Jolla 5.1.0.11 aarch64 repository
(`releases.jolla.com/releases/5.1.0.11/jolla/aarch64/`). The installer accepts
either the two RPMs or the two files extracted from them (see
[`overlay/README.md`](overlay/README.md)).

### 0. Or prepare everything from a computer

`scripts/prepare-phone.sh` downloads the two Jolla packages from the 5.1.0.11
repository, verifies them against Jolla's signed repository metadata
(GPG signature on `repomd.xml`, then SHA256 of the RPMs), and copies the
result plus the built RPM and `install.sh` to the phone:

```bash
# asks for the IP shown in Settings -> Developer tools -> SSH,
# then the SSH password (neither is stored)
./scripts/prepare-phone.sh --ask
```

For repeated development runs, install an SSH key once and reuse it:

```bash
./scripts/setup-ssh-key.sh
SSH_KEY=~/.ssh/id_ed25519_xperia10v ./scripts/prepare-phone.sh
```

The key is a **developer convenience**, not part of the end-user install: the
private key stays on your host, the public key goes into the phone's
`~/.ssh/authorized_keys`, and uninstalling the RPM does not remove it. It is
created without a passphrase, so anyone who can read the key can log in as
`defaultuser` (but not root — `devel-su` still needs the device code). For an
end-user machine, use the password path, or use your own passphrase-protected
key with `SSH_KEY=...`.

Then continue with step 2. The signing key fingerprint is pinned in the script
(`BE6885DC16FA9420BA2DA558CB2904D42F7DA79C`); override `JOLLA_KEY_FPR` only if
Jolla rotates its release key. `install.sh` re-checks `jolla/SHA256SUMS` on the
phone to catch copy corruption; the authoritative verification is the GPG +
metadata check on the host.

Do not `export PHONE_PW=...`: it stays in the shell environment and in shell
history. `--ask` reads it silently with `read -rsp` **inside the script**, so
it is not echoed, not in history, and gone when the script exits.
`prepare-phone.sh` passes it to `sshpass -e`, so it is never visible in `ps`.
If you exported it in your shell instead, run `unset PHONE_PW SSHPASS` and
remove the `export` line from your history.

### 1. Copy the files from a computer

`prepare-phone.sh` does this automatically. Manually:

```bash
ssh defaultuser@phone 'mkdir -p /home/defaultuser/xperia10v-fingerprint/jolla'

scp xperia10v-fingerprint-1.0-8.aarch64.rpm install.sh \
    defaultuser@phone:/home/defaultuser/xperia10v-fingerprint/

# extract on the host (the phone image has no cpio)
./scripts/extract-jolla-overlay.sh /path/to/jolla-rpms
scp overlay/encsfa-fpd overlay/libsailfishdevicelock.so.1.2.0 \
    overlay/SHA256SUMS \
    defaultuser@phone:/home/defaultuser/xperia10v-fingerprint/jolla/
```

The RPM and `install.sh` must be in the same directory; the wrapper picks the
newest `xperia10v-fingerprint-*.aarch64.rpm` next to itself. The Jolla files go
in `jolla/` (or pass `--jolla DIR`). `install.sh` also accepts the Jolla RPMs
if the phone has `cpio`, but extracting on the host is the reliable path.

If you just flashed the phone, its SSH host key changed and `scp` will refuse
to connect. Remove the old key from `~/.ssh/known_hosts`, or connect once with
`-o StrictHostKeyChecking=accept-new`.

### 2. Log in and run the installer on the phone

```bash
ssh defaultuser@phone
cd /home/defaultuser/xperia10v-fingerprint
ls -l xperia10v-fingerprint-*.aarch64.rpm install.sh jolla/
devel-su sh install.sh --check   # compatibility only, no changes
devel-su sh install.sh           # warning + confirmation + install
devel-su reboot
```

A successful run ends with:

```text
  Jolla:     /home/defaultuser/xperia10v-fingerprint/jolla (extracted files, checksums OK)
== compatible ==
...
Updating / installing...
   1:xperia10v-fingerprint-1.0-8      ################################# [100%]
Created symlink .../multi-user.target.wants/sailfish-fpd-community.service ...
Created symlink .../nemo-devicelock.service -> .../sailfish-devicelock-encsfa-fpd.service

xperia10v-fingerprint installed.
REBOOT REQUIRED ...
```

### 3. After reboot

Open **Settings → Security → Device Lock → Fingerprint**, add a finger (touch
~14 times and shift the fingertip between touches), then lock the phone and
rest the enrolled finger on the sensor.

### Clean install / after a reflash

A minimal reset only needs the Sailfish userdata image:

```bash
fastboot flash userdata sailfish.img001
fastboot reboot
```

That wipes `/home/defaultuser`, the installed RPM, the Jolla overlay files and
the enrolments (fingerprints). The Lineage 22.2 vendor base (and the boot
images) are untouched, so no Lineage reflash or source change is needed. Copy
all four files again and repeat steps 1–3.

This verified flow was tested from a reflashed Xperia 10 V: `scp` the RPM,
`install.sh` and the two Jolla packages, `ssh` in, run the wrapper, reboot, add
a finger, unlock.

`install.sh` validates before touching anything:

| Area | Check | Expected |
|---|---|---|
| Sailfish | `ID` / `VERSION_ID` | `sailfishos` / `5.1.0.11` |
| Lineage | `ro.lineage.build.version` / `ro.lineage.device` | `22.2` / `pdx235` |
| Android | `ro.build.version.sdk` / `release` | `35` / `15` |
| Device | `ro.product.vendor.device` | `XQ-DC72` |
| HAL | `ro.hardware.fingerprint` / `/dev/esfp0` | `default` / present |
| AIDL | the V4 fingerprint/common/keymaster libs + gatekeeper | all present |
| Service | `init.svc.vendor.fingerprint-default` | `running` |
| Port | `nemo-devicelock.socket` | unit exists |
| Conflict | `sailfish-devicelock-fpd` | not installed |
| Overlay | `jolla/` packages or extracted files | present |
| Arch | `uname -m` | `aarch64` |

A mismatch aborts. The RPM also has a `%pre` gate: a direct `rpm -Uvh` without
`XPERIA10V_FP_CONFIRM=1` aborts with the warning.

After reboot: Settings → Security → **Device Lock → Fingerprint**, then lock and
rest an enrolled finger on the sensor.

## Developer quick start (host-side)

The split RPMs and overlay scripts remain available for development, with
the phone reachable over SSH as `phone`:

```bash
export PHONE_PW='<ssh-password>'         # required; no default
export DEVEL_PW='<device-lock-code>'     # optional; defaults to PHONE_PW

# 1. sailfish-fpd-community + droid-biometry-fp
./scripts/install-fpd.sh

# 2. official devicelock fpd overlay + lipstick switch
#    (first populate overlay/encsfa-fpd and the library; see overlay/README.md)
./scripts/extract-jolla-overlay.sh /path/to/jolla-rpms
./scripts/install-devicelock-overlay.sh

# or both:
# ./scripts/deploy.sh
```

After reboot:

* Settings → Security → **Device Lock → Fingerprint** should list the enrolled
  fingers and allow adding/removing.
* Lock the phone and rest an enrolled finger on the power-button sensor.
* With the screen off, a light sensor touch wakes it (do not press the power key).

Enrollment can also be done from a terminal while the screen is on and unlocked:

```bash
ssh phone
dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 \
  /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.Enroll string:"finger1"
```

Then touch the sensor until the daemon reports `remaining=0`.

---

## Build from source

Prerequisites:

* LineageOS 22.2 tree (`TOP`, e.g. `~/android/lineage-22.2`) with
  `device/sony/pdx235`, `vendor/sony/pdx235` and kernel sources.
* Sailfish Platform SDK 5.1.0.11 with target
  `SailfishOS-5.1.0.11-aarch64-qt612`.
* `libhybris-common.so` and headers available to the SDK target
  (`libhybris-devel` or a copy of the phone's `libhybris-common.so.1`).
* A phone reachable as `phone` with `devel-su` access.

```bash
./scripts/build-android-bridge.sh   # m libbiometry_fp_api
./scripts/build-bridge-rpm.sh       # droid-biometry-fp RPM
./scripts/build-daemon-rpm.sh       # sailfish-fpd-community RPM
```

See [`docs/scripts.md`](docs/scripts.md) for every command and
[`docs/troubleshooting.md`](docs/troubleshooting.md) for the host-specific issues
(soong OOM, `ap2a` vs `ap4a`, `mb2` spec selection, etc.).

---

## Caveats

* The official devicelock fpd files are installed as an **overlay** because the
  Jolla `sailfish-devicelock-fpd` 5.1 package conflicts with the port's
  `jolla-devicelock-plugin-encsfa` and would remove the device adaptation
  pattern. The overlay is functional and survives reboot, but a future update of
  `jolla-devicelock-plugin-encsfa` can revert `devicelock.conf`. A backup is kept
  at `/usr/share/lipstick/devicelock/devicelock.conf.bak`.
* The old `jolla-devicelock-daemon-encsfa`/`jolla-devicelock-plugin-encsfa`
  packages remain installed but the old daemon is disabled. Rollback steps are in
  [`docs/system-integration.md`](docs/system-integration.md).
* The kernel source checkout in this container is newer than the flashed kernel
  commit; this does not affect the fingerprint stack, which uses the on-device
  vendor HAL.
* The first template (`finger1`) was enrolled with repeated samples on the same
  spot and is narrow. `finger2` is the better template; delete `finger1` from
  Settings if a match is unreliable.

---

## Licenses / provenance

* This project is licensed under **GPL-3.0-or-later**; see [`LICENSE`](LICENSE).
* `src/sailfish-fpd-community/` is a modified copy of the GPL-3.0
  `sailfishos-open/sailfish-fpd-community` project. See its `LICENSE` and
  `README.md`.
* `src/lineage/.../biometry/` is new code for this port, Apache-2.0, compatible
  with the LineageOS tree. `biometry.h` is LGPL-3.0 from the Ubuntu Touch /
  community fpd project.
* **Jolla binaries are not included or redistributed.** `encsfa-fpd` and
  `libsailfishdevicelock.so.1.2.0` come from Jolla's proprietary
  `sailfish-devicelock-fpd` / `sailfish-devicelock-libs` packages. `install.sh`
  installs them on the phone from packages the user supplies. They are
  gitignored and must not be committed or published.
* The legacy Android HAL, firmware and vendor blobs remain the property of
  Sony/EgisTec and are not part of this repository.
* “Sony”, “Xperia”, “Jolla” and “Sailfish” are trademarks of their respective
  owners. This is an unofficial community project, provided without warranty.
