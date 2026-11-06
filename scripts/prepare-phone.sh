#!/bin/bash
# Download the official Jolla devicelock packages, verify them against
# Jolla's signed repository metadata, and copy everything to the phone.
#
#   ./scripts/prepare-phone.sh                 # verify + copy to `phone`
#   ./scripts/prepare-phone.sh --ask           # ask for address + password
#   ./scripts/prepare-phone.sh --no-copy       # verify only
#   ./scripts/prepare-phone.sh --phone myphone
#   ./scripts/prepare-phone.sh --phone defaultuser@10.0.0.5 --port 2222
#   SSH_KEY=~/.ssh/id_ed25519_xperia10v ./scripts/prepare-phone.sh
#
# The verification chain:
#   1. download Jolla's repository key and pin its fingerprint;
#   2. verify the GPG signature on repomd.xml (the repo metadata);
#   3. verify the SHA256 of primary.xml.gz from the signed metadata;
#   4. verify the SHA256 of each RPM from primary.xml.gz.
#
# The RPM header signature uses a different Jolla key that is not published in
# the repository, so the signed-metadata checksum is the trust anchor here.
#
# Jolla's packages are proprietary. They are stored in dist/jolla/ (gitignored)
# and are never committed or published.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${JOLLA_REPO:-https://releases.jolla.com/releases/5.1.0.11/jolla/aarch64}"
KEY_FPR="${JOLLA_KEY_FPR:-BE6885DC16FA9420BA2DA558CB2904D42F7DA79C}"
CACHE="$ROOT/dist/jolla"
PHONE_EXPLICIT=0
if [ -n "${PHONE:-}" ]; then
    PHONE_EXPLICIT=1
fi
PHONE="${PHONE:-phone}"
PHONE_PORT="${PHONE_PORT:-}"
REMOTE_DIR="xperia10v-fingerprint"
COPY=1
ASK=0

usage() {
    awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' \
        "${BASH_SOURCE[0]}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-copy) COPY=0 ;;
        --copy) COPY=1 ;;
        --ask) ASK=1 ;;
        --phone)
            [ $# -ge 2 ] || { echo "ERROR: --phone needs a host" >&2; exit 1; }
            PHONE=$2
            PHONE_EXPLICIT=1
            shift
            ;;
        --port)
            [ $# -ge 2 ] || { echo "ERROR: --port needs a number" >&2; exit 1; }
            PHONE_PORT=$2
            shift
            ;;
        --cache)
            [ $# -ge 2 ] || { echo "ERROR: --cache needs a directory" >&2; exit 1; }
            CACHE=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

for t in curl gpg sha256sum python3; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "ERROR: $t is required on the host" >&2
        exit 1
    }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jolla-fetch.XXXXXX")
CTRL_SOCK=""
cleanup() {
    if [ -n "$CTRL_SOCK" ]; then
        ssh -o ControlPath="$CTRL_SOCK" -O exit "$PHONE" >/dev/null 2>&1 || :
    fi
    chmod -R u+rwX "$TMP" 2>/dev/null || :
    rm -rf "$TMP" 2>/dev/null || :
}
trap cleanup EXIT HUP INT TERM

echo "== Jolla repository =="
echo "  repo: $REPO"

curl -fsSL --retry 3 -o "$TMP/repomd.xml.key" "$REPO/repodata/repomd.xml.key"
curl -fsSL --retry 3 -o "$TMP/repomd.xml" "$REPO/repodata/repomd.xml"
curl -fsSL --retry 3 -o "$TMP/repomd.xml.asc" "$REPO/repodata/repomd.xml.asc"

export GNUPGHOME="$TMP/gpg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg -q --import "$TMP/repomd.xml.key" 2>/dev/null

SIG_FPR=$(gpg --status-fd 1 --verify "$TMP/repomd.xml.asc" "$TMP/repomd.xml" 2>/dev/null \
    | awk '/VALIDSIG/ {print $3; exit}')
if [ -z "$SIG_FPR" ]; then
    echo "ERROR: repomd.xml.asc did not verify" >&2
    exit 1
