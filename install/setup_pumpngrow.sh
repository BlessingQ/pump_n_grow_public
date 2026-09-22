#!/usr/bin/env bash
# PumpnGrow first-time setup script for Raspberry Pi OS 64-bit (GUI).
#
# One-line install on a Pi that is online:
#   curl -fsSL https://raw.githubusercontent.com/BlessingQ/pump_n_grow_public/main/install/setup_pumpngrow.sh | bash
#
# Offline / USB install: copy the whole install/ folder to the Pi, then
#   bash ~/install/setup_pumpngrow.sh
#
# The release and the boot image come from the PUBLIC repository
# BlessingQ/pump_n_grow_public, so no GitHub token is needed anywhere.
# Progress is printed as [1/8] .. [8/8].
#
# All output is ASCII-only on purpose: the Raspberry Pi framebuffer console
# has no CJK font and renders non-ASCII text as garbage.
set -euo pipefail

# When run through "curl | bash" there is no script file on disk, so fall back
# to ~/install as the working folder for the boot image assets.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR="$HOME/install"
fi

# Keep the installed application outside the source checkout. This prevents a
# source update or Git cleanup from deleting the executable or its launcher.
APP_ROOT="${PUMPNGROW_APP_ROOT:-$HOME/pumpngrow}"
BUNDLE_DIR="$APP_ROOT/bundle"
DOWNLOAD_DIR="$APP_ROOT/.updates"
RELEASE_REPOSITORY="${PUMPNGROW_GITHUB_REPOSITORY:-BlessingQ/pump_n_grow_public}"
ASSET_NAME="${PUMPNGROW_UPDATE_ASSET:-pumpngrow-linux-arm64.zip}"
CHECKSUM_NAME="${ASSET_NAME}.sha256"
# Fixed download URLs: no API call, no rate limit, no authentication.
RELEASE_BASE_URL="https://github.com/$RELEASE_REPOSITORY/releases/latest/download"
RAW_BASE_URL="https://raw.githubusercontent.com/$RELEASE_REPOSITORY/main/install"
DOWNLOAD_HOST='github.com'
# Boot splash source folder. Leave empty to auto-detect the splash folder
# next to this script (downloaded from the public repository when missing).
SPLASH_SRC_DIR="${SPLASH_SRC_DIR:-}"
# Raspberry Pi 5 onboard RTC: trickle-charge voltage for the official
# rechargeable battery (uV). Use 0 for a non-rechargeable cell.
RTC_CHARGE_UV="${PUMPNGROW_RTC_CHARGE_UV:-3000000}"

cleanup() {
  [ -n "${ZIP_PART_PATH:-}" ] && rm -f "$ZIP_PART_PATH"
  [ -n "${CHECKSUM_PART_PATH:-}" ] && rm -f "$CHECKSUM_PART_PATH"
}
trap cleanup EXIT

# --- progress helpers ------------------------------------------------------
TOTAL=8
STEP=0
if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_END=$'\033[0m'
else C_STEP=''; C_OK=''; C_WARN=''; C_END=''; fi
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s\n' "$C_STEP" "$STEP" "$TOTAL" "$C_END" "$1"; }
ok()   { printf '  %s[OK]%s %s\n' "$C_OK" "$C_END" "$1"; }
warn() { printf '  %s[!]%s %s\n' "$C_WARN" "$C_END" "$1"; }

# --- 1) environment check --------------------------------------------------
step 'Checking environment'
case "$(uname -m)" in
  aarch64|arm64) ok "Architecture: $(uname -m)" ;;
  *)
    echo "This installer must run on Raspberry Pi OS / Linux arm64. Found: $(uname -m)" >&2
    exit 1
    ;;
esac

# Resolve github.com before doing anything slow. On a freshly booted Pi
# the network may not be up yet, so retry for a while instead of failing at
# step 3 with a bare "curl: (6) Could not resolve host".
DNS_READY=0
for attempt in $(seq 1 20); do
  if getent hosts "$DOWNLOAD_HOST" >/dev/null 2>&1; then
    DNS_READY=1
    break
  fi
  if [ "$attempt" -eq 1 ]; then
    warn "Cannot resolve $DOWNLOAD_HOST yet. Waiting for the network (up to 60s)..."
  fi
  sleep 3
