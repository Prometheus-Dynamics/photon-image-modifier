# Docker Build Workflow

These helpers run the same build scripts you’d use locally, but inside a clean
container for reproducibility.

## Prereqs

- `photon-image-modifier` checked out
- `IMAGE_URL` set to the base OS image you want to customize
- Optional: set local repos if you want to use your own checkouts
- Default mount backend is guestfs (no privileged container). Loop mounts require an explicit opt-in.

## Build (default HeliOS Raze)

```
IMAGE_URL=... tools/workflow/run-build.sh
```

## Build any image

Pick the install script and name:

```
IMAGE_URL=... INSTALL_SCRIPT=./install_pi.sh IMAGE_NAME=pi tools/workflow/run-build.sh
```

Available install scripts:

```
install_helios_raze.sh
install_pi.sh
install_limelight.sh
install_limelight3.sh
install_limelight3g.sh
install_limelight4.sh
install_luma_p1.sh
install_opi5.sh
install_rubikpi3.sh
install_snakeyes.sh
```

## Use local repos (optional)

If you want to build from local checkouts, point to them:

```
PHOTONVISION_REPO=../photonvision \
LIBCAMERA_DRIVER_REPO=../photon-libcamera-gl-driver \
IMAGE_URL=... \
tools/workflow/run-build.sh
```

If those env vars are not set, the container will clone the official repos
into `/workspace/photonvision` and `/workspace/photon-libcamera-gl-driver`.

If the base image uses different partitions, set them explicitly:

```
ROOT_LOCATION=partition=2 BOOT_PARTITION=1 IMAGE_URL=... INSTALL_SCRIPT=./install_pi.sh IMAGE_NAME=pi tools/workflow/run-build.sh
```

## Mount backend

By default the build uses libguestfs in the container (no `--privileged`):

```
IMAGE_MOUNT_BACKEND=guestfs tools/workflow/run-build.sh
```

To use loop mounts instead (requires privileged):

```
IMAGE_MOUNT_BACKEND=loop ALLOW_PRIVILEGED=1 tools/workflow/run-build.sh
```
