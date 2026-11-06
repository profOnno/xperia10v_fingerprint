# Scripts

All scripts are host-side unless stated otherwise. They assume:

* the phone is reachable over SSH as `phone` (override with `PHONE`);
* `PHONE_PW` is set to the phone SSH password (there is no default);
* `sshpass` and `scp` are installed on the host;
* the project root is the directory containing `scripts/`.

Common environment:

```bash
export PHONE=phone
read -rsp 'SSH password: ' PHONE_PW; echo   # not stored in shell history
export PHONE_PW
export DEVEL_PW='<device-lock-code>'        # optional: defaults to PHONE_PW
```

There is **no credential cache**. Caching the device-lock password (the way
sudo caches local privilege) would mean storing it in a file or a long-lived
process; use `scripts/setup-ssh-key.sh` for passwordless repeat access instead.
For a single run, `prepare-phone.sh --ask` prompts without touching history.

`devel-su` uses the device lock code, which is not necessarily the same as the
SSH password. Set `DEVEL_PW` if they differ.

The root helper used by the install scripts:

```bash
run_root() {
    SSHPASS="$PHONE_PW" sshpass -e ssh \
        -o StrictHostKeyChecking=accept-new "$PHONE" \
        "echo '$DEVEL_PW' | devel-su /bin/sh -c '$1'"
}
```

`devel-su -c` only execs a single program; compound commands need
`devel-su /bin/sh -c '...'`.

---

## `build-android-bridge.sh`

**Purpose:** build `libbiometry_fp_api.so` in the Lineage tree.

**Inputs:**

* `TOP` (the LineageOS 22.2 tree; e.g. `~/android/lineage-22.2`)
* the `hardware/sony/biometry` module must be present in the tree
* `PRODUCT=pdx235`, release `ap4a` (Android 15 / SDK 35)

**What it does:**

```bash
cd "$TOP"
source build/envsetup.sh
lunch lineage_pdx235-ap4a-userdebug
m libbiometry_fp_api -j8
```

**Output:**

```
out/target/product/pdx235/vendor/lib64/libbiometry_fp_api.so
out/target/product/pdx235/vendor/lib/libbiometry_fp_api.so
```

**Notes:**

* Use `ap4a`/`ap3a`, **not** `ap2a`. `ap2a` is Android 14 (SDK 34) and causes
  `libc.ndk version 35` errors.
* The host needs enough memory. The first `soong_build` on this container used
  ~29.5 GB RSS; a 24 GB swap file fixed the OOM. A `soong_build` wrapper with
  `GOMEMLIMIT=22GiB GOGC=50` is an alternative (see
  `docs/troubleshooting.md`).
* The module is installed as a `vendor: true` library; the packaging script
  stages it into a `system/lib64` path because the droid-biometry-fp spec
  expects that.

---

## `build-bridge-rpm.sh`

**Purpose:** package the bridge into `droid-biometry-fp`.

**Inputs:**

* `TOP` (Lineage tree)
* `SRC` (project `src/sailfish-fpd-community`)
* `PRODUCT` (`pdx235`)
* the built `libbiometry_fp_api.so`

**What it does:**

1. Finds `$TOP/out/target/product/$PRODUCT/{vendor,system}/lib64/libbiometry_fp_api.so`.
2. Creates a temporary build copy of `$SRC`.
3. Stages the `.so` as
   `droid-biometry-fp-0.0.0/out/target/product/$PRODUCT/system/lib64/libbiometry_fp_api.so`.
4. Creates `droid-biometry-fp-0.0.0.tgz`.
5. Removes the staging tree (the `droid-biometry-fp.spec` `%build` also does
   `rm -rf` before extracting, because mb2 reuses the directory).
6. Runs:

   ```bash
   mb2 -t SailfishOS-5.1.0.11-aarch64-qt612 \
       -s rpm/droid-biometry-fp.spec build
   ```

7. Copies the resulting RPM to `dist/`.

**Output:** `dist/droid-biometry-fp-*.aarch64.rpm` containing

```
/usr/libexec/droid-hybris/system/lib64/libbiometry_fp_api.so
```

---

## `build-daemon-rpm.sh`

**Purpose:** build `sailfish-fpd-community`.

**Inputs:** the project source, the Sailfish SDK chroot and target.

**What it does:**

1. Copies `src/sailfish-fpd-community` to a temporary build directory.
2. `chown -R sailfish:sailfish` the temp tree (the SDK build runs as the
   unprivileged `sailfish` user).
3. Runs:

   ```bash
   sudo -u sailfish -H /srv/sailfishos/sdks/sfossdk/sdk-chroot -m all \
       bash -lc 'cd /parentroot<build> && \
       mb2 -t SailfishOS-5.1.0.11-aarch64-qt612 \
           -s rpm/sailfish-fpd-community.spec build'
   ```

