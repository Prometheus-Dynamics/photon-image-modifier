# Gaia Build Layout

Gaia is driven from the root `build.toml`.

```bash
gaia tui build.toml
gaia run build.toml --set input.target=generic-arm64 --set input.profile=full
```

Selectors:

- `target`: `generic-arm64` by default. Selectable targets are listed in
  `build.toml`.
- `profile`: `base-os` or `full`.

Layout:

- `base/arm64/`: shared ARM64 OS backing, universal packages, common
  PhotonVision application/service wiring, and common system assets.
  Targets other than `raze` ship the official PhotonVision release jar for
  `input.photonvision_ref`.
- `platform/`: platform-family layers such as Raspberry Pi, Orange Pi 5, and
  Rubik Pi 3.
- Root target folders such as `limelight/`, `raze/`, and `rubikpi3/`:
  selectable target fragments and target assets.
- `docker/build/`: the container every Gaia command runs in.

The root `build.toml` is the entrypoint. Target and platform files are fragments
that Gaia imports after resolving the selected inputs.

The legacy shell image-modifier path has been removed. Do not add new
`install_*.sh` or `mount_*.sh` build paths; add Gaia fragments instead.

Buildroot `config_overrides` are not checked by `gaia validate`: kconfig
silently drops symbols that do not exist in the pinned Buildroot release or
whose dependencies are not met. Gaia 2.1 compares every override with the
final `.config` after `olddefconfig` and fails the image step before the long
`make` when one was dropped (`[providers.buildroot] override_check`, default
`"error"`). Overrides are keyed by symbol and the last layer wins, so a target
layer turns off a base-layer symbol it cannot have with `"n"`.

The entrypoint requires Gaia 2.1.0 or later (`gaia_version`). Buildroot is
pinned to a commit in `build.gaia.lock` (`gaia lock build.toml`).

## Build Container

Gaia runs source fetching, Buildroot and the artifact builds in Docker
(`execution.docker` in `base/arm64/workspace.toml`), so the host only needs
Docker and a current Gaia. Build the image once:

```bash
docker build -t photonvision-gaia-build:bookworm docker/build
```

It holds the Buildroot host prerequisites plus JDK 17, Node 22, pnpm and
CMake for the Java artifacts. Gradle, pnpm and the WPILib arm64 toolchain are
cached in `.gaia/docker-home/`.

## Raze

`raze` builds an image for the Prometheus Dynamics Raze (Raspberry Pi CM5
with an OV9782 global-shutter camera). Everything the hardware needs comes
from the Raze device package in the Atlas repository
(`devices/raze/` in Atlas-Hardware-Manager), shared with every OS that runs
on Raze; this repository only adds PhotonVision and the OS around it.

### Layout

| Import (in order) | When | What it brings |
| --- | --- | --- |
| `base/arm64/*.toml` | always | OS base (Buildroot, systemd, OpenJDK), identity, ops |
| `platform/raspberry-pi/build.toml` | `full` | NetworkManager, Mesa, Pi tools, Wi-Fi/BT blacklist |
| `atlas:devices/raze/gaia/device.toml` | `raze` | CM5 defconfig and kernel, OV9782 driver, libcamera/libpisp, `raze-device.txt` and overlays, device services |
| `atlas:devices/raze/gaia/gpu.toml` | `raze`, `full` | Mesa V3D/VC4 with EGL, GLES and gbm for the libcamera GL driver |
| `base/arm64/photonvision.toml` | `full` | PhotonVision service and jar install |
| `raze/build.toml` | `raze` | declares the `atlas` source; `config.txt`, `cmdline.txt`, boot partition and `sdcard.img`, minimum-size rootfs and first-boot grow, NetworkManager + systemd-resolved |
| `raze/photonvision.toml` | `raze`, `full` | libcamera GL driver and PhotonVision jar built from the forks |

Layers imported after the device layer override its defaults. The `atlas`
source is declared in `raze/build.toml`, so other targets never fetch Atlas.

The device package provides the fan, LED ring, USB port power, USB gadget
networking (`usbbr0`, 172.31.250.1), the identity endpoint
(`http://<device>:5899/.well-known/pd-device`) with its `_pd-device._tcp`
mDNS advertisement, EEPROM files for Atlas, the OV9782 kernel driver, the
libcamera/libpisp package overrides and the PiSP tuning. See
`devices/README.md` in Atlas for the device services and how to turn each one
off (all are defaults; `/etc/pd-device/*.env` overrides them).

