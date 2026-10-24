# bootc-ventuno developer tasks.

# Image repository for the built images.
repository := "docker.io/yeetypete/bootc-ventuno"
# The rolling tag installed systems follow with `bootc upgrade`.
tag := "24.04"
reference := repository + ":" + tag
# Local image of the rootfs stage, which chunkah rechunks.
rootfs := "localhost/bootc-ventuno-rootfs"
# chunkah is used to split the rootfs into a layer per group of packages.
chunkah_image := "quay.io/coreos/chunkah:v0.7.1@sha256:71e593421c5de7dcc7c8c5c50e98d3bac572055a76f399f61a491d123c20a523"
oci_archive := "image.oci"
# Registry that caches the rootfs build's layers, if set.
cache := env("CACHE", "")
cache_args := if cache == "" { "" } else { "--cache-from=" + cache + " --cache-to=" + cache }

disk_image := "build/bootc-ventuno.img"
disk_size := "8G"
qcomflash_dir := "build/bootc-ventuno.qcomflash"

# List available recipes.
default:
    @just --list

# Build the rootfs stage, rechunk it with chunkah, and build the image from it.
build *args:
    podman build --platform linux/arm64 --target rootfs --tag {{ rootfs }} {{ cache_args }} {{ args }} .
    rm -rf chunked
    podman run --rm \
        --mount type=image,src={{ rootfs }},dst=/chunkah \
        --volume "$PWD:/srv:z" \
        --env CHUNKAH_CONFIG_STR="$(podman image inspect {{ rootfs }})" \
        {{ chunkah_image }} build \
            --max-layers 128 \
            --source-date-epoch 0 \
            --output oci:chunked
    podman build --platform linux/arm64 \
        --build-context chunked=container-image://"$(podman pull --quiet oci:chunked)" \
        --tag {{ reference }} {{ args }} .

# Save the image as an OCI archive for `disk`.
save:
    # bootc runs as root and cannot read the rootless podman store.
    rm -f {{ oci_archive }}
    podman save --quiet --format oci-archive --output {{ oci_archive }} {{ reference }}

# Push the image tagged <tag>-<short_sha>, and for a release also <tag>-<version> and <tag>.
push short_sha version="":
    #!/usr/bin/env bash
    set -euo pipefail
    # The short sha tag is pushed on every build.
    tags=("{{ tag }}-{{ short_sha }}")
    # Releases also push the version tag and move the rolling tag, which
    # `bootc upgrade` follows.
    if [ -n "{{ version }}" ]; then
        tags+=("{{ tag }}-{{ version }}" "{{ tag }}")
    fi
    for t in "${tags[@]}"; do
        podman push --compression-format zstd --force-compression \
            {{ reference }} "{{ repository }}:$t"
    done

# Install an image into a raw disk image via bootc install to-disk.
disk imgref=("oci-archive:" + oci_archive):
    mkdir -p build
    rm -f {{ disk_image }}
    truncate -s {{ disk_size }} {{ disk_image }}
    sudo podman run \
        --rm --privileged --pid=host \
        --security-opt label=disable \
        -v /dev:/dev \
        -v "$PWD:/output" \
        -w /output \
        {{ imgref }} \
        bootc install to-disk \
            --source-imgref {{ imgref }} \
            --target-imgref {{ reference }} \
            --composefs-backend \
            --via-loopback /output/{{ disk_image }}

# Download the newest CI disk image built from a branch, by default the current one.
download branch=`git branch --show-current`:
    scripts/download.sh {{ disk_image }} {{ branch }}

# Assemble the qcomflash directory qdl flashes from the disk image.
qcomflash:
    scripts/qcomflash.sh {{ disk_image }} {{ qcomflash_dir }}

# Flash a board in EDL mode. Erases the eMMC.
flash:
    cd {{ qcomflash_dir }} && qdl --storage emmc prog_firehose_ddr.elf rawprogram*.xml patch*.xml

# Connect to a VENTUNO Q's serial console over USB.
connect:
    scripts/connect.sh

# Remove the build output, the OCI archive and the chunkah output.
clean:
    rm -rf build {{ oci_archive }} chunked