4. Copies the RPM to `dist/`.

**Prerequisites:**

* `mb2` target `SailfishOS-5.1.0.11-aarch64-qt612`;
* Qt5 Core/DBus development files in the target;
* `libhybris-common.so` available to the target linker. The container solved
  this by copying the phone's `/usr/lib64/libhybris-common.so.1.0.0` into the
  target and creating `libhybris-common.so`/`.so.1` symlinks. Installing
  `libhybris-devel` into the target would be the cleaner equivalent.
* The spec no longer requires `libhybris-devel`/`desktop-file-utils` (they are
  not present in the generic target).

**Output:** `dist/sailfish-fpd-community-*.aarch64.rpm` containing:

```
/usr/bin/sailfish-fpd-community
/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf
/usr/lib/systemd/system/sailfish-fpd-community.service
/usr/lib/systemd/system/multi-user.target.wants/sailfish-fpd-community.service
```

---

## `install-fpd.sh`

**Purpose:** install the two RPMs on the phone and create the HAL store path.

**What it does:**

1. Copies `dist/droid-biometry-fp-*.rpm` and
   `dist/sailfish-fpd-community-*.rpm` to `/tmp/fp/`.
2. Creates `/data/vendor_de/100000/fpdata`, owned `system:system`, mode 0770.
3. `rpm -Uvh --replacepkgs --nosignature --nodigest` both RPMs.
4. `systemctl daemon-reload`, `systemctl reload dbus`,
   `systemctl enable --now sailfish-fpd-community`.
5. Prints `GetState` and `GetAll`.

**Result:**

```
org.sailfishos.fingerprint1 → FPSTATE_IDLE
```

The community unit provides `sailfish-fpd`; the official devicelock fpd plugin
will find it.

---

## `install-devicelock-overlay.sh`

**Purpose:** install the official Jolla devicelock fpd plugin/daemon and make
lipstick use it. This is the developer path; end users run `install.sh`.

**Before running:** the two binaries are Jolla proprietary and are not tracked.
Populate them with `extract-jolla-overlay.sh` (below) or copy them from the
official packages.

**Why an overlay:** the official `sailfish-devicelock-fpd` 5.1 RPM conflicts with
the port's `jolla-devicelock-plugin-encsfa` and would remove the
`patterns-sailfish-device-adaptation-xqdc72` and `droid-hal-version-xqdc72`
packages. The files themselves are drop-in compatible, so they are copied
manually.

**What it does:**

1. Copies `overlay/encsfa-fpd`, `overlay/libsailfishdevicelock.so.1.2.0`,
   `overlay/devicelock.conf` and `overlay/sailfish-devicelock-encsfa-fpd.service`
   to `/tmp/fpd-overlay/`. The first two must already exist; see
   `extract-jolla-overlay.sh`.
2. Installs `encsfa-fpd` as `root:disk` mode 2755 at
   `/usr/lib64/qt5/plugins/devicelock/encsfa-fpd`.
3. Installs the library at `/usr/lib64/libsailfishdevicelock.so.1.2.0` and
   creates `.so.1`/`.so.1.2` symlinks.
4. Installs the unit at
   `/usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service`.
5. Backs up `devicelock.conf` to `devicelock.conf.bak`.
6. Disables the old `jolla-devicelock-encsfa.service` and removes the
   `nemo-devicelock.service` symlink.
7. `daemon-reload`, enables/starts `sailfish-devicelock-encsfa-fpd`.
8. Switches `devicelock.conf` to
   `pluginName=/usr/lib64/qt5/plugins/devicelock/encsfa-fpd`.
9. Restarts lipstick as `defaultuser` so the new device-lock plugin is loaded:

   ```bash
   XDG_RUNTIME_DIR=/run/user/100000
   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
   systemctl --user daemon-reload
   systemctl --user restart lipstick
   ```

**Result:** lipstick loads the fpd plugin; the native lockscreen path and the
Settings fingerprint service work. The old daemon package remains installed but
disabled for rollback.

---

## `setup-ssh-key.sh`

**Purpose:** install an SSH key on the phone once, so later scripts need no
password. This is a **developer convenience**, not part of the end-user flow;
the RPM and `install.sh` never touch SSH.

The private key stays on the host (default
`~/.ssh/id_ed25519_xperia10v`), the public key is added to the phone's
`~/.ssh/authorized_keys`. It is generated without a passphrase, so anyone who
can read it can log in as `defaultuser`. It does not grant root; `devel-su`
still requires the device code. Use `SSH_KEY=...` with your own
passphrase-protected key if you prefer.

**Usage:**

```bash
./scripts/setup-ssh-key.sh
./scripts/setup-ssh-key.sh --key ~/.ssh/my_key
PHONE_PW='...' ./scripts/setup-ssh-key.sh   # non-interactive
```

