# Devicelock fpd overlay

The fpd device-lock support is provided by Jolla's official packages:

| File | Source package |
|---|---|
| `encsfa-fpd` | `sailfish-devicelock-fpd` |
| `libsailfishdevicelock.so.1.2.0` | `sailfish-devicelock-libs` |
| `devicelock.conf` | `sailfish-devicelock-fpd` (configuration only) |
| `sailfish-devicelock-encsfa-fpd.service` | based on the same package, with the boot-order fix below |

The binaries are **Jolla proprietary** and are **not** included in this
repository or in the published RPM. `installer/install.sh` copies them from
the official packages that you supply.

## Getting the files

Download these two packages for Sailfish OS 5.1.0.11 (aarch64) from Jolla:

```
sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
```

They are in the Jolla 5.1.0.11 aarch64 repository
(`releases.jolla.com/releases/5.1.0.11/jolla/aarch64/`).

The easy path is:

```bash
./scripts/prepare-phone.sh
```

It downloads the RPMs, verifies them against Jolla's signed repository
metadata (GPG + SHA256), and copies them to `jolla/` on the phone.

Or, manually, either:

* put both RPMs in a `jolla/` directory next to `install.sh` on the phone, or
* extract them on a computer and copy the two files:

```bash
./scripts/extract-jolla-overlay.sh /path/to/rpms
# writes overlay/encsfa-fpd and overlay/libsailfishdevicelock.so.1.2.0
```

`overlay/encsfa-fpd` and `overlay/libsailfishdevicelock.so.1.2.0` are
gitignored. Do not commit or redistribute them.

## Why an overlay instead of the RPM

The official `sailfish-devicelock-fpd` 5.1 package conflicts with the port's
`jolla-devicelock-plugin-encsfa` 0.3.4-1.9.3 and the zypper solver would remove
the `patterns-sailfish-device-adaptation-xqdc72` pattern and
`droid-hal-version-xqdc72`. The daemon and plugin files themselves are drop-in
compatible, so they are installed as an overlay while the port's packages remain
untouched.

## Service boot-order fix

The upstream unit only waits for `dbus.socket`, `mce.service` and
`nemo-devicelock.socket`. This port's fpd daemon is a separate unit, so the
overlay unit adds:

```
After=... sailfish-fpd-community.service
Wants=mce.service sailfish-fpd-community.service
```

Without that, the devicelock daemon can start before `org.sailfishos.fingerprint1`
exists and never initialise its fingerprint service.

## Boot start

The upstream unit only has:

```
[Install]
Alias=nemo-devicelock.service
```

On this port that creates the alias but **not** a `multi-user.target.wants`
start link, so the daemon stayed inactive after reboot. The overlay unit adds:

```
WantedBy=multi-user.target
```

so `systemctl enable` creates the boot link. The meta RPM `%post` also
stops and masks the old `jolla-devicelock-encsfa` daemon and restarts
`nemo-devicelock.socket`; otherwise both daemons run and the socket is served
by the old one (no fingerprint service).

## Installation

`installer/install.sh` does the work on the phone:

1. extracts `encsfa-fpd` and `libsailfishdevicelock.so.1.2.0` from the Jolla
   RPMs (or uses already-extracted files),
2. installs `encsfa-fpd` as `root:disk 2755` and the library with its
   `so.1`/`so.1.2` symlinks,
3. runs the meta RPM, whose `%post` installs the unit, disables the old daemon,
   and enables/starts the new one,
4. switches `devicelock.conf` to `pluginName=encsfa-fpd`.

The meta RPM `%pre` refuses to run if the two Jolla files are missing, so a
direct `rpm -Uvh` cannot leave a half-configured stack.

## License

The binaries are Jolla proprietary packages. They are not part of this
project's source or releases. Check Jolla's terms before redistributing them.
