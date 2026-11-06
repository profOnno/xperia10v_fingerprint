# File map

What every file/directory in this repository is, and where it ends up on the
phone.

## Repository

| Path | Purpose |
|---|---|
| `README.md` | Overview, status, architecture summary, quick start, caveats |
| `dist/` | Final aarch64 artifacts: the single RPM, the split RPMs, the bridge `.so` and the phone-side `install.sh` |
| `dist/xperia10v-fingerprint-*.rpm` | Single end-user RPM (daemon + bridge + unit/config + post-install logic) |
| `dist/install.sh` | Phone-side validation/warning/confirmation wrapper |
| `dist/droid-biometry-fp-*.rpm` | Package containing `/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so` |
| `dist/sailfish-fpd-community-*.rpm` | Package containing the daemon, D-Bus policy and unit |
| `dist/libbiometry_fp_api.so` | The AIDL bridge binary (same file as in the RPM) |
| `docs/` | Documentation (see `docs/README.md`) |
| `docs/file-map.md` | This file |
| `docs/architecture.md` | Layer-by-layer working principle and sequences |
| `docs/functions.md` | Function/script index with one-line descriptions |
| `docs/biometry-bridge.md` | Function-by-function AIDL bridge reference |
| `docs/fpd-daemon.md` | Community daemon API and patches |
| `docs/scripts.md` | Every script explained |
| `docs/system-integration.md` | Units, boot order, overlay, config, rollback |
| `docs/troubleshooting.md` | Concrete failures and fixes |
| `overlay/` | Devicelock overlay unit/config; Jolla binaries are not tracked |
| `overlay/encsfa-fpd` | Jolla plugin/daemon binary (gitignored; user-supplied) |
| `overlay/libsailfishdevicelock.so.1.2.0` | Jolla library (gitignored; user-supplied) |
| `overlay/devicelock.conf` | `pluginName=.../encsfa-fpd` |
| `overlay/sailfish-devicelock-encsfa-fpd.service` | Unit with the `After/Wants=sailfish-fpd-community` boot-order fix |
| `overlay/README.md` | Provenance, licensing and why an overlay |
| `installer/install.sh` | Phone-side single-RPM validation/warning/confirmation wrapper |
| `packaging/xperia10v-fingerprint.spec` | Meta-RPM spec (payload, `%pre` gate, `%post`/`%preun`) |
| `patches/` | Upstream diff for the GPL daemon |
| `patches/sailfish-fpd-community.patch` | `git diff` of the daemon changes |
| `scripts/build-android-bridge.sh` | Build `libbiometry_fp_api.so` in the Lineage tree |
| `scripts/build-bridge-rpm.sh` | Build `droid-biometry-fp` |
| `scripts/build-daemon-rpm.sh` | Build `sailfish-fpd-community` |
| `scripts/build-meta-rpm.sh` | Build the single RPM + `dist/install.sh` |
| `scripts/install-fpd.sh` | Install both RPMs + create the HAL store directory |
| `scripts/install-devicelock-overlay.sh` | Install the overlay, switch daemon/config, restart lipstick |
| `scripts/setup-ssh-key.sh` | Install an SSH key on the phone (passwordless later runs) |
| `scripts/prepare-phone.sh` | Download/verify Jolla RPMs and copy the install set to the phone |
| `scripts/extract-jolla-overlay.sh` | Extract the two Jolla files from the official RPMs |
| `scripts/test-fpd.sh` | D-Bus state/GetAll/Enroll/Identify + journal |
| `scripts/deploy.sh` | `install-fpd.sh` + `install-devicelock-overlay.sh` |
| `src/lineage/hardware/sony/biometry/` | New Android module (AIDL bridge) |
| `src/lineage/.../Android.bp` | `cc_library_shared` module definition |
| `src/lineage/.../biometry.h` | Ubuntu Touch/community C ABI (LGPL-3.0) |
| `src/lineage/.../biometry_fp_aidl_for_hybris.cpp` | The bridge implementation |
| `src/sailfish-fpd-community/` | Modified GPL-3.0 community daemon source |
| `src/sailfish-fpd-community/src/fpdcommunity.cpp` | D-Bus API/state machine (120 s timeout, `Verify` fix) |
| `src/sailfish-fpd-community/src/androidfp.cpp` | C++ wrapper over the bridge ABI |
| `src/sailfish-fpd-community/src/hardware/` | `DLSYM` trampolines and libhybris path selection |
| `src/sailfish-fpd-community/src/bridge/` | Generic libhybris dlopen/dlsym bridge |
| `src/sailfish-fpd-community/src/biometry.h` | Upstream copy of the ABI |
| `src/sailfish-fpd-community/rpm/*.spec` | Packaging for both RPMs |
| `src/sailfish-fpd-community/sailfish-fpd-community.service` | Daemon unit (`After=wait_for_keymaster`) |
| `src/sailfish-fpd-community/org.sailfishos.fingerprint1.conf` | D-Bus policy |
| `src/sailfish-fpd-community/LICENSE` | GPL-3.0 |