fi
if [ "$SIG_FPR" != "$KEY_FPR" ]; then
    echo "ERROR: repo metadata signed by $SIG_FPR, expected $KEY_FPR" >&2
    exit 1
fi
echo "  signing key: $SIG_FPR (verified)"

# Locate and verify the primary metadata.
PRIMARY_LOC=$(python3 - "$TMP/repomd.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"r": "http://linux.duke.edu/metadata/repo"}
for data in ET.parse(sys.argv[1]).getroot().findall("r:data", ns):
    if data.get("type") == "primary":
        print(data.find("r:location", ns).get("href"))
        break
PY
)
[ -n "$PRIMARY_LOC" ] || { echo "ERROR: primary metadata not listed" >&2; exit 1; }

PRIMARY_SUM=$(python3 - "$TMP/repomd.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"r": "http://linux.duke.edu/metadata/repo"}
for data in ET.parse(sys.argv[1]).getroot().findall("r:data", ns):
    if data.get("type") == "primary":
        print(data.find("r:checksum", ns).text)
        break
PY
)

curl -fsSL --retry 3 -o "$TMP/primary.xml.gz" "$REPO/$PRIMARY_LOC"
echo "$PRIMARY_SUM  $TMP/primary.xml.gz" | sha256sum -c - >/dev/null
echo "  primary metadata: verified"

mkdir -p "$CACHE"

python3 - "$TMP/primary.xml.gz" > "$TMP/packages.txt" <<'PY'
import sys, gzip, xml.etree.ElementTree as ET
want = {"sailfish-devicelock-fpd", "sailfish-devicelock-libs"}
ns = {"c": "http://linux.duke.edu/metadata/common"}
root = ET.parse(gzip.open(sys.argv[1])).getroot()
for pkg in root.findall("c:package", ns):
    name = pkg.find("c:name", ns).text
    if name not in want:
        continue
    ver = pkg.find("c:version", ns)
    loc = pkg.find("c:location", ns).get("href")
    chk = pkg.find("c:checksum", ns)
    print("|".join([name, ver.get("ver"), ver.get("rel"),
                    chk.get("type"), chk.text, loc]))
PY

[ -s "$TMP/packages.txt" ] || { echo "ERROR: Jolla packages not found in the repo" >&2; exit 1; }

while IFS='|' read -r name ver rel typ sum loc; do
    [ "$typ" = "sha256" ] || { echo "ERROR: unsupported checksum $typ for $name" >&2; exit 1; }
    file="$CACHE/$name-$ver-$rel.aarch64.rpm"
    if [ -f "$file" ] && echo "$sum  $file" | sha256sum -c - >/dev/null 2>&1; then
        echo "  $name-$ver-$rel: cached"
    else
        echo "  downloading $name-$ver-$rel"
        curl -fsSL --retry 3 -o "$file.part" "$REPO/$loc"
        echo "$sum  $file.part" | sha256sum -c - >/dev/null
        mv "$file.part" "$file"
        echo "  $name-$ver-$rel: checksum OK"
    fi
done < "$TMP/packages.txt"

( cd "$CACHE" && sha256sum sailfish-devicelock-*.aarch64.rpm > SHA256SUMS )

EXTRACTED="$CACHE/extracted"
EXTRACT_OK=0
if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
    echo "  extracting on the host (the phone does not need cpio)"
    chmod -R u+rwX "$EXTRACTED" 2>/dev/null || :
    rm -rf "$EXTRACTED" 2>/dev/null || :
    mkdir -p "$EXTRACTED"
    XTMP=$(mktemp -d "$TMP/extract.XXXXXX")
    for rpm in "$CACHE"/sailfish-devicelock-*.aarch64.rpm; do
        ( cd "$XTMP" && rpm2cpio "$rpm" | cpio -idm --quiet --no-preserve-owner ) || {
            echo "ERROR: failed to extract $rpm" >&2
            exit 1
        }
    done
    cp "$XTMP/usr/lib64/qt5/plugins/devicelock/encsfa-fpd" "$EXTRACTED/"
    cp "$XTMP/usr/lib64/libsailfishdevicelock.so.1.2.0" "$EXTRACTED/"
    ( cd "$EXTRACTED" && \
      sha256sum encsfa-fpd libsailfishdevicelock.so.1.2.0 > SHA256SUMS )
    EXTRACT_OK=1
