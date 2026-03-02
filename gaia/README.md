# Gaia Build: PhotonVision HeliOS Raze

This is the Gaia-native image pipeline for this repository.

It builds the full image flow directly from Buildroot (no RPiOS chroot mutation path), and stages the helios-raze runtime/services into the final image.

## Inputs

This build now uses Gaia build inputs (`--set ...`) so the mode is visible in TUI and configurable per run.

Primary inputs:

- `pv_jar_source = repo|release|local`
- `pv_jar_release_url = <url>` (used when `pv_jar_source=release`)
- `pv_jar_local_path = </abs/path/to/jar>` (used when `pv_jar_source=local`)
- `photonvision_repo = </abs/path/to/photonvision>` (used when `pv_jar_source=repo`)
- `libcamera_driver_repo = </abs/path/to/photon-libcamera-gl-driver>`
- `pv_build_jni = true|false`
- `sysroot_dir = </abs/path/to/sysroot>` (required when `pv_build_jni=true`)
- `maven_local_repo = <path>`

Examples:

```bash
# Release jar download (default)
bash gaia/scripts/build-helios-raze-image.sh run

# Pull jar from release URL
bash gaia/scripts/build-helios-raze-image.sh run \
  --set pv_jar_source=release \
  --set pv_jar_release_url=https://github.com/PhotonVision/photonvision/releases/latest/download/photonvision-linuxarm64.jar

# Use local prebuilt jar
bash gaia/scripts/build-helios-raze-image.sh run \
  --set pv_jar_source=local \
  --set pv_jar_local_path=/abs/path/to/photonvision-linuxarm64.jar

# Build from source repo
bash gaia/scripts/build-helios-raze-image.sh run \
  --set pv_jar_source=repo \
  --set photonvision_repo=/abs/path/to/photonvision

# Open TUI (inputs editable there)
bash gaia/scripts/build-helios-raze-image.sh tui
```

Legacy env vars are still accepted as compatibility fallback, but `--set`/TUI is now the intended control surface.

## Run

From repo root:

```bash
bash gaia/scripts/build-helios-raze-image.sh
```

The script outputs:

- `output/photonvision-helios-raze.img`
- `output/photonvision_helios-raze.img` (compatibility copy for old tooling)

## Checkpoints

Checkpoint config is in `gaia/configs/checkpoints.toml`.

- Base checkpoint anchor: `buildroot.build`
- Default policy: local auto restore/capture
- Optional remote cache: S3 via env-backed creds (`GAIA_CP_*` vars)
