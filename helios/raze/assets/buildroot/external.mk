# Package overrides are materialized by Gaia; Linux extensions are discovered
# from this external tree's linux/ directory by Buildroot.

# On aarch64, rpi-userland builds no EGL/GLES libraries (Mesa provides them),
# but its install still copies the old Broadcom EGL/GLES/KHR headers into
# staging, where they can overwrite Mesa's depending on build order. The
# photon-libcamera-gl-driver JNI is compiled against this sysroot, so keep
# rpi-userland out of staging: nothing links against it, and vcgencmd and
# friends are still installed to the target. This file is included after the
# package .mk files; the staging command is only expanded when the step runs.
ifeq ($(BR2_aarch64)$(BR2_PACKAGE_RPI_USERLAND),yy)
define RPI_USERLAND_INSTALL_STAGING_CMDS
	@echo "rpi-userland: not installed to staging on aarch64 (keeps Mesa's EGL/GLES headers)"
endef
endif
