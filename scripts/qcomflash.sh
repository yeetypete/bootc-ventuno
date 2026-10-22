#!/usr/bin/env bash
# Build the qcomflash directory written to the VENTUNO Q eMMC by qdl
# (https://github.com/linux-msm/qdl). bootc install to-disk cannot be used
# directly because the boot firmware shares the eMMC with the OS.
#
# See https://dragonwingdocs.qualcomm.com/Key-Documents/Flash-Guide/flash-with-qdl
#
# Usage: qcomflash.sh DISK_IMAGE DTB_DIR OUTPUT_DIR
set -euo pipefail
shopt -s inherit_errexit

disk=$(realpath "$1")
dtb_dir=$(realpath "$2")
out=$3

cache=$(realpath "$(dirname "$0")/..")/build/cache

# Qualcomm's QCS8300 boot firmware, the release meta-qcom uses for the VENTUNO Q.
firmware_version=00142
firmware_url=https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCS8300_bootbinaries.1.0/qcs8300_bootbinaries.1.0-test-device-public/$firmware_version
firmware_sha256=22182317cfe5b09f8cc9bc428d755391561cb9d25c9e77aeca4e62195d4b97e8
firmware_immutable_sha256=ffc05bf1323d828f8c944421d8cadaf1c45697032b26b9f34ecce042ddae291d

cdt_url=https://artifacts.codelinaro.org/artifactory/codelinaro-le/Qualcomm_Linux/QCS8300/cdt/qcs8275-Monza_v1.zip
cdt_sha256=8484beb2ac1ff74a129c586f6d5331536765975dbabfb0600509f11010ec1c41

dtb_metadata_rev=c2c5fdab4419a6717d2e40bbab228cb9ff8a1620
dtb_metadata_sha256=8187371721a3c6a039b5832c155e5a2ebcf6c34761658cba6f85a496a0b7aa23

ptool_rev=bae4bce2f09a56ba0a13743a21ab0e4b29c72b3e
ptool_sha256=1ffad487ffa75a972cc43ed3a6622dd5f42052c936af04fa574afac6afb34071

# Download URL to the cache unless it is there, and check its sha256.
fetch() {
    local url=$1 sha256=$2 file
    file="$cache/$(basename "$url")"
    if [ ! -f "$file" ]; then
        curl --fail --location --silent --show-error --output "$file.part" "$url"
        echo "$sha256  $file.part" | sha256sum --check --quiet
        mv "$file.part" "$file"
    fi
    echo "$file"
}

# Download a qualcomm-linux repository at a commit and unpack it in the cache.
fetch_repo() {
    local repo=$1 rev=$2 sha256=$3 dir tarball
    dir="$cache/$repo-$rev"
    if [ ! -d "$dir" ]; then
        tarball=$(fetch "https://github.com/qualcomm-linux/$repo/archive/$rev.tar.gz" "$sha256")
        tar -xzf "$tarball" -C "$cache"
    fi
    echo "$dir"
}

mkdir -p "$cache"
rm -rf "$out"
mkdir -p "$out"

firmware=$(fetch "$firmware_url/QCS8300_bootbinaries_$firmware_version.zip" "$firmware_sha256")
firmware_immutable=$(fetch "$firmware_url/QCS8300_bootbinaries_immutable_$firmware_version.zip" "$firmware_immutable_sha256")
unzip -q -j "$firmware" -x '*/sail_nor/*' '*/partition_*.xml' -d "$out"
unzip -q -j -o "$firmware_immutable" -d "$out"

cdt=$(fetch "$cdt_url" "$cdt_sha256")
unzip -q -p "$cdt" cdt_qcs8275-Monza.bin >"$out/cdt.bin"

dtb_metadata=$(fetch_repo qcom-dtb-metadata "$dtb_metadata_rev" "$dtb_metadata_sha256")
"$dtb_metadata/build-dtb-image.sh" --dtb-src "$dtb_dir" --soc qcs8275 --prune --out "$out/dtb.bin" >/dev/null

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

ptool=$(fetch_repo qcom-ptool "$ptool_rev" "$ptool_sha256")
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
