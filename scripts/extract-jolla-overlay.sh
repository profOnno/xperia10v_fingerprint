#!/bin/sh
# Extract Jolla's devicelock overlay files from the official packages.
#
#   ./scripts/extract-jolla-overlay.sh /path/to/rpms [outdir]
#
# The two packages are:
#   sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
#   sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm
#
# They are Jolla proprietary; this project does not redistribute them. The
# extracted files are gitignored and are installed by installer/install.sh.
#
# Requires rpm2cpio and cpio on this machine (rpm2cpio is in the rpm package).
# On Debian/Ubuntu: sudo apt install rpm cpio

set -eu

usage() {
    echo "Usage: $0 <dir-with-jolla-rpms> [outdir]" >&2
    echo "  outdir defaults to overlay/" >&2
    exit 1
}

[ $# -ge 1 ] || usage
SRC=$1
OUT=${2:-overlay}

[ -d "$SRC" ] || { echo "ERROR: $SRC is not a directory" >&2; exit 1; }

FPD_RPM=$(ls -1t "$SRC"/sailfish-devicelock-fpd-*.aarch64.rpm 2>/dev/null | head -1 || true)
LIBS_RPM=$(ls -1t "$SRC"/sailfish-devicelock-libs-*.aarch64.rpm 2>/dev/null | head -1 || true)
[ -n "$FPD_RPM" ] || { echo "ERROR: sailfish-devicelock-fpd-*.aarch64.rpm not found in $SRC" >&2; exit 1; }
[ -n "$LIBS_RPM" ] || { echo "ERROR: sailfish-devicelock-libs-*.aarch64.rpm not found in $SRC" >&2; exit 1; }

command -v rpm2cpio >/dev/null 2>&1 || {
    echo "ERROR: rpm2cpio not found (install the rpm package)" >&2
    exit 1
}
command -v cpio >/dev/null 2>&1 || {
    echo "ERROR: cpio not found (install cpio)" >&2
    exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jolla-overlay.XXXXXX")
cleanup() {
    chmod -R u+rwX "$TMP" 2>/dev/null || :
    rm -rf "$TMP" 2>/dev/null || :
}
trap cleanup EXIT HUP INT TERM

( cd "$TMP" && rpm2cpio "$FPD_RPM" | cpio -idm --quiet --no-preserve-owner )
( cd "$TMP" && rpm2cpio "$LIBS_RPM" | cpio -idm --quiet --no-preserve-owner )

FPD="$TMP/usr/lib64/qt5/plugins/devicelock/encsfa-fpd"
LIB="$TMP/usr/lib64/libsailfishdevicelock.so.1.2.0"
[ -f "$FPD" ] || FPD=$(find "$TMP" -type f -name encsfa-fpd | head -1)
[ -f "$LIB" ] || LIB=$(find "$TMP" -type f -name 'libsailfishdevicelock.so.1.2.0' | head -1)
[ -n "$FPD" ] && [ -f "$FPD" ] || { echo "ERROR: encsfa-fpd not found in $FPD_RPM" >&2; exit 1; }
[ -n "$LIB" ] && [ -f "$LIB" ] || { echo "ERROR: libsailfishdevicelock.so.1.2.0 not found in $LIBS_RPM" >&2; exit 1; }

mkdir -p "$OUT"
cp "$FPD" "$OUT/encsfa-fpd"
cp "$LIB" "$OUT/libsailfishdevicelock.so.1.2.0"
( cd "$OUT" && sha256sum encsfa-fpd libsailfishdevicelock.so.1.2.0 > SHA256SUMS )

echo "Extracted to $OUT:"
ls -l "$OUT/encsfa-fpd" "$OUT/libsailfishdevicelock.so.1.2.0" "$OUT/SHA256SUMS"
echo
echo "These files are Jolla proprietary and are gitignored. Do not publish them."
echo "On the phone, put them in a jolla/ directory next to install.sh."