What stays here:

- `raze/assets/config.txt`: the OS owns `config.txt`; it ends with
  `include raze-device.txt`, which the device layer puts on the boot
  partition. To change a device setting (fan curve, port power, camera
  overlay), copy the line from `raze-device.txt` into `config.txt` instead
  of including it.
- `raze/assets/cmdline.txt`, the boot assembly tree `boot`, and the
  partition layout.
- The root filesystem is sized to its content: Buildroot makes
  `rootfs.tar`, and `raze/assets/buildroot/post-image-rootfs-ext4.sh` builds
  the smallest `rootfs.ext4` that holds it (plus 32 MiB). On first boot
  `grow-rootfs.service` grows the partition and filesystem to fill the eMMC.
  The flashable output is `output/gaia/photonvision-full-raze/images/<build>-<version>.img.xz`
  (also `sdcard.img`); Atlas flashes either.
- The hostname stays `photonvision` (`/etc/hostname`); the device default
  `raze-{serial8}` only applies over an unset or stock hostname.
- mDNS: NetworkManager owns Ethernet and hands mDNS to systemd-resolved
  (`connection.mdns=2` from the device package), which also advertises
  `_pd-device._tcp`. Do not add avahi. `BR2_SYSTEM_DHCP` is cleared so
  systemd-networkd does not run a second DHCP client on Ethernet.

### Atlas pin and local development

The `atlas` source is pinned by `rev` (a full commit) in `raze/build.toml`.
Until that commit is pushed to Atlas-Hardware-Manager, every Raze command
needs a local Atlas checkout:

```bash
gaia run build.toml --set input.target=raze --set input.profile=full \
  --set sources.atlas.path=/path/to/Atlas-Hardware-Manager
```

The same `--set` works for `validate`, `plan` and `tui`. With it, Gaia reads
the device layer from that directory instead of the pinned commit, so check
the checkout is at the pinned commit. `atlas` has no entry in
`build.gaia.lock`: sources pinned by `rev` need none (and `gaia lock` with a
path override drops the entry anyway). To move to a new package version,
update `rev` in `raze/build.toml`.

### PhotonVision and the libcamera GL driver

`raze` builds two applications from the Prometheus Dynamics forks:

- `photon-libcamera-gl-driver`: the GPU camera driver JNI. It is
  cross-compiled with the Buildroot toolchain against the image sysroot after
  Buildroot prepare (`BUILDROOT_HOST_DIR` mode of `tools/build_arm64_jni.sh`),
  linking Mesa's EGL/GLESv2/gbm and the image's libcamera directly.
- `photonvision`: built against that driver through the workspace maven repo
  (`build/gaia/<build>/m2`).

Both sources are pinned to commits, not branches:

| Input | Meaning |
| --- | --- |
| `raze_photonvision_repo`, `raze_libcamera_driver_repo` | Git URL or local path |
| `raze_photonvision_rev`, `raze_libcamera_driver_rev` | Commit that is built |
| `raze_photonvision_version`, `raze_libcamera_driver_version` | Version string forced into the build |

The version strings must match their revs: use `dev-` plus
`git describe --tags --match 'v*' <rev>`. The driver version is also the maven
coordinate PhotonVision resolves the driver by. Build changes the forks need
are commits in the forks, not patches applied by this repository.

The pinned revs are the `gaia-build-fix` branches of the forks. The driver
branch is based on `3958ada` rather than the current `ov9782` tip: the tip
moved to WPILib 2027 and Java 25, which the 2026 PhotonVision fork and
Buildroot's OpenJDK (17 or 21) cannot run.

To bump a fork, take the new commit and its describe string:

```bash
git -C ../photonvision rev-parse <branch>
git -C ../photonvision describe --tags --match 'v*' <branch>
```

and update the matching `*_rev` and `*_version` defaults in `build.toml`.

To try unpushed commits, point the repo inputs at local clones:

```bash
gaia run build.toml --set input.target=raze --set input.profile=full \
  --set sources.atlas.path=$PWD/../Atlas-Hardware-Manager \
  --set input.raze_photonvision_repo=$PWD/../photonvision \
  --set input.raze_libcamera_driver_repo=$PWD/../photon-libcamera-gl-driver
```
