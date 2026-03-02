# The upstream Coral runtime bundles prebuilt libraries for each
# architecture/thermal profile.  Instead of trying to cross-compile
# libedgetpu with Bazel, unpack the official runtime archive and
# install the prebuilt aarch64/armv7 libraries directly.
CORALTPU_VERSION = 20221024
CORALTPU_SOURCE = edgetpu_runtime_$(CORALTPU_VERSION).zip
CORALTPU_SITE = https://github.com/google-coral/libedgetpu/releases/download/release-grouper
CORALTPU_LICENSE = Apache-2.0
CORALTPU_LICENSE_FILES = libedgetpu/LICENSE
CORALTPU_INSTALL_STAGING = NO

# Only ARM targets are supported by the runtime blobs provided in the
# release archive.
ifeq ($(BR2_aarch64),y)
CORALTPU_LIB_ARCH = aarch64
else ifeq ($(BR2_arm),y)
CORALTPU_LIB_ARCH = armv7a
else
$(error "coraltpu package currently supports only 32/64-bit Arm targets")
endif

define CORALTPU_EXTRACT_CMDS
	unzip -q $(CORALTPU_DL_DIR)/$(CORALTPU_SOURCE) -d $(@D)
	mv $(@D)/edgetpu_runtime/* $(@D)/
	rmdir $(@D)/edgetpu_runtime
endef

define CORALTPU_INSTALL_TARGET_CMDS
	$(INSTALL) -d $(TARGET_DIR)/usr/lib/edgetpu

	$(INSTALL) -m 0644 $(CORALTPU_SRCDIR)/libedgetpu/throttled/$(CORALTPU_LIB_ARCH)/libedgetpu.so.1.0 \
		$(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-standard.so.1.0
	ln -sf libedgetpu-standard.so.1.0 $(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-standard.so.1
	ln -sf libedgetpu-standard.so.1 $(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-standard.so

	$(INSTALL) -m 0644 $(CORALTPU_SRCDIR)/libedgetpu/direct/$(CORALTPU_LIB_ARCH)/libedgetpu.so.1.0 \
		$(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-max.so.1.0
	ln -sf libedgetpu-max.so.1.0 $(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-max.so.1
	ln -sf libedgetpu-max.so.1 $(TARGET_DIR)/usr/lib/edgetpu/libedgetpu-max.so

	# Keep the canonical libedgetpu path and default runtime pointing at the standard firmware
	rm -rf $(TARGET_DIR)/usr/lib/libedgetpu
	ln -sf edgetpu $(TARGET_DIR)/usr/lib/libedgetpu
	ln -sf edgetpu/libedgetpu-standard.so.1.0 $(TARGET_DIR)/usr/lib/libedgetpu.so.1.0
	ln -sf libedgetpu.so.1.0 $(TARGET_DIR)/usr/lib/libedgetpu.so.1
	ln -sf libedgetpu.so.1 $(TARGET_DIR)/usr/lib/libedgetpu.so

	$(INSTALL) -d $(TARGET_DIR)/etc/udev/rules.d
	$(INSTALL) -m 0644 $(CORALTPU_SRCDIR)/libedgetpu/edgetpu-accelerator.rules \
		$(TARGET_DIR)/etc/udev/rules.d/65-edgetpu-accelerator.rules
endef

$(eval $(generic-package))
