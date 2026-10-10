include $(sort $(wildcard $(BR2_EXTERNAL_PHOTONVISION_OS_PATH)/package/*/*.mk))

# host-erofs-utils with multithreaded compression, for mkfs.erofs --workers in
# post-image-rootfs.sh (upstream Buildroot doesn't enable it). The configure
# options are expanded when the package configures, so appending here works.
HOST_EROFS_UTILS_CONF_OPTS += --enable-multithreading
