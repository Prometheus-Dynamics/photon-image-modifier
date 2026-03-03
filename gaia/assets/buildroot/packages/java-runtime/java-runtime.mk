################################################################################
#
# java-runtime
#
################################################################################

JAVA_RUNTIME_LICENSE = GPL-2.0 with Classpath exception

JAVA_RUNTIME_RELEASE_URL = $(call qstrip,$(BR2_PACKAGE_JAVA_RUNTIME_RELEASE_URL))
JAVA_RUNTIME_LOCAL_PATH = $(call qstrip,$(BR2_PACKAGE_JAVA_RUNTIME_LOCAL_PATH))

ifeq ($(BR2_PACKAGE_JAVA_RUNTIME_SOURCE_LOCAL),y)
ifeq ($(strip $(JAVA_RUNTIME_LOCAL_PATH)),)
$(error BR2_PACKAGE_JAVA_RUNTIME_SOURCE_LOCAL=y but BR2_PACKAGE_JAVA_RUNTIME_LOCAL_PATH is empty)
endif
JAVA_RUNTIME_SITE = $(patsubst %/,%,$(dir $(JAVA_RUNTIME_LOCAL_PATH)))
JAVA_RUNTIME_SOURCE = $(notdir $(JAVA_RUNTIME_LOCAL_PATH))
JAVA_RUNTIME_SITE_METHOD = file
else
ifeq ($(strip $(JAVA_RUNTIME_RELEASE_URL)),)
$(error BR2_PACKAGE_JAVA_RUNTIME_SOURCE_RELEASE=y but BR2_PACKAGE_JAVA_RUNTIME_RELEASE_URL is empty)
endif
JAVA_RUNTIME_SITE = $(patsubst %/,%,$(dir $(JAVA_RUNTIME_RELEASE_URL)))
JAVA_RUNTIME_SOURCE = $(notdir $(JAVA_RUNTIME_RELEASE_URL))
endif

define JAVA_RUNTIME_INSTALL_TARGET_CMDS
	set -eu; \
	install_dir="$(call qstrip,$(BR2_PACKAGE_JAVA_RUNTIME_INSTALL_DIR))"; \
	if [ -z "$$install_dir" ]; then \
		install_dir="/usr/lib/jvm"; \
	fi; \
	java_bin="$$(find $(@D) -mindepth 1 -maxdepth 8 -type f -path '*/bin/java' -print -quit)"; \
	if [ -z "$$java_bin" ]; then \
		echo "java-runtime: unable to locate bin/java under $(@D)" >&2; \
		exit 1; \
	fi; \
	runtime_root="$$(dirname "$$(dirname "$$java_bin")")"; \
	$(RM) -rf "$(TARGET_DIR)$$install_dir"; \
	$(INSTALL) -d -m 0755 "$(TARGET_DIR)$$install_dir"; \
	cp -a "$$runtime_root/." "$(TARGET_DIR)$$install_dir/"; \
	$(INSTALL) -d -m 0755 "$(TARGET_DIR)/usr/bin"; \
	ln -snf "$$install_dir/bin/java" "$(TARGET_DIR)/usr/bin/java"
endef

$(eval $(generic-package))
