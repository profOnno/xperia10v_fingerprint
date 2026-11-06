#!/bin/bash
# Build the sailfish-fpd-community RPM.
#
# Prerequisites:
#   - Sailfish SDK target SailfishOS-5.1.0.11-aarch64-qt612
#   - Qt5 Core/DBus development files in the target
#   - libhybris-common available to the target linker, e.g.:
#       cp /path/to/phone/usr/lib64/libhybris-common.so.1.0.0 \
#          /srv/sailfishos/targets/SailfishOS-5.1.0.11-aarch64-qt612/usr/lib64/
#       ln -sf libhybris-common.so.1.0.0 \
#          /srv/sailfishos/targets/SailfishOS-5.1.0.11-aarch64-qt612/usr/lib64/libhybris-common.so
#       ln -sf libhybris-common.so.1.0.0 \
#          /srv/sailfishos/targets/SailfishOS-5.1.0.11-aarch64-qt612/usr/lib64/libhybris-common.so.1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-$ROOT/src/sailfish-fpd-community}"
TARGET="${TARGET:-SailfishOS-5.1.0.11-aarch64-qt612}"

BUILD="$(mktemp -d /tmp/fpd-daemon-build.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

cp -a "$SRC/." "$BUILD/"
chown -R sailfish:sailfish "$BUILD"

sudo -u sailfish -H /srv/sailfishos/sdks/sfossdk/sdk-chroot -m all bash -lc \
    "cd /parentroot$BUILD && mb2 -t $TARGET -s rpm/sailfish-fpd-community.spec build"

mkdir -p "$ROOT/dist"
cp "$BUILD"/RPMS/*.rpm "$ROOT/dist/"
ls -l "$ROOT"/dist/sailfish-fpd-community-*.rpm
