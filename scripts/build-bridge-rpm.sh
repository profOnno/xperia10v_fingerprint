#!/bin/bash
# Package the AIDL bridge as droid-biometry-fp.
#
# Prerequisites:
#   - libbiometry_fp_api.so built with build-android-bridge.sh
#   - Sailfish SDK target SailfishOS-5.1.0.11-aarch64-qt612
#   - the `sailfish` user can write to the temp build directory
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="${TOP:-$HOME/lineage-22.2}"
SRC="${SRC:-$ROOT/src/sailfish-fpd-community}"
PRODUCT="${PRODUCT:-pdx235}"
TARGET="${TARGET:-SailfishOS-5.1.0.11-aarch64-qt612}"

SO="$TOP/out/target/product/$PRODUCT/vendor/lib64/libbiometry_fp_api.so"
if [ ! -f "$SO" ]; then
    SO="$TOP/out/target/product/$PRODUCT/system/lib64/libbiometry_fp_api.so"
fi
if [ ! -f "$SO" ]; then
    echo "ERROR: libbiometry_fp_api.so not found under $TOP/out/target/product/$PRODUCT" >&2
    exit 1
fi

BUILD="$(mktemp -d /tmp/fpd-bridge-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

cp -a "$SRC/." "$BUILD/"
STAGE="$BUILD/droid-biometry-fp-0.0.0/out/target/product/$PRODUCT/system/lib64"
rm -rf "$BUILD/droid-biometry-fp-0.0.0"
mkdir -p "$STAGE"
cp -a "$SO" "$STAGE/"

tar -C "$BUILD" -czf "$BUILD/droid-biometry-fp-0.0.0.tgz" droid-biometry-fp-0.0.0
rm -rf "$BUILD/droid-biometry-fp-0.0.0"
chmod 644 "$BUILD/droid-biometry-fp-0.0.0.tgz"

chown -R sailfish:sailfish "$BUILD"
sudo -u sailfish -H /srv/sailfishos/sdks/sfossdk/sdk-chroot -m all bash -lc \
    "cd /parentroot$BUILD && mb2 -t $TARGET -s rpm/droid-biometry-fp.spec build"

mkdir -p "$ROOT/dist"
# The build user owns RPMS; copy the new RPM out before the trap removes BUILD.
cp "$BUILD"/RPMS/*.rpm "$ROOT/dist/"
ls -l "$ROOT"/dist/droid-biometry-fp-*.rpm
