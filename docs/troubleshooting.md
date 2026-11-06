# Troubleshooting and porting notes

This is the list of concrete failures hit while bringing the sensor up, with the
diagnosis and the fix. Most commands are run from the container over SSH.

---

## Host / build

### `soong_build` is OOM-killed

Symptom:

```
Killed
09:17:15 soong bootstrap failed with: exit status 1
```

`soong_build` peaked at ~29.5 GB RSS on a 31 GB host with only 2 GB swap.

Fixes:

1. A **24 GB swap file** on the host (this container cannot `swapon`; it must be
   done on the LXD host):

   ```bash
   sudo swapoff /swapfile
   sudo fallocate -l 24G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

   `swapon` inside the container fails with `Operation not permitted`; use the
   host.

2. Cap Go's heap. `soong_ui` invokes `soong_build` with `env -i`, so a shell
   `GOMEMLIMIT` is stripped. Wrap the binary:

   ```bash
   cd out/host/linux-x86/bin
   mv soong_build soong_build.real
   printf '#!/bin/sh\nGOMEMLIMIT=22GiB GOGC=50 exec "$(dirname "$0")/soong_build.real" "$@"\n' > soong_build
   chmod +x soong_build
   touch -r soong_build.real soong_build
   ```

   Run `m ... -j8`. The wrapper survives because the bootstrap target is
   up-to-date.

### `Invalid lunch combo` / `No release config set`

`lineage_pdx235-userdebug` and `lineage_pdx235-ap2a-userdebug` are wrong or
Android 14. Use:

```bash
lunch lineage_pdx235-ap4a-userdebug   # Android 15 / SDK 35
```

`ap2a` gives `PLATFORM_SDK_VERSION=34`, which causes:

```
dependency "libc.ndk" ... missing variant ... version:35
```

### `libhwbinder` visibility

```
module "libbiometry_fp_api" ... depends on //system/libhwbinder:libhwbinder which is not visible
```

Do not list `libhwbinder` explicitly; `android.hardware.gatekeeper@1.0`
pulls it in transitively.

### `mb2` “Multiple RPM SPEC files found”

The community repo contains `sailfish-fpd-community.spec`,
`droid-biometry-fp.spec` and `droid-fake-crypt.spec`. Select one:

```bash
mb2 -t SailfishOS-5.1.0.11-aarch64-qt612 \
    -s rpm/sailfish-fpd-community.spec build
```

### `mb2` cannot write `.mb2`

The SDK build runs as `sailfish` (uid 1001). The source tree must be writable:

```bash
chown -R sailfish:sailfish <source>
```

The scripts build in a temp copy and chown it, so the git tree stays clean.

### Single-RPM install fails: `libbase.so`, `libbinder_ndk.so`, `libc.so` needed

```
error: Failed dependencies:
    libbase.so()(64bit) is needed by xperia10v-fingerprint-1.0-6.aarch64
    libbinder_ndk.so()(64bit) is needed by xperia10v-fingerprint-1.0-6.aarch64
    libc.so()(64bit) is needed by xperia10v-fingerprint-1.0-6.aarch64
    ...
```

The bridge (`libbiometry_fp_api.so`) is a **bionic** library. RPM's automatic
requires scan it and treat its Android SONAMEs as glibc dependencies that no
Sailfish package provides.

Fix: exclude only the bridge from the auto-requires:

```spec
%define __requires_exclude_from ^.*/libbiometry_fp_api\.so$
```

The daemon/plugin keep their real glibc/Qt/libhybris requires. Rebuild the meta
RPM and re-run `install.sh`; the failed transaction did not install anything.

### `ERROR: the Jolla devicelock overlay is missing`

`install.sh` needs Jolla's proprietary `encsfa-fpd` and
`libsailfishdevicelock.so.1.2.0`. They are not shipped with this project.

Download the two official packages and put them in `jolla/` next to
`install.sh`:

```
sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
```

Or extract them on a computer with `scripts/extract-jolla-overlay.sh` and copy
`encsfa-fpd` + `libsailfishdevicelock.so.1.2.0` into `jolla/`.

### `cpio is missing` during install

The port image does not ship `cpio`, so `install.sh` cannot extract the Jolla
RPMs on the phone. This is the normal fallback, not a corrupted package.

Re-run `prepare-phone.sh`: it extracts the two files on the host and copies
`encsfa-fpd`, `libsailfishdevicelock.so.1.2.0` and `SHA256SUMS` into
`~/xperia10v-fingerprint/jolla/`. Or do it manually:

```bash
./scripts/extract-jolla-overlay.sh /path/to/jolla-rpms
scp overlay/encsfa-fpd overlay/libsailfishdevicelock.so.1.2.0 overlay/SHA256SUMS \
    defaultuser@phone:/home/defaultuser/xperia10v-fingerprint/jolla/
