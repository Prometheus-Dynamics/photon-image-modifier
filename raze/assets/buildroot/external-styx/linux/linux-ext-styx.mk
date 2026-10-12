################################################################################
# Linux extension: Styx's sensor bridge module and PiSP back end driver, from
# the Styx checkout in BR2_LINUX_KERNEL_EXT_STYX_DIR.
#
# The same steps as Styx's own kernel-modules/styx-sensor-bridge/buildroot/
# linux-ext-styx-sensor-bridge.mk, which expects the module sources copied next
# to it; here they are read from the pinned Styx source instead. The bridge's
# overlay is compiled by the image assembly (raze/photonvision-styx.toml).
################################################################################

STYX_EXT_DIR = $(call qstrip,$(BR2_LINUX_KERNEL_EXT_STYX_DIR))

ifeq ($(BR2_LINUX_KERNEL_EXT_STYX_SENSOR_BRIDGE),y)

STYX_BRIDGE_SRC = $(STYX_EXT_DIR)/styx-sensor-bridge
STYX_BRIDGE_KDIR = $(LINUX_DIR)/drivers/media/platform/styx

define STYX_BRIDGE_COPY_FILES
	@echo "[styx-bridge] staging styx_sensor_bridge from $(STYX_BRIDGE_SRC)"
	@test -f $(STYX_BRIDGE_SRC)/styx_sensor_bridge.c || \
		{ echo "[styx-bridge] no styx_sensor_bridge.c in $(STYX_BRIDGE_SRC)"; exit 1; }
	@mkdir -p $(STYX_BRIDGE_KDIR)
	@cp -f $(STYX_BRIDGE_SRC)/styx_sensor_bridge.c \
		$(STYX_BRIDGE_SRC)/styx_sensor_bridge.h \
		$(STYX_BRIDGE_SRC)/Kconfig $(STYX_BRIDGE_KDIR)/
	@cp -f $(STYX_BRIDGE_SRC)/Kbuild $(STYX_BRIDGE_KDIR)/Makefile
	@grep -q "^obj-y += styx/" $(LINUX_DIR)/drivers/media/platform/Makefile || \
		echo 'obj-y += styx/' >> $(LINUX_DIR)/drivers/media/platform/Makefile
	@grep -q "platform/styx/Kconfig" $(LINUX_DIR)/drivers/media/platform/Kconfig || \
		sed -i '/^endif # MEDIA_PLATFORM_DRIVERS/i source "drivers/media/platform/styx/Kconfig"' \
			$(LINUX_DIR)/drivers/media/platform/Kconfig
	@grep -q "platform/styx/Kconfig" $(LINUX_DIR)/drivers/media/platform/Kconfig || \
		{ echo "[styx-bridge] could not wire Kconfig"; exit 1; }
endef

LINUX_POST_PATCH_HOOKS += STYX_BRIDGE_COPY_FILES

define STYX_BRIDGE_ENABLE_CONFIG
	$(LINUX_DIR)/scripts/config --file $(LINUX_DIR)/.config --module VIDEO_STYX_SENSOR_BRIDGE
	$(MAKE) -C $(LINUX_DIR) $(LINUX_MAKE_FLAGS) olddefconfig
	grep -q '^CONFIG_VIDEO_STYX_SENSOR_BRIDGE=m' $(LINUX_DIR)/.config || \
		{ echo "[styx-bridge] CONFIG_VIDEO_STYX_SENSOR_BRIDGE did not stay =m"; exit 1; }
endef

LINUX_POST_CONFIGURE_HOOKS += STYX_BRIDGE_ENABLE_CONFIG

endif

ifeq ($(BR2_LINUX_KERNEL_EXT_STYX_PISPBE),y)

STYX_PISPBE_SRC = $(STYX_EXT_DIR)/pispbe
STYX_PISPBE_KDIR = $(LINUX_DIR)/drivers/media/platform/raspberrypi/pisp_be
# The stock pisp_be.c the Styx version was made from (rpi-7.2.y 53679a5, the
# Raze kernel; see pispbe/README.md in Styx).
STYX_PISPBE_STOCK_SHA256 = 6d36c1076af7276aeb5b3f5f9d8f3f88ee6a3deb16477d1e3a977ca2459adbce

# Unlike Styx's own extension, a kernel whose pisp_be.c is not the expected
# one fails the build: this image exists to ship the faster driver.
define STYX_PISPBE_COPY_FILES
	@if [ "$$(sha256sum $(STYX_PISPBE_KDIR)/pisp_be.c | cut -d' ' -f1)" = "$(STYX_PISPBE_STOCK_SHA256)" ]; then \
		echo "[styx-pispbe] replacing pisp_be.c with the Styx version"; \
		cp -f $(STYX_PISPBE_SRC)/pisp_be.c $(STYX_PISPBE_SRC)/pisp_be_formats.h \
			$(STYX_PISPBE_KDIR)/; \
	elif cmp -s $(STYX_PISPBE_SRC)/pisp_be.c $(STYX_PISPBE_KDIR)/pisp_be.c; then \
		echo "[styx-pispbe] pisp_be.c is already the Styx version"; \
	else \
		echo "[styx-pispbe] this kernel's pisp_be.c is not the one the Styx version was made from"; \
		exit 1; \
	fi
endef

LINUX_POST_PATCH_HOOKS += STYX_PISPBE_COPY_FILES

endif
