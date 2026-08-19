#!/usr/bin/env bash
#
# IRL Player kiosk installer for Raspberry Pi (arm64)
#
# One-line remote install (run on the Pi):
#   curl -fsSL https://linux-player.theirlnetwork.com/install.sh | sudo bash
#
# The script expects the .deb to be hosted next to it at the same base URL
# (the GitHub Pages site on the custom domain by default; set IRL_BASE_URL
# to use another server).
#
# What it does:
#   1. Verifies the machine is a Raspberry Pi running a 64-bit (arm64) OS
#   2. Downloads and installs the irl-player .deb (with dependencies)
#   3. Installs cage (Wayland kiosk compositor) so the app runs fullscreen,
#      alone on the screen, on the top layer — nothing can appear over it
#   4. Creates a dedicated "irlplayer" user and a systemd service that
#      starts the app on boot and restarts it if it ever crashes
#   5. Disables console blanking and any desktop display manager
#   6. Sets up auto-update: the device re-fetches this script on boot and
#      every hour, and reinstalls whenever the published script changes
#
set -euo pipefail

# ----------------------- configuration -----------------------
BASE_URL="${IRL_BASE_URL:-https://linux-player.theirlnetwork.com}"
VERSION="1.2.5"
# Architectures with a build in packages/ — add e.g. "amd64" here once
# packages/irl-player_<version>_amd64.deb exists.
SUPPORTED_ARCHS="arm64"
APP_BIN="/opt/irl-player/IRLPlayer"
KIOSK_USER="irlplayer"
SERVICE_NAME="irl-player-kiosk"
# Every file this installer creates on the device (one per line). Used for
# cleanup: anything listed in the previous install's manifest but no longer
# listed here is disabled and deleted on the next run — so removing a
# service/helper from this script removes it from every device on its next
# auto-update. Keep this list in sync when adding or deleting things below.
MANIFEST=/etc/irl-player/manifest
MANAGED_FILES="
/etc/systemd/system/irl-player-kiosk.service
/etc/systemd/system/irl-player-hotkey.service
/etc/systemd/system/irl-player-update.service
/etc/systemd/system/irl-player-update.timer
/usr/local/bin/irl-kiosk-run
/usr/local/bin/irl-kiosk-toggle
/usr/local/bin/irl-hotkeyd
/usr/local/bin/irl-update
"
# -------------------------------------------------------------

# Bumped on every change to this script — shown at start of every run
INSTALLER_REV=8

log() { printf '\033[1;32m[irl-player]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[irl-player] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

log "Installer revision $INSTALLER_REV (app $VERSION)"

[ "$(id -u)" -eq 0 ] || die "must run as root — use: curl -fsSL $BASE_URL/install.sh | sudo bash"

# --- 1. Device + architecture detection --------------------------------------
command -v dpkg >/dev/null 2>&1 || die "this is not a Debian-based system (dpkg not found)"
ARCH="$(dpkg --print-architecture)"
case " $SUPPORTED_ARCHS " in
  *" $ARCH "*) ;;
  *)
    [ "$ARCH" = "armhf" ] && die "32-bit OS detected. irl-player needs a 64-bit OS — reinstall Raspberry Pi OS 64-bit."
    die "no irl-player build for architecture '$ARCH' (available: $SUPPORTED_ARCHS)"
    ;;
esac

if [ "$ARCH" = "arm64" ]; then
  # arm64 builds target the Raspberry Pi — refuse other boards
  MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
  case "$MODEL" in
    *"Raspberry Pi"*) log "Detected: $MODEL ($ARCH)" ;;
    *) die "this does not look like a Raspberry Pi (model: '${MODEL:-unknown}')" ;;
  esac
else
  log "Detected architecture: $ARCH"
fi

DEB_NAME="irl-player_${VERSION}_${ARCH}.deb"

# --- 2. Install dependencies ------------------------------------------------
log "Installing packages (cage kiosk compositor + deps)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cage xwayland curl ca-certificates python3-evdev
# transparent cursor theme + X-level cursor hiding = invisible mouse pointer
apt-get install -y -qq xcursor-transparent-theme || log "xcursor-transparent-theme unavailable"
apt-get install -y -qq unclutter-xfixes || apt-get install -y -qq unclutter || log "unclutter unavailable; cursor may be visible"

