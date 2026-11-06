#!/bin/sh
# Phone-side installer for xperia10v-fingerprint.
#
# Copy this file, xperia10v-fingerprint-*.aarch64.rpm and the Jolla package
# files into ~/xperia10v-fingerprint on the phone, then:
#
#   cd ~/xperia10v-fingerprint
#   devel-su sh install.sh
#
# or validate only:
#
#   devel-su sh install.sh --check
#
# The two Jolla packages are:
#   sailfish-devicelock-fpd-*.aarch64.rpm
#   sailfish-devicelock-libs-*.aarch64.rpm
#
# They are not redistributed with this project. Put them in a jolla/
# subdirectory, or pass --jolla DIR. Already-extracted files are accepted too.
#
# The RPM itself refuses to install unless XPERIA10V_FP_CONFIRM=1 is set; this
# script sets it after the compatibility checks and the confirmation prompt.

set -u

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: devel-su sh install.sh [--check] [--jolla DIR]

  --check       validate only, change nothing
  --jolla DIR   directory containing the two official Jolla packages
                (default: ./jolla, then the script's own directory)

DIR may contain either the RPMs:
  sailfish-devicelock-fpd-*.aarch64.rpm
  sailfish-devicelock-libs-*.aarch64.rpm
or the extracted files:
  encsfa-fpd
  libsailfishdevicelock.so.1.2.0
EOF
}

