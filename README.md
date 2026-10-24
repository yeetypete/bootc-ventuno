# bootc-ventuno

A [bootc](https://bootc-dev.github.io/bootc/) image for the
[Arduino VENTUNO Q](https://docs.arduino.cc/hardware/ventuno-q/), running
Ubuntu 24.04 with the kernel, firmware and device tree of Arduino's own image.

> [!WARNING]
> This repository is intended as a **reference example** of running `bootc` on
> the VENTUNO Q, not as a base image that other projects consume directly.
> Fork it and adapt the `Containerfile` and `system_files/` to your own needs
> rather than depending on the published bootc images in production.

## What's in the image

- `bootc` with the [composefs backend](https://bootc.dev/bootc/bootc-experimental-composefs.7.html)
  enabled for image storage and deployment, and a read-only `/usr`.
- Ubuntu 24.04 with Canonical's `linux-qcom` kernel and
  [Qualcomm IoT PPA](https://launchpad.net/~ubuntu-qcom-iot/+archive/ubuntu/qcom-ppa).
- A sealed [UKI](https://bootc.dev/bootc/bootc-experimental-composefs.7.html#building-sealed-images)
  booted by `systemd-boot`, built and finalized with
  [`bootc-imagectl`](https://github.com/yeetypete/bootc-imagectl).
- A `systemd-networkd`/`resolved`/`timesyncd` base with SSH enabled.
- An `ubuntu` user (password `ubuntu`).
- Layers rechunked by package with
  [chunkah](https://github.com/coreos/chunkah).
- A [transient `/etc`](https://github.com/yeetypete/bootc-imagectl#transient-etc)
  that discards changes on every reboot, and read-only account files (accounts
  should be configured in the image only).

## Requirements

- A VENTUNO Q and a jumper for EDL mode (see
  [Flash Ubuntu Image](https://docs.arduino.cc/tutorials/ventuno-q/flash-image/)).
- A Linux host with [`just`](https://github.com/casey/just) and
  [`qdl`](https://github.com/linux-msm/qdl).
- Only for [building locally](#option-2-build-locally): an `arm64` host with
  [Podman](https://podman.io/) installed.

## Flashing a VENTUNO Q

> [!IMPORTANT]
> Flashing erases the whole eMMC, including the boot firmware, which is
> replaced with the build from Arduino's own image.

Put the board in EDL mode before running `just flash`.

### Option 1: flash a CI build

```bash
just download   # Download the newest CI disk image built from this branch.
just qcomflash  # Prepare the disk image for flashing.
just flash      # Flash the board.
```

### Option 2: build locally

> [!NOTE]
> Building locally requires an `arm64` host.

```bash
just build      # Build the bootc image with Podman.
just save       # Save the image as an OCI archive for `just disk`.
just disk       # Install the image into a loopback raw disk image.
just qcomflash  # Prepare the disk image for flashing.
just flash      # Flash the board.
```

Once booted, the system updates transactionally with `bootc upgrade`. See the
[`bootc` upgrade docs](https://bootc-dev.github.io/bootc/upgrades.html).

## License

`bootc-ventuno` is released under the
[MIT License](LICENSE).
