#!/bin/sh
set -eu

log() { printf '%s\n' "$*" >&2; }

TARGET_DIR="${TARGET_DIR:-}"
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  log "prune-rootfs: TARGET_DIR is missing or not a directory; skipping"
  exit 0
fi

on() { [ "${1:-0}" = "1" ] || [ "${1:-0}" = "true" ]; }

PRUNE_TZ="${PRUNE_TZ:-1}"
PRUNE_DOCS="${PRUNE_DOCS:-1}"
PRUNE_MAN="${PRUNE_MAN:-1}"
PRUNE_LOCALES="${PRUNE_LOCALES:-1}"
PRUNE_I18N="${PRUNE_I18N:-1}"
PRUNE_HEADERS="${PRUNE_HEADERS:-1}"
PRUNE_PKGCONFIG="${PRUNE_PKGCONFIG:-1}"
PRUNE_STATICLIBS="${PRUNE_STATICLIBS:-1}"
PRUNE_HWDB="${PRUNE_HWDB:-0}"
PRUNE_UDEV_INPUT="${PRUNE_UDEV_INPUT:-0}"
PRUNE_TERMINFO="${PRUNE_TERMINFO:-1}"
PRUNE_SYSTEMD_CATALOG="${PRUNE_SYSTEMD_CATALOG:-1}"

PRUNE_LOCALE_KEEP="${PRUNE_LOCALE_KEEP:-en_US:en:C:POSIX}"
HELIOS_TZ="${HELIOS_TZ:-}"

rm_rf() {
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    rm -rf "$p"
  done
}

rm_f() {
  for p in "$@"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    rm -f "$p"
  done
}

prune_zoneinfo() {
  zone="$TARGET_DIR/usr/share/zoneinfo"
  [ -d "$zone" ] || return 0

  tmp="$TARGET_DIR/.zoneinfo.keep.$$"
  mkdir -p "$tmp"

  # Always keep UTC variants if present.
  for rel in UTC Etc/UTC Etc/GMT GMT; do
    if [ -f "$zone/$rel" ]; then
      mkdir -p "$tmp/$(dirname "$rel")"
      cp -p "$zone/$rel" "$tmp/$rel"
    fi
  done

  # Keep the configured timezone if provided.
  if [ -n "$HELIOS_TZ" ] && [ -f "$zone/$HELIOS_TZ" ]; then
    mkdir -p "$tmp/$(dirname "$HELIOS_TZ")"
    cp -p "$zone/$HELIOS_TZ" "$tmp/$HELIOS_TZ"
  fi

  rm_rf "$zone"
  mkdir -p "$zone"
  # shellcheck disable=SC2038
  find "$tmp" -type f -print0 | xargs -0 -I{} sh -c '
    src="$1"
    rel="${src#"$2"/}"
    dst="$3/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  ' sh {} "$tmp" "$zone"
  rm_rf "$tmp"
}

