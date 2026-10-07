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
whose dependencies are not met. Gaia compares every override with the
final `.config` after `olddefconfig` and fails the image step before the long
`make` when one was dropped (`[providers.buildroot] override_check`, default
`"error"`). Overrides are keyed by symbol and the last layer wins, so a target
layer turns off a base-layer symbol it cannot have with `"n"`.

The entrypoint requires Gaia 2.0.0 or later (`gaia_version`; Gaia reset its
version to 2.0.0, so builds from its current main satisfy it). Buildroot is
pinned to a commit in `build.gaia.lock` (`gaia lock build.toml`).

## Build Container

Gaia runs source fetching, Buildroot and the artifact builds in Docker
(`execution.docker` in `base/arm64/workspace.toml`), so the host only needs
Docker and a current Gaia. Build the image once:

```bash
docker build -t photonvision-gaia-build:trixie docker/build
```

It holds the Buildroot host prerequisites plus JDK 25, Node 24, pnpm and
CMake for the Java artifacts (PhotonVision 2027 builds with a Java 25
toolchain). Gradle, pnpm and the WPILib arm64 toolchain are
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
| `base/arm64/*.toml` | always | OS base (Buildroot, systemd, OpenJDK; Raze turns OpenJDK off), identity, ops |
| `platform/raspberry-pi/build.toml` | `full` | NetworkManager, Mesa, Pi tools, Wi-Fi/BT blacklist |
| `atlas:devices/raze/gaia/device.toml` | `raze` | CM5 defconfig and kernel, OV9782 driver, libcamera/libpisp, `raze-device.txt` and overlays, device services |
| `atlas:devices/raze/gaia/gpu.toml` | `raze`, `full` | Mesa V3D/VC4 with EGL, GLES and gbm for the libcamera GL driver |
| `base/arm64/photonvision.toml` | `full` | PhotonVision service and jar install |
| `raze/build.toml` | `raze` | declares the `atlas` source; `config.txt`, `cmdline.txt`, boot partition and `sdcard.img`, the read-only EROFS root and its writable paths, the jlink'd Java runtime, module check and first-boot grow of `/data`, NetworkManager + systemd-resolved |
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
- The root filesystem is a read-only, LZMA-compressed EROFS image
  (`rootfs.erofs`) in a 512 MiB slot; see "Read-only root" below. Buildroot
  makes `rootfs.tar`, and `raze/assets/buildroot/post-image-rootfs.sh` turns
  it into `rootfs.erofs` and an empty `data.ext4`, failing the build if the
  root does not fit its slot. The same script checks that every kernel
  module of the kernel build ships (Buildroot ignores a failed
  `modules_install`, which once left 58 of 1898 modules in the image),
  reruns depmod, writes `/opt/photonvision/image-metadata.json` from the
  `photonvision-image` env set, and packs PhotonVision's jar
  (`pack-photonvision-jar.py`, below). On every boot `grow-rootfs.service`
  grows `/data` (p7) to fill the eMMC if it does not already; PhotonVision
  starts after it.
  The flashable output is `output/gaia/photonvision-full-raze/images/<build>-<version>.img.xz`
  (also `sdcard.img`); Atlas flashes either.
- The hostname stays `photonvision` (`/etc/hostname`, a link to
  `/data/etc/hostname` seeded from the image); the device default
  `raze-{serial8}` only applies over an unset or stock hostname.
- mDNS: NetworkManager owns Ethernet and hands mDNS to systemd-resolved
  (`connection.mdns=2` from the device package), which also advertises
  `_pd-device._tcp`. Do not add avahi. `BR2_SYSTEM_DHCP` is cleared and
  `raze/assets/rootfs/usr/lib/systemd/system-preset/50-photonvision-os.preset`
  disables systemd-networkd, so NetworkManager is the only network manager.

### Read-only root

The root slots hold EROFS (`rootfstype=erofs ro` in `cmdline.txt`; the
kernel support comes from the device package, 1.5.0 or later). Nothing
writes to `/` at run time. `photonvision-data-early.service` runs before
`local-fs.target`, after `/data` (p7, mounted with
`x-systemd.before=local-fs.target`) and makes the writable places:

