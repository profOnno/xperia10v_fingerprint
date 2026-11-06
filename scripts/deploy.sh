#!/bin/bash
# Full deployment: fpd daemon + bridge, then the devicelock fpd overlay.
#
# PHONE=phone PHONE_PW=<ssh-password> ./deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/install-fpd.sh"
"$ROOT/scripts/install-devicelock-overlay.sh"

cat <<'EOF'

Deployment complete.

Recommended next steps:
  1. Reboot the phone (verifies the boot ordering:
       sailfish-fpd-community -> sailfish-devicelock-encsfa-fpd -> lipstick).
  2. Settings -> Security -> Device Lock -> Fingerprint: add/remove fingers.
  3. Lock the phone and rest an enrolled finger on the power-button sensor.

Quick check without reboot:
  ./scripts/test-fpd.sh
EOF
