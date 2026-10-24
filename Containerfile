# hadolint global ignore=DL3006,DL3008,DL3059,DL4006
# DL3006: chunked is a build context, not an image to tag.
# DL4006: podman builds OCI images, which ignore SHELL, so RUN keeps /bin/sh.

ARG UBUNTU_IMAGE=docker.io/library/ubuntu:26.10@sha256:93e29beff5257b2cdf1c024d831f6d2997e53655a653ff76a811fc9e6564a719
ARG RUST_IMAGE=docker.io/library/rust:1.99-bookworm@sha256:114c7a4425406451c2866b6aafe69fe29b1b298832db1277d411ac73c82d04d6
ARG BOOTC_IMAGECTL_REV=a2ef68fc68e8d272f16e502abd432f071ce350d5


FROM ${UBUNTU_IMAGE} AS system-files

COPY system_files/ /system_files/
RUN chmod -R go-w /system_files


FROM ${UBUNTU_IMAGE} AS bootc-builder

ARG BOOTC_VERSION=v1.17.1
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    ca-certificates \
    cargo \
    git \
    go-md2man \
    libostree-dev \
    libssl-dev \
    libzstd-dev \
    pkg-config \
    rustc

WORKDIR /bootc
RUN git clone --depth 1 --branch "${BOOTC_VERSION}" https://github.com/bootc-dev/bootc.git .

RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/bootc/target,sharing=locked \
    CARGO_PROFILE_RELEASE_DEBUG=false CARGO_PROFILE_RELEASE_STRIP=true \
    make bin install DESTDIR=/out \
    CARGO_OPTIONS='--no-default-features --features install-to-disk'


FROM ${RUST_IMAGE} AS bootc-imagectl

ARG BOOTC_IMAGECTL_REV
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    cargo install --locked --root /out \
    --git https://github.com/yeetypete/bootc-imagectl --rev "${BOOTC_IMAGECTL_REV}" \
    bootc-imagectl


FROM ${UBUNTU_IMAGE} AS image

ENV DEBIAN_FRONTEND=noninteractive

# Keep package installs from generating an initramfs. finalize builds it with dracut.
ENV INITRD=No

# Create every user and group with the UID and GID the sysusers lock file fixes
# before any package can allocate a different one.
COPY --from=system-files /system_files/usr/lib/sysusers.d/ /usr/lib/sysusers.d/
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y systemd && \
    systemd-sysusers

# TODO: Install linux-image-generic. Its signed kernel is wrapped in stubble
# (Ubuntu's EFI stub that loads device trees), which systemd-stub refuses to
# boot from a UKI. Add support in bootc-imagectl for unwrapping the kernel.
#
# TODO: Drop --force-overwrite once firmware-qcom-dsp declares that it replaces
# the DSP firmware files it shares with linux-firmware-qualcomm-misc.
ARG KERNEL_RELEASE=7.3.0-9-generic
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    -o Dpkg::Options::=--force-overwrite \
    acl \
    ca-certificates \
    dbus \
    dosfstools \
    dracut \
    fastrpc-support \
    fdisk \
    hexagon-dsp-binaries-arduino-monza \
    libfastrpc1 \
    libnss-systemd \
    linux-firmware-qualcomm-graphics \
    linux-firmware-qualcomm-misc \
    linux-firmware-qualcomm-wireless \
    linux-image-unsigned-${KERNEL_RELEASE} \
    openssh-server \
    ostree \
    podman \
    skopeo \
    sudo-rs \
    systemd-boot \
    systemd-resolved \
    systemd-sysv \
    systemd-timesyncd \
    systemd-ukify \
    udev \
    zstd

COPY --from=bootc-builder /out/usr/ /usr/

COPY --from=system-files /system_files/ /

RUN systemctl enable systemd-growfs@sysroot.service

# apt cannot update the read-only /usr.
RUN systemctl disable apt-daily-upgrade.timer apt-daily.timer

# A transient /etc requires setting systemd-firstboot's settings in the image.
RUN systemd-firstboot --locale=C.UTF-8 --timezone=UTC

