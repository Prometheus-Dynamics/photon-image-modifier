################################################################################
# Linux extension: enforce camera stack for libcamera on Raspberry Pi (6.6+)
#
# - Prefer the modern Media Controller Unicam driver over the legacy one
# - Ensure Media Controller Request API is enabled (required by libcamera)
# - Keep related V4L2/MC options on
#
# Buildroot includes linux-ext-*.mk and runs PACKAGES_LINUX_CONFIG_FIXUPS
# during kernel kconfig fixups. We use this to override upstream defconfigs
# that may default to the legacy Unicam driver on 6.6.x.
################################################################################

PACKAGES_LINUX_CONFIG_FIXUPS += $(LINUX_CAMERA_FIXUPS)$(sep)

define LINUX_CAMERA_FIXUPS
	# Core media controller + request API used by libcamera
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_SUPPORT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_CONTROLLER)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_CONTROLLER_REQUEST_API)
	$(call KCONFIG_ENABLE_OPT,CONFIG_MEDIA_CAMERA_SUPPORT)
	$(call KCONFIG_ENABLE_OPT,CONFIG_V4L2_SUBDEV_API)
	$(call KCONFIG_ENABLE_OPT,CONFIG_V4L2_FWNODE)

    # Force the modern Unicam and disable legacy to avoid duplicate
    # driver registration ("Driver 'unicam' is already registered") on 6.6/6.12.
    $(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_BCM2835_UNICAM)
    $(call KCONFIG_DISABLE_OPT,CONFIG_VIDEO_BCM2835_UNICAM_LEGACY)

	# Helpful on Pi4/CM4: make sure ISP is available
	$(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_BCM2835_ISP)

	# OV9782 sensor must be present for default CM5 camera streams to probe/start.
	# Enabling this at kconfig-fixup time avoids relying on fragile fragment wiring.
	$(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_OV9782)

	# Make sure video core is present
	$(call KCONFIG_ENABLE_OPT,CONFIG_VIDEO_DEV)

	# I2C muxing on CSI connector is common; ensure these are available
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C_MUX)
	$(call KCONFIG_ENABLE_OPT,CONFIG_I2C_MUX_PINS)
endef
