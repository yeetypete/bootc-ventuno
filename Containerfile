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

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    dbus \
    dosfstools \
    dracut \
    fdisk \
    libnss-systemd \
    linux-image-generic \
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


# `just build` passes rootfs rechunked by chunkah as the chunked build context.
# Seal the UKI from chunked so that its composefs digest covers the mtimes
# chunkah rewrites.
FROM chunked AS uki

# Replaces the firmware's device tree, which targets Canonical's linux-qcom kernel.
RUN --mount=type=bind,from=chunked,target=/target \
    --mount=type=bind,from=finalized,source=/usr/lib/modules,target=/kernel \
    kver="$(basename "$(dirname /kernel/*/vmlinuz)")" && \
    mkdir /uki && \
    bootc container ukify --rootfs /target --kernel-dir "/kernel/${kver}" \
    -- \
    --devicetree "/target/usr/lib/firmware/${kver}/device-tree/qcom/monaco-arduino-monza.dtb" \
    --output "/uki/${kver}.efi"


FROM chunked

COPY --from=uki /uki/ /boot/EFI/Linux/

ARG VERSION=v0.0.0
ARG REVISION=
LABEL org.opencontainers.image.source="https://github.com/yeetypete/bootc-ventuno" \
    org.opencontainers.image.version="${VERSION}" \
    org.opencontainers.image.revision="${REVISION}" \
    org.opencontainers.image.title="bootc-ventuno" \
    org.opencontainers.image.description="bootc image for the Arduino VENTUNO Q on Ubuntu 26.10."