done

if [ "$DNS_READY" -ne 1 ]; then
  cat >&2 <<EOF

ERROR: Cannot resolve $DOWNLOAD_HOST (DNS failure -- this is curl error 6).
The Raspberry Pi has no working name resolution, so the release cannot be
downloaded. Check the following, then run this script again:

  1. Is the network connected?
       nmcli device status
  2. Not connected to Wi-Fi yet? Configure it:
       sudo raspi-config   ->   System Options   ->   Wireless LAN
  3. Does name resolution work at all?
       getent hosts $DOWNLOAD_HOST
  4. Does raw IP routing work?
       ping -c 3 8.8.8.8

If step 4 succeeds but step 3 fails, the connection is fine and only DNS is
broken. Add a public DNS server:

       echo 'nameserver 8.8.8.8' | sudo tee -a /etc/resolv.conf

On a wired-only setup, also confirm the Ethernet cable is seated and the
switch port is active.
EOF
  exit 1
fi
ok "Network reachable, $DOWNLOAD_HOST resolves"

# --- 2) install required packages ------------------------------------------
step 'Installing required packages'
sudo -v
sudo apt update || warn 'apt update reported errors; continuing with cached package lists'
sudo apt install -y curl jq unzip libgtk-3-0 imagemagick plymouth
ok 'Packages ready'

# --- 3) installer assets and latest version -------------------------------
step 'Fetching installer assets and checking the latest release'
# "curl | bash" has no install/ folder beside it: fetch the boot image and the
# splash helper from the public repository so step 6 can use them.
if [ ! -f "$SCRIPT_DIR/splash/splash.png" ]; then
  mkdir -p "$SCRIPT_DIR/splash"
  curl --fail --silent --show-error --location \
    --connect-timeout 15 --retry 3 --retry-delay 2 \
    --output "$SCRIPT_DIR/splash/splash.png" "$RAW_BASE_URL/splash/splash.png"
  curl --fail --silent --show-error --location \
    --connect-timeout 15 --retry 3 --retry-delay 2 \
    --output "$SCRIPT_DIR/splash/apply_boot_splash.sh" "$RAW_BASE_URL/splash/apply_boot_splash.sh"
  chmod +x "$SCRIPT_DIR/splash/apply_boot_splash.sh"
  ok "Installer assets downloaded to: $SCRIPT_DIR/splash"
else
  ok "Using installer assets in: $SCRIPT_DIR/splash"
fi

# The tag is informational only (the download uses the fixed /latest/ URL).
# Unauthenticated API calls are limited to 60/hour per IP; one call is fine.
RELEASE_TAG="$(
  curl --fail --silent --show-error --location \
    --connect-timeout 15 --retry 2 --retry-delay 2 \
    --header 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$RELEASE_REPOSITORY/releases/latest" \
    | jq -er '.tag_name' 2>/dev/null || echo 'latest'
)"
ok "Latest release: $RELEASE_TAG ($RELEASE_REPOSITORY)"

# --- 4) download the release (with progress bar) ---------------------------
step "Downloading release ($ASSET_NAME)"
mkdir -p "$DOWNLOAD_DIR"
ZIP_PATH="$DOWNLOAD_DIR/$ASSET_NAME"
CHECKSUM_PATH="$DOWNLOAD_DIR/$CHECKSUM_NAME"
ZIP_PART_PATH="$ZIP_PATH.part"
CHECKSUM_PART_PATH="$CHECKSUM_PATH.part"
rm -f "$ZIP_PART_PATH" "$CHECKSUM_PART_PATH"
curl --fail --show-error --location --progress-bar \
  --connect-timeout 15 --retry 3 --retry-delay 2 \
  --output "$ZIP_PART_PATH" \
  "$RELEASE_BASE_URL/$ASSET_NAME"
curl --fail --show-error --location --progress-bar \
  --connect-timeout 15 --retry 3 --retry-delay 2 \
  --output "$CHECKSUM_PART_PATH" \
  "$RELEASE_BASE_URL/$CHECKSUM_NAME"
