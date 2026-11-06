# Single-RPM installer

The end-user artefacts are two files (built into `dist/` or attached to a
release):

```
xperia10v-fingerprint-1.0-8.aarch64.rpm
install.sh
```

You also need Jolla's two official packages (proprietary, not redistributed):

```
sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
```

`install.sh` is the **phone-side** wrapper. It validates the phone, shows the
warning, asks for confirmation, installs the two Jolla overlay files, and only
then calls `rpm`. The RPM itself has a `%pre` gate so a direct `rpm -Uvh`
without the wrapper (or without the overlay) aborts.

> `rpm` has no GUI popup. The confirmation lives in `install.sh`; a direct
> `rpm -Uvh` only prints terminal warnings and errors. See
> [`troubleshooting.md`](troubleshooting.md).

---

## Install on the phone

Copy the RPM and wrapper to `/home/defaultuser/xperia10v-fingerprint/`, and the
extracted Jolla files (`encsfa-fpd`, `libsailfishdevicelock.so.1.2.0`,
`SHA256SUMS`) to `/home/defaultuser/xperia10v-fingerprint/jolla/`, then in a
terminal **on the phone**:

```bash
cd /home/defaultuser/xperia10v-fingerprint
devel-su sh install.sh --check   # validate only; makes no changes
devel-su sh install.sh           # warning, confirmation, install
devel-su reboot
```

`--jolla DIR` selects another directory. It may contain either the two
extracted files or the RPMs; RPM extraction on the phone needs `rpm2cpio` and
`cpio`, which the current port image does not ship. `prepare-phone.sh` extracts
on the host and copies the files, which is the supported path.

After reboot:

1. Settings → Security → **Device Lock → Fingerprint**.
2. Add a finger.
3. Lock the phone and rest an enrolled finger on the power-button sensor.

If you reflashed Sailfish/userdata, the previous enrollments are gone; add a
finger again.

---

## Compatibility checks

`install.sh` refuses to install unless all of these match. It uses `getprop`
values from the running Android/vendor base and Sailfish's `/etc/os-release`.

| Area | Check | Expected |
|---|---|---|
| Sailfish | `/etc/os-release` `ID` | `sailfishos` |
| Sailfish | `/etc/os-release` `VERSION_ID` | `5.1.0.11` |
| Arch | `uname -m` | `aarch64` |
| Port | `ro.lineage.device` | `pdx235` |
| Device | `ro.product.vendor.device` | `XQ-DC72` |
| Lineage | `ro.lineage.build.version` | `22.2` |
| Android | `ro.build.version.sdk` | `35` |
| Android | `ro.build.version.release` | `15` |
| HAL | `ro.hardware.fingerprint` | `default` |
| Sensor | `/dev/esfp0` | present |
| HAL libs | `/vendor/lib64/hw/fingerprint.default.so` | present |
| AIDL | `/vendor/lib64/android.hardware.biometrics.fingerprint-V4-ndk.so` | present |
| AIDL | `/vendor/lib64/android.hardware.biometrics.common-V4-ndk.so` | present |
| AIDL | `/vendor/lib64/android.hardware.keymaster-V4-ndk.so` | present |
| AIDL | `/vendor/lib64/android.hardware.gatekeeper@1.0.so` | present |
| Service | `init.svc.vendor.fingerprint-default` | `running` |
| Port | `systemctl cat nemo-devicelock.socket` | unit exists |
| Conflict | `rpm -q sailfish-devicelock-fpd` | not installed |
| Overlay | `jolla/` packages or extracted files | present |

The check output on a matching phone:

```
== compatibility checks ==
  Sailfish:  Sailfish OS 5.1.0.11 (Pispala)
  Lineage:   22.2 / Android 15 (SDK 35)
  Device:    pdx235 / XQ-DC72
  HAL:       running / esfp0
  Package:   xperia10v-fingerprint-1.0-8.aarch64.rpm
  Jolla:     /home/defaultuser/xperia10v-fingerprint/jolla (extracted files, checksums OK)
== compatible ==
```

A mismatch aborts before any file or service is touched.

---

## What the RPM contains

| Path | Source |
|---|---|
| `/usr/bin/sailfish-fpd-community` | split daemon RPM |
| `/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf` | split daemon RPM |
| `/usr/lib/systemd/system/sailfish-fpd-community.service` | split daemon RPM |
| `/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so` | split bridge RPM / `dist/libbiometry_fp_api.so` |
| `/usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service` | `overlay/...service` |
| `/usr/share/xperia10v-fingerprint/devicelock.conf` | payload; copied to lipstick by `%post` |
| `/usr/share/xperia10v-fingerprint/install.sh` | reference copy of the wrapper |
| `/usr/share/doc/xperia10v-fingerprint/README.md` | project README |