```

`rpm2cpio` may also be missing; the same fix applies.

### `%pre`: `The Jolla devicelock overlay is missing`

A direct `rpm -Uvh` was run without `install.sh`, so the two files were never
copied. Run `devel-su sh install.sh`, which installs them before the RPM
transaction.

### Password left in the shell or history

`export PHONE_PW=...` stays in the shell environment and is written to shell
history. The scripts do not cache or clear it (a child process cannot modify
its parent shell).

Use `prepare-phone.sh --ask` (silent `read -rsp`), or install a key with
`setup-ssh-key.sh`. To clean up:

```bash
unset PHONE_PW SSHPASS
history | grep PHONE_PW      # find the line number
history -d <line>
history -w
```

Add `HISTIGNORE='*PHONE_PW*'` to your shell profile to prevent future entries.

### `Text file busy` when updating the daemon

The running executable cannot be overwritten in place. Use `systemctl stop`
first, or atomically replace the directory entry:

```bash
cp new /usr/bin/sailfish-fpd-community.new
chmod 755 /usr/bin/sailfish-fpd-community.new
mv -f /usr/bin/sailfish-fpd-community.new /usr/bin/sailfish-fpd-community
systemctl restart sailfish-fpd-community
```

### `droid-biometry-fp` `%build`: `File exists`

`mb2` reuses the source directory, and the spec extracts the tarball twice (or
finds the staging tree from the previous run). The spec now starts `%build`
with:

```spec
rm -rf droid-biometry-fp-0.0.0
```

Also remove the staging tree after creating the tarball.

### `swapon` denied in the container

Unprivileged LXD blocks `swapon`. Add swap on the host or via LXD
(`limits.memory.swap`), not inside the container.

### `logcat` aborts with `linker_tls.cpp`

Run it with a clean environment:

```bash
env -i /system/bin/logcat -d -b main,system -v threadtime -t 20000
```

Without `env -i`, the bionic linker inherits something incompatible and aborts
with `unregister_tls_module CHECK 'mod.static_offset == SIZE_MAX' failed`.

### `devel-su -c` fails on compound commands

`devel-su -c` execs a single program, not a shell. Use:

```bash
echo "$PHONE_PW" | devel-su /bin/sh -c 'cmd1 && cmd2'
```

---

## Runtime

### Enrollment stalls right after `ISession::enroll started`

This is the classic symptom of the missing binder thread pool:

```
[biometry] enroll: calling ISession::enroll
[biometry] ISession::enroll started
...  (nothing)
```

The HAL logs `onAcquired(1, 0)` on the Android side, then blocks because
`onAcquired` is a synchronous callback and the daemon has no binder thread.
Fix: `ABinderProcess_setThreadPoolMaxThreadCount(4); ABinderProcess_startThreadPool();`
in the bridge `init()`.

Verify the threads:

```bash
ps -T | grep sailfish-fpd
# should show binder:<pid>_1..4
```

### `gk enroll` / `gk verify` failures

```
[biometry] gk enroll code=-2
[biometry] gk verify code=-1
```

* `-2` is `ERROR_RETRY_TIMEOUT`; wait/retry.
* If the gatekeeper credential exists but the handle file is missing, the bridge
  calls `deleteUser(uid)` and retries once.
* `data=69` from `verify` is the 69-byte `hw_auth_token_t`; a smaller size is an
  error.

The handle is `/var/lib/sailfish-fpd/gatekeeper_handle`.

### `BIX_FTM_NOT_MATCH`, `score=0`

The software is correct; the template and the presented finger disagree. The
enrollment log often shows `BIX_FTX_REDUNDANT` — the user touched the same spot
repeatedly, producing a narrow template.

Fix: re-enroll the same finger while **shifting** the fingertip (center, top,
bottom, left, right, slight rotations), lifting fully between touches. Use the
Settings UI or a D-Bus `Enroll` with a new name.

### Identify times out

The community daemon's identify timer was 30 s. It is now 120 s. The HAL
enrollment timeout is still 60 s (hard-coded in the Lineage AIDL service).

### Screen goes black during enrollment/unlock

* Enrollment needs the screen **on and unlocked**. If the lock screen is showing
  or the display is off, the HAL may not capture.
* Pressing the power button toggles the screen off. Use
  `dbus-send ... com.nokia.mce.request.req_display_state_on` or `mcetool -U`
  to wake it, then **rest** the finger without pressing.
* For screen-off wakeup, mce requires `powerkey_pressed == false`; pressing the
  button disables the wakeup path.

### `Abort` returns “already idle” but the state is not idle

`Abort` is only accepted from the D-Bus caller that started the operation. A
`dbus-send` connection disappears after the call, so a later `Abort` from a new
connection is rejected. Restart the daemon to clear a stuck operation:

```bash
systemctl restart sailfish-fpd-community
```

The native UI keeps a persistent connection and aborts normally.

### Native Settings/lockscreen has no fingerprint

Check, in order:

1. `sailfish-fpd-community` active and `org.sailfishos.fingerprint1` present.
2. `devicelock.conf` points to `encsfa-fpd` (not `encpartition`).
3. lipstick was restarted after the config change
   (`systemctl --user daemon-reload && systemctl --user restart lipstick`).
4. `sailfish-devicelock-encsfa-fpd` is active.
5. mce's fingerprint wakeup mode is not `never`
   (`/system/osso/dsm/fingerprint/mode`).

The fingerprint service uses `nemo-devicelock.socket`; do not expect a
`Fingerprint.Sensor` interface in `dbus-send ... Introspect` on `/devicelock`.

### devicelock fpd daemon starts but doesn't contact fpd

Check the community daemon journal around the devicelock start; it should show
`GetState()` and `GetAll()` calls from the devicelock daemon. If not, the unit
started before fpd; the overlay unit adds:

```
After=sailfish-fpd-community.service
Wants=sailfish-fpd-community.service
```

### Official `sailfish-fpd-slave-binder` doesn't work

Its `fpslave` strings only contain
`android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint` — HIDL 2.1.
This phone has only the AIDL V4 service. Do not install the official slave; keep
the community daemon + AIDL bridge.

### `jolla-devicelock-plugin-encsfa` update reverts the config

The old package owns `devicelock.conf`. Restore the fpd line from
`devicelock.conf.bak` (or re-run `install-devicelock-overlay.sh`) and restart
lipstick.

---

## Useful diagnostic commands

```bash
# daemon state and fingers
dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 \
  /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.GetState
dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 \
  /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.GetAll

# bridge/daemon log
journalctl -u sailfish-fpd-community -f

# Android side (AIDL service, Egis HAL)
env -i /system/bin/logcat -d -b main,system -v threadtime -t 20000 \
  | grep -iE 'fingerprint|biometric|egis|BIX_FTM|onAuthenticated|onEnroll'

# kernel driver
dmesg | grep -iE 'esfp|egis'

# units
systemctl status sailfish-fpd-community sailfish-devicelock-encsfa-fpd
systemctl status nemo-devicelock.socket
```

## Rollback

See [`system-integration.md`](system-integration.md#9-rollback).