EXPECTED_SHA256="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_PART_PATH")"
if ! [[ "$EXPECTED_SHA256" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "Invalid SHA-256 checksum file: $CHECKSUM_NAME" >&2
  exit 1
fi
ACTUAL_SHA256="$(sha256sum "$ZIP_PART_PATH" | awk '{ print $1 }')"
if [ "${ACTUAL_SHA256,,}" != "${EXPECTED_SHA256,,}" ]; then
  echo "SHA-256 verification failed for $ASSET_NAME." >&2
  exit 1
fi
unzip -tqq "$ZIP_PART_PATH" >/dev/null
mv -f "$ZIP_PART_PATH" "$ZIP_PATH"
mv -f "$CHECKSUM_PART_PATH" "$CHECKSUM_PATH"
ZIP_PART_PATH=''
CHECKSUM_PART_PATH=''
ok "Download verified and saved to: $DOWNLOAD_DIR"

# --- 5) install the app ----------------------------------------------------
step 'Installing the app'
mkdir -p "$APP_ROOT"
NEXT_BUNDLE="$APP_ROOT/.bundle.next.$$"
rm -rf "$NEXT_BUNDLE"
mkdir -p "$NEXT_BUNDLE"
unzip -q "$ZIP_PATH" -d "$NEXT_BUNDLE"
for required_path in pumpngrow data lib; do
  if [ ! -e "$NEXT_BUNDLE/$required_path" ]; then
    echo "Invalid release asset: missing $required_path at the zip root." >&2
    exit 1
  fi
done
chmod +x "$NEXT_BUNDLE/pumpngrow"
if [ -d "$BUNDLE_DIR" ]; then
  BACKUP_DIR="$APP_ROOT/bundle.backup.$(date +%Y%m%d-%H%M%S)"
  mv "$BUNDLE_DIR" "$BACKUP_DIR"
  ok "Previous bundle backed up to: $BACKUP_DIR"
fi
mv "$NEXT_BUNDLE" "$BUNDLE_DIR"
ok "Installed to: $BUNDLE_DIR"

# --- 6) apply the boot splash screen ---------------------------------------
step 'Applying boot splash screen'
if [ -z "$SPLASH_SRC_DIR" ]; then
  for d in "$SCRIPT_DIR/splash" "$HOME/install/splash" "$BUNDLE_DIR"; do
    if [ -f "$d/splash.png" ]; then
      SPLASH_SRC_DIR="$d"; break
    fi
  done
fi
APP_SPLASH_PNG="$APP_ROOT/splash.png"
PIX_THEME_DIR='/usr/share/plymouth/themes/pix'
PIX_SPLASH_PNG="$PIX_THEME_DIR/splash.png"
PIX_RENDER_PNG="$APP_ROOT/pumpngrow-pix-splash.png"
PIX_SPLASH_WIDTH=1024
PIX_SPLASH_HEIGHT=600
BOOT_CMDLINE=''
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  if [ -f "$candidate" ]; then
    BOOT_CMDLINE="$candidate"
    break
  fi
done
if [ -n "$SPLASH_SRC_DIR" ]; then
  ok "Boot splash source: $SPLASH_SRC_DIR"
  # Copy the source so the launcher icon remains available after the installer
  # folder has been removed.
  if [ -f "$SPLASH_SRC_DIR/splash.png" ]; then
    install -m 0644 "$SPLASH_SRC_DIR/splash.png" "$APP_SPLASH_PNG"
  fi
  if [ -f "$APP_SPLASH_PNG" ]; then
    if [ ! -f "$PIX_SPLASH_PNG" ]; then
      warn "Raspberry Pi OS pix theme was not found at: $PIX_SPLASH_PNG"
      warn 'Skipping boot splash to avoid enabling a custom graphics path.'
    else
      # Use the Raspberry Pi OS supplied pix theme only.  In particular, do
      # not run configure-splash or install a script theme: those paths enable
      # an extra early-graphics renderer and have caused unreliable boots on
      # some HMI panels.  The source logo is 1920x1080; make a smaller,
      # opaque 1024x600 PNG so the native theme never has to decode it at the
      # panel's full-HD size.
      convert "$APP_SPLASH_PNG" \
        -resize "${PIX_SPLASH_WIDTH}x${PIX_SPLASH_HEIGHT}" \
        -background white -gravity center -extent "${PIX_SPLASH_WIDTH}x${PIX_SPLASH_HEIGHT}" \
        -alpha off -strip -depth 8 "PNG24:$PIX_RENDER_PNG"
      if [ ! -f "$PIX_THEME_DIR/splash.pumpngrow-original.png" ]; then
        sudo cp "$PIX_SPLASH_PNG" "$PIX_THEME_DIR/splash.pumpngrow-original.png"
      fi
      sudo install -m 0644 "$PIX_RENDER_PNG" "$PIX_SPLASH_PNG"
      sudo plymouth-set-default-theme -R pix
      # Recent Raspberry Pi OS releases can load pix assets from initramfs.
      # -R normally refreshes it, but update explicitly when it is available.
      if command -v update-initramfs >/dev/null 2>&1; then
        sudo update-initramfs -u || warn 'initramfs refresh failed; pix may update after the next kernel update.'
      fi

      # Disable the fullscreen_logo options left by older PumpnGrow installers
      # that used rpi-splash-screen-support/configure-splash.  The native pix
      # theme does not need them.
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
        warn 'No Raspberry Pi cmdline.txt found; boot text options were not changed.'
      fi
      ok 'Native Raspberry Pi OS pix boot splash installed'
    fi
  fi
else
  warn 'No boot image found in install/splash or bundle; skipping the splash step.'
fi

# --- 7) Raspberry Pi 5 onboard RTC -----------------------------------------
# The official rechargeable battery is NOT charged unless rtc_bbat_vchg is set
# in config.txt, and without it the clock is lost on the next power cut.
# Feeding/cleaning schedules depend on the clock, so configure it here.
step 'Configuring onboard RTC'
PI_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
BOOT_CONFIG=''
for candidate in /boot/firmware/config.txt /boot/config.txt; do
  if [ -f "$candidate" ]; then
    BOOT_CONFIG="$candidate"
    break
  fi
done
case "$PI_MODEL" in
  *"Raspberry Pi 5"*)
    if [ -n "$BOOT_CONFIG" ]; then
      if grep -qE '^[[:space:]]*dtparam=rtc_bbat_vchg=' "$BOOT_CONFIG"; then
        sudo sed -i -E "s|^[[:space:]]*dtparam=rtc_bbat_vchg=.*|dtparam=rtc_bbat_vchg=$RTC_CHARGE_UV|" "$BOOT_CONFIG"
      else
        printf 'dtparam=rtc_bbat_vchg=%s\n' "$RTC_CHARGE_UV" | sudo tee -a "$BOOT_CONFIG" >/dev/null
      fi
      ok "RTC battery charging set to $RTC_CHARGE_UV uV in $BOOT_CONFIG (active after reboot)"
    else
      warn 'config.txt not found; RTC battery charging was not enabled'
    fi
    if [ -e /dev/rtc0 ]; then
      if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
        sudo hwclock -w && ok 'System time written to onboard RTC'
      else
        warn 'System time is not NTP-synchronized yet; run "sudo hwclock -w" once the time is correct'
      fi
    else
      warn '/dev/rtc0 not found; onboard RTC driver is missing (update Raspberry Pi OS)'
    fi
    ;;
  *)
    warn "Onboard RTC step skipped: not a Raspberry Pi 5 ($PI_MODEL)"
    ;;