# --- 3. Get and install the .deb --------------------------------------------
# If a local copy sits next to this script (repo checkout), use it;
# otherwise download from the server.
DEB_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/packages/$DEB_NAME" ]; then
  DEB_PATH="$SCRIPT_DIR/packages/$DEB_NAME"
  log "Using local package: $DEB_PATH"
else
  DEB_PATH="$(mktemp -d)/$DEB_NAME"
  log "Downloading $BASE_URL/packages/$DEB_NAME ..."
  curl -fSL --retry 3 -o "$DEB_PATH" "$BASE_URL/packages/$DEB_NAME"
fi

log "Installing irl-player $VERSION ..."
apt-get install -y -qq "$DEB_PATH"
[ -x "$APP_BIN" ] || die "install finished but $APP_BIN is missing"

# --- 4. Kiosk user -----------------------------------------------------------
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  log "Creating user '$KIOSK_USER' ..."
  useradd -m -s /usr/sbin/nologin "$KIOSK_USER"
fi
usermod -aG video,render,input,audio "$KIOSK_USER"

# --- 5. Disable any desktop display manager (would fight over the screen) ---
for dm in lightdm gdm3 sddm greetd; do
  if systemctl is-enabled "$dm" >/dev/null 2>&1; then
    log "Disabling display manager '$dm' (kiosk takes over the screen)"
    systemctl disable --now "$dm" >/dev/null 2>&1 || true
  fi
done

# --- 6. Disable console blanking so the screen never turns off ---------------
CMDLINE=""
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$f" ] && CMDLINE="$f" && break
done
if [ -n "$CMDLINE" ] && ! grep -q 'consoleblank=' "$CMDLINE"; then
  sed -i '1s/$/ consoleblank=0/' "$CMDLINE"
  log "Disabled console blanking in $CMDLINE"
fi

# --- 7. systemd kiosk service -------------------------------------------------
# Invisible mouse cursor: expose the transparent theme as the "default"
# theme through a private XCURSOR_PATH, so every lookup path (compositor,
# GTK, X fallback) resolves to it — but only inside the kiosk service.
CURSOR_DIR="$(find /usr/share/icons -maxdepth 2 -name cursors -path '*transparent*' -print -quit 2>/dev/null || true)"
if [ -n "$CURSOR_DIR" ]; then
  mkdir -p /etc/irl-player/icons/default
  ln -sfn "$CURSOR_DIR" /etc/irl-player/icons/default/cursors
  log "Cursor hidden via transparent theme ($CURSOR_DIR)"
else
  log "WARNING: transparent cursor theme not found; cursor may stay visible"
fi

# Launcher run inside cage: hides the X cursor at the server level
# (XFixes), then starts the player. DISPLAY is set by cage's Xwayland.
cat > /usr/local/bin/irl-kiosk-run <<'EOF'
#!/bin/bash
if command -v unclutter >/dev/null 2>&1; then
  # unclutter-xfixes syntax first, classic unclutter as fallback
  unclutter --timeout 1 --start-hidden --fork 2>/dev/null || unclutter -idle 1 -root &
fi
exec /opt/irl-player/IRLPlayer
EOF
chmod +x /usr/local/bin/irl-kiosk-run

log "Writing /etc/systemd/system/$SERVICE_NAME.service ..."
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=IRL Player fullscreen kiosk
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
Conflicts=getty@tty1.service
Before=graphical.target

[Service]
Type=simple
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
UtmpIdentifier=tty1
UtmpMode=user
# X11 backend (via Xwayland): the Flutter runner drops its GTK title bar
# on X11 with a non-GNOME WM, so the app is a clean borderless fullscreen
Environment=GDK_BACKEND=x11
# invisible cursor: "default" theme resolves to the transparent theme
# through the private XCURSOR_PATH set up by the installer
Environment=XCURSOR_PATH=/etc/irl-player/icons:/usr/share/icons
Environment=XCURSOR_THEME=default
Environment=XCURSOR_SIZE=24
ExecStart=/usr/bin/cage -d -- /usr/local/bin/irl-kiosk-run
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

