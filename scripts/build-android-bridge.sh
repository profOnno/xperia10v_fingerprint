#!/bin/bash
# Build libbiometry_fp_api.so in the LineageOS tree.
#
# The source module must already be in the tree at
#   hardware/sony/biometry
# Use ap4a (Android 15 / SDK 35), not ap2a (Android 14 / SDK 34).
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="${TOP:-$HOME/lineage-22.2}"
JOBS="${JOBS:-8}"

if [ ! -d "$TOP/hardware/sony/biometry" ]; then
    echo "ERROR: $TOP/hardware/sony/biometry is missing." >&2
    echo "Copy src/lineage/hardware/sony/biometry into the tree first." >&2
    exit 1
fi

cd "$TOP"
# shellcheck disable=SC1091
source build/envsetup.sh
lunch lineage_pdx235-ap4a-userdebug
m libbiometry_fp_api -j"$JOBS"

SO="$TOP/out/target/product/pdx235/vendor/lib64/libbiometry_fp_api.so"
echo
echo "Built:"
ls -l "$SO"