esac

# --- 8) launcher script, autostart, desktop shortcut, launch ---------------
step 'Creating launcher, autostart entry, desktop shortcut and starting the app'
cat > "$APP_ROOT/start_pumpngrow.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$APP_ROOT/bundle/pumpngrow"
LOG_FILE="$APP_ROOT/pumpngrow.log"

# Bookworm/labwc can process both its native autostart file and XDG .desktop
# entries. Keep the launcher single-instance while the application is alive so
# the two compatible registration methods cannot open two HMIs or contend for
# the RS-485 adapter.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$APP_ROOT/.pumpngrow-launch.lock"
  if ! flock -n 9; then
    exit 0
  fi
fi

exec >> "$LOG_FILE" 2>&1
printf '\n[%s] PumpnGrow launcher started\n' "$(date '+%Y-%m-%d %H:%M:%S')"

# A desktop can start before an interrupted update has completed its atomic
# bundle replacement. Wait briefly for a complete, executable bundle instead
# of failing once and leaving the HMI at the desktop after a reboot.
for attempt in $(seq 1 15); do
  if [ -x "$APP" ] && [ -d "$APP_ROOT/bundle/lib" ] && [ -d "$APP_ROOT/bundle/data" ]; then
    break
  fi
  sleep 1
done
if [ ! -x "$APP" ] || [ ! -d "$APP_ROOT/bundle/lib" ] || [ ! -d "$APP_ROOT/bundle/data" ]; then
  echo "PumpnGrow bundle is incomplete: $APP_ROOT/bundle"
  exit 1