It generates `~/.ssh/id_ed25519_xperia10v` if needed (no passphrase), runs
`ssh-copy-id`, tests `BatchMode=yes` login, and prints the matching
`~/.ssh/config` block. Use the key with
`SSH_KEY=~/.ssh/id_ed25519_xperia10v ./scripts/prepare-phone.sh`.

The password is used only by `ssh-copy-id`; it is not written anywhere. The
private key has no passphrase, so keep `~/.ssh` at 0700 and the key at 0600.
Uninstalling the fingerprint RPM does **not** remove the key; clean up with:

```bash
ssh phone 'sed -i "/xperia10v-fingerprint@/d" ~/.ssh/authorized_keys'
rm -f ~/.ssh/id_ed25519_xperia10v ~/.ssh/id_ed25519_xperia10v.pub
```

---

## `prepare-phone.sh`

**Purpose:** download the two official Jolla packages, verify them against
Jolla's signed repository metadata, and copy the complete install set to the
phone. End users normally use this instead of manual `scp`.

**Usage:**

```bash
./scripts/prepare-phone.sh --ask          # prompt for IP/port/user + password
SSH_KEY=~/.ssh/id_ed25519_xperia10v ./scripts/prepare-phone.sh
./scripts/prepare-phone.sh --no-copy
./scripts/prepare-phone.sh --phone other-host
```

`--ask` first offers to read the phone IP (as shown in
**Settings -> Developer tools -> SSH**), port and user, then opens one SSH
connection. `ssh` asks for the password once; `scp` and later `ssh` calls reuse
that connection, so no password is stored, echoed, or passed to `sshpass`.
If `PHONE` is already set (or `--phone` is given), the address prompt is
skipped. If you exported `PHONE_PW` in your shell instead, the script uses
`sshpass -e` and prints an `unset` reminder — a child process cannot clear its
parent's environment.

**Inputs:**

* `dist/xperia10v-fingerprint-*.aarch64.rpm` and `dist/install.sh` (build them
  with `./scripts/build-meta-rpm.sh`);
* network access to `releases.jolla.com`.

**Verification chain:**

1. Download Jolla's `repomd.xml.key` and pin the signing fingerprint
   `BE6885DC16FA9420BA2DA558CB2904D42F7DA79C`.
2. `gpg --verify repomd.xml.asc` — the repository metadata must be signed by
   that key.
3. Verify the SHA256 of `primary.xml.gz` from the signed `repomd.xml`.
4. Verify the SHA256 of each downloaded RPM from `primary.xml.gz`.

**Output:** `dist/jolla/` with the two RPMs and a `SHA256SUMS` manifest. The
script copies the RPM + `install.sh` to `~/` and the Jolla files +
`SHA256SUMS` to `~/jolla/` on the phone. `dist/jolla/` is gitignored.

**Note:** the RPM header signature uses a different Jolla key that is not
published in the repository. The trust anchor is therefore the signed metadata
checksum, not `rpm -K`. If Jolla rotates its release key, update
`JOLLA_KEY_FPR` (or set it in the environment).

---

## `extract-jolla-overlay.sh`

**Purpose:** extract `encsfa-fpd` and `libsailfishdevicelock.so.1.2.0` from the
official Jolla packages into `overlay/` (gitignored).

**Usage:**

```bash
./scripts/extract-jolla-overlay.sh <dir-with-rpms> [outdir]
```

**Inputs:** a directory containing

```
sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
```

from the Jolla 5.1.0.11 aarch64 repository. Requires `rpm2cpio` and `cpio` on
the host.

**Output:** `overlay/encsfa-fpd` and
`overlay/libsailfishdevicelock.so.1.2.0`, both gitignored. Copy them into a
`jolla/` directory on the phone, or let `install.sh` extract the RPMs there.

**License:** the extracted files are Jolla proprietary; do not commit or
redistribute them.

---

## `test-fpd.sh`

**Purpose:** quick sanity check over SSH.

Shows:

* `GetState` (`FPSTATE_IDLE` expected);
* `GetAll` (`finger1`, `finger2`, ...);
* optional `Enroll <name>` / `Identify` if passed an argument;
* the last 30 journal lines from `sailfish-fpd-community`.

Usage:

```bash
./scripts/test-fpd.sh
./scripts/test-fpd.sh enroll finger3
./scripts/test-fpd.sh identify
```

Enrollment requires the screen on and unlocked; the bridge/daemon timeout is
60 s (HAL) and each good touch reduces `remaining`.

---

## `deploy.sh`

**Purpose:** run the full installation in the right order:

```bash
./scripts/install-fpd.sh
./scripts/install-devicelock-overlay.sh
```

Then it prints the reboot/test instructions. Run `devel-su reboot` afterwards to verify
the boot ordering:

