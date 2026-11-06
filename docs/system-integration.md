# System integration

This document lists exactly what is installed/configured on the phone, why, and
how to roll it back.

---

## 1. systemd units

| Unit | State | Role |
|---|---|---|
| `sailfish-fpd-community.service` | enabled, active | D-Bus `org.sailfishos.fingerprint1`; loads the AIDL bridge |
| `sailfish-devicelock-encsfa-fpd.service` | enabled, active | official devicelock daemon with the fpd plugin (`encsfa-fpd --daemon`) |
| `jolla-devicelock-encsfa.service` | disabled, **masked**, inactive | port's old devicelock daemon (no fingerprint backend) |
| `nemo-devicelock.socket` | active | private socket used by the devicelock daemon and lipstick plugin |
| `wait_for_keymaster.service` | active (oneshot) | ensures keymaster is ready before `sailfish-fpd` |
| `mce.service` | active | fingerprint wakeup / display policy |
| `lipstick.service` (user) | active | loads `encsfa-fpd` as the device-lock plugin |

`nemo-devicelock.service` is now an **alias** for
`sailfish-devicelock-encsfa-fpd.service`; the old alias was removed when the old
daemon was disabled.

## 2. Boot order

```
droid-hal-init
  └─ vendor.fingerprint-default (AIDL V4 service)
wait_for_keymaster
  └─ sailfish-fpd-community
       └─ sailfish-devicelock-encsfa-fpd
            └─ lipstick (user session)
```

Implemented by:

* `sailfish-fpd-community.service`:
  `After=droid-hal-init.service droid-late-start.service wait_for_keymaster.service`
* `sailfish-devicelock-encsfa-fpd.service`:
  `After=dbus.socket mce.service nemo-devicelock.socket sailfish-fpd-community.service`
  and `Wants=sailfish-fpd-community.service`

The AIDL bridge also calls `AServiceManager_waitForService()`, so a late
`vendor.fingerprint-default` is tolerated.

## 3. Overlay files

Installed by `scripts/install-devicelock-overlay.sh`:

| Installed path | Mode/owner | Source |
|---|---|---|
| `/usr/lib64/qt5/plugins/devicelock/encsfa-fpd` | 2755 `root:disk` | `overlay/encsfa-fpd` |
| `/usr/lib64/libsailfishdevicelock.so.1.2.0` | 0755 `root:root` | `overlay/libsailfishdevicelock.so.1.2.0` |
| `/usr/lib64/libsailfishdevicelock.so.1.2` | symlink | created by script |
| `/usr/lib64/libsailfishdevicelock.so.1` | symlink | created by script |
| `/usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service` | 0644 | `overlay/sailfish-devicelock-encsfa-fpd.service` |
| `/usr/share/lipstick/devicelock/devicelock.conf` | 0644 | `overlay/devicelock.conf` |
| `/usr/share/lipstick/devicelock/devicelock.conf.bak` | backup | original port config |

Why an overlay: the official `sailfish-devicelock-fpd` RPM conflicts with
`jolla-devicelock-plugin-encsfa` 0.3.4-1.9.3 and zypper would remove the
adaptation pattern and `droid-hal-version-xqdc72`. The files are installed
manually instead; the old packages stay installed but the old daemon is disabled.

## 4. `devicelock.conf`

The port shipped:

```ini
[DeviceLock]
pluginName=/usr/lib64/qt5/plugins/devicelock/encpartition
```

The fpd version installs:

```ini
[DeviceLock]
pluginName=/usr/lib64/qt5/plugins/devicelock/encsfa-fpd
```

Lipstick reads this at startup. After changing it, **lipstick must be restarted**
(`systemctl --user daemon-reload && systemctl --user restart lipstick` as
`defaultuser`) or the phone rebooted. Without the restart, lipstick keeps the old
`encpartition` plugin and the lockscreen has no fingerprint unlock — even though
the daemon is correct.

## 5. mce / screen-off wakeup

`/etc/mce/60-fingerprint-sensor.conf`:

```
/system/osso/dsm/fingerprint/mode=1
```

`mode` values (mce `fingerprint_wakeup_mode`):

| Value | Meaning |
|---|---|
| `0` | never |
| `1` | always |
| `2` | proximity |

The same setting can be changed live:

```bash
mcetool --set-fingerprint-wakeup-mode=always
```

mce's `fpwakeup_evaluate_allowed()` additionally requires:

