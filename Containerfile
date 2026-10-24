# hadolint global ignore=DL3006,DL3008,DL3059,DL4006
# DL3006: chunked is a build context, not an image to tag.
# DL4006: podman builds OCI images, which ignore SHELL, so RUN keeps /bin/sh.

ARG UBUNTU_IMAGE=docker.io/library/ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG RUST_IMAGE=docker.io/library/rust:1.99-bookworm@sha256:114c7a4425406451c2866b6aafe69fe29b1b298832db1277d411ac73c82d04d6
ARG BOOTC_IMAGECTL_REV=a2ef68fc68e8d272f16e502abd432f071ce350d5


FROM ${UBUNTU_IMAGE} AS system-files

COPY system_files/ /system_files/
RUN chmod -R go-w /system_files


FROM ${UBUNTU_IMAGE} AS bootc-builder

ENV PATH=/usr/lib/rust-1.91/bin:$PATH

ARG BOOTC_VERSION=v1.17.1
ARG OSTREE_VERSION=v2026.4

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    autoconf \
    automake \
    bison \
    build-essential \
    ca-certificates \
    cargo-1.91 \
    git \
    go-md2man \
    libext2fs-dev \
    libglib2.0-dev \
    liblzma-dev \
    libssl-dev \
    libsystemd-dev \
    libtool \
    libzstd-dev \
    pkg-config

# bootc requires ostree >= 2025.3 but Ubuntu 24.04 ships 2024.5, so build from source.
WORKDIR /ostree
RUN git clone \
    --depth 1 \
    --branch ${OSTREE_VERSION} \
    --recurse-submodules \
    --shallow-submodules \
    --jobs 8 \
    https://github.com/ostreedev/ostree.git . && \
    env NOCONFIGURE=1 ./autogen.sh && \
    ./configure \
    --prefix=/usr \
    --libdir=/usr/lib \
    --sysconfdir=/etc \
    --without-gpgme \
    --with-libsystemd \
    --disable-rofiles-fuse && \
    make -j"$(nproc)" && \
    make install && \
    make install-libLTLIBRARIES install-binPROGRAMS DESTDIR=/out && \
    ldconfig

WORKDIR /bootc
RUN git clone --depth 1 --branch "${BOOTC_VERSION}" https://github.com/bootc-dev/bootc.git .

# The rhel9 feature selects composefs-rs loopback EROFS mounts, which work on
# the 6.8 kernel (file-backed EROFS needs Linux 6.12+). Ubuntu does not use
# SELinux, so leave out the default selinux feature.
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/bootc/target,sharing=locked \
    CARGO_PROFILE_RELEASE_DEBUG=false CARGO_PROFILE_RELEASE_STRIP=true \
    make bin install DESTDIR=/out \
    CARGO_OPTIONS='--no-default-features --features "install-to-disk rhel9"'


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
    apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    systemd && \
    systemd-sysusers

COPY --from=system-files /system_files/etc/apt/sources.list.d/ /etc/apt/sources.list.d/

# The kernel Arduino's image ships, which built the device tree in firmware/dtb.bin.
ARG KERNEL_RELEASE=6.8.0-1080-qcom
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y \
    acl \
    dbus \
    dosfstools \
    dracut \
    fdisk \
    libnss-systemd \
    linux-firmware \
    linux-firmware-dragonwing \
    linux-image-${KERNEL_RELEASE} \
    openssh-server \
    podman \
    qcom-fastrpc1 \
    skopeo \
    sudo \
    systemd-boot \
    systemd-resolved \
    systemd-sysv \
    systemd-timesyncd \
    systemd-ukify \
    udev \
    zstd

# bootc links against the ostree built alongside it.
COPY --from=bootc-builder /out/usr/ /usr/
RUN ldconfig

COPY --from=system-files /system_files/ /

# The *rpcd services link the SoC's DSP libraries into /usr/lib/dsp when they
# start, so point it at /run, which tmpfiles.d creates.
RUN ln -s /run/dsp /usr/lib/dsp

RUN systemctl enable systemd-growfs@sysroot.service

# Ubuntu 24.04 keeps /tmp on the root filesystem.
RUN cp /usr/share/systemd/tmp.mount /usr/lib/systemd/system/ && \
    systemctl enable tmp.mount

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


# `just build` passes rootfs rechunked by chunkah as the chunked build context.
# Seal the UKI from chunked so that its composefs digest covers the mtimes
# chunkah rewrites.
FROM chunked AS uki

# The UKI carries no device tree. The firmware loads it from the dtb partition.
RUN --mount=type=bind,from=chunked,target=/target \
    --mount=type=bind,from=finalized,source=/usr/lib/modules,target=/kernel \
    kver="$(basename "$(dirname /kernel/*/vmlinuz)")" && \
    mkdir /uki && \
    bootc container ukify --rootfs /target --kernel-dir "/kernel/${kver}" \
    -- --output "/uki/${kver}.efi"


FROM chunked

COPY --from=uki /uki/ /boot/EFI/Linux/

ARG VERSION=v0.0.0
ARG REVISION=
LABEL org.opencontainers.image.source="https://github.com/yeetypete/bootc-ventuno" \
    org.opencontainers.image.version="${VERSION}" \
    org.opencontainers.image.revision="${REVISION}" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.title="bootc-ventuno" \
    org.opencontainers.image.description="bootc image for the Arduino VENTUNO Q on Ubuntu 24.04."
