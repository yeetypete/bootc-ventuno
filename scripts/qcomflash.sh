#!/usr/bin/env bash
# Build the qcomflash directory written to the VENTUNO Q eMMC by qdl
# (https://github.com/linux-msm/qdl). bootc install to-disk cannot be used
# directly because the boot firmware shares the eMMC with the OS.
#
# See https://dragonwingdocs.qualcomm.com/Key-Documents/Flash-Guide/flash-with-qdl
#
# Usage: qcomflash.sh DISK_IMAGE OUTPUT_DIR
set -euo pipefail
shopt -s inherit_errexit

disk=$(realpath "$1")
out=$2

repo=$(realpath "$(dirname "$0")/..")
cache=$repo/build/cache

dtb_metadata_rev=c2c5fdab4419a6717d2e40bbab228cb9ff8a1620
ptool_rev=bae4bce2f09a56ba0a13743a21ab0e4b29c72b3e

# Clone a qualcomm-linux repository at a commit into the cache.
fetch_repo() {
    local dir="$cache/$1-$2"
    [ -d "$dir" ] || git clone --quiet --depth 1 --revision "$2" \
        "https://github.com/qualcomm-linux/$1.git" "$dir"
    echo "$dir"
}

mkdir -p "$cache"
rm -rf "$out"
mkdir -p "$out"

# Vendored from Arduino's VENTUNO Q image
# https://people.canonical.com/~platform/images/qualcomm-iot/ventunoq/ubuntu-desktop-24.04/20260729-248/arduino-ventunoq-ubuntu-24.04-desktop-arm64-image-x13-20260729-248.tar.zst
cp "$repo"/firmware/*.{bin,elf,fv,mbn} "$out"

# The ESP and root, named as partitions.conf expects.
partx --show --noheadings --output NAME,START,SECTORS "$disk" |
    while read -r name start sectors; do
        case "$name" in
        EFI-SYSTEM) file=efi.bin ;;
        root) file=rootfs.img ;;
        *) continue ;;
        esac
        dd if="$disk" of="$out/$file" bs=1M status=none \
            iflag=skip_bytes,count_bytes \
            skip=$((start * 512)) count=$((sectors * 512))
    done

# Give the firmware the device tree the UKI boots with.
dtb_dir=$(mktemp -d)
trap 'rm -rf "$dtb_dir"' EXIT
mcopy -i "$out/efi.bin" '::/EFI/Linux/bootc/*.efi' - |
    llvm-objcopy --dump-section .dtb="$dtb_dir/monaco-arduino-monza.dtb" - /dev/null

dtb_metadata=$(fetch_repo qcom-dtb-metadata "$dtb_metadata_rev")
"$dtb_metadata/build-dtb-image.sh" --dtb-src "$dtb_dir" --soc qcs8275 --prune --out "$out/dtb.bin" >/dev/null

ptool=$(fetch_repo qcom-ptool "$ptool_rev")
# bootc gives the composefs backend a 2 GiB ESP.
sed 's/--name=efi --size=524288KB/--name=efi --size=2097152KB/' \
    "$ptool/platforms/qcs8275-monza/emmc/partitions.conf" >"$out/partitions.conf"
grep -q -- '--name=efi --size=2097152KB' "$out/partitions.conf"

cd "$out"
export PYTHONPATH=$ptool
python3 -m qcom_ptool.gen_partition -i partitions.conf -o ptool-partitions.xml
python3 -m qcom_ptool.ptool -x ptool-partitions.xml >/dev/null

# Leave only the files `qdl rawprogram*.xml patch*.xml` should flash.
rm -f ./*_BLANK_GPT.xml ./*_WIPE_PARTITIONS.xml wipe_rawprogram*.xml