* `system_state == USER`
* `fpd_service_state == RUNNING`
* at least one enrolled fingerprint
* `powerkey_pressed == false`
* lid open
* display `OFF`/`LPM_OFF` (or `ON`/`DIM` with devicelock unlocked + tklock)

The power-key condition matters: **do not press the power button** when relying
on fingerprint wakeup. A light rest on the sensor surface is enough.

## 6. D-Bus names and paths

| Name / path | Owner |
|---|---|
| `org.sailfishos.fingerprint1` @ `/org/sailfishos/fingerprint1` | `sailfish-fpd-community` |
| `org.nemomobile.devicelock` @ `/devicelock`, `/authenticator` | `sailfish-devicelock-encsfa-fpd` |
| `android.hardware.biometrics.fingerprint.IFingerprint/default` | `vendor.fingerprint-default` (AIDL V4) |

The Settings page and lipstick use the devicelock private socket, not a public
`Fingerprint.Sensor` D-Bus interface. That is why `dbus-send ... Introspect`
does not show a fingerprint interface on `/devicelock`; the fingerprint data
flows over `nemo-devicelock.socket`.

## 7. Persistent data

| Path | Content | Survives reboot |
|---|---|---|
| `/var/lib/sailfish-fpd-community/100000/fingerprints.db` | display name ↔ HAL fid | yes |
| `/data/vendor_de/100000/fpdata/` | HAL template/cache directory | yes |
| `/var/lib/sailfish-fpd/gatekeeper_handle` | gatekeeper password handle | yes |
| `/usr/share/lipstick/devicelock/devicelock.conf` | fpd plugin selection | yes (but see caveat) |
| `/etc/mce/60-fingerprint-sensor.conf` | wakeup mode | yes |

## 8. Package state

| Package | State |
|---|---|
| `sailfish-fpd-community` | installed (provides `sailfish-fpd`) |
| `droid-biometry-fp` | installed (bridge `.so`) |
| `jolla-devicelock-daemon-encsfa` | installed, service disabled |
| `jolla-devicelock-plugin-encsfa` | installed, `encpartition` plugin unused |
| `nemo-qml-plugin-devicelock` | installed (Settings QML types) |
| `sailfish-devicelock-encsfa-fpd` | unit from the meta RPM; plugin/lib installed by `install.sh` |

Not installed/used:

* `sailfish-fpd` (Jolla closed daemon) — conflicts with the community package;
* `sailfish-fpd-slave-binder` — only speaks HIDL 2.1
  (`android.hardware.biometrics.fingerprint@2.1`), while this phone exposes AIDL
  V4. The community daemon + AIDL bridge replaces it.

## 9. Rollback

To return to the port's original devicelock behavior:

```bash
sudo systemctl disable --now sailfish-devicelock-encsfa-fpd
sudo cp /usr/share/lipstick/devicelock/devicelock.conf.bak \
        /usr/share/lipstick/devicelock/devicelock.conf
sudo systemctl unmask jolla-devicelock-encsfa
sudo systemctl enable --now jolla-devicelock-encsfa
sudo rm -f /usr/lib64/qt5/plugins/devicelock/encsfa-fpd \
           /usr/lib64/libsailfishdevicelock.so.1 \
           /usr/lib64/libsailfishdevicelock.so.1.2 \
           /usr/lib64/libsailfishdevicelock.so.1.2.0
# as defaultuser:
systemctl --user daemon-reload
systemctl --user restart lipstick
```

To remove the overlay files as well:

```bash
sudo rm -f /usr/lib64/qt5/plugins/devicelock/encsfa-fpd
sudo rm -f /usr/lib64/libsailfishdevicelock.so.1*
sudo rm -f /usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service
sudo systemctl daemon-reload
```

The community fpd and bridge can be removed with
`rpm -e sailfish-fpd-community droid-biometry-fp` (this removes the fingerprint
unlock, but the rest of Sailfish is unaffected).

## 10. Update caveats

* `jolla-devicelock-plugin-encsfa` owns
  `/usr/share/lipstick/devicelock/devicelock.conf`. A future update of that
  package may overwrite the fpd config. Keep
  `devicelock.conf.bak` and re-apply the fpd line if needed.
* The overlay files are unowned. A package transaction that installs the
  official `sailfish-devicelock-fpd` would conflict with the installed
  `jolla-devicelock-plugin-encsfa`; avoid installing it via zypper unless the
  port's pattern/plugin situation is reworked.
* `sailfish-fpd-community`/`droid-biometry-fp` are normal RPMs and can be
  upgraded with the `dist/` artifacts.
