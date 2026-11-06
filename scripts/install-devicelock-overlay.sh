#!/bin/bash
# Install the official Jolla devicelock fpd plugin/daemon as an overlay and
# switch lipstick to it.
#
# PHONE=phone PHONE_PW=<ssh-password> ./install-devicelock-overlay.sh
#
# The overlay is used because the official sailfish-devicelock-fpd 5.1 RPM
# conflicts with the port's jolla-devicelock-plugin-encsfa and would remove the
# device adaptation pattern.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/overlay"
PHONE="${PHONE:-phone}"
PHONE_PW="${PHONE_PW:?set PHONE_PW to the phone SSH password}"
DEVEL_PW="${DEVEL_PW:-$PHONE_PW}"

for f in encsfa-fpd libsailfishdevicelock.so.1.2.0 devicelock.conf \
         sailfish-devicelock-encsfa-fpd.service; do
    if [ ! -f "$OVERLAY/$f" ]; then
        echo "ERROR: missing overlay file $OVERLAY/$f" >&2
        exit 1
    fi
done

run_root() {
    SSHPASS="$PHONE_PW" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PHONE" \
        "echo '$DEVEL_PW' | devel-su /bin/sh -c '$1'"
}

echo "== copying overlay =="
SSHPASS="$PHONE_PW" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PHONE" 'mkdir -p /tmp/fpd-overlay'
SSHPASS="$PHONE_PW" sshpass -e scp -o StrictHostKeyChecking=accept-new \
    "$OVERLAY/encsfa-fpd" \
    "$OVERLAY/libsailfishdevicelock.so.1.2.0" \
    "$OVERLAY/devicelock.conf" \
    "$OVERLAY/sailfish-devicelock-encsfa-fpd.service" \
    "$PHONE:/tmp/fpd-overlay/"

echo "== installing files =="
run_root "[ -f /usr/share/lipstick/devicelock/devicelock.conf.bak ] || cp -a /usr/share/lipstick/devicelock/devicelock.conf /usr/share/lipstick/devicelock/devicelock.conf.bak"
run_root "install -m 2755 -o root -g disk /tmp/fpd-overlay/encsfa-fpd /usr/lib64/qt5/plugins/devicelock/encsfa-fpd"
run_root "install -m 755 /tmp/fpd-overlay/libsailfishdevicelock.so.1.2.0 /usr/lib64/libsailfishdevicelock.so.1.2.0 && ln -sf libsailfishdevicelock.so.1.2.0 /usr/lib64/libsailfishdevicelock.so.1.2 && ln -sf libsailfishdevicelock.so.1.2.0 /usr/lib64/libsailfishdevicelock.so.1"
run_root "install -m 644 /tmp/fpd-overlay/sailfish-devicelock-encsfa-fpd.service /usr/lib/systemd/system/sailfish-devicelock-encsfa-fpd.service"

echo "== switching devicelock daemon =="
run_root "systemctl disable --now jolla-devicelock-encsfa 2>/dev/null || true"
run_root "rm -f /etc/systemd/system/nemo-devicelock.service"
run_root "systemctl daemon-reload"
run_root "systemctl enable --now sailfish-devicelock-encsfa-fpd"
run_root "install -m 644 /tmp/fpd-overlay/devicelock.conf /usr/share/lipstick/devicelock/devicelock.conf"
run_root "systemctl daemon-reload"

echo "== restarting lipstick to load the fpd device-lock plugin =="
run_root "su -s /bin/sh defaultuser -c \"export XDG_RUNTIME_DIR=/run/user/100000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket; systemctl --user daemon-reload; systemctl --user restart lipstick\""
sleep 4

echo "== status =="
run_root "systemctl --no-pager --full status sailfish-devicelock-encsfa-fpd | head -20 || true"
run_root "cat /usr/share/lipstick/devicelock/devicelock.conf"

cat <<'EOF'

Done. Recommended:
  1. Reboot the phone.
  2. Settings -> Security -> Device Lock -> Fingerprint: add/remove fingers.
  3. Lock the phone and rest an enrolled finger on the power-button sensor.

Rollback:
  systemctl disable --now sailfish-devicelock-encsfa-fpd
  cp /usr/share/lipstick/devicelock/devicelock.conf.bak \
     /usr/share/lipstick/devicelock/devicelock.conf
  systemctl enable --now jolla-devicelock-encsfa
EOF
