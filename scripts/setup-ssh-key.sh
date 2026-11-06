#!/bin/bash
# Install an SSH key on the phone so later scripts need no password.
#
# DEVELOPER CONVENIENCE ONLY. This is not part of the end-user install, and the
# RPM/install.sh never touches SSH. The private key stays on this host and is
# not removed by uninstalling the fingerprint package. End users should use the
# password path (install.sh + scp/ssh) instead.
#
#   ./scripts/setup-ssh-key.sh              # prompts for the phone password
#   PHONE_PW='...' ./scripts/setup-ssh-key.sh
#   ./scripts/setup-ssh-key.sh --key ~/.ssh/my_key
#   ./scripts/setup-ssh-key.sh --phone defaultuser@10.0.0.5 --port 2222
#
# This is the safe alternative to caching a password: the password is used
# once (by ssh-copy-id); afterwards authentication uses the key. The key has no
# passphrase, so protect ~/.ssh (0600) and do not copy the private key around.
set -euo pipefail

PHONE="${PHONE:-phone}"
PHONE_PORT="${PHONE_PORT:-}"
KEY="${KEY:-$HOME/.ssh/id_ed25519_xperia10v}"

usage() {
    awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' \
        "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --phone)
            [ $# -ge 2 ] || { echo "ERROR: --phone needs a host" >&2; exit 1; }
            PHONE=$2; shift ;;
        --key)
            [ $# -ge 2 ] || { echo "ERROR: --key needs a path" >&2; exit 1; }
            KEY=$2; shift ;;
        --port)
            [ $# -ge 2 ] || { echo "ERROR: --port needs a number" >&2; exit 1; }
            PHONE_PORT=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

command -v ssh-keygen >/dev/null 2>&1 || { echo "ERROR: ssh-keygen is missing" >&2; exit 1; }
command -v ssh-copy-id >/dev/null 2>&1 || { echo "ERROR: ssh-copy-id is missing" >&2; exit 1; }

mkdir -p "$(dirname "$KEY")"
chmod 700 "$(dirname "$KEY")"

if [ ! -f "$KEY" ]; then
    echo "== generating $KEY =="
    ssh-keygen -q -t ed25519 -N '' -f "$KEY" \
        -C "xperia10v-fingerprint@$(hostname)"
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

SSH_PORT_ARGS=()
[ -n "${PHONE_PORT:-}" ] && SSH_PORT_ARGS=(-p "$PHONE_PORT")

echo "== installing $KEY.pub on $PHONE =="
if [ -n "${PHONE_PW:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || {
        echo "ERROR: PHONE_PW is set but sshpass is not installed" >&2
        exit 1
    }
    SSHPASS="$PHONE_PW" sshpass -e ssh-copy-id -i "$KEY.pub" \
        ${SSH_PORT_ARGS[@]+"${SSH_PORT_ARGS[@]}"} \
        -o StrictHostKeyChecking=accept-new "$PHONE"
    unset PHONE_PW SSHPASS
else
    ssh-copy-id -i "$KEY.pub" \
        ${SSH_PORT_ARGS[@]+"${SSH_PORT_ARGS[@]}"} \
        -o StrictHostKeyChecking=accept-new "$PHONE"
fi

echo "== testing key login =="
ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    ${SSH_PORT_ARGS[@]+"${SSH_PORT_ARGS[@]}"} \
    -o StrictHostKeyChecking=accept-new "$PHONE" 'echo "key login OK"'

cat <<EOF

Key installed. Use it explicitly:

    SSH_KEY=$KEY ./scripts/prepare-phone.sh
    SSH_KEY=$KEY ./scripts/test-fpd.sh

Or add this to ~/.ssh/config so plain \`ssh $PHONE\` uses it:

    Host $PHONE
        IdentityFile $KEY
        IdentitiesOnly yes

The private key stays on this host; only $KEY.pub was added to the phone's
~/.ssh/authorized_keys. It has no passphrase, so anyone who can read it can
log in as defaultuser. For development only — end users should use the
password path.

Remove it later with:

    ssh $PHONE 'sed -i "/xperia10v-fingerprint@/d" ~/.ssh/authorized_keys'
    rm -f $KEY $KEY.pub

The password was not stored anywhere by this script. If you exported
PHONE_PW in this shell, clear it with: unset PHONE_PW
EOF
