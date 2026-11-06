#!/bin/bash
# Quick fingerprint stack check over SSH.
#
#   ./test-fpd.sh                 # state + finger list + journal
#   ./test-fpd.sh enroll finger3  # arm enrollment (screen on & unlocked)
#   ./test-fpd.sh identify        # arm authentication
#   ./test-fpd.sh journal         # only the journal tail
set -euo pipefail

PHONE="${PHONE:-phone}"
PHONE_PW="${PHONE_PW:?set PHONE_PW to the phone SSH password}"
DEVEL_PW="${DEVEL_PW:-$PHONE_PW}"
ACTION="${1:-state}"

run_root() {
    SSHPASS="$PHONE_PW" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$PHONE" \
        "echo '$DEVEL_PW' | devel-su /bin/sh -c '$1'"
}

state() {
    echo "=== state ==="
    run_root "dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.GetState"
    echo "=== fingers ==="
    run_root "dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.GetAll"
}

journal() {
    echo "=== journal ==="
    run_root "journalctl -u sailfish-fpd-community -n 40 --no-pager"
}

case "$ACTION" in
    state)
        state
        journal
        ;;
    enroll)
        NAME="${2:-finger3}"
        echo "Arming enrollment '$NAME' (screen must be on and unlocked)."
        run_root "dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.Enroll string:\"$NAME\""
        sleep 1
        state
        echo "Touch the sensor repeatedly, shifting the fingertip; watch:"
        echo "  ./test-fpd.sh journal"
        ;;
    identify)
        echo "Arming identify (120 s window)."
        run_root "dbus-send --system --print-reply --dest=org.sailfishos.fingerprint1 /org/sailfishos/fingerprint1 org.sailfishos.fingerprint1.Identify"
        sleep 1
        state
        ;;
    journal)
        journal
        ;;
    *)
        echo "usage: $0 [state|enroll <name>|identify|journal]" >&2
        exit 2
        ;;
esac