CHECK_ONLY=0
JOLLA_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --jolla)
            [ $# -ge 2 ] || fail "--jolla needs a directory"
            JOLLA_DIR=$2
            shift
            ;;
        --jolla=*) JOLLA_DIR=${1#--jolla=} ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[ "$(id -u)" = "0" ] || fail "run as root: devel-su sh install.sh"

DIR=$(cd "$(dirname "$0")" && pwd)
RPM=$(ls -1t "$DIR"/xperia10v-fingerprint-*.aarch64.rpm 2>/dev/null | head -1)
[ -n "$RPM" ] || fail "xperia10v-fingerprint-*.aarch64.rpm not found next to $0"

getp() {
    # getprop can abort after printing on this port; the value is already on
    # stdout, so hide stderr and ignore the exit status.
    getprop "$1" 2>/dev/null || true
}

echo "== compatibility checks =="

# Sailfish
[ -r /etc/os-release ] || fail "missing /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "sailfishos" ] || fail "not Sailfish OS (ID=${ID:-unknown})"
[ "${VERSION_ID:-}" = "5.1.0.11" ] || \
    fail "Sailfish ${VERSION_ID:-unknown}; this package is validated for 5.1.0.11"

[ "$(uname -m)" = "aarch64" ] || fail "not aarch64"

# Device / port
LINEAGE_DEV=$(getp ro.lineage.device)
[ "$LINEAGE_DEV" = "pdx235" ] || \
    fail "Lineage device '${LINEAGE_DEV:-unknown}'; expected pdx235"
VENDOR_DEV=$(getp ro.product.vendor.device)
[ "$VENDOR_DEV" = "XQ-DC72" ] || \
    fail "vendor device '${VENDOR_DEV:-unknown}'; expected XQ-DC72"

# Lineage / Android base
LINEAGE_VER=$(getp ro.lineage.build.version)
[ "$LINEAGE_VER" = "22.2" ] || \
    fail "Lineage ${LINEAGE_VER:-unknown}; expected 22.2"
SDK=$(getp ro.build.version.sdk)
[ "$SDK" = "35" ] || fail "Android SDK ${SDK:-unknown}; expected 35 (Android 15)"
REL=$(getp ro.build.version.release)
[ "$REL" = "15" ] || fail "Android ${REL:-unknown}; expected 15"

# Fingerprint HAL
[ "$(getp ro.hardware.fingerprint)" = "default" ] || \
    fail "unexpected ro.hardware.fingerprint=$(getp ro.hardware.fingerprint)"
[ -e /dev/esfp0 ] || fail "missing /dev/esfp0"
for lib in \
    hw/fingerprint.default.so \
    android.hardware.biometrics.fingerprint-V4-ndk.so \
    android.hardware.biometrics.common-V4-ndk.so \
    android.hardware.keymaster-V4-ndk.so \
    android.hardware.gatekeeper@1.0.so
do
    [ -e "/vendor/lib64/$lib" ] || fail "missing /vendor/lib64/$lib"
done

AIDL_STATE=$(getp init.svc.vendor.fingerprint-default)
[ "$AIDL_STATE" = "running" ] || \
    fail "vendor.fingerprint-default is '${AIDL_STATE:-unknown}', expected running"

# Port integration
systemctl cat nemo-devicelock.socket >/dev/null 2>&1 || \
    fail "nemo-devicelock.socket is missing (not the expected port image)"
if rpm -q sailfish-devicelock-fpd >/dev/null 2>&1; then
    fail "official sailfish-devicelock-fpd is installed; remove it before using this overlay"
fi

# Jolla overlay source: the files themselves or the official packages.
if [ -z "$JOLLA_DIR" ]; then
    for candidate in "$DIR/jolla" "$DIR"; do
        if [ -f "$candidate/encsfa-fpd" ] ||
           ls "$candidate"/sailfish-devicelock-fpd-*.aarch64.rpm >/dev/null 2>&1
        then
            JOLLA_DIR=$candidate
            break
        fi
    done
fi

FPD_SRC=""
LIB_SRC=""
JOLLA_SRC_KIND=""
if [ -n "$JOLLA_DIR" ] && [ -d "$JOLLA_DIR" ]; then
    if [ -f "$JOLLA_DIR/encsfa-fpd" ] && \
       [ -f "$JOLLA_DIR/libsailfishdevicelock.so.1.2.0" ]; then
        FPD_SRC="$JOLLA_DIR/encsfa-fpd"
        LIB_SRC="$JOLLA_DIR/libsailfishdevicelock.so.1.2.0"
        JOLLA_SRC_KIND="extracted files"
    else
        JOLLA_FPD_RPM=$(ls -1t "$JOLLA_DIR"/sailfish-devicelock-fpd-*.aarch64.rpm 2>/dev/null | head -1)
        JOLLA_LIBS_RPM=$(ls -1t "$JOLLA_DIR"/sailfish-devicelock-libs-*.aarch64.rpm 2>/dev/null | head -1)
        if [ -n "$JOLLA_FPD_RPM" ] && [ -n "$JOLLA_LIBS_RPM" ]; then
            JOLLA_SRC_KIND="official Jolla packages"
        fi
    fi
fi

if [ -z "$JOLLA_SRC_KIND" ]; then
    cat >&2 <<'EOF'
ERROR: the Jolla devicelock overlay is missing.

This project does not redistribute Jolla's proprietary files. Download these
two packages for Sailfish OS 5.1.0.11 (aarch64) from Jolla:

  sailfish-devicelock-fpd-1.2.0-1.3.12.jolla.aarch64.rpm
  sailfish-devicelock-libs-1.2.0-1.3.12.jolla.aarch64.rpm

Copy them next to install.sh in a jolla/ directory (or pass --jolla DIR),
then run again. On a computer you can also run:

  scripts/extract-jolla-overlay.sh <dir-with-rpms>

and copy the two extracted files to jolla/ on the phone.
EOF
    exit 1
fi

JOLLA_VERIFY=""
if [ -f "$JOLLA_DIR/SHA256SUMS" ]; then
    command -v sha256sum >/dev/null 2>&1 || \
        fail "sha256sum is missing; cannot verify the Jolla packages"
    if ( cd "$JOLLA_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
        JOLLA_VERIFY=", checksums OK"
    else
        fail "Jolla package checksum mismatch ($JOLLA_DIR/SHA256SUMS)"
    fi
fi

echo "  Sailfish:  $PRETTY_NAME"
echo "  Lineage:   $LINEAGE_VER / Android $REL (SDK $SDK)"
echo "  Device:    $LINEAGE_DEV / $VENDOR_DEV"
echo "  HAL:       ${AIDL_STATE} / esfp0"
echo "  Package:   $(basename "$RPM")"
if [ "$JOLLA_SRC_KIND" = "extracted files" ]; then
    echo "  Jolla:     $JOLLA_DIR (extracted files$JOLLA_VERIFY)"
else
    echo "  Jolla:     $JOLLA_DIR (official packages$JOLLA_VERIFY)"
fi
echo "== compatible =="

if [ "$CHECK_ONLY" = "1" ]; then
    exit 0
fi

cat <<'EOF'

This will:
  - install the sailfish-fpd daemon and the AIDL fingerprint bridge
  - install the Jolla devicelock fpd plugin/library from the supplied files
  - disable the old jolla-devicelock-encsfa daemon
  - enable sailfish-fpd-community and sailfish-devicelock-encsfa-fpd
  - switch devicelock.conf to the fpd plugin
  - create /data/vendor_de/100000/fpdata
  - require a reboot

If you reflashed Sailfish/userdata, existing enrolments (fingerprints) are gone; add a finger after reboot.

EOF

printf "Continue? [y/N] "
read -r answer
case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
esac

TMP=""
cleanup() {
    [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

if [ "$JOLLA_SRC_KIND" = "official Jolla packages" ]; then
    command -v rpm2cpio >/dev/null 2>&1 || \
        fail "rpm2cpio is missing; extract the packages on a computer with scripts/extract-jolla-overlay.sh and copy the files instead"
    command -v cpio >/dev/null 2>&1 || \
        fail "cpio is missing; extract the packages on a computer with scripts/extract-jolla-overlay.sh and copy the files instead"

    TMP=$(mktemp -d /tmp/xperia10v-jolla.XXXXXX) || fail "cannot create temp dir"
    ( cd "$TMP" && rpm2cpio "$JOLLA_FPD_RPM" | cpio -idm --quiet ) || \
        fail "cannot extract $JOLLA_FPD_RPM"
    ( cd "$TMP" && rpm2cpio "$JOLLA_LIBS_RPM" | cpio -idm --quiet ) || \
        fail "cannot extract $JOLLA_LIBS_RPM"

    FPD_SRC="$TMP/usr/lib64/qt5/plugins/devicelock/encsfa-fpd"
    LIB_SRC="$TMP/usr/lib64/libsailfishdevicelock.so.1.2.0"
    [ -f "$FPD_SRC" ] || FPD_SRC=$(find "$TMP" -type f -name encsfa-fpd | head -1)
    [ -f "$LIB_SRC" ] || LIB_SRC=$(find "$TMP" -type f -name 'libsailfishdevicelock.so.1.2.0' | head -1)
    [ -n "$FPD_SRC" ] && [ -f "$FPD_SRC" ] || fail "encsfa-fpd not found in the Jolla packages"
    [ -n "$LIB_SRC" ] && [ -f "$LIB_SRC" ] || fail "libsailfishdevicelock.so.1.2.0 not found in the Jolla packages"
fi

[ -n "$FPD_SRC" ] && [ -f "$FPD_SRC" ] || \
    fail "internal error: encsfa-fpd path is empty"
[ -n "$LIB_SRC" ] && [ -f "$LIB_SRC" ] || \
    fail "internal error: libsailfishdevicelock path is empty"

echo "== installing =="

install -D -m 2755 -o root -g disk "$FPD_SRC" \
    /usr/lib64/qt5/plugins/devicelock/encsfa-fpd || \
    fail "cannot install the Jolla devicelock plugin"
install -D -m 0755 -o root -g root "$LIB_SRC" \
    /usr/lib64/libsailfishdevicelock.so.1.2.0 || \
    fail "cannot install libsailfishdevicelock"
ln -sf libsailfishdevicelock.so.1.2.0 /usr/lib64/libsailfishdevicelock.so.1.2
ln -sf libsailfishdevicelock.so.1.2.0 /usr/lib64/libsailfishdevicelock.so.1
mkdir -p /usr/share/xperia10v-fingerprint
touch /usr/share/xperia10v-fingerprint/overlay-installed
/sbin/ldconfig 2>/dev/null || :

touch /run/xperia10v-fingerprint.confirm
XPERIA10V_FP_CONFIRM=1 rpm -Uvh --replacepkgs --nosignature --nodigest "$RPM"
rc=$?
rm -f /run/xperia10v-fingerprint.confirm
[ "$rc" -eq 0 ] || fail "rpm installation failed"

cat <<'EOF'

Installed. Reboot required (as root):

    devel-su reboot

After reboot: Settings -> Security -> Device Lock -> Fingerprint.
Then lock the phone and rest an enrolled finger on the sensor.
EOF
