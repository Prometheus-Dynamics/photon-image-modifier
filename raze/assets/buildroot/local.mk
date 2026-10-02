# Buildroot package override file for the Raze target (BR2_PACKAGE_OVERRIDE_FILE).
# Buildroot includes it before the package .mk files.
#
# On aarch64, rpi-userland builds no EGL/GLES libraries (Mesa provides them),
# but its install still copies the old Broadcom EGL/GLES/KHR headers into
# staging, where they can overwrite Mesa's depending on build order. The
# photon-libcamera-gl-driver JNI is compiled against this sysroot, so keep
# rpi-userland out of staging: nothing links against it, and vcgencmd and
# friends are still installed to the target. The cmake infrastructure only
# defines RPI_USERLAND_INSTALL_STAGING_CMDS when it is not already defined.
#
# This lives here instead of in a Buildroot external tree so the Raze target
# can use the device package's external tree as is: a combined external_tree
# value needs an @source:atlas token in a local layer, which Gaia 2.1 resolves
# for every target, not only Raze.
ifeq ($(BR2_aarch64)$(BR2_PACKAGE_RPI_USERLAND),yy)
define RPI_USERLAND_INSTALL_STAGING_CMDS
	@echo "rpi-userland: not installed to staging on aarch64 (keeps Mesa's EGL/GLES headers)"
endef
endif