prune_locales() {
  locale_dir="$TARGET_DIR/usr/share/locale"
  [ -d "$locale_dir" ] || return 0

  keep_list=$(printf '%s' "$PRUNE_LOCALE_KEEP" | tr ':' ' ')
  for entry in "$locale_dir"/*; do
    [ -d "$entry" ] || continue
    base=$(basename "$entry")
    keep=0
    for k in $keep_list; do
      if [ "$base" = "$k" ]; then
        keep=1
        break
      fi
    done
    [ "$keep" -eq 1 ] || rm_rf "$entry"
  done
}

if on "$PRUNE_DOCS"; then
  rm_rf \
    "$TARGET_DIR/usr/share/doc" \
    "$TARGET_DIR/usr/share/info" \
    "$TARGET_DIR/usr/share/gtk-doc"
fi

if on "$PRUNE_MAN"; then
  rm_rf "$TARGET_DIR/usr/share/man"
fi

if on "$PRUNE_HEADERS"; then
  rm_rf "$TARGET_DIR/usr/include"
fi

if on "$PRUNE_PKGCONFIG"; then
  rm_rf \
    "$TARGET_DIR/usr/lib/pkgconfig" \
    "$TARGET_DIR/usr/share/pkgconfig"
fi

if on "$PRUNE_STATICLIBS"; then
  find "$TARGET_DIR/usr" -type f \( -name '*.a' -o -name '*.la' \) -delete 2>/dev/null || true
fi

if on "$PRUNE_LOCALES"; then
  prune_locales
fi

if on "$PRUNE_I18N"; then
  rm_rf "$TARGET_DIR/usr/share/i18n"
fi

if on "$PRUNE_TZ"; then
  prune_zoneinfo
fi

if on "$PRUNE_HWDB"; then
  rm_f "$TARGET_DIR/usr/lib/udev/hwdb.bin"
  rm_rf "$TARGET_DIR/usr/lib/udev/hwdb.d"
fi

if on "$PRUNE_UDEV_INPUT"; then
  rules="$TARGET_DIR/usr/lib/udev/rules.d"
  if [ -d "$rules" ]; then
    rm_f \
      "$rules/60-input-id.rules" \
      "$rules/70-joystick.rules" \
      "$rules/70-power-switch.rules" \
      "$rules/70-touchpad.rules" \
      "$rules/71-seat.rules"
    find "$rules" -maxdepth 1 -type f -name '*input*' -delete 2>/dev/null || true
  fi
fi

if on "$PRUNE_TERMINFO"; then
  rm_rf "$TARGET_DIR/usr/share/terminfo"
fi

if on "$PRUNE_SYSTEMD_CATALOG"; then
  rm_rf "$TARGET_DIR/usr/lib/systemd/catalog"
fi

# Ensure systemd is the init (busybox can overwrite the symlink) and keep a
# persistent journal directory so logs survive reboots.
if [ -x "$TARGET_DIR/usr/lib/systemd/systemd" ]; then
	# Use absolute symlink targets: /sbin and /usr/sbin are often symlinks to
	# /usr/bin in merged-/usr layouts, and relative links can resolve to
	# /usr/usr/lib/... (broken), causing kernel fallback to /bin/sh.
	ln -sf /usr/lib/systemd/systemd "$TARGET_DIR/sbin/init"
	ln -sf /usr/lib/systemd/systemd "$TARGET_DIR/usr/sbin/init"
	rm_f "$TARGET_DIR/etc/inittab"
	mkdir -p "$TARGET_DIR/var/log/journal"
	# Systemd's getty units expect /sbin/agetty; util-linux installs it in /usr/bin.
	if [ -x "$TARGET_DIR/usr/bin/agetty" ]; then
		# Avoid clobbering /usr/bin/agetty when /usr/sbin (or /sbin) is a symlink to /usr/bin.
		if [ -d "$TARGET_DIR/usr/sbin" ] && [ ! -L "$TARGET_DIR/usr/sbin" ]; then
			ln -sf /usr/bin/agetty "$TARGET_DIR/usr/sbin/agetty"
		fi
		if [ -d "$TARGET_DIR/sbin" ] && [ ! -L "$TARGET_DIR/sbin" ]; then
			ln -sf /usr/bin/agetty "$TARGET_DIR/sbin/agetty"
		fi
	fi
	# systemd-fsck uses fsck from util-linux; ensure fsck.ext* helpers are on PATH.
	for ext in ext2 ext3 ext4; do
		if [ -x "$TARGET_DIR/sbin/fsck.$ext" ] && [ ! -e "$TARGET_DIR/usr/sbin/fsck.$ext" ]; then
			ln -sf /sbin/fsck.$ext "$TARGET_DIR/usr/sbin/fsck.$ext"
		fi
	done
fi

# Some scripts call /bin/tee; busybox installs it under /usr/bin by default.
[ -x "$TARGET_DIR/usr/bin/tee" ] && [ ! -e "$TARGET_DIR/bin/tee" ] && ln -sf busybox "$TARGET_DIR/bin/tee"

# Clean up legacy provisioning unit names/links to avoid double execution when
# stage output is incrementally reused across builds.
rm_f "$TARGET_DIR/etc/systemd/system/helios-provisioner.service"
rm_f "$TARGET_DIR/etc/systemd/system/local-fs.target.wants/helios-provisioner.service"
rm_f "$TARGET_DIR/etc/systemd/system/helios-provision.target.wants/helios-provisioner.service"

exit 0
