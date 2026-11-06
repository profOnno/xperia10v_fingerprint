#!/bin/bash
# Install sailfish-fpd-community + droid-biometry-fp on the phone.
#
# PHONE=phone PHONE_PW=<ssh-password> ./install-fpd.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
PHONE="${PHONE:-phone}"
PHONE_PW="${PHONE_PW:?set PHONE_PW to the phone SSH password}"
DEVEL_PW="${DEVEL_PW:-$PHONE_PW}"

BIOMETRY="$(ls -1 "$DIST"/droid-biometry-fp-*.rpm 2>/dev/null | tail -1 || true)"
FPD="$(ls -1 "$DIST"/sailfish-fpd-community-*.rpm 2>/dev/null | tail -1 || true)"

if [ -z "$BIOMETRY" ] || [ -z "$FPD" ]; then
    echo "ERROR: missing RPMs in $DIST" >&2
    echo "  droid-biometry-fp: ${BIOMETRY:-<none>}" >&2
    echo "  sailfish-fpd-community: ${FPD:-<none>}" >&2
    exit 1
fi

run_root() {
    # devel-su -c execs one program; compound commands need a shell.
    SSHPASS="$PHONE_PW" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PHONE" \
        "echo '$DEVEL_PW' | devel-su /bin/sh -c '$1'"
}

echo "== preparing phone =="
SSHPASS="$PHONE_PW" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PHONE" 'mkdir -p /tmp/fp'
SSHPASS="$PHONE_PW" sshpass -e scp -o StrictHostKeyChecking=accept-new \
    "$BIOMETRY" "$FPD" "$PHONE:/tmp/fp/"

echo "== AIDL HAL store directory =="
run_root "mkdir -p /data/vendor_de/100000/fpdata && chown -R system:system /data/vendor_de/100000 && chmod 770 /data/vendor_de/100000/fpdata"

echo "== installing RPMs =="
run_root "rpm -Uvh --replacepkgs --nosignature --nodigest /tmp/fp/droid-biometry-fp-*.rpm /tmp/fp/sailfish-fpd-community-*.rpm"

echo "== starting sailfish-fpd-community =="
run_root "systemctl daemon-reload; systemctl reload dbus || true; systemctl enable --now sailfish-fpd-community"
sleep 2

echo "== status =="
run_root "systemctl --no-pager --full status sailfish-fpd-community | head -20 || true"
echo
run_root "dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.GetState"

cat <<'EOF'

Next:
  - Install the devicelock overlay: ./install-devicelock-overlay.sh
  - Or run the full deployment:  ./deploy.sh
EOF