else
    echo "  NOTE: rpm2cpio/cpio missing on the host; copying RPMs instead."
    echo "        The phone then needs cpio. Install rpm2cpio and cpio to avoid that."
fi

echo
echo "Verified Jolla packages in $CACHE:"
ls -l "$CACHE"/sailfish-devicelock-*.aarch64.rpm "$CACHE/SHA256SUMS"
if [ "$EXTRACT_OK" -eq 1 ]; then
    ls -l "$EXTRACTED"/encsfa-fpd \
        "$EXTRACTED/libsailfishdevicelock.so.1.2.0" "$EXTRACTED/SHA256SUMS"
fi

if [ "$COPY" -eq 0 ]; then
    echo
    echo "Skipped copying (--no-copy)."
    exit 0
fi

DIST_RPM=$(ls -1t "$ROOT"/dist/xperia10v-fingerprint-*.aarch64.rpm 2>/dev/null | head -1 || true)
[ -n "$DIST_RPM" ] || {
    echo "ERROR: no dist/xperia10v-fingerprint-*.aarch64.rpm; run ./scripts/build-meta-rpm.sh" >&2
    exit 1
}
[ -f "$ROOT/dist/install.sh" ] || {
    echo "ERROR: dist/install.sh is missing; run ./scripts/build-meta-rpm.sh" >&2
    exit 1
}

if [ "$ASK" -eq 1 ] && [ -n "${PHONE_PW:-}" ]; then
    echo "ERROR: --ask and PHONE_PW are mutually exclusive" >&2
    exit 1
fi

if [ "$ASK" -eq 1 ] && [ "$PHONE_EXPLICIT" -eq 0 ]; then
    echo
    echo "== phone address =="
    echo "   Settings -> Developer tools -> SSH shows the IP address."
    printf 'Phone IP/host (empty = SSH alias "phone"): '
    read -r answer
    if [ -n "$answer" ]; then
        PHONE=$answer
        if [ -z "${PHONE_PORT:-}" ]; then
            printf 'SSH port [22]: '
            read -r answer
            PHONE_PORT=${answer:-22}
        fi
        case "$PHONE" in
            *@*) ;;
            *)
                printf 'SSH user [defaultuser]: '
                read -r answer
                PHONE="${answer:-defaultuser}@$PHONE"
                ;;
        esac
    fi
fi

SSH=(ssh)
SCP=(scp)
if [ -n "${PHONE_PORT:-}" ]; then
    SSH+=(-p "$PHONE_PORT")
    SCP+=(-P "$PHONE_PORT")
fi
if [ -n "${SSH_KEY:-}" ]; then
    SSH+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
    SCP+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi
if [ -n "${PHONE_PW:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || {
        echo "ERROR: PHONE_PW is set but sshpass is not installed" >&2
        exit 1
    }
    SSH=(sshpass -e "${SSH[@]}")
    SCP=(sshpass -e "${SCP[@]}")
elif [ "$ASK" -eq 1 ]; then
    # One interactive SSH connection; ssh/scp reuse it (no sshpass needed).
    CTRL_SOCK="$TMP/ssh-control"
    echo
    echo "== opening SSH connection to $PHONE =="
    echo "   ssh may ask for the password once; scp/ssh reuse the connection."
    if ! "${SSH[@]}" -o ControlMaster=yes -o ControlPath="$CTRL_SOCK" \
         -o ControlPersist=120 -o StrictHostKeyChecking=accept-new \
         -fN "$PHONE"; then
        cat >&2 <<EOF
ERROR: could not connect to '$PHONE'.

Use an SSH alias in ~/.ssh/config, or pass the host and port:

    $0 --phone defaultuser@HOST --port 2222 --ask

