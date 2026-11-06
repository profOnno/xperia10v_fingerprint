#!/bin/bash
# Build the single xperia10v-fingerprint RPM and its phone-side install.sh.
#
# It bundles the already-built daemon/bridge/overlay; no compiler is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
TARGET="${TARGET:-SailfishOS-5.1.0.11-aarch64-qt612}"

[ -f "$DIST/libbiometry_fp_api.so" ] || {
    echo "ERROR: $DIST/libbiometry_fp_api.so is missing" >&2
    exit 1
}
[ -f "$ROOT/overlay/sailfish-devicelock-encsfa-fpd.service" ] || {
    echo "ERROR: overlay unit is missing" >&2
    exit 1
}
[ -f "$ROOT/overlay/devicelock.conf" ] || {
    echo "ERROR: overlay devicelock.conf is missing" >&2
    exit 1
}

BUILD="$(mktemp -d /tmp/fpd-meta.XXXXXX)"
EXTRACT="$(mktemp -d /tmp/fpd-meta-extract.XXXXXX)"
trap 'rm -rf "$BUILD" "$EXTRACT"' EXIT

PAYLOAD="$BUILD/xperia10v-fingerprint-1.0"
mkdir -p "$PAYLOAD"

# The daemon binary/conf/unit come from the split RPM (or the build tree).
DAEMON_RPM=$(ls -1 "$DIST"/sailfish-fpd-community-*.aarch64.rpm 2>/dev/null | tail -1 || true)
if [ -n "$DAEMON_RPM" ]; then
    chown -R sailfish:sailfish "$EXTRACT"
    sudo -u sailfish -H /srv/sailfishos/sdks/sfossdk/sdk-chroot -m all bash -lc \
        "cd /parentroot$EXTRACT && rpm2cpio /parentroot$DAEMON_RPM | cpio -idm --quiet"
    cp "$EXTRACT/usr/bin/sailfish-fpd-community" "$PAYLOAD/"
    cp "$EXTRACT/etc/dbus-1/system.d/org.sailfishos.fingerprint1.conf" "$PAYLOAD/"
    cp "$EXTRACT/usr/lib/systemd/system/sailfish-fpd-community.service" "$PAYLOAD/"
elif [ -x "${DAEMON_BIN:-$ROOT/../sailfish-fpd-community/sailfish-fpd-community}" ]; then
    cp "${DAEMON_BIN:-$ROOT/../sailfish-fpd-community/sailfish-fpd-community}" "$PAYLOAD/"
    cp "$ROOT/src/sailfish-fpd-community/org.sailfishos.fingerprint1.conf" "$PAYLOAD/"
    cp "$ROOT/src/sailfish-fpd-community/sailfish-fpd-community.service" "$PAYLOAD/"
else
    echo "ERROR: no daemon binary or daemon RPM found" >&2
    exit 1
fi

cp "$DIST/libbiometry_fp_api.so" "$PAYLOAD/"
cp "$ROOT/overlay/devicelock.conf" "$PAYLOAD/"
cp "$ROOT/overlay/sailfish-devicelock-encsfa-fpd.service" "$PAYLOAD/"
cp "$ROOT/installer/install.sh" "$PAYLOAD/"
cp "$ROOT/README.md" "$PAYLOAD/"

tar -C "$BUILD" -cjf "$BUILD/xperia10v-fingerprint-1.0.tar.bz2" xperia10v-fingerprint-1.0
cp "$ROOT/packaging/xperia10v-fingerprint.spec" "$BUILD/"

chown -R sailfish:sailfish "$BUILD"
sudo -u sailfish -H /srv/sailfishos/sdks/sfossdk/sdk-chroot -m all bash -lc \
    "cd /parentroot$BUILD && mb2 -t $TARGET -s xperia10v-fingerprint.spec build"

mkdir -p "$DIST"
cp "$BUILD"/RPMS/*.rpm "$DIST/"
cp "$ROOT/installer/install.sh" "$DIST/install.sh"
chmod 0755 "$DIST/install.sh"

echo
echo "Single-RPM installer ready:"
ls -l "$DIST"/xperia10v-fingerprint-*.aarch64.rpm "$DIST/install.sh"