The two Jolla files are **not** in the RPM. `install.sh` installs them before
the RPM transaction:

| Path | Source |
|---|---|
| `/usr/lib64/qt5/plugins/devicelock/encsfa-fpd` | user-supplied `sailfish-devicelock-fpd` |
| `/usr/lib64/libsailfishdevicelock.so.1.2.0` + symlinks | user-supplied `sailfish-devicelock-libs` |

The RPM **obsoletes** the split `sailfish-fpd-community` and `droid-biometry-fp`
packages (`Obsoletes: < 1.2`) and provides `sailfish-fpd`, so the mce/devicelock
dependencies are satisfied.

## RPM scriptlets

### `%pre`

First checks that the two Jolla overlay files are present; otherwise it aborts
with instructions to run the wrapper. Then aborts unless
`XPERIA10V_FP_CONFIRM=1` is set **or** the wrapper has created
`/run/xperia10v-fingerprint.confirm`. The warning text is printed. The wrapper
sets both and removes the marker afterwards; `%post` removes it too.

### `%post`

* `systemctl daemon-reload`
* enables `sailfish-fpd-community.service`
* stops and **masks** `jolla-devicelock-encsfa.service` (old daemon)
* removes the old `nemo-devicelock.service` alias
* restarts `nemo-devicelock.socket` and enables/starts `sailfish-devicelock-encsfa-fpd.service` (creates the new alias)
* creates `/data/vendor_de/100000/fpdata` as `system:system`
* backs up `devicelock.conf` to `.bak` (only once)
* switches `devicelock.conf` to `pluginName=.../encsfa-fpd`
* runs `ldconfig`
* prints **reboot required**

It deliberately does **not** restart lipstick; the reboot loads the new plugin
cleanly.

### `%preun` (erase only)

* disables/stops the two new units
* restores `devicelock.conf.bak`
* unmasks/restarts `jolla-devicelock-encsfa.service`
* if the wrapper marker `/usr/share/xperia10v-fingerprint/overlay-installed`
  exists, removes the two Jolla overlay files and the marker
* `daemon-reload`

---

## Host-side vs phone-side

| Wrapper | Runs on | Use |
|---|---|---|
| `dist/install.sh` | the phone (`devel-su sh install.sh`) | end user |
| `scripts/deploy.sh` | the container/host over SSH | developer/CI |
| `scripts/install-fpd.sh` | the container/host over SSH | split-package developer path |
| `scripts/install-devicelock-overlay.sh` | the container/host over SSH | split-package developer path |

The host-side scripts use `sshpass` + `devel-su`; the phone-side script needs no
host, only developer mode/Terminal.

---

## Build

```bash
./scripts/build-meta-rpm.sh
```

It bundles the existing daemon RPM, `dist/libbiometry_fp_api.so`, the overlay
unit and `devicelock.conf` into `xperia10v-fingerprint-1.0-8.aarch64.rpm`, and
copies `installer/install.sh` to `dist/install.sh`. No compiler is needed. The
Jolla binaries are not part of the payload.

The `rpmlint` warnings are expected: the `%post` removes the old alias, the
`%preun` restores the config, and the package installs files on behalf of the
wrapper. The package is unsigned, so the wrapper installs it with
`--nosignature --nodigest`.

The bridge is a **bionic** `.so`. RPM's automatic dependency scanner would
otherwise turn its Android SONAMEs (`libbase.so`, `libbinder_ndk.so`,
`libc.so`, `libm.so`, `libdl.so`, `libhardware.so`, `libhidlbase.so`, …) into
unsatisfiable glibc requirements. The spec excludes only
`/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so` via
`%__requires_exclude_from`; the daemon and the devicelock plugin keep their
normal glibc/Qt/libhybris requires.

---

## Caveats

* The single RPM is validated for exactly **Sailfish 5.1.0.11 / pdx235 / XQ-DC72**
  with **LineageOS 22.2 / Android 15** and the AIDL V4 fingerprint HAL.
* A different Sailfish or Android/Lineage base needs a rebuilt bridge/daemon and
  a matching Jolla devicelock overlay.
* The overlay binaries are Jolla proprietary and are supplied by the user; see
  `overlay/README.md`. They are not in the RPM or the repository.
* Do not install the official `sailfish-devicelock-fpd` RPM via zypper: it
  conflicts with the port's `jolla-devicelock-plugin-encsfa` and would remove the
  adaptation pattern.
* The RPM does not include an enforced reboot; it only prints the requirement.
  The new lipstick plugin is loaded at the next lipstick start/reboot.
* Enrollments are stored in the Sailfish rootfs; a userdata reflash wipes them.