# --- 8. Ctrl+Alt+P hotkey: toggle kiosk (on top) <-> normal console/desktop --
log "Installing Ctrl+Alt+P layer-toggle hotkey ..."

cat > /usr/local/bin/irl-kiosk-toggle <<'EOF'
#!/usr/bin/env bash
# Toggle IRL Player between kiosk mode (fullscreen, on top — the default)
# and "normal" mode (regular console login / desktop if one is installed).
set -u
SERVICE=irl-player-kiosk

if systemctl is-active --quiet "$SERVICE"; then
  # -> normal layer: hand the screen back to a desktop or the console login
  systemctl stop "$SERVICE"
  for dm in lightdm gdm3 sddm greetd; do
    if [ -e "/lib/systemd/system/$dm.service" ] || [ -e "/etc/systemd/system/$dm.service" ]; then
      exec systemctl start "$dm"
    fi
  done
  exec systemctl start getty@tty1.service
else
  # -> back on top: kiosk takes over the screen again
  for dm in lightdm gdm3 sddm greetd; do
    systemctl stop "$dm" 2>/dev/null || true
  done
  exec systemctl start "$SERVICE"
fi
EOF
chmod +x /usr/local/bin/irl-kiosk-toggle

cat > /usr/local/bin/irl-hotkeyd <<'EOF'
#!/usr/bin/env python3
"""Global hotkey daemon: Ctrl+Alt+P runs irl-kiosk-toggle.

Reads raw input events, so it works no matter what is on screen
(kiosk, console, or desktop) and survives keyboard hot-plugging.
"""
import select
import subprocess
import time

import evdev
from evdev import ecodes

CTRL = {ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL}
ALT = {ecodes.KEY_LEFTALT, ecodes.KEY_RIGHTALT}
COOLDOWN = 2.0


def keyboards():
    devs = {}
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            if ecodes.KEY_P in dev.capabilities().get(ecodes.EV_KEY, []):
                devs[dev.fd] = dev
        except OSError:
            pass
    return devs


def main():
    devs = keyboards()
    pressed = set()
    last_fire = 0.0
    last_rescan = time.monotonic()
    while True:
        readable, _, _ = select.select(list(devs), [], [], 5.0)
        now = time.monotonic()
        if now - last_rescan > 5.0:  # pick up hot-plugged keyboards
            for dev in devs.values():
                try:
                    dev.close()
                except OSError:
                    pass
            devs, pressed, last_rescan = keyboards(), set(), now
            continue
        for fd in readable:
            dev = devs.get(fd)
            if dev is None:
                continue
            try:
                events = list(dev.read())
            except OSError:  # device unplugged
                devs.pop(fd, None)
                continue
            for event in events:
                if event.type != ecodes.EV_KEY:
                    continue
                if event.value == 1:
                    pressed.add(event.code)
                elif event.value == 0:
                    pressed.discard(event.code)
                if (
                    event.value == 1
                    and event.code == ecodes.KEY_P
                    and pressed & CTRL
                    and pressed & ALT
                    and now - last_fire > COOLDOWN
                ):
                    last_fire = now
                    subprocess.Popen(["/usr/local/bin/irl-kiosk-toggle"])


if __name__ == "__main__":
    main()
EOF
chmod +x /usr/local/bin/irl-hotkeyd

cat > /etc/systemd/system/irl-player-hotkey.service <<'EOF'
[Unit]
Description=IRL Player Ctrl+Alt+P layer-toggle hotkey
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/irl-hotkeyd
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# --- 9. Auto-update: reinstall whenever the published install.sh changes ------
# The device fetches $BASE_URL/install.sh on boot and every hour, compares
# its hash to the one recorded at install time, and re-runs the script if it
# changed. Any edit to the script (new app version, config fix, ...) rolls
# out to every device automatically — no version file to maintain.
log "Setting up auto-update (reinstalls when the published install.sh changes) ..."
mkdir -p /etc/irl-player