```
sailfish-fpd-community
  → sailfish-devicelock-encsfa-fpd
    → lipstick (encsfa-fpd plugin)
```

---

## `build-meta-rpm.sh`

**Purpose:** build the single end-user RPM and its phone-side wrapper.

**What it does:**

1. Extracts the daemon binary, D-Bus policy and unit from
   `dist/sailfish-fpd-community-*.rpm` (or falls back to the build tree).
2. Builds a payload with:
   * the daemon files,
   * `dist/libbiometry_fp_api.so`,
   * the four `overlay/` files,
   * `installer/install.sh`,
   * the project `README.md`.
3. Creates `xperia10v-fingerprint-1.0.tar.bz2`.
4. Builds `packaging/xperia10v-fingerprint.spec` with `mb2` for
   `SailfishOS-5.1.0.11-aarch64-qt612`.
5. Copies the result and the wrapper to `dist/`.

**Output:**

```
dist/xperia10v-fingerprint-1.0-8.aarch64.rpm
dist/install.sh
```

No compiler is needed; it bundles the already-built daemon/bridge/overlay. The
`rpmlint` errors about the `setgid` plugin and the `%post`/`%preun` commands are
expected.

## `installer/install.sh` (phone-side)

**Purpose:** the end-user validation/warning/confirmation wrapper. It runs **on
the phone**, not on the host.

**Usage:**

Copy the RPM, the wrapper and the two official Jolla packages to the phone
first; the wrapper selects the newest `xperia10v-fingerprint-*.aarch64.rpm` in
its own directory:

```bash
# on the host
ssh defaultuser@phone 'mkdir -p /home/defaultuser/xperia10v-fingerprint/jolla'
scp dist/xperia10v-fingerprint-1.0-8.aarch64.rpm dist/install.sh \
    defaultuser@phone:/home/defaultuser/xperia10v-fingerprint/
./scripts/extract-jolla-overlay.sh /path/to/jolla-rpms
scp overlay/encsfa-fpd overlay/libsailfishdevicelock.so.1.2.0 overlay/SHA256SUMS \
    defaultuser@phone:/home/defaultuser/xperia10v-fingerprint/jolla/

# on the phone
cd /home/defaultuser/xperia10v-fingerprint
devel-su sh install.sh --check   # validate only
devel-su sh install.sh           # warning + confirmation + install
# or point at another directory:
# devel-su sh install.sh --jolla /path/to/jolla
```

`--jolla DIR` may contain the two extracted files (`encsfa-fpd`,
`libsailfishdevicelock.so.1.2.0`) or the RPMs. RPM extraction needs
`rpm2cpio`/`cpio` on the phone, which this port image does not ship;
`prepare-phone.sh` extracts on the host instead. When `DIR/SHA256SUMS` exists,
the wrapper verifies the files before installing and aborts on a mismatch.

After a reflash the SSH host key changes; clear it with
remove the phone entry from `~/.ssh/known_hosts` before `scp`.

**What it validates:** Sailfish `5.1.0.11`, Lineage `22.2` (`pdx235`), Android
15 / SDK 35, `XQ-DC72`, the AIDL V4/gatekeeper libs, `/dev/esfp0`, the running
`vendor.fingerprint-default` service, `nemo-devicelock.socket`, and that the
official `sailfish-devicelock-fpd` package is not installed. A mismatch aborts.

**What it does:** prints the change summary (including that a reflash loses
the enrolments (fingerprints)), asks `Continue? [y/N]`, installs the two Jolla
overlay files (`encsfa-fpd` 2755 root:disk and `libsailfishdevicelock`), then
runs `XPERIA10V_FP_CONFIRM=1 rpm -Uvh --replacepkgs --nosignature --nodigest`,
and finally prints “Reboot required”.

**Why phone-side:** the host-side `deploy.sh` needs SSH/`sshpass` and the
container. The end user only needs developer mode/Terminal. The wrapper cannot
live inside the RPM because the RPM `%pre` gate runs before the installer is
available, so it ships next to the RPM (and a reference copy is included in the
RPM at `/usr/share/xperia10v-fingerprint/install.sh`). The Jolla binaries are not in
the RPM; the wrapper installs them from the supplied packages.

## Manual build commands (for reference)

```bash
# 1. AIDL bridge
cd "$TOP"
source build/envsetup.sh
lunch lineage_pdx235-ap4a-userdebug
m libbiometry_fp_api -j8

# 2. bridge RPM
cd /path/to/xperia10v-fingerprint
./scripts/build-bridge-rpm.sh

# 3. daemon RPM
./scripts/build-daemon-rpm.sh

# 4. install
./scripts/install-fpd.sh
./scripts/install-devicelock-overlay.sh
```

The first Android build is the only long step (it bootstraps soong and builds
the AIDL/keymaster/common libraries). Incremental builds of the bridge take
~10 s.
