#!/usr/bin/env bash
# PumpnGrow boot splash screen installer.
#
# This script uses splash.png sitting next to it in install/splash/ and puts
# it into Raspberry Pi OS's built-in pix Plymouth theme.  It deliberately
# avoids the custom early-splash and script-theme rendering paths.
# Copy the whole install/ folder to the Raspberry Pi, then run it from a
# GUI terminal:
#
#   bash ~/install/splash/apply_boot_splash.sh
#
# The script resolves file paths relative to its own location, so it works
# from any directory without edits.
#
# All output is ASCII-only on purpose: the Raspberry Pi framebuffer console
# has no CJK font and renders non-ASCII text as garbage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPLASH_PNG="$SCRIPT_DIR/splash.png"
PIX_THEME_DIR='/usr/share/plymouth/themes/pix'
PIX_SPLASH_PNG="$PIX_THEME_DIR/splash.png"
PIX_SPLASH_WIDTH=1024
PIX_SPLASH_HEIGHT=600
WORK_DIR="$(mktemp -d)"
PIX_RENDER_PNG="$WORK_DIR/pumpngrow-pix-splash.png"
BOOT_CMDLINE=''
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  if [ -f "$candidate" ]; then
    BOOT_CMDLINE="$candidate"
    break
  fi
done

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Applying the PumpnGrow boot splash"
echo "  PNG: $SPLASH_PNG"
echo "  theme: Raspberry Pi OS pix (native)"
echo "  render size: ${PIX_SPLASH_WIDTH}x${PIX_SPLASH_HEIGHT}"

if [ ! -f "$SPLASH_PNG" ]; then
  echo "PNG file not found: $SPLASH_PNG" >&2
  echo "Make sure splash.png from install/ sits next to this script." >&2
  exit 1
fi

sudo apt update || echo "  [!] apt update reported errors; continuing with cached package lists"
sudo apt install -y imagemagick plymouth

if [ ! -f "$PIX_SPLASH_PNG" ]; then
  echo "Raspberry Pi OS pix theme was not found at: $PIX_SPLASH_PNG" >&2
  echo "No boot setting was changed. Use a Raspberry Pi OS image that includes the pix theme." >&2
  exit 1
fi

# Keep the original system asset once so the change is reversible.  The pix
# theme is the native Raspberry Pi OS theme that the device already supports.
convert "$SPLASH_PNG" \
  -resize "${PIX_SPLASH_WIDTH}x${PIX_SPLASH_HEIGHT}" \
  -background white -gravity center -extent "${PIX_SPLASH_WIDTH}x${PIX_SPLASH_HEIGHT}" \
  -alpha off -strip -depth 8 "PNG24:$PIX_RENDER_PNG"
if [ ! -f "$PIX_THEME_DIR/splash.pumpngrow-original.png" ]; then
  sudo cp "$PIX_SPLASH_PNG" "$PIX_THEME_DIR/splash.pumpngrow-original.png"
fi
sudo install -m 0644 "$PIX_RENDER_PNG" "$PIX_SPLASH_PNG"
sudo plymouth-set-default-theme -R pix
# On current Raspberry Pi OS, the pix asset may be read from initramfs.  The
# theme command normally refreshes it; do it explicitly when available.
if command -v update-initramfs >/dev/null 2>&1; then
  sudo update-initramfs -u || echo "  [!] initramfs refresh failed; pix may update after the next kernel update."
fi

# Older PumpnGrow installers enabled the rpi-splash fullscreen-logo renderer.
# Remove only its two cmdline options, then add standard quiet-pix options.
if [ -n "$BOOT_CMDLINE" ]; then
  cmdline="$(sudo tr '\n' ' ' < "$BOOT_CMDLINE")"
  cmdline="$(printf '%s\n' "$cmdline" | sed -E 's/(^| )fullscreen_logo_name=[^ ]+//g; s/(^| )fullscreen_logo=[^ ]+//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  for option in quiet splash plymouth.ignore-serial-consoles logo.nologo vt.global_cursor_default=0; do
    case " $cmdline " in
      *" $option "*) ;;
      *) cmdline="$cmdline $option" ;;
    esac
  done
  printf '%s\n' "$cmdline" | sudo tee "$BOOT_CMDLINE" >/dev/null
else
  echo "  [!] No Raspberry Pi cmdline.txt found; boot text options were not changed."
fi

echo
echo "Done. A reboot is required to see the new screen."
read -r -p "Reboot now? [y/N] " ans || ans=""
case "$ans" in
  [yY]|[yY][eE][sS]) sudo reboot ;;
  *) echo "Run 'sudo reboot' later to apply it." ;;
esac
