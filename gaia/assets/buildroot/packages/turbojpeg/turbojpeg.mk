# Latest stable libjpeg-turbo release as of 2025
TURBOJPEG_VERSION = 3.1.0
TURBOJPEG_SITE = https://github.com/libjpeg-turbo/libjpeg-turbo.git
TURBOJPEG_SITE_METHOD = git

# pkg-config is used during configuration; nasm is needed for SIMD
# optimisations on x86. These are provided as host tools.
TURBOJPEG_DEPENDENCIES = \
    host-pkgconf \
    host-nasm

TURBOJPEG_CONF_OPTS = \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib

$(eval $(cmake-package))