## Installed on the phone

| Phone path | Source |
|---|---|
| `/usr/bin/sailfish-fpd-community` | `dist/sailfish-fpd-community-*.rpm` |
| `/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf` | same RPM |
| `/usr/lib/systemd/system/sailfish-fpd-community.service` | same RPM |
| `/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so` | `dist/droid-biometry-fp-*.rpm` |
| `/usr/lib64/qt5/plugins/devicelock/encsfa-fpd` | `install.sh` from user-supplied Jolla RPM |
| `/usr/lib64/libsailfishdevicelock.so.1.2.0` | `install.sh` from user-supplied Jolla RPM |
| `/usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service` | `overlay/sailfish-devicelock-encsfa-fpd.service` |
| `/usr/share/lipstick/devicelock/devicelock.conf` | `overlay/devicelock.conf` |
| `/data/vendor_de/100000/fpdata/` | created by `install-fpd.sh` / daemon |
| `/var/lib/sailfish-fpd-community/100000/fingerprints.db` | daemon runtime |
| `/var/lib/sailfish-fpd/gatekeeper_handle` | bridge runtime |

## Not in this repository

| Thing | Where |
|---|---|
| LineageOS 22.2 tree | your checkout (`TOP`) |
| Sailfish SDK target | `/srv/sailfishos/targets/SailfishOS-5.1.0.11-aarch64-qt612` |
| Vendor blobs / kernel | Lineage tree and phone `/vendor` |
| Jolla `sailfish-devicelock-fpd` / `-libs` RPMs | Jolla 5.1.0.11 aarch64 repository; supplied by the user |
| Android build `out/` | `lineage-22.2/out` |

## Build artifact provenance

* `dist/libbiometry_fp_api.so` — `m libbiometry_fp_api`, aarch64,
  `lineage-22.2/out/target/product/pdx235/vendor/lib64/`.
* `dist/droid-biometry-fp-*.rpm` — `scripts/build-bridge-rpm.sh` (packages the
  above `.so` into `/usr/libexec/droid-hybris/system/lib64/`).
* `dist/sailfish-fpd-community-*.rpm` — `scripts/build-daemon-rpm.sh` (modified
  GPL source).
* `dist/xperia10v-fingerprint-*.rpm` — `scripts/build-meta-rpm.sh` (bundles the
  daemon, bridge, unit/config and the phone-side wrapper; no Jolla binaries).
* `overlay/encsfa-fpd`, `overlay/libsailfishdevicelock.so.1.2.0` — extracted
  from Jolla's `sailfish-devicelock-fpd` / `sailfish-devicelock-libs`
  1.2.0-1.3.12.jolla packages. Gitignored and never published; see
  `overlay/README.md`.
