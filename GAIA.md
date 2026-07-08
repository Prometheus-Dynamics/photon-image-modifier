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
- `platform/`: platform-family layers such as Raspberry Pi, Orange Pi 5, and
  Rubik Pi 3.
- Root target folders such as `limelight/`, `luma_p1/`, and `rubikpi3/`:
  selectable target fragments and target assets.

The root `build.toml` is the entrypoint. Target and platform files are fragments
that Gaia imports after resolving the selected inputs.

The legacy shell image-modifier path has been removed. Do not add new
`install_*.sh` or `mount_*.sh` build paths; add Gaia fragments instead.