| Written at run time | Where it goes | How |
| --- | --- | --- |
| `/var` (NetworkManager leases and `secret_key`, Orion's `/var/lib/orion`, systemd timers, random seed, timesync) | `/data/var` | bind-mounted by data-early; each boot copies in what the image's `/var` has and `/data/var` lacks (`BR2_INIT_SYSTEMD_VAR_NONE`) |
| static hostname (PhotonVision runs `hostnamectl set-hostname` and writes `/etc/hostname`) | `/data/etc/hostname` | `/etc/hostname` links there; systemd-hostnamed writes it through `SYSTEMD_ETC_HOSTNAME`; data-early seeds it from `/usr/share/photonvision-os/hostname` and sets the kernel hostname; os-release `DEFAULT_HOSTNAME` covers early boot |
| NetworkManager profiles (`nmcli`, PhotonVision's DHCP/static settings) | `/data/NetworkManager/system-connections` | `keyfile.path` in `/usr/lib/NetworkManager/conf.d/40-photonvision-os.conf` |
| SSH host keys | `/data/ssh` | `HostKey` lines in `/etc/ssh/sshd_config.d/40-photonvision-os.conf`, generated once by data-setup; `ssh-keygen -A` is removed from `sshd.service`; `sshd_config` gets `Include /etc/ssh/sshd_config.d/*.conf` first (the device package's authorized keys in `/run` need it too) |
| PhotonVision settings, database, logs, snapshots | `/data/photonvision_config` | bind-mounted over `/opt/photonvision/photonvision_config` by data-setup |
| PhotonVision's WPILib/OpenCV natives | nowhere | unpacked into the image at build time (`/usr/lib/photonvision/wpilib`, linked from `/root/.wpilib`); the loader finds them with the right MD5s and writes nothing |
| sqlite-jdbc, diozero, JNA native unpacking, uploads | `/tmp` (tmpfs) | `-Djava.io.tmpdir=/tmp -Djna.tmpdir=/tmp/jna` in `photonvision.service.d/20-read-only-root.conf` |
| `/etc/machine-id` | transient | the image ships it empty: systemd generates one per boot and mounts it over the file (not a first boot) |
| journal | RAM | `Storage=volatile`, 32 MiB (`journald.conf.d/40-photonvision-os.conf`); PhotonVision's own logs persist on `/data` |
| `manage-url` for Atlas | `/run/pd-device/manage-url` | `/etc/pd-device/manage-url` links there |
| `systemd-update-done` stamps | in the image | `/etc/.updated` and `/var/.updated` are written at build time, so `ConditionNeedsUpdate=` units do not run every boot |

If `/data` does not mount, data-early mounts a tmpfs there: the board boots
and works, but keeps nothing across a reboot. PhotonVision's offline update
(uploading a jar in the UI) cannot replace the jar on a read-only root;
updates go through the device package's A/B updater.

### Java runtime

Raze does not build OpenJDK. The `photonvision-jre` package
(`raze/assets/buildroot/external/package/photonvision-jre`, a `BR2_EXTERNAL`
tree listed after the device package's in `raze/build.toml`) downloads
Eclipse Temurin 25.0.4.1+1's prebuilt aarch64 jmods and the host JDK of the
same release (pinned by sha256), runs `jlink`, strips the natives with the
target toolchain, and installs the runtime to `/usr/lib/jvm`
(`/usr/bin/java`). The modules, from `jdeps --print-module-deps` on the jar
plus a margin, are listed and explained in `photonvision-jre.mk`:

```
java.base java.desktop java.instrument java.logging java.management
java.naming java.security.jgss java.sql jdk.unsupported jdk.zipfs
jdk.management jdk.net jdk.crypto.ec
```

The module image is not compressed by jlink (`--compress=zip-0`): EROFS's
LZMA packs it smaller than zip-9 does (the runtime takes about 20 MiB of the
image against 34 MiB, 89 MiB unpacked), and classes load without inflating.

### PhotonVision jar

The jar artifact is PhotonVision's normal linuxarm64 shadow jar. The image's
copy is packed by `raze/assets/buildroot/pack-photonvision-jar.py`: natives
for other platforms (sqlite-jdbc, JNA, diozero), the RKNN and TFLite object
detection backends and models (PhotonVision loads them only on RK3588 and
QCS6490), and the web UI's source maps are dropped; the natives are unpacked
and stripped into the image; every entry is stored uncompressed for the
filesystem's LZMA. The bundled offline docs stay: they are the largest part
of the jar (about 59 MB, mostly PNG screenshots and MP4 clips that do not
compress further).

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

The pinned revs are the `raze-2027` branches of the forks: PhotonVision on
upstream main (2027, WPILib 2027 alpha, Java 25) with the Raze changes, and
the driver with the OV9782 and Buildroot cross-build changes, built against
the device package's libcamera 0.7. The image runs them on the jlink'd
Temurin 25 runtime described above.

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