fi

# Prevent screen blanking in the GUI session.
xset s off || true
xset s noblank || true
xset -dpms || true

cd "$APP_ROOT"
exec "$APP"
EOF
chmod +x "$APP_ROOT/start_pumpngrow.sh"

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/pumpngrow.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=PumpnGrow
Exec=$APP_ROOT/start_pumpngrow.sh
StartupNotify=false
Terminal=false
X-GNOME-Autostart-Delay=3
EOF
ok 'Autostart registered: ~/.config/autostart/pumpngrow.desktop'

# Raspberry Pi OS Bookworm uses the labwc Wayland desktop by default. Its
# native autostart file is the reliable GUI-ready hook on that desktop, while
# the XDG .desktop entry above keeps older/X11 Raspberry Pi OS releases
# working. Replace only our marked block so unrelated user commands survive.
LABWC_DIR="$HOME/.config/labwc"
LABWC_AUTOSTART="$LABWC_DIR/autostart"
LABWC_TEMP="$LABWC_AUTOSTART.pumpngrow.$$"
mkdir -p "$LABWC_DIR"
if [ -f "$LABWC_AUTOSTART" ]; then
  awk '/^# >>> PumpnGrow autostart >>>$/,/^# <<< PumpnGrow autostart <<</ { next } { print }' \
    "$LABWC_AUTOSTART" > "$LABWC_TEMP"
else
  : > "$LABWC_TEMP"
fi
cat >> "$LABWC_TEMP" <<EOF
# >>> PumpnGrow autostart >>>
"$APP_ROOT/start_pumpngrow.sh" &
# <<< PumpnGrow autostart <<<
EOF
mv "$LABWC_TEMP" "$LABWC_AUTOSTART"
ok 'Labwc autostart registered: ~/.config/labwc/autostart'

# Desktop shortcut for manual relaunch after the user closes the app.
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$DESKTOP_DIR"
DESKTOP_LAUNCHER="$DESKTOP_DIR/PumpnGrow.desktop"
if [ -f "$APP_SPLASH_PNG" ]; then ICON_PATH="$APP_SPLASH_PNG"; else ICON_PATH="$BUNDLE_DIR/splash.png"; fi
cat > "$DESKTOP_LAUNCHER" <<EOF
[Desktop Entry]
Type=Application
Name=PumpnGrow
Comment=Launch PumpnGrow
Exec=$APP_ROOT/start_pumpngrow.sh
Icon=$ICON_PATH
Terminal=false
StartupNotify=false
Categories=Utility;
EOF
chmod +x "$DESKTOP_LAUNCHER"
gio set "$DESKTOP_LAUNCHER" metadata::trusted true 2>/dev/null || true
ok "Desktop shortcut: $DESKTOP_LAUNCHER"

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx 'dialout'; then
  sudo usermod -aG dialout "$USER"
  ok 'Added to the dialout group (takes effect at next login)'
fi

nohup "$APP_ROOT/start_pumpngrow.sh" > "$APP_ROOT/pumpngrow.log" 2>&1 &
ok 'PumpnGrow started in full screen'

printf '\n%sSetup complete%s -- release %s\n' "$C_OK" "$C_END" "$RELEASE_TAG"
printf 'Executable: %s\n' "$BUNDLE_DIR/pumpngrow"
printf 'Reboot once to apply RS-485 (dialout) permissions and the RTC setting: sudo reboot\n'
