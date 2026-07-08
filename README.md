# Photon Image Modifier

This repository now builds images through Gaia only.

Run the interactive selector:

```bash
gaia tui build.toml
```

Run a specific target:

```bash
gaia run build.toml --set input.target=limelight --set input.profile=full
```

Selectors:

- `input.profile`: `base-os` or `full`
- `input.target`: `generic-arm64`, `raspi`, `raspi_dev`,
  `limelight`, `limelight3`, `limelight3g`, `limelight4`, `luma_p1`,
  `snakeyes`, `helios-raze`, `opi`, or `rubikpi3`

Layout:

- `base/arm64/`: shared ARM64 OS, universal packages, PhotonVision app/service,
  identity, and ops.
- `platform/`: reusable board-family layers.
- Root target folders such as `limelight/`, `luma_p1/`, and `rubikpi3/`:
  final target fragments and target assets.

Legacy `install_*.sh` and `mount_*.sh` paths have been removed.