Example ~/.ssh/config:

    Host phone
        HostName HOST
        Port 2222
        User defaultuser
EOF
        exit 1
    fi
    SSH+=(-o ControlPath="$CTRL_SOCK")
    SCP+=(-o ControlPath="$CTRL_SOCK")
fi

echo
echo "== copying to $PHONE =="
export SSHPASS="${PHONE_PW:-}"
"${SSH[@]}" -o StrictHostKeyChecking=accept-new "$PHONE" \
    "mkdir -p ~/$REMOTE_DIR/jolla"
"${SCP[@]}" -o StrictHostKeyChecking=accept-new \
    "$DIST_RPM" "$ROOT/dist/install.sh" "$PHONE:~/$REMOTE_DIR/"
if [ "$EXTRACT_OK" -eq 1 ]; then
    "${SSH[@]}" -o StrictHostKeyChecking=accept-new "$PHONE" \
        "rm -f ~/$REMOTE_DIR/jolla/*.rpm"
    "${SCP[@]}" -o StrictHostKeyChecking=accept-new \
        "$EXTRACTED/encsfa-fpd" \
        "$EXTRACTED/libsailfishdevicelock.so.1.2.0" \
        "$EXTRACTED/SHA256SUMS" "$PHONE:~/$REMOTE_DIR/jolla/"
    JOLLA_FILES="  ~/$REMOTE_DIR/jolla/encsfa-fpd
  ~/$REMOTE_DIR/jolla/libsailfishdevicelock.so.1.2.0
  ~/$REMOTE_DIR/jolla/SHA256SUMS"
else
    "${SSH[@]}" -o StrictHostKeyChecking=accept-new "$PHONE" \
        "rm -f ~/$REMOTE_DIR/jolla/encsfa-fpd ~/$REMOTE_DIR/jolla/libsailfishdevicelock.so.1.2.0"
    "${SCP[@]}" -o StrictHostKeyChecking=accept-new \
        "$CACHE"/sailfish-devicelock-*.aarch64.rpm "$CACHE/SHA256SUMS" \
        "$PHONE:~/$REMOTE_DIR/jolla/"
    JOLLA_FILES="  ~/$REMOTE_DIR/jolla/sailfish-devicelock-fpd-*.aarch64.rpm
  ~/$REMOTE_DIR/jolla/sailfish-devicelock-libs-*.aarch64.rpm
  ~/$REMOTE_DIR/jolla/SHA256SUMS"
fi

SSH_HINT="ssh $PHONE"
if [ -n "${PHONE_PORT:-}" ]; then
    SSH_HINT="ssh -p $PHONE_PORT $PHONE"
fi

cat <<EOF

== files copied — NOT installed yet ==

Copied to the phone:
  ~/$REMOTE_DIR/$(basename "$DIST_RPM")
  ~/$REMOTE_DIR/install.sh
$JOLLA_FILES

The fingerprint stack has NOT been installed and the phone has NOT been
changed. Only the files were copied.

NEXT STEP

1. On THIS COMPUTER, open an SSH session to the phone:

     $SSH_HINT

2. Once you are at the phone's shell prompt, run these ON THE PHONE:

     cd ~/$REMOTE_DIR
     devel-su sh install.sh --check    # validate only, no changes
     devel-su sh install.sh            # install; asks Continue? [y/N]
     devel-su reboot

devel-su asks for the device lock code, not the SSH password.
Nothing is installed until you answer y to the install prompt, and a reboot
is required afterwards.
EOF

if [ -n "${PHONE_PW:-}" ] && [ "$ASK" -eq 0 ]; then
    cat <<'EOF'

PHONE_PW came from your shell environment and is still set there. Clear it now:

    unset PHONE_PW SSHPASS

If you typed `export PHONE_PW=...`, also remove that line from your history
(`history | grep PHONE_PW`, then `history -d <line>`).
EOF
elif [ "$ASK" -eq 1 ]; then
    echo
    echo "The password was entered only in ssh's prompt; nothing was stored."
fi
