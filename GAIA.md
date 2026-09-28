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
  Targets ship the official PhotonVision release jar for `input.photonvision_ref`.
- `platform/`: platform-family layers such as Raspberry Pi, Orange Pi 5, and
  Rubik Pi 3.
- Root target folders such as `limelight/`, `luma_p1/`, and `rubikpi3/`:
  selectable target fragments and target assets.
- `docker/build/`: the container every Gaia command runs in.

The root `build.toml` is the entrypoint. Target and platform files are fragments
that Gaia imports after resolving the selected inputs.

The legacy shell image-modifier path has been removed. Do not add new
`install_*.sh` or `mount_*.sh` build paths; add Gaia fragments instead.

Buildroot `config_overrides` are not checked by `gaia validate`: kconfig
silently drops symbols that do not exist in the pinned Buildroot release or
whose dependencies are not met. After changing them, compare the overrides
with `build/gaia/<build>/image/buildroot-output/.config`.

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

The Gaia binary must include `build_command`/`build_env` support for Java
artifacts (Gaia-Image-Builder 409d87c or later); older 2.0.0 builds silently
ignore those fields and run `./gradlew build` instead.

## HeliOS Raze

`helios-raze` builds a Raspberry Pi CM5 image from Buildroot's
`raspberrypicm5io_defconfig` with the OV9782 camera, plus two applications
from the Prometheus Dynamics forks:

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
gaia run build.toml --set input.target=helios-raze --set input.profile=full \
  --set input.raze_photonvision_repo=$PWD/../photonvision \
  --set input.raze_libcamera_driver_repo=$PWD/../photon-libcamera-gl-driver
```

The Buildroot package overrides for Raze (`libcamera`, `libpisp`) live in
`helios/raze/assets/buildroot/packages/` and follow the HeliOS product build:
LTTng tracing is opt-in (`BR2_PACKAGE_LIBCAMERA_TRACING`), IPA signatures use
OpenSSL unless gnutls is already in the image, and the stripped IPA modules
are re-signed so they load in-process.
