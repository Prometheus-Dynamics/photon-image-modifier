################################################################################
#
# openvscode-server
#
################################################################################

OPENVSCODE_SERVER_VERSION = 1.106.3
OPENVSCODE_SERVER_SITE = https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v$(OPENVSCODE_SERVER_VERSION)
OPENVSCODE_SERVER_SOURCE = openvscode-server-v$(OPENVSCODE_SERVER_VERSION)-linux-arm64.tar.gz
OPENVSCODE_SERVER_SUBDIR = openvscode-server-v$(OPENVSCODE_SERVER_VERSION)-linux-arm64
OPENVSCODE_SERVER_LICENSE = MIT
OPENVSCODE_SERVER_LICENSE_FILES = extensions/ms-vscode.js-debug/LICENSE.txt
OPENVSCODE_SERVER_DL_SUBDIR = openvscode-server

define OPENVSCODE_SERVER_INSTALL_TARGET_CMDS
	$(RM) -rf $(TARGET_DIR)/opt/helios/ide
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/opt/helios/ide
	cp -dpfr $(@D)/. $(TARGET_DIR)/opt/helios/ide
	# Prune bundled extensions/assets to keep the IDE small.
	# Helios only targets FFI languages: Java, Python3, C/C++, Rust, TypeScript/JavaScript.
	# (Note: language servers/debuggers may still be installed separately.)
	$(RM) -rf $(TARGET_DIR)/opt/helios/ide/extensions/node_modules
	@keep_exts="cpp java python rust typescript-language-features javascript git git-base configuration-editing json yaml shellscript make terminal-suggest search-result references-view merge-conflict theme-defaults theme-seti editorconfig markdown-language-features markdown-math html css scss less emmet ms-vscode.js-debug ms-vscode.cpptools ms-vscode.cmake-tools ms-vscode.makefile-tools ms-python.python ms-python.vscode-pylance ms-python.debugpy redhat.java rust-lang.rust-analyzer vscjava.vscode-java-debug vscjava.vscode-java-test vscjava.vscode-java-dependency vscjava.vscode-java-pack vscjava.vscode-maven vscjava.vscode-gradle esbenp.prettier-vscode dbaeumer.vscode-eslint" ; \
	for d in $(TARGET_DIR)/opt/helios/ide/extensions/* ; do \
		[ -d "$$d" ] || continue ; \
		b=$$(basename "$$d") ; \
		case "$$b" in \
			cpp|java|python|rust|typescript-language-features|javascript|git|git-base|configuration-editing|json|yaml|shellscript|make|terminal-suggest|search-result|references-view|merge-conflict|theme-defaults*|theme-seti*|editorconfig|markdown-language-features|markdown-math|html|css|scss|less|emmet|ms-vscode.js-debug*|ms-vscode.cpptools*|ms-vscode.cmake-tools*|ms-vscode.makefile-tools*|ms-python.python*|ms-python.vscode-pylance*|ms-python.debugpy*|redhat.java*|rust-lang.rust-analyzer*|vscjava.vscode-java-debug*|vscjava.vscode-java-test*|vscjava.vscode-java-dependency*|vscjava.vscode-java-pack*|vscjava.vscode-maven*|vscjava.vscode-gradle*|esbenp.prettier-vscode*|dbaeumer.vscode-eslint*) ;; \
			*) $(RM) -rf "$$d" ;; \
		esac ; \
	done
	# Drop source maps (debug-only, large on disk).
	@find $(TARGET_DIR)/opt/helios/ide -type f \( -name '*.map' -o -name '*.map.gz' \) -exec rm -f {} +
endef

$(eval $(generic-package))
