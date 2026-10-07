################################################################################
#
# photonvision-jre
#
################################################################################

# A minimal Java runtime for PhotonVision, made with jlink from Eclipse
# Temurin's prebuilt aarch64 jmods instead of compiling OpenJDK. jlink runs
# from a prebuilt Temurin host JDK of exactly the same release (jlink refuses
# target jmods of any other version). Both downloads are pinned by sha256 in
# photonvision-jre.hash.
PHOTONVISION_JRE_VERSION = 25.0.4.1_1
PHOTONVISION_JRE_RELEASE = jdk-$(subst _,%2B,$(PHOTONVISION_JRE_VERSION))
PHOTONVISION_JRE_SITE = https://github.com/adoptium/temurin25-binaries/releases/download/$(PHOTONVISION_JRE_RELEASE)
PHOTONVISION_JRE_SOURCE = OpenJDK25U-jmods_aarch64_linux_hotspot_$(PHOTONVISION_JRE_VERSION).tar.gz
PHOTONVISION_JRE_LICENSE = GPL-2.0 with Classpath exception
PHOTONVISION_JRE_INSTALL_STAGING = NO

ifeq ($(HOSTARCH),x86_64)
PHOTONVISION_JRE_HOST_ARCH = x64
else ifeq ($(HOSTARCH),aarch64)
PHOTONVISION_JRE_HOST_ARCH = aarch64
endif
PHOTONVISION_JRE_HOST_JDK = OpenJDK25U-jdk_$(PHOTONVISION_JRE_HOST_ARCH)_linux_hotspot_$(PHOTONVISION_JRE_VERSION).tar.gz
PHOTONVISION_JRE_EXTRA_DOWNLOADS = $(PHOTONVISION_JRE_HOST_JDK)

# The modules PhotonVision needs. `jdeps --print-module-deps` on the
# linuxarm64 jar (PhotonVision 2027, Javalin/Jetty 11, sqlite-jdbc, tinylog,
# OSHI, diozero, Jackson) reports:
#   java.base java.desktop java.instrument java.management java.naming
#   java.security.jgss java.sql jdk.unsupported
# (java.desktop: java.awt.Color, BufferedImage and ImageIO in PhotonVision
# itself; it pulls in java.xml, java.prefs and java.datatransfer). Added as a
# margin for what is only reached reflectively or through service lookup:
#   java.logging     java.util.logging, used by several libraries at run time
#   jdk.zipfs        the zip/jar FileSystem provider (Jetty resources in jars)
#   jdk.management   com.sun.management MXBeans (OSHI, JVM metrics)
#   jdk.net          extended socket options Jetty probes for
#   jdk.crypto.ec    empty since JDK 22 (SunEC is in java.base); harmless,
#                    kept so code that requires it by name still resolves
# PhotonVision starts with exactly this set and serves its UI and docs (checked
# under qemu-user). Locales other than English and the extra charsets
# (jdk.localedata, jdk.charsets) are left out.
PHOTONVISION_JRE_MODULES = \
	java.base,java.desktop,java.instrument,java.logging,java.management,\
	java.naming,java.security.jgss,java.sql,jdk.unsupported,jdk.zipfs,\
	jdk.management,jdk.net,jdk.crypto.ec

# The module image (lib/modules) is left uncompressed: the root filesystem
# is EROFS with LZMA, which packs it to about 60 % of a zip-9 image (20 MiB
# against 34 MiB for the whole runtime), and the JVM then maps classes
# without inflating each one. Set to zip-9 for a smaller unpacked size.
PHOTONVISION_JRE_COMPRESS ?= zip-0

# Libraries the headless runtime never loads and whose dependencies the image
# does not have (X11, ALSA), and the keytool launcher.
PHOTONVISION_JRE_REMOVE = \
	lib/libawt_xawt.so lib/libjawt.so lib/libsplashscreen.so \
	lib/libjsound.so bin/keytool

define PHOTONVISION_JRE_BUILD_CMDS
	rm -rf $(@D)/host-jdk $(@D)/jmods $(@D)/image $(@D)/tmp
	mkdir -p $(@D)/host-jdk $(@D)/jmods $(@D)/tmp
	$(call suitable-extractor,$(PHOTONVISION_JRE_HOST_JDK)) \
		$(PHOTONVISION_JRE_DL_DIR)/$(PHOTONVISION_JRE_HOST_JDK) | \
		$(TAR) --strip-components=1 -C $(@D)/host-jdk $(TAR_OPTIONS) -
	cp $(@D)/*.jmod $(@D)/jmods/
	$(@D)/host-jdk/bin/jlink -J-Djava.io.tmpdir=$(@D)/tmp \
		--module-path $(@D)/jmods \
		--add-modules $(subst $(space),,$(strip $(PHOTONVISION_JRE_MODULES))) \
		--strip-java-debug-attributes --no-header-files --no-man-pages \
		--compress=$(PHOTONVISION_JRE_COMPRESS) \
		--output $(@D)/image
	cd $(@D)/image && rm -f $(PHOTONVISION_JRE_REMOVE)
	# jlink's --strip-debug would strip the natives with the host objcopy,
	# which cannot read aarch64 objects; strip with the target toolchain.
	find $(@D)/image -type f \( -name '*.so' -o -path '*/bin/*' \
		-o -name jspawnhelper -o -name jexec \) \
		-exec $(TARGET_CROSS)strip --strip-unneeded {} +
endef

define PHOTONVISION_JRE_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/lib/jvm
	mkdir -p $(TARGET_DIR)/usr/lib/jvm $(TARGET_DIR)/usr/bin
	cp -dpfr $(@D)/image/. $(TARGET_DIR)/usr/lib/jvm/
	ln -snf ../lib/jvm/bin/java $(TARGET_DIR)/usr/bin/java
endef

$(eval $(generic-package))
