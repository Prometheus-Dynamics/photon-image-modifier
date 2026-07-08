# ARM64 Base

This folder owns Gaia build pieces shared by every ARM64 target:

- `workspace.toml`: common Gaia workspace, output, providers, and path aliases.
- `base-os.toml`: expensive reusable OS backing and platform-agnostic packages.
- `photonvision.toml`: common PhotonVision application jar and service layer.
- `identity.toml`: shared PhotonVision identity files.
- `ops.toml`: shared operational defaults.

Target folders may import files from here. This folder should not import target
folders.
