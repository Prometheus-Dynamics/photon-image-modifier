# Platform Layers

Platform folders hold board-family setup shared by multiple final targets.

- `raspberry-pi/`: firmware, boot partition conventions, Pi kernel settings,
  shared network defaults, and common camera/GL runtime pieces.
- `orange-pi-5/`: Orange Pi 5 cloud-init/network defaults and shared RK3588
  runtime policy.
- `rubikpi3/`: Rubik Pi 3 Qualcomm/runtime defaults and shared device quirks.

The root `build.toml` imports these conditionally from `input.target`.
