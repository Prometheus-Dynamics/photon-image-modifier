# TODO

## Next release (Raze PhotonVision images: 2026 season and 2027 test)

The release list for the Raze PhotonVision images built here: the 2026-10-27 feature freeze plus
the hardware-support work added on 2026-10-30 (the last addition). Both flavours ship from the same
device package: PhotonVision 2026 (fork branch `styx-eidos-2026`) and 2027 (`styx-eidos`), on Styx +
Eidos, plus the stock libcamera image. Fixes go to both fork branches. Every item: what, why, done
when, blocked by.

### 1. Freeze items still open

- [x] **The PhotonVision version format.** `<year>.<maj>.<min>-dev.<count>+<sha8>` on both fork
      branches (styx-eidos-2026 8fc5cf6f, styx-eidos 9761564b); `-PversionString` still overrides it.
- [ ] **Drop the version override from the presets.** Why: the presets still pass
      `-PversionString=dev-v...`, which hides the new format. Done when: the styx presets in
      build.toml build without `-PversionString`, and the image's PhotonVision reports the new
      format. Blocked by: nothing.
- [ ] **Slot version without `+`.** Why: slot ids and file names must not carry `+`. Done when: each
      preset's `input.slot_version` is the PhotonVision version with the build metadata dropped
      (or `+` mapped to a safe character), and Atlas installs and shows it. Blocked by: nothing.
- [ ] **Pin Styx by revision.** Why: reproducible images. Done when: the PhotonVision fork branches
      pin Styx (and Eidos) by `rev`, never by branch, and `raze_styx_eidos_rev` here names the same
      commits. Blocked by: nothing.
- [ ] **Bump the image pins.** Why: they're 11–19 days old. Done when: the presets' PhotonVision,
      libcamera-driver, Styx/Eidos and Atlas device-package revisions match the current
      releases-to-be, and both flavours boot on a Raze with camera, LEDs and fan working. Blocked by:
      the Styx/Eidos release revisions.

### 2. Hardware support (added 2026-10-30)

- [ ] **Raze only for this release.** The new boards (K230D, Rockchip modules, Flame) are HeliOS
      targets; a PhotonVision image for them isn't part of this release unless the user adds it.

### 3. Release mechanics

- [ ] Release images for both flavours from one commit of this repo, with the slot sizes reported.
- [ ] The bundled offline docs and their media stay complete (never trimmed to save space).
- [ ] Each flavour flashed with Atlas and updated slot-to-slot on a Raze before release.