# Create home directories on first login.
RUN pam-auth-update --enable mkhomedir

# The base image's ubuntu user, with password ubuntu.
RUN echo 'ubuntu:ubuntu' | chpasswd

LABEL containers.bootc=1
CMD ["/sbin/init"]


FROM image AS finalized

RUN --network=none \
    --mount=type=bind,from=bootc-imagectl,source=/out/bin/bootc-imagectl,target=/usr/libexec/bootc-imagectl \
    /usr/libexec/bootc-imagectl finalize \
    --sysusers-lock /usr/lib/sysusers.d/00-bootc-imagectl.lock.conf \
    --read-only-accounts \
    --chunkah-xattrs \
    --transient-etc


# The UKI embeds the kernel and initramfs.
FROM finalized AS rootfs

RUN bootc container split-kernel-and-rootfs --output /kernel && \
    rm -r /kernel

RUN bootc container lint --fatal-warnings


FROM ${UBUNTU_IMAGE} AS dtb

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y device-tree-compiler

# TODO: Drop once the kernel's VENTUNO Q device tree gives the SGMII SerDes its
# 0.9 V supply, which Ethernet needs. The kernel driver and the other Monaco
# boards already have the fix, see
# https://lore.kernel.org/r/20260804-b4-sgmiieth_serdes_regulator-v2-0-c4bc688177dd@oss.qualcomm.com.
RUN --mount=type=bind,from=finalized,source=/usr/lib/firmware,target=/firmware \
    dtb=/dtb/monaco-arduino-monza.dtb && \
    mkdir /dtb && \
    cp /firmware/*/device-tree/qcom/monaco-arduino-monza.dtb "${dtb}" && \
    l4a="$(fdtget -t u "${dtb}" /soc@0/rsc@18200000/regulators-0/ldo4 phandle)" && \
    l5a="$(fdtget -t u "${dtb}" /soc@0/rsc@18200000/regulators-0/ldo5 phandle)" && \
    fdtput -t u "${dtb}" /soc@0/phy@8909000 vdda-0p9-supply "${l4a}" && \
    fdtput -t u "${dtb}" /soc@0/phy@8909000 vdda-1p2-supply "${l5a}" && \
    fdtput -d "${dtb}" /soc@0/phy@8909000 phy-supply

# The firmware's EFI_DT_FIXUP_PROTOCOL ignores the buffer size systemd-stub
# passes and grows the device tree in place, see
# https://github.com/U-Boot-EFI/EFI_DT_FIXUP_PROTOCOL. Without free space in
# the blob it overwrites whatever follows, which can be the kernel command line.
RUN dtc -I dtb -O dtb -p 65536 \
    -o /dtb/monaco-arduino-monza.dtb /dtb/monaco-arduino-monza.dtb


# `just build` passes rootfs rechunked by chunkah as the chunked build context.
# Seal the UKI from chunked so that its composefs digest covers the mtimes
# chunkah rewrites.
FROM chunked AS uki

# Replaces the firmware's device tree, which targets Canonical's linux-qcom kernel.
RUN --mount=type=bind,from=chunked,target=/target \
    --mount=type=bind,from=finalized,source=/usr/lib/modules,target=/kernel \
    --mount=type=bind,from=dtb,source=/dtb,target=/dtb \
    kver="$(basename "$(dirname /kernel/*/vmlinuz)")" && \
    mkdir /uki && \
    bootc container ukify --rootfs /target --kernel-dir "/kernel/${kver}" \
    -- \
    --devicetree /dtb/monaco-arduino-monza.dtb \
    --output "/uki/${kver}.efi"


FROM chunked

COPY --from=uki /uki/ /boot/EFI/Linux/

ARG VERSION=v0.0.0
ARG REVISION=
LABEL org.opencontainers.image.source="https://github.com/yeetypete/bootc-ventuno" \
    org.opencontainers.image.version="${VERSION}" \
    org.opencontainers.image.revision="${REVISION}" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.title="bootc-ventuno" \
    org.opencontainers.image.description="bootc image for the Arduino VENTUNO Q on Ubuntu 26.10."
