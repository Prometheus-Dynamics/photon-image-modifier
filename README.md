# photon-image-modifier

This repo now includes a Gaia-native full image pipeline for PhotonVision HeliOS Raze under `gaia/`.

## Default build path (Gaia)

`build_helios_raze_image.sh` now defaults image creation to Gaia (`IMAGE_BUILDER=gaia`).

Typical run:

```bash
./build_helios_raze_image.sh
```

In Gaia mode, the PhotonVision jar is now built from source as part of the build pipeline (`program.custom`) by default.

You can still run the legacy workflow path by setting:

```bash
IMAGE_BUILDER=workflow ./build_helios_raze_image.sh
```

## Gaia build assets

- Build entry: `gaia/builds/helios-raze.toml`
- Configs: `gaia/configs/*.toml`
- Buildroot external overrides (libcamera, ov9782, board scripts): `gaia/assets/buildroot/`
- Runner: `gaia/scripts/build-helios-raze-image.sh`

## Gaia runner env

- `PHOTONVISION_JAR_PATH` or `PHOTONVISION_JAR_URL`
- Optional Gaia locator:
  - `GAIA_BIN=/path/to/gaia`
  - or `GAIA_REPO=/path/to/Gaia-Image-Builder`

Outputs:

- `output/photonvision-helios-raze.img`
- `output/photonvision_helios-raze.img` (compatibility copy)