cat > /usr/local/bin/irl-update <<'EOF'
#!/usr/bin/env bash
# IRL Player auto-update check. Fetches the published install.sh and, if it
# differs from the copy this device was installed with, re-runs it.
#
# Everything lives in main() so bash parses the whole script before running
# it — the reinstall overwrites this very file, which would otherwise corrupt
# the running instance.
set -u

main() {
  BASE_URL="@BASE_URL@"
  STATE=/etc/irl-player/installer.sha256

  # never run two update checks (or a check during an install) at once
  exec 9>/var/lock/irl-update.lock
  flock -n 9 || exit 0

  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  # offline or server unreachable: fine, the timer tries again next hour
  curl -fsSL --retry 3 -o "$TMP" "$BASE_URL/install.sh" || exit 0
  head -1 "$TMP" | grep -q '^#!' || exit 0   # not a script (captive portal etc.)

  NEW="$(sha256sum "$TMP" | awk '{print $1}')"
  OLD="$(cat "$STATE" 2>/dev/null || true)"
  [ "$NEW" = "$OLD" ] && exit 0

  echo "install.sh changed (${OLD:-none} -> $NEW) — reinstalling"
  if bash "$TMP"; then
    echo "$NEW" > "$STATE"
    echo "update applied"
  else
    echo "reinstall failed — will retry next cycle" >&2
    exit 1
  fi
}

main "$@"
EOF
sed -i "s|@BASE_URL@|$BASE_URL|" /usr/local/bin/irl-update
chmod +x /usr/local/bin/irl-update

# Record the hash of this exact installer so the updater only fires on a
# future change. When piped from curl there is no file to hash, so fetch the
# published copy; if that fails, the updater self-heals by reinstalling once
# on its first successful check.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
  sha256sum "$SELF" | awk '{print $1}' > /etc/irl-player/installer.sha256
else
  HASH_TMP="$(mktemp)"
  if curl -fsSL --retry 3 -o "$HASH_TMP" "$BASE_URL/install.sh"; then
    sha256sum "$HASH_TMP" | awk '{print $1}' > /etc/irl-player/installer.sha256
  fi
  rm -f "$HASH_TMP"
fi

cat > /etc/systemd/system/irl-player-update.service <<'EOF'
[Unit]
Description=IRL Player auto-update check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/irl-update
EOF

cat > /etc/systemd/system/irl-player-update.timer <<'EOF'
[Unit]
Description=IRL Player auto-update check (on boot and hourly)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
# spread devices out so they don't all hit the server at the same second
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- 10. Remove leftovers from previous installs ------------------------------
# Anything the previous install created that this version of the script no
# longer ships (see MANAGED_FILES) gets disabled and deleted here, so
# services/helpers deleted from this script disappear from every device.
if [ -f "$MANIFEST" ]; then
  while IFS= read -r OLD_FILE; do
    [ -n "$OLD_FILE" ] || continue
    if printf '%s\n' $MANAGED_FILES | grep -Fxq "$OLD_FILE"; then
      continue  # still managed by this version
    fi
    log "Removing obsolete $OLD_FILE"
    case "$OLD_FILE" in
      /etc/systemd/system/*.service|/etc/systemd/system/*.timer)
        systemctl disable --now "$(basename "$OLD_FILE")" 2>/dev/null || true ;;
    esac
    rm -f "$OLD_FILE"
  done < "$MANIFEST"
fi
printf '%s\n' $MANAGED_FILES | grep . > "$MANIFEST"

systemctl daemon-reload
systemctl set-default graphical.target >/dev/null
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl enable --now irl-player-hotkey >/dev/null
systemctl enable --now irl-player-update.timer >/dev/null

log "Starting kiosk ..."
systemctl restart "$SERVICE_NAME"

log "Done. IRL Player will start fullscreen on every boot."
log "Auto-update: checks $BASE_URL/install.sh hourly and reinstalls on change"
log "Hotkey:  Ctrl+Alt+P toggles kiosk (on top) <-> normal console/desktop"
log "Logs:    journalctl -u $SERVICE_NAME -f"
log "Stop:    sudo systemctl stop $SERVICE_NAME"
log "Remove:  curl -fsSL $BASE_URL/uninstall.sh | sudo bash"
