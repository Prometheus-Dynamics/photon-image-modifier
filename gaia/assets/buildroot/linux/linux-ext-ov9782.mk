################################################################################
# Linux extension: stage OV9782 driver and bindings into kernel tree
#
# Copies prebuilt source files from this repo into $(LINUX_DIR) so we avoid
# carrying a large kernel patch. Also appends minimal build wiring if missing.
################################################################################

OV9782_EXT_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# Stage source + Kconfig wiring before kernel configure step.
LINUX_POST_PATCH_HOOKS += OV9782_COPY_FILES$(sep)

define OV9782_COPY_FILES
	@echo "[ov9782] staging driver into kernel tree"
	@mkdir -p $(LINUX_DIR)/drivers/media/i2c
	@cp -f $(OV9782_EXT_DIR)/ov9782/drivers/media/i2c/ov9782.c \
		$(LINUX_DIR)/drivers/media/i2c/ov9782.c
	@mkdir -p $(LINUX_DIR)/Documentation/devicetree/bindings/media/i2c
	@cp -f $(OV9782_EXT_DIR)/ov9782/Documentation/devicetree/bindings/media/i2c/ovti,ov9782.yaml \
		$(LINUX_DIR)/Documentation/devicetree/bindings/media/i2c/ovti,ov9782.yaml
	@grep -q "CONFIG_VIDEO_OV9782" $(LINUX_DIR)/drivers/media/i2c/Makefile || \
		echo 'obj-$$(CONFIG_VIDEO_OV9782) += ov9782.o' >> $(LINUX_DIR)/drivers/media/i2c/Makefile
	@grep -q "config VIDEO_OV9782" $(LINUX_DIR)/drivers/media/i2c/Kconfig || \
		printf '\nconfig VIDEO_OV9782\n\ttristate "OmniVision OV9782 sensor support"\n\tdepends on OF_GPIO\n\thelp\n\t  This is a Video4Linux2 sensor driver for the OmniVision\n\t  OV9782 camera sensor.\n\n\t  To compile this driver as a module, choose M here: the\n\t  module will be called ov9782.\n' \
		>> $(LINUX_DIR)/drivers/media/i2c/Kconfig
	@grep -q "OMNIVISION OV9782 SENSOR DRIVER" $(LINUX_DIR)/MAINTAINERS || \
		printf '\nOMNIVISION OV9782 SENSOR DRIVER\nM:\tPaul J. Murphy <paul.j.murphy@intel.com>\nM:\tDaniele Alessandrelli <daniele.alessandrelli@intel.com>\nL:\tlinux-media@vger.kernel.org\nS:\tMaintained\nT:\tgit git://linuxtv.org/media_tree.git\nF:\tDocumentation/devicetree/bindings/media/i2c/ovti,ov9782.yaml\nF:\tdrivers/media/i2c/ov9782.c\n' \
		>> $(LINUX_DIR)/MAINTAINERS
endef

# Ensure the OV9782 symbol is enabled after kernel configuration is generated.
define OV9782_ENABLE_CONFIG
	@if [ -x $(LINUX_DIR)/scripts/config ]; then \
		$(LINUX_DIR)/scripts/config --module VIDEO_OV9782; \
	else \
		$(MAKE) -C $(LINUX_DIR) $(LINUX_MAKE_FLAGS) scripts; \
		$(LINUX_DIR)/scripts/config --module VIDEO_OV9782; \
	fi
	$(MAKE) -C $(LINUX_DIR) $(LINUX_MAKE_FLAGS) olddefconfig
endef

LINUX_POST_CONFIGURE_HOOKS += OV9782_ENABLE_CONFIG$(sep)

# Ensure the module is installed into the target rootfs and depmod picks it up.
define OV9782_INSTALL_MODULE
	@if [ -f $(LINUX_DIR)/drivers/media/i2c/ov9782.ko ]; then \
		$(INSTALL) -D $(LINUX_DIR)/drivers/media/i2c/ov9782.ko \
			$(TARGET_DIR)/usr/lib/modules/$(LINUX_VERSION_PROBED)/extra/ov9782.ko; \
		$(HOST_DIR)/sbin/depmod -b $(TARGET_DIR) $(LINUX_VERSION_PROBED); \
	else \
		echo "[ov9782] module missing; skipping install"; \
	fi
endef

LINUX_POST_INSTALL_TARGET_HOOKS += OV9782_INSTALL_MODULE$(sep)
