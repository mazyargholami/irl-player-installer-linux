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
#   7. Installs a freeze watchdog: if the screen stops changing the player
#      is restarted, then the device rebooted; a hardware watchdog reboots
#      the Pi if the whole OS ever locks up
#   8. Enables unattended OS security updates and a network watchdog that
#      repairs a dead connection (restart networking, then reboot)
#   9. Canary rollout: `sudo touch /etc/irl-player/canary` marks a device to
#      take every update immediately; all others follow FLEET_DELAY_HOURS
#      later
#  10. Fleet screen switch: screen.txt on the website ("0" or "1") turns
#      every display off or on within a couple of minutes; the player keeps
#      running underneath
#
set -euo pipefail

# ----------------------- configuration -----------------------
BASE_URL="${IRL_BASE_URL:-https://linux-player.theirlnetwork.com}"
# Refuse protocol downgrades (a redirect to plain http) on every fetch of
# executable content. Only relaxed when the base URL itself is http (tests).
CURL_HTTPS_ONLY=""
case "$BASE_URL" in https://*) CURL_HTTPS_ONLY="--proto =https --tlsv1.2";; esac
VERSION="1.2.6"
# Architectures with a build in packages/ — add e.g. "amd64" here once
# packages/irl-player_<version>_amd64.deb exists.
SUPPORTED_ARCHS="arm64"
APP_BIN="/opt/irl-player/IRLPlayer"
KIOSK_USER="irlplayer"
SERVICE_NAME="irl-player-kiosk"
# Canary rollout: devices WITHOUT /etc/irl-player/canary wait this many hours
# after a new install.sh appears before applying it; a device marked with
# `sudo touch /etc/irl-player/canary` applies immediately. Devices read this
# value from the NEW script, so publishing an urgent fix with 0 here makes
# the whole fleet apply it right away.
FLEET_DELAY_HOURS=24
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
/etc/systemd/system/irl-player-watchdog.service
/etc/systemd/system/irl-player-netwatch.service
/etc/systemd/system.conf.d/irl-watchdog.conf
/etc/apt/apt.conf.d/52irl-unattended-upgrades
/etc/apt/apt.conf.d/60irl-auto-upgrades
/usr/local/bin/irl-kiosk-run
/usr/local/bin/irl-kiosk-toggle
/usr/local/bin/irl-hotkeyd
/usr/local/bin/irl-update
/usr/local/bin/irl-watchdog
/usr/local/bin/irl-netwatch
/etc/systemd/system/irl-gateway.service
/opt/irl-gateway/gateway.py
/opt/irl-gateway/broker-ca.pem
/usr/local/bin/irl-gateway-config
/usr/local/bin/irl-telemetry
/etc/systemd/system/irl-player-telemetry.service
/etc/systemd/system/irl-player-telemetry.timer
/usr/local/bin/irl-screen
/etc/systemd/system/irl-player-screen.service
/etc/systemd/system/irl-player-screen.timer
/etc/systemd/system/irl-player-reboot.service
/etc/systemd/system/irl-player-reboot.timer
"
# -------------------------------------------------------------

# Bumped on every change to this script — shown at start of every run
INSTALLER_REV=25

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
# grim takes the tiny screenshots the freeze watchdog compares
apt-get install -y -qq grim || log "grim unavailable; freeze watchdog will stay idle"

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
  curl -fSL --retry 3 $CURL_HTTPS_ONLY -o "$DEB_PATH" "$BASE_URL/packages/$DEB_NAME"
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

# --- 9. Freeze watchdog: self-heal when the screen stops changing -------------
# systemd already restarts the app if it CRASHES; this catches FREEZES,
# where the process is alive but the picture is stuck. Every 30s it takes a
# tiny screenshot and hashes it — playing video always changes pixels, so a
# screen that is pixel-identical for 5 minutes means the player is frozen.
# Escalation: restart the player (up to 3 times), then reboot the device
# (at most once every 2 hours). If the screen can't be captured, it does
# nothing — it never acts on a guess.
log "Installing freeze watchdog ..."

cat > /usr/local/bin/irl-watchdog <<'EOF'
#!/usr/bin/env bash
# IRL Player freeze watchdog. See install.sh for the design.
set -u
SERVICE=irl-player-kiosk
KIOSK_USER=irlplayer
STATE_DIR=/var/lib/irl-player
INTERVAL=30        # seconds between screen checks
FREEZE_AFTER=300   # unchanged screen for this long = frozen
GRACE=120          # after acting, give the player this long to come back
MAX_RESTARTS=3     # restarts before escalating to a reboot
REBOOT_BACKOFF=7200  # never watchdog-reboot more than once per 2 hours

mkdir -p "$STATE_DIR"

# Hash of the current screen, captured as the kiosk user via grim.
# Fails (returns 1) rather than guessing when the screen can't be read.
capture() {
  local uid xdg sock tmp
  command -v grim >/dev/null 2>&1 || return 1
  uid="$(id -u "$KIOSK_USER" 2>/dev/null)" || return 1
  xdg="/run/user/$uid"
  sock="$(find "$xdg" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -1)"
  [ -n "$sock" ] || return 1
  tmp="$(mktemp)"
  if XDG_RUNTIME_DIR="$xdg" WAYLAND_DISPLAY="${sock##*/}" \
       setpriv --reuid "$KIOSK_USER" --regid "$KIOSK_USER" --init-groups grim -t ppm -s 0.125 - > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    sha256sum "$tmp" | awk '{print $1}'
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

last_hash=""
static_for=0
healthy_for=0
restarts=0
grace_until=0

while true; do
  sleep "$INTERVAL"
  now="$(date +%s)"

  # kiosk intentionally off (Ctrl+Alt+P, manual stop): not our business
  if ! systemctl is-active --quiet "$SERVICE"; then
    last_hash=""; static_for=0; healthy_for=0; restarts=0
    continue
  fi
  [ "$now" -lt "$grace_until" ] && continue

  h="$(capture)" || continue

  if [ "$h" != "$last_hash" ]; then
    last_hash="$h"; static_for=0
    # only a sustained healthy screen clears the escalation counter —
    # a brief flicker right after a restart must not reset it
    healthy_for=$((healthy_for + INTERVAL))
    [ "$healthy_for" -ge "$FREEZE_AFTER" ] && restarts=0
    continue
  fi

  healthy_for=0
  static_for=$((static_for + INTERVAL))
  [ "$static_for" -lt "$FREEZE_AFTER" ] && continue

  if [ "$restarts" -lt "$MAX_RESTARTS" ]; then
    restarts=$((restarts + 1))
    echo "screen unchanged for ${static_for}s — restarting $SERVICE (attempt $restarts/$MAX_RESTARTS)"
    systemctl restart "$SERVICE"
  else
    last_reboot="$(cat "$STATE_DIR/last-watchdog-reboot" 2>/dev/null || echo 0)"
    if [ $((now - last_reboot)) -ge "$REBOOT_BACKOFF" ]; then
      echo "still frozen after $MAX_RESTARTS restarts — rebooting device"
      echo "$now" > "$STATE_DIR/last-watchdog-reboot"
      sync
      reboot
    else
      echo "still frozen but rebooted recently — retrying a service restart"
      systemctl restart "$SERVICE"
    fi
  fi
  static_for=0
  grace_until=$((now + GRACE))
done
EOF
chmod +x /usr/local/bin/irl-watchdog

cat > /etc/systemd/system/irl-player-watchdog.service <<'EOF'
[Unit]
Description=IRL Player freeze watchdog (restarts the player if the screen stops changing)
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/irl-watchdog
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Hardware watchdog: the Pi's watchdog chip force-reboots the device if the
# whole OS freezes (the case no software watchdog can catch). systemd pets
# the chip; if systemd itself stops responding for 15s, the chip fires.
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/irl-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=2min
EOF
systemctl daemon-reexec 2>/dev/null || true

# --- 10. Unattended OS security updates ---------------------------------------
# The player updates itself via irl-update; this keeps the OS underneath
# patched too. Runs via Debian's standard apt-daily timers (early morning,
# randomized). No automatic reboots — kernel updates apply whenever the
# device next reboots anyway. irl-player itself is blacklisted so app
# versions stay controlled exclusively by this script.
log "Enabling unattended OS security updates ..."
apt-get install -y -qq unattended-upgrades || log "unattended-upgrades unavailable"
mkdir -p /etc/apt/apt.conf.d

cat > /etc/apt/apt.conf.d/52irl-unattended-upgrades <<'EOF'
// Installed by the irl-player installer — OS security updates only.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Raspbian,codename=${distro_codename}";
        "origin=Raspberry Pi Foundation,codename=${distro_codename}";
};
// the player app is managed exclusively by irl-update, never by apt upgrades
Unattended-Upgrade::Package-Blacklist { "irl-player"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/60irl-auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# --- 11. Network watchdog: self-heal a dead connection ------------------------
# The freeze watchdog covers a stuck PICTURE; this covers a stuck CONNECTION
# (router rebooted, Wi-Fi dropped and never rejoined). 10 minutes with no
# internet -> restart networking; 30 minutes -> reboot the device (only when
# the kiosk is running, at most once every 2 hours).
log "Installing network watchdog ..."

cat > /usr/local/bin/irl-netwatch <<'EOF'
#!/usr/bin/env bash
# IRL Player network watchdog. See install.sh for the design.
set -u
SERVICE=irl-player-kiosk
STATE_DIR=/var/lib/irl-player
INTERVAL=60             # seconds between connectivity checks
RESTART_NET_AFTER=600   # offline this long -> restart networking
REBOOT_AFTER=1800       # offline this long -> reboot (kiosk running only)
REBOOT_BACKOFF=7200     # never netwatch-reboot more than once per 2 hours

online() {
  ping -c1 -W5 1.1.1.1 >/dev/null 2>&1 && return 0
  ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 && return 0
  curl -fsm 10 -o /dev/null https://linux-player.theirlnetwork.com/ 2>/dev/null
}

restart_networking() {
  if systemctl is-active --quiet NetworkManager; then
    systemctl restart NetworkManager
  elif systemctl is-active --quiet dhcpcd; then
    systemctl restart dhcpcd
  else
    local i d
    for i in /sys/class/net/wl*; do
      [ -e "$i" ] || continue
      d="${i##*/}"
      ip link set "$d" down 2>/dev/null
      ip link set "$d" up 2>/dev/null
    done
  fi
}

offline_for=0
net_restarted=0

while true; do
  sleep "$INTERVAL"
  if online; then
    offline_for=0
    net_restarted=0
    continue
  fi
  offline_for=$((offline_for + INTERVAL))
  if [ "$net_restarted" -eq 0 ] && [ "$offline_for" -ge "$RESTART_NET_AFTER" ]; then
    echo "offline for ${offline_for}s — restarting networking"
    restart_networking
    net_restarted=1
  elif [ "$offline_for" -ge "$REBOOT_AFTER" ]; then
    # a reboot only helps a wedged device; skip when kiosk intentionally off
    systemctl is-active --quiet "$SERVICE" || continue
    now="$(date +%s)"
    last="$(cat "$STATE_DIR/last-netwatch-reboot" 2>/dev/null || echo 0)"
    if [ $((now - last)) -ge "$REBOOT_BACKOFF" ]; then
      echo "still offline after networking restart — rebooting device"
      mkdir -p "$STATE_DIR"
      echo "$now" > "$STATE_DIR/last-netwatch-reboot"
      sync
      reboot
    fi
  fi
done
EOF
chmod +x /usr/local/bin/irl-netwatch

cat > /etc/systemd/system/irl-player-netwatch.service <<'EOF'
[Unit]
Description=IRL Player network watchdog (repairs a dead connection)
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/irl-netwatch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- 12. IRL Gateway: USB master board -> MQTT bridge (opt-in per device) -----
# The gateway code ships to every device, but it only bridges where
# /opt/irl-gateway/mqtt.json exists — that file holds the MQTT broker
# credentials, fetched from the config panel by irl-gateway-config (below).
# Neither mqtt.json nor config-ca.pem (the broker CA the gateway materializes
# from the config's optional "tls_ca_pem" field) is ever written by this
# public script or touched by reinstalls — secrets stay off the website and
# both files survive every auto-update.
# Source of truth for the code: irl-microcontroller repo, gateway/gateway.py.
log "Installing IRL gateway (fetches its config from the fleet config service; unapproved devices request access automatically) ..."
mkdir -p /opt/irl-gateway

cat > /opt/irl-gateway/gateway.py <<'GATEWAY_PY_EOF'
#!/usr/bin/env python3
"""
IRL Gateway - PC-side live monitor for a IRL master over USB serial.

Runs on the computer (normal Python 3, not MicroPython). It finds the
master board automatically among the connected USB-serial devices and
speaks the master's machine-readable serial protocol: one JSON object
per line (see master/main.py). The gateway is the human-readable end -
it renders a live dashboard of every worker (unique id, LED state,
chip temperature, last heard) plus a rolling event log, and is the
natural place to forward fleet state to a server later.

Every device has a unique id: its full MAC as 12 hex chars - 2^48
possible ids, so any fleet size is fine with zero registration.

Whatever you type is forwarded to the master:

    list | on | off | on <n> | on <id> | off <n|id>     (q quits)

Runs on macOS, Linux (incl. Raspberry Pi), and Windows.

Usage:
    python3 gateway/gateway.py            # auto-detect the master
    python3 gateway/gateway.py /dev/cu.usbserial-1120   # use this port
    python gateway/gateway.py COM5        # Windows, explicit port
    python3 gateway/gateway.py --touch    # event log shows only worker
                                          # touch events (combinable with
                                          # an explicit port)

Piped/redirected (no TTY) it degrades to a plain timestamped line log:
    python3 gateway/gateway.py > fleet.log

MQTT bridge (optional): if gateway/mqtt.json exists (copy
mqtt.example.json and fill in the broker credentials - the real file
is gitignored), the gateway also bridges the fleet to an MQTT broker
over TLS. Topics, all under <base_topic>/<master_id>/:
    fleet             retained inventory snapshot: master id + its own
                      chip temp + every worker's state
    events            every master event, as-is plus a "ts" field
    workers/<id>      retained per-worker state:
                      {"id","name","led","temp","online","ts"}
    status            retained "online" / "master-offline" / "offline"
                      ("offline" is the broker's last-will if the
                      gateway dies)
    cmd  (subscribed) publish "on", "off", "on <id>", "off <id>",
                      "list" here and the gateway forwards it to the
                      master - this is how a server switches LEDs
The broker's self-signed CA chain is pinned via gateway/broker-ca.pem
(refresh it with: python3 gateway/gateway.py --fetch-ca).

Requires:  pip install -r gateway/requirements.txt
Note:      close Thonny / mpremote first - only one program can hold
           the serial port. Opening the port may briefly reset the
           board (USB auto-reset wiring); the master rediscovers the
           whole fleet by itself within a second or two.
"""

import json
import os
import re
import select
import sys
import time
from collections import deque

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("pyserial is missing - install it with:\n"
             "  pip install -r gateway/requirements.txt")

try:
    import paho.mqtt.client as paho
except ImportError:
    paho = None  # fine unless gateway/mqtt.json asks for MQTT

GATEWAY_DIR = os.path.dirname(os.path.abspath(__file__))
MQTT_CONFIG = os.path.join(GATEWAY_DIR, "mqtt.json")


def get_device_serial():
    """Hardware serial of the machine the gateway runs on (the "Serial"
    line of /proc/cpuinfo on a Raspberry Pi) - the same value the IRL
    kiosk devices report to the config panel, so the panel can join a
    fleet's MQTT data to its device row. Empty string on non-Pi hosts."""
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("Serial"):
                    return line.split(":", 1)[1].strip().lower()
    except OSError:
        pass
    return ""


DEVICE_SERIAL = get_device_serial()


# ---- cross-platform keyboard (dashboard input) ----------------------
if os.name == "nt":
    import msvcrt

    def keyboard_init():
        os.system("")  # switches the Windows console to ANSI colors
        return None

    def keyboard_restore(state):
        pass

    def read_keys():
        keys = []
        while msvcrt.kbhit():
            ch = msvcrt.getwch()
            keys.append("\n" if ch == "\r" else ch)
        return keys
else:
    import termios
    import tty

    def keyboard_init():
        state = termios.tcgetattr(sys.stdin.fileno())
        tty.setcbreak(sys.stdin.fileno())
        return state

    def keyboard_restore(state):
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, state)

    def read_keys():
        keys = []
        while select.select([sys.stdin], [], [], 0)[0]:
            data = os.read(sys.stdin.fileno(), 64)
            if not data:
                break  # EOF (piped input ended)
            keys.extend(data.decode("utf-8", "ignore"))
        return keys

BAUD = 115200
LIST_INTERVAL_S = 10.0     # slow "list" refresh heals any dropped bytes
REDRAW_INTERVAL_S = 0.5
PROBE_TIMEOUT_S = 2.5
EVENT_LOG_LEN = 10

# USB-serial bridge chips common on ESP32 dev boards
KNOWN_VIDS = {0x10C4, 0x1A86, 0x0403, 0x303A, 0x067B}

# The master answers "list" with JSON event lines; workers do not
MASTER_MARKERS = (b'"ev"',)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

CSI = "\x1b["
RESET, BOLD, DIM = CSI + "0m", CSI + "1m", CSI + "2m"
GREEN, YELLOW, CYAN, RED = CSI + "32m", CSI + "33m", CSI + "36m", CSI + "31m"


def open_port(dev):
    """Open without touching DTR/RTS so the board is not auto-reset."""
    ser = serial.Serial()
    ser.port = dev
    ser.baudrate = BAUD
    ser.timeout = 0
    ser.dtr = False
    ser.rts = False
    ser.open()
    ser.reset_input_buffer()
    return ser


def candidate_ports():
    """USB-serial devices, most-likely-ESP32 first."""
    found = []
    for p in list_ports.comports():
        dev = p.device
        if sys.platform == "darwin":
            if "Bluetooth" in dev or "debug" in dev:
                continue
            dev = dev.replace("/dev/tty.", "/dev/cu.")
        score = 0
        if p.vid in KNOWN_VIDS:
            score += 2
        if "usbserial" in dev.lower() or "USB" in (p.description or ""):
            score += 1
        if score:
            found.append((score, dev))
    return [dev for _, dev in sorted(found, key=lambda x: -x[0])]


def probe(dev):
    """True if the device answers 'list' like a IRL master."""
    try:
        ser = open_port(dev)
    except (serial.SerialException, OSError):
        return False
    try:
        ser.write(b"\r\nlist\r\n")
        buf = b""
        deadline = time.monotonic() + PROBE_TIMEOUT_S
        while time.monotonic() < deadline:
            chunk = ser.read(256)
            if chunk:
                buf += chunk
                if any(m in buf for m in MASTER_MARKERS):
                    return True
            else:
                time.sleep(0.05)
        return False
    except (serial.SerialException, OSError):
        return False
    finally:
        ser.close()


def materialize_inline_ca(cfg):
    """Write the config's inline CA to a local file paho can load.

    "tls_ca_pem" is injected into the served config by the IRL Config
    Panel when the operator uploads a CA for that broker - it rides in
    over the panel's HTTPS fetch, so a fleet slice moved to an external
    broker gets verified TLS with no file shipped out-of-band. It beats
    the "tls_ca" file when present. Returns the path, or None when the
    config carries no inline CA (or the file can't be written - the
    normal tls_ca path then applies unchanged).
    """
    pem = cfg.get("tls_ca_pem")
    if not isinstance(pem, str) or not pem.strip():
        return None
    path = os.path.join(GATEWAY_DIR, "config-ca.pem")
    content = pem.strip() + "\n"
    try:
        if os.path.exists(path):
            with open(path) as f:
                if f.read() == content:
                    return path
        with open(path, "w") as f:
            f.write(content)
    except OSError:
        return None
    return path


def fetch_broker_ca(cfg):
    """Save the broker's certificate chain as the pinned CA bundle."""
    import socket
    import ssl
    ctx = ssl._create_unverified_context()
    with socket.create_connection((cfg["host"], cfg["port"]),
                                  timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=cfg["host"]) as s:
            chain = s.get_unverified_chain()  # needs Python 3.13+
    path = os.path.join(GATEWAY_DIR, cfg.get("tls_ca", "broker-ca.pem"))
    with open(path, "w") as f:
        f.write("".join(ssl.DER_cert_to_PEM_cert(der) for der in chain))
    return path


class MqttLink:
    """Background MQTT bridge; safe to keep across serial reconnects."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.client = None
        self.master_id = None
        self.topic = None
        self.state = "waiting for master id"
        self.commands = deque()    # filled by the broker thread

    def start(self, master_id):
        """Connect (or reconnect under a new master id)."""
        if self.client is not None:
            if master_id == self.master_id:
                return
            self.stop()
        self.master_id = master_id
        self.topic = "%s/%s" % (self.cfg.get("base_topic", "irl"),
                                master_id)
        c = paho.Client(paho.CallbackAPIVersion.VERSION2,
                        client_id="irl-gw-" + master_id)
        c.username_pw_set(self.cfg["username"], self.cfg["password"])
        if self.cfg.get("tls", True):
            ca = materialize_inline_ca(self.cfg)  # panel-delivered CA wins
            if not ca:
                ca = self.cfg.get("tls_ca")
                if ca and not os.path.isabs(ca):
                    ca = os.path.join(GATEWAY_DIR, ca)
            c.tls_set(ca_certs=ca if ca and os.path.exists(ca) else None)
            if self.cfg.get("tls_insecure"):
                c.tls_insecure_set(True)
        c.will_set(self.topic + "/status", "offline", retain=True)
        c.on_connect = self._on_connect
        c.on_disconnect = self._on_disconnect
        c.on_message = self._on_message
        c.reconnect_delay_set(1, 30)
        self.state = "connecting"
        c.connect_async(self.cfg["host"], self.cfg.get("port", 8883),
                        keepalive=30)
        c.loop_start()  # paho's own thread; auto-reconnects
        self.client = c

    def _on_connect(self, c, u, flags, rc, props=None):
        if rc == 0:
            self.state = "connected"
            # QoS 2 = exactly once: LED commands are never lost or
            # duplicated on the MQTT leg (publishers must use QoS 2
            # as well - effective QoS is the lower of the two sides)
            c.subscribe(self.topic + "/cmd", qos=2)
            self.publish_status("online")
        else:
            self.state = "refused: %s" % rc

    def _on_disconnect(self, c, u, flags, rc, props=None):
        self.state = "reconnecting"

    def _on_message(self, c, u, msg):
        cmd = msg.payload.decode("utf-8", "replace").strip()[:64]
        if cmd:
            self.commands.append(cmd.splitlines()[0])

    def _pub(self, subtopic, payload, retain=False):
        if self.client is not None:
            self.client.publish(self.topic + "/" + subtopic, payload,
                                retain=retain)

    def publish_event(self, e):
        e = dict(e, ts=int(time.time()))
        self._pub("events", json.dumps(e))

    def publish_worker(self, w, online):
        self._pub("workers/" + w["id"],
                  json.dumps({"id": w["id"], "name": w["name"],
                              "led": 1 if w["led"] else 0,
                              "temp": w["temp"], "online": online,
                              "device_serial": DEVICE_SERIAL,
                              "ts": int(time.time())}),
                  retain=True)

    def publish_fleet(self, workers, master_temp=None, channel=None):
        """Retained inventory snapshot - one message tells a server
        everything this master currently has. temp is the master's
        own chip temperature (None until the first eol carries it).
        device_serial identifies the HOST machine (Pi) this gateway
        runs on, "" elsewhere; ch is the master's radio channel (from
        its ready event) - additive fields, protocol-compatible."""
        now = time.monotonic()
        self._pub("fleet",
                  json.dumps({"master": self.master_id,
                              "temp": master_temp, "n": len(workers),
                              "ch": channel,
                              "device_serial": DEVICE_SERIAL,
                              "workers": [
                                  {"id": w["id"], "name": w["name"],
                                   "led": 1 if w["led"] else 0,
                                   "temp": w["temp"],
                                   "ago": int(now - w["seen_at"])}
                                  for w in workers],
                              "ts": int(time.time())}),
                  retain=True)

    def publish_status(self, status):
        self._pub("status", status, retain=True)

    def stop(self):
        if self.client is not None:
            self.publish_status("offline")
            self.client.loop_stop()
            self.client.disconnect()
            self.client = None


def find_master(explicit=None):
    """Block until a master is found; returns an open Serial."""
    announced = False
    while True:
        ports = [explicit] if explicit else candidate_ports()
        for dev in ports:
            if explicit or probe(dev):
                try:
                    ser = open_port(dev)
                    ser.write(b"\r\n")  # flush any half-typed line
                    return ser
                except (serial.SerialException, OSError):
                    pass
        if not announced:
            what = explicit or "a IRL master board"
            print("Waiting for %s (checking every 2 s, Ctrl-C quits)..."
                  % what)
            announced = True
        time.sleep(2)


class Gateway:
    def __init__(self, ser, mqtt=None, touch_only=False):
        self.ser = ser
        self.mqtt = mqtt
        self.touch_only = touch_only
        self.master_id = "?"
        self.master_temp = None    # master's own chip temp, from ready/eol
        self.channel = None        # radio channel, from the ready event
        self.workers = {}          # id -> dict(id name index led temp seen_at)
        self.events = deque(maxlen=EVENT_LOG_LEN)
        self.rx = b""
        self.input_line = ""
        self.connected_at = time.monotonic()
        self.last_list = 0.0
        self.dirty = True

    def event(self, text, color="", kind="info"):
        # kind: "info" (fleet chatter), "touch", or "alert" (lifecycle,
        # errors, command feedback). --touch hides plain "info" lines.
        if self.touch_only and kind == "info":
            return
        stamp = time.strftime("%H:%M:%S")
        self.events.append("%s%s  %s%s" % (color, stamp, text, RESET))
        self.dirty = True

    def whois(self, wid):
        w = self.workers.get(wid)
        return w["name"] if w else wid

    # ---- master JSON protocol ---------------------------------------
    def touch_worker(self, wid, **fields):
        w = self.workers.setdefault(
            wid, {"id": wid, "name": wid, "index": 0, "led": False,
                  "temp": 0})
        w["seen_at"] = time.monotonic()
        w.update(fields)
        self.dirty = True

    def set_master_id(self, mid):
        self.master_id = mid
        if self.mqtt is not None:
            self.mqtt.start(mid)

    def handle_event(self, e):
        ev = e.get("ev")
        if ev == "ready":
            self.workers.clear()
            self.set_master_id(e.get("id", "?"))
            self.master_temp = e.get("temp", self.master_temp)
            self.channel = e.get("ch", self.channel)
            self.event("master %s ready on channel %s"
                       % (self.master_id, e.get("ch")), CYAN, kind="alert")
            self.last_list = 0  # refresh the table right away
        elif ev in ("row", "join"):
            self.touch_worker(e["id"], name=e.get("name", e["id"]),
                              led=e["led"] == 1, temp=e["temp"])
            if ev == "row":
                self.workers[e["id"]]["index"] = e["i"]
                self.workers[e["id"]]["seen_at"] = (
                    time.monotonic() - e.get("ago", 0))
            else:
                self.event("joined %s (%s) - %s known"
                           % (e.get("name"), e["id"], e.get("n")), GREEN)
        elif ev == "state":
            state = e["led"] == 1
            known = self.workers.get(e["id"])
            if known and known["led"] != state:
                self.event("[%s] LED %s" % (self.whois(e["id"]),
                                            "ON" if state else "OFF"),
                           GREEN if state else DIM)
            self.touch_worker(e["id"], led=state, temp=e["temp"])
        elif ev == "lost":
            self.workers.pop(e["id"], None)
            self.event("lost %s (%s)" % (e.get("name"), e["id"]), RED)
        elif ev == "touch":
            if e["val"] == 1:
                self.event("[%s] touch started" % self.whois(e["id"]),
                           YELLOW, kind="touch")
            else:
                self.event("[%s] touch released after %.1f s"
                           % (self.whois(e["id"]), e.get("ms", 0) / 1000),
                           YELLOW, kind="touch")
        elif ev == "sent":
            led = "ON" if e["led"] == 1 else "OFF"
            if e.get("to") == "all":
                self.event("master sent LED %s to all (%s known)"
                           % (led, e.get("n")))
            else:
                self.event("master sent LED %s to %s" % (led, e.get("to")))
        elif ev == "ack":
            self.event("[%s] LED %s confirmed (%s tr%s)"
                       % (self.whois(e["id"]),
                          "ON" if e["led"] == 1 else "OFF", e["tries"],
                          "y" if e["tries"] == 1 else "ies"), GREEN)
        elif ev == "cmd_timeout":
            self.event("[%s] NO confirmation for LED %s - worker "
                       "unreachable?" % (self.whois(e["id"]),
                                         "ON" if e["led"] == 1 else "OFF"),
                       RED)
        elif ev in ("err", "notice"):
            self.event("%s: %s" % (ev, e.get("msg")),
                       RED if ev == "err" else YELLOW, kind="alert")
        elif ev == "eol":
            # carries the master's id and own chip temp, so we learn
            # both without a reboot and keep the temp fresh
            if self.master_id == "?" and e.get("id"):
                self.set_master_id(e["id"])
            if e.get("temp") is not None and e["temp"] != self.master_temp:
                self.master_temp = e["temp"]
                self.dirty = True
        else:
            self.event("unknown event: %r" % (e,), DIM)

        if self.mqtt is not None and self.mqtt.client is not None:
            self.mqtt.publish_event(e)
            if ev in ("row", "join", "state") and e.get("id") in self.workers:
                self.mqtt.publish_worker(self.workers[e["id"]], True)
            elif ev == "lost":
                self.mqtt.publish_worker(
                    {"id": e["id"], "name": e.get("name", e["id"]),
                     "led": False, "temp": 0}, False)
            if ev in ("ready", "join", "lost", "eol"):
                self.mqtt.publish_fleet(
                    sorted(self.workers.values(),
                           key=lambda w: (w["index"] or 9999, w["id"])),
                    self.master_temp, self.channel)

    def handle_line(self, line):
        if line.startswith("{"):
            try:
                self.handle_event(json.loads(line))
                return
            except (ValueError, KeyError):
                pass
        self.event(line, DIM)  # ROM boot chatter, tracebacks, ...

    def feed(self, data):
        self.rx += data
        while b"\n" in self.rx:
            raw, self.rx = self.rx.split(b"\n", 1)
            line = raw.decode("utf-8", "replace").strip("\r ")
            if line:
                self.handle_line(line)

    # ---- keyboard ---------------------------------------------------
    def handle_key(self, ch):
        if ch in ("\r", "\n"):
            cmd = self.input_line.strip()
            self.input_line = ""
            self.dirty = True
            if cmd in ("q", "quit", "exit"):
                raise KeyboardInterrupt
            if cmd:
                self.ser.write(cmd.encode() + b"\r\n")
                self.event("sent: " + cmd, CYAN, kind="alert")
        elif ch in ("\x7f", "\x08"):
            self.input_line = self.input_line[:-1]
            self.dirty = True
        elif ch.isprintable():
            self.input_line += ch
            self.dirty = True

    # ---- dashboard --------------------------------------------------
    def render(self):
        now = time.monotonic()
        up = int(now - self.connected_at)
        out = [CSI + "2J" + CSI + "H"]
        mq = "off" if self.mqtt is None else self.mqtt.state
        mode = "  %stouch-only%s" % (YELLOW, RESET) if self.touch_only else ""
        mtemp = ("" if self.master_temp is None
                 else " %d C" % self.master_temp)
        out.append(
            "%sIRL Gateway%s  master %s%s  %s  MQTT: %s  up %d:%02d:%02d%s\n"
            % (BOLD, RESET, self.master_id, mtemp, self.ser.port, mq,
               up // 3600, up % 3600 // 60, up % 60, mode))
        out.append(DIM + "-" * 72 + RESET + "\n")
        out.append("%s %-3s %-13s %-19s %-4s %-6s %s%s\n" % (
            BOLD, "#", "ID", "NAME", "LED", "TEMP", "SEEN", RESET))
        rows = sorted(self.workers.values(),
                      key=lambda w: (w["index"] or 9999, w["id"]))
        if not rows:
            out.append(DIM + "  (no workers heard from yet)" + RESET + "\n")
        for w in rows:
            ago = int(now - w["seen_at"])
            led = (GREEN + "ON " if w["led"] else DIM + "OFF") + RESET
            stale = RED if ago > 16 else ""
            out.append(" %-3s %-13s %-19s %s  %3d C  %s%d s ago%s\n" % (
                w["index"] or "?", w["id"], w["name"][:19], led,
                w["temp"], stale, ago, RESET))
        out.append(DIM + "-" * 72 + RESET + "\n")
        for e in self.events:
            out.append(" %s\n" % e)
        out.append("\n%scommand (list | on | off | on <n|id> | q):%s > %s" % (
            DIM, RESET, self.input_line))
        sys.stdout.write("".join(out))
        sys.stdout.flush()
        self.dirty = False

    # ---- main loop --------------------------------------------------
    def run(self, interactive):
        """Portable poll loop - no select() on the serial port, so it
        runs on Windows (COM ports) as well as macOS/Linux."""
        self.event("connected to %s" % self.ser.port, GREEN, kind="alert")
        last_draw = 0.0
        while True:
            data = self.ser.read(4096)
            if data:
                self.feed(data)
            if interactive:
                for ch in read_keys():
                    self.handle_key(ch)
            while self.mqtt is not None and self.mqtt.commands:
                cmd = self.mqtt.commands.popleft()
                self.ser.write(cmd.encode() + b"\r\n")
                self.event("mqtt cmd: " + cmd, CYAN, kind="alert")
            now = time.monotonic()
            if now - self.last_list > LIST_INTERVAL_S:
                self.last_list = now
                self.ser.write(b"list\r\n")
            if interactive:
                if self.dirty or now - last_draw > REDRAW_INTERVAL_S:
                    last_draw = now
                    self.render()
            else:
                while self.events:
                    print(ANSI_RE.sub("", self.events.popleft()),
                          flush=True)
            time.sleep(0.03)


def load_mqtt():
    """MqttLink from gateway/mqtt.json, or None when not configured."""
    if not os.path.exists(MQTT_CONFIG):
        return None
    with open(MQTT_CONFIG) as f:
        cfg = json.load(f)
    if paho is None:
        sys.exit("gateway/mqtt.json exists but paho-mqtt is missing -\n"
                 "  pip install -r gateway/requirements.txt")
    return MqttLink(cfg)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--fetch-ca":
        with open(MQTT_CONFIG) as f:
            path = fetch_broker_ca(json.load(f))
        print("Pinned broker CA chain saved to", path)
        return
    touch_only = "--touch" in args
    args = [a for a in args if a != "--touch"]
    explicit = args[0] if args else None
    interactive = sys.stdin.isatty() and sys.stdout.isatty()
    mqtt = load_mqtt()

    kb_state = None
    if interactive:
        kb_state = keyboard_init()

    try:
        while True:
            ser = find_master(explicit)
            gw = Gateway(ser, mqtt, touch_only)
            if mqtt is not None and mqtt.client is not None:
                mqtt.publish_status("online")
            try:
                gw.run(interactive)
            except (serial.SerialException, OSError):
                ser.close()
                if mqtt is not None:
                    mqtt.publish_status("master-offline")
                print("\nSerial connection lost - looking for the master "
                      "again...")
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if mqtt is not None:
            mqtt.stop()
        if interactive:
            keyboard_restore(kb_state)
        print("\nGateway stopped.")


if __name__ == "__main__":
    main()
GATEWAY_PY_EOF

cat > /opt/irl-gateway/broker-ca.pem <<'GATEWAY_CA_EOF'
-----BEGIN CERTIFICATE-----
MIIDRjCCAi6gAwIBAgIUT43iBu8opvCtIY/+AF+oaXs7DNowDQYJKoZIhvcNAQEL
BQAwITEfMB0GA1UEAwwWbXF0dC50aGVpcmxuZXR3b3JrLmNvbTAeFw0yNjA4MTcw
ODEwMTlaFw0zNjA4MTQwODEwMTlaMCExHzAdBgNVBAMMFm1xdHQudGhlaXJsbmV0
d29yay5jb20wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDPmQCJlUwT
KFo/18aslJS1buKFX97DdYMrkEV6Aog/zjiVW6gN1qRMShcsFt81ojNlgicaluOr
sFhdlnWF9Ks8PQ0DIoypN0ti4gHl9XPcS2HPsaKG/x5mXeSeV6JOD6CtiFcoGNxs
FcoYcYUgx+jPM9Zy61P/3rCbgPv2E7eKyUcO0xWC9RN9qEb3PJs/kGsRBxCePOOp
fqSYxz6NEQ2ZTLoSpha/6NxAog3+DFNLKDM90OtGkOfztVLrADT5B8HUpv9Yf5Kb
HlYlDuQY4IQ9vl0Ubij9OgKnAf1/f+bja9oNUD7d8YsPt/m6D5tOgnYldqecnINt
qtMqIKcberBJAgMBAAGjdjB0MB0GA1UdDgQWBBTaPvHdOKUDnS8Qdw8rBqUChv2j
bDAfBgNVHSMEGDAWgBTaPvHdOKUDnS8Qdw8rBqUChv2jbDAPBgNVHRMBAf8EBTAD
AQH/MCEGA1UdEQQaMBiCFm1xdHQudGhlaXJsbmV0d29yay5jb20wDQYJKoZIhvcN
AQELBQADggEBAEVYGrxXhMRk0WdVSCXzEHraNu49w+Kj6BNA2b99XHtT5mt22iXn
EVuD1qhT5Y9I82wZerzZyjU7Ma0GvFna9NAujnnsxi1gpxBqcMA6WY+RgO+JEuun
ZAbby9pGsKiWYeV+uPdIQAqsRCfdap5b+QyDfWFXo2kW7LUxA/6zcQdoZWXSHo+t
pZurE873Sm6F56mS/3VANFgcrKGAyspuht9ISr6pFv5sTV3G3euvwDzUQ7DuaXwn
N/K2aZPxO1VRxEWmKUpb5nR/aBLQUBbdJ/U9hWEL24nUjx59T+/lcSM7myyEemHt
DTt1ziw6WWKuaJMzrNYH2cbpdcxvF4g3m5M=
-----END CERTIFICATE-----
GATEWAY_CA_EOF

# The MQTT config is fetched over HTTPS from the fleet config panel (the
# self-hosted service at iot-config.theirlnetwork.com, source in the
# irl-microcontroller repo, config-panel/) at every gateway start,
# identified by the device's hardware serial. No credentials live in this
# script. The device keeps the last good copy, so a network blip or
# config-service outage never stops a previously-configured gateway.
# Unknown devices auto-register as "pending" in the panel; approve them
# there. Rotation = edit the config in the panel (devices refresh within a
# day via RuntimeMaxSec, or instantly on systemctl restart irl-gateway).
cat > /usr/local/bin/irl-gateway-config <<'GWCONF_EOF'
#!/usr/bin/env bash
# Fetches the fleet MQTT config for the IRL gateway from the config service.
set -u
OUT=/opt/irl-gateway/mqtt.json
URL="https://iot-config.theirlnetwork.com/mqtt-config"
SERIAL="$(awk '/^Serial/{print $3}' /proc/cpuinfo 2>/dev/null || true)"
HTTPS_ONLY=""
case "$URL" in https://*) HTTPS_ONLY="--proto =https --tlsv1.2";; esac
umask 077
if curl -fsS --max-time 20 $HTTPS_ONLY "${URL}?serial=${SERIAL}" -o "$OUT.tmp" 2>/dev/null \
   && grep -q '"host"' "$OUT.tmp"; then
  mv "$OUT.tmp" "$OUT"
  exit 0
fi
rm -f "$OUT.tmp"
if [ -s "$OUT" ]; then
  echo "config fetch failed — using the cached config" >&2
  exit 0
fi
# no config and no cache (offline, or this serial is not approved yet):
# pause so the systemd restart loop stays gentle on the config service
echo "config fetch failed and no cached config — retrying shortly" >&2
sleep 55
exit 1
GWCONF_EOF
chmod +x /usr/local/bin/irl-gateway-config

# deps live in a venv: paho-mqtt >= 2.0 is newer than the apt package
if [ ! -x /opt/irl-gateway/venv/bin/python3 ]; then
  apt-get install -y -qq python3-venv >/dev/null 2>&1 || true
  python3 -m venv /opt/irl-gateway/venv 2>/dev/null \
    || log "WARNING: could not create the gateway venv; irl-gateway will not start"
fi
if [ -x /opt/irl-gateway/venv/bin/pip ]; then
  /opt/irl-gateway/venv/bin/pip install --quiet "pyserial>=3.5" "paho-mqtt>=2.0" \
    || log "WARNING: gateway dependency install failed; irl-gateway may not start"
fi

cat > /etc/systemd/system/irl-gateway.service <<'EOF'
[Unit]
Description=IRL Gateway (USB master board -> MQTT bridge)
After=network-online.target
Wants=network-online.target
[Service]
# fetch the fleet-published config on every start
ExecStartPre=/usr/local/bin/irl-gateway-config
ExecStart=/opt/irl-gateway/venv/bin/python3 /opt/irl-gateway/gateway.py
Restart=always
RestartSec=5
# restart daily so a rotated config (or a fresh approval) is picked up
# within a day even without any manual restart
RuntimeMaxSec=1d

[Install]
WantedBy=multi-user.target
EOF

# --- 13. Telemetry: hourly device-health snapshot to the fleet panel ----------
# Every device POSTs a small JSON snapshot (identity, versions, health, wifi)
# to the config panel on boot and hourly, so the whole fleet is visible and
# manageable in one place. Fire-and-forget: a failed post never affects
# anything. The snapshot also carries the player's CMS device token (resolved
# at report time, see below), so the panel can join a device row to its CMS
# identity. That token is a credential: it travels only device -> panel over
# HTTPS inside this POST and is never committed to this public repo.
log "Installing telemetry reporter (hourly device snapshot to the fleet panel) ..."

cat > /usr/local/bin/irl-telemetry <<'TELEMETRY_EOF'
#!/usr/bin/env bash
# Posts a device-health snapshot to the fleet config panel.
# Fire-and-forget: any failure is silent. `irl-telemetry --print` shows the
# payload without sending (debugging).
set -u
URL="https://iot-config.theirlnetwork.com/telemetry"

T_SERIAL="$(awk '/^Serial/{print $3}' /proc/cpuinfo 2>/dev/null)" || true
[ -n "${T_SERIAL:-}" ] || exit 0
T_HOSTNAME="$(hostname 2>/dev/null)" || true
T_MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)" || true
T_OS="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")" || true
T_REV="@INSTALLER_REV@"
T_APP="$(dpkg-query -W -f '${Version}' irl-player 2>/dev/null)" || true
T_CANARY=false; [ -e /etc/irl-player/canary ] && T_CANARY=true
T_UPTIME="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)" || true
T_CPUTEMP="$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)" || true
T_THROTTLED="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2; exit}')" || true
T_DISKFREE="$(df -Pk / 2>/dev/null | awk 'NR==2{print int($4/1024)}')" || true
T_DISKPCT="$(df -Pk / 2>/dev/null | awk 'NR==2 && $2>0 {printf "%.1f", $4*100/$2}')" || true
T_MEMFREE="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null)" || true
WIFI="$(iw dev wlan0 link 2>/dev/null)" || true
T_SSID="$(printf '%s' "${WIFI:-}" | awk -F': ' '/SSID:/{print $2; exit}')" || true
T_SIGNAL="$(printf '%s' "${WIFI:-}" | awk '/signal:/{print $2; exit}')" || true
T_KIOSK="$(systemctl is-active irl-player-kiosk 2>/dev/null)" || true
T_GATEWAY="$(systemctl is-active irl-gateway 2>/dev/null)" || true
T_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true

# Player identity: pairing UUID + cached screen name from the Flutter app's
# shared_preferences, and the CMS device token. The token is NOT stored on
# disk, so resolve it exactly the way the player does: ask the ad server
# (API_URL, from the player's bundled .env) for this device_id's external_id.
# All best-effort - an unpaired or offline device just omits these three fields.
PREFS="/home/irlplayer/.local/share/IRLPlayer/shared_preferences.json"
PLAYER_ENV="/opt/irl-player/data/flutter_assets/.env"
T_DEVICE_ID=""; T_SCREEN=""; T_DEVICE_TOKEN=""
if [ -r "$PREFS" ]; then
  T_DEVICE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("flutter.device_id") or "")' "$PREFS" 2>/dev/null)" || true
  T_SCREEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("flutter.screen_identity") or "")' "$PREFS" 2>/dev/null)" || true
fi
if [ -n "${T_DEVICE_ID:-}" ] && [ -r "$PLAYER_ENV" ]; then
  API_URL="$(awk -F= '/^API_URL=/{sub(/^API_URL=/,""); gsub(/[\r"]/,""); print; exit}' "$PLAYER_ENV")" || true
  if [ -n "${API_URL:-}" ]; then
    API_HTTPS_ONLY=""
    case "$API_URL" in https://*) API_HTTPS_ONLY="--proto =https --tlsv1.2";; esac
    T_DEVICE_TOKEN="$(curl -fsS --max-time 5 $API_HTTPS_ONLY "$API_URL/api/v1/status/$T_DEVICE_ID" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("external_id") or "")' 2>/dev/null)" || true
  fi
fi

export T_SERIAL T_HOSTNAME T_MODEL T_OS T_REV T_APP T_CANARY T_UPTIME \
       T_CPUTEMP T_THROTTLED T_DISKFREE T_DISKPCT T_MEMFREE \
       T_SSID T_SIGNAL T_KIOSK T_GATEWAY T_IP \
       T_DEVICE_ID T_SCREEN T_DEVICE_TOKEN

PAYLOAD="$(python3 - <<'PY' 2>/dev/null
import json, os
def num(v, cast):
    try:
        return cast(v)
    except (TypeError, ValueError):
        return None
def throttled(v):
    # vcgencmd get_throttled bitmask: bits 0/1/2 = under-voltage / arm freq
    # capped / throttled right now; bits 16/18 = under-voltage / throttling
    # has occurred since boot. Null when vcgencmd is missing or fails.
    try:
        bits = int(v, 16)
    except (TypeError, ValueError):
        return None
    return {
        "under_voltage_now":      bool(bits & (1 << 0)),
        "freq_capped_now":        bool(bits & (1 << 1)),
        "throttled_now":          bool(bits & (1 << 2)),
        "under_voltage_occurred": bool(bits & (1 << 16)),
        "throttled_occurred":     bool(bits & (1 << 18)),
    }
e = os.environ.get
print(json.dumps({
    "serial": e("T_SERIAL", ""),
    "hostname": e("T_HOSTNAME") or None,
    "model": e("T_MODEL") or None,
    "os": e("T_OS") or None,
    "installer_rev": num(e("T_REV"), int),
    "app_version": e("T_APP") or None,
    "canary": e("T_CANARY") == "true",
    "uptime_s": num(e("T_UPTIME"), int),
    "cpu_temp_c": num(e("T_CPUTEMP"), float),
    "throttled_flags": throttled(e("T_THROTTLED")),
    "disk_free_mb": num(e("T_DISKFREE"), int),
    "disk_free_pct": num(e("T_DISKPCT"), float),
    "mem_free_mb": num(e("T_MEMFREE"), int),
    "wifi_ssid": e("T_SSID") or None,
    "wifi_signal_dbm": num(e("T_SIGNAL"), int),
    "kiosk_active": e("T_KIOSK") == "active",
    "gateway_active": e("T_GATEWAY") == "active",
    "local_ip": e("T_IP") or None,
    "device_id": e("T_DEVICE_ID") or None,
    "screen_identity": e("T_SCREEN") or None,
    "device_token": e("T_DEVICE_TOKEN") or None,
}))
PY
)" || true
[ -n "${PAYLOAD:-}" ] || exit 0
if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

# HMAC signing (panel contract, rev >= 25): once approved, the device receives
# a per-device secret as the additive "telemetry_hmac" key (64 hex chars) in
# the gateway's panel-fetched mqtt.json. Sign "<unix ts>.<exact body bytes>"
# with HMAC-SHA256 and send the timestamp + lowercase-hex signature headers.
# No secret (pending device, or config never fetched) -> post unsigned, which
# the panel accepts unchanged. The secret must be signed with as-is bytes:
# the body signed and the body sent must be identical.
SECRET="$(python3 -c 'import json,sys,re; s=json.load(open(sys.argv[1])).get("telemetry_hmac") or ""; print(s if re.fullmatch(r"[0-9a-f]{64}", s) else "")' /opt/irl-gateway/mqtt.json 2>/dev/null)" || true
CURL=(curl -fsS --max-time 15 -H "Content-Type: application/json")
case "$URL" in https://*) CURL+=(--proto =https --tlsv1.2);; esac
if [ -n "${SECRET:-}" ]; then
  TS="$(date +%s)"
  SIG="$(T_SIGN_TS="$TS" T_SIGN_KEY="$SECRET" T_SIGN_BODY="$PAYLOAD" python3 -c '
import hashlib, hmac, os
e = os.environ
print(hmac.new(bytes.fromhex(e["T_SIGN_KEY"]),
               (e["T_SIGN_TS"] + "." + e["T_SIGN_BODY"]).encode(),
               hashlib.sha256).hexdigest())' 2>/dev/null)" || true
  [ -n "${SIG:-}" ] && CURL+=(-H "X-IRL-Timestamp: $TS" -H "X-IRL-Signature: $SIG")
fi
"${CURL[@]}" -d "$PAYLOAD" "$URL" >/dev/null 2>&1 || true
exit 0
TELEMETRY_EOF
chmod +x /usr/local/bin/irl-telemetry
sed -i "s|@INSTALLER_REV@|$INSTALLER_REV|" /usr/local/bin/irl-telemetry

cat > /etc/systemd/system/irl-player-telemetry.service <<'EOF'
[Unit]
Description=IRL Player telemetry report (device-health snapshot to the fleet panel)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/irl-telemetry
EOF

cat > /etc/systemd/system/irl-player-telemetry.timer <<'EOF'
[Unit]
Description=IRL Player telemetry report (on boot and hourly)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
# spread devices out so they don't all report at the same second
RandomizedDelaySec=10min

[Install]
WantedBy=timers.target
EOF

# --- 13b. Fleet screen switch: screen.txt turns every display off/on ----------
# The website serves screen.txt ("0" = screens off, "1" = normal). A 1-minute
# timer fetches it and applies the value with wlr-randr. Turning the output
# off (rather than painting black or stopping the player) keeps the player
# running for an instant wake AND keeps the freeze watchdog quiet: with no
# output, grim fails to capture, which the watchdog treats as "not my
# business" (verified on the canary: grim exits 1 "no wl_output").
# Fail-safe: only an explicit "0" blanks — a missing file, fetch error, or
# offline device always means ON.
log "Installing fleet screen switch (screen.txt on the website) ..."

cat > /usr/local/bin/irl-screen <<'EOF'
#!/usr/bin/env bash
# IRL Player screen switch. Fetches screen.txt from the website every minute:
# "0" = all displays off (player keeps running), anything else = displays on.
set -u
SCREEN_URL="${IRL_SCREEN_URL:-@BASE_URL@/screen.txt}"
KIOSK_USER=irlplayer
STATE_FILE=/var/lib/irl-player/screen-state

HTTPS_ONLY=""
case "$SCREEN_URL" in https://*) HTTPS_ONLY="--proto =https --tlsv1.2";; esac
# Pages' CDN caches ~10 min; the cache-buster keeps the switch near-real-time.
val="$(curl -fsSL --max-time 15 $HTTPS_ONLY "${SCREEN_URL}?t=$(date +%s)" 2>/dev/null | head -c 8 | tr -d '[:space:]')"
want=on
[ "$val" = "0" ] && want=off

# The compositor's socket only exists while the kiosk is up; in normal/console
# mode (Ctrl+Alt+P) there is nothing to blank — leave the screen alone.
uid="$(id -u "$KIOSK_USER" 2>/dev/null)" || exit 0
xdg="/run/user/$uid"
sock="$(find "$xdg" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' 2>/dev/null | head -1)"
[ -n "$sock" ] || exit 0

wlr() {
  XDG_RUNTIME_DIR="$xdg" WAYLAND_DISPLAY="${sock##*/}" \
    setpriv --reuid "$KIOSK_USER" --regid "$KIOSK_USER" --init-groups wlr-randr "$@"
}

# Re-apply every run, not only on change: a kiosk restart re-enables outputs,
# and an idempotent --on/--off keeps the device converged on the published
# value. All outputs are toggled — CM5/Pi 5 may have both HDMI ports in use.
outputs="$(wlr 2>/dev/null | awk '/^[^ ]/{print $1}')"
[ -n "$outputs" ] || exit 0
for out in $outputs; do
  wlr --output "$out" "--$want" 2>/dev/null || true
done

prev="$(cat "$STATE_FILE" 2>/dev/null || echo "")"
if [ "$want" != "$prev" ]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  echo "$want" > "$STATE_FILE"
  echo "screen switch: displays $want (screen.txt=${val:-unreachable})"
fi
EOF
chmod +x /usr/local/bin/irl-screen
sed -i "s|@BASE_URL@|$BASE_URL|" /usr/local/bin/irl-screen

cat > /etc/systemd/system/irl-player-screen.service <<'EOF'
[Unit]
Description=IRL Player screen switch (applies screen.txt from the website)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/irl-screen
EOF

cat > /etc/systemd/system/irl-player-screen.timer <<'EOF'
[Unit]
Description=IRL Player screen switch check (every minute)

[Timer]
OnBootSec=30
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

# --- 14. Auto-update: reinstall whenever the published install.sh changes -----
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
  PENDING=/etc/irl-player/pending-update
  CANARY=/etc/irl-player/canary

  # never run two update checks (or a check during an install) at once
  exec 9>/var/lock/irl-update.lock
  flock -n 9 || exit 0

  # refuse protocol downgrades on the fetch that gets executed as root
  HTTPS_ONLY=""
  case "$BASE_URL" in https://*) HTTPS_ONLY="--proto =https --tlsv1.2";; esac

  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  # offline or server unreachable: fine, the timer tries again next hour
  curl -fsSL --retry 3 $HTTPS_ONLY -o "$TMP" "$BASE_URL/install.sh" || exit 0
  head -1 "$TMP" | grep -q '^#!' || exit 0   # not a script (captive portal etc.)

  NEW="$(sha256sum "$TMP" | awk '{print $1}')"
  OLD="$(cat "$STATE" 2>/dev/null || true)"
  if [ "$NEW" = "$OLD" ]; then
    rm -f "$PENDING"
    exit 0
  fi

  # Canary rollout: a device marked with the canary file applies instantly;
  # everyone else waits FLEET_DELAY_HOURS (read from the NEW script, so a
  # release published with 0 rolls out to the whole fleet immediately).
  if [ ! -e "$CANARY" ]; then
    DELAY_H="$(sed -n 's/^FLEET_DELAY_HOURS=\([0-9][0-9]*\)$/\1/p' "$TMP" | head -1)"
    DELAY_H="${DELAY_H:-0}"
    if [ "$DELAY_H" -gt 0 ]; then
      now="$(date +%s)"
      p_hash=""; p_time=0
      [ -f "$PENDING" ] && read -r p_hash p_time < "$PENDING"
      p_time="${p_time:-0}"
      if [ "$p_hash" != "$NEW" ]; then
        mkdir -p "$(dirname "$PENDING")"
        echo "$NEW $now" > "$PENDING"
        echo "new install.sh seen — this device applies it in ${DELAY_H}h (canary devices go first)"
        exit 0
      fi
      [ $((now - p_time)) -lt $((DELAY_H * 3600)) ] && exit 0
    fi
  fi

  echo "install.sh changed (${OLD:-none} -> $NEW) — reinstalling"
  if bash "$TMP"; then
    echo "$NEW" > "$STATE"
    rm -f "$PENDING"
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
  if curl -fsSL --retry 3 $CURL_HTTPS_ONLY -o "$HASH_TMP" "$BASE_URL/install.sh"; then
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
# NOTE: no Persistent= here. It only has an effect on OnCalendar= timers; on a
# monotonic-only timer (systemd 257) starting mid-session with a stamp already
# on disk - which is exactly the state right after every install - it collapses
# the next elapse to infinity and the hourly re-check never fires again (boot
# still works, so updates only landed on reboot). The telemetry timer omits it
# and stays healthy; keep this timer identical. Do not re-add Persistent=true.

[Install]
WantedBy=timers.target
EOF

# --- 14. Weekly scheduled reboot ---------------------------------------------
# Kiosks never reboot on their own - unattended-upgrades has Automatic-Reboot
# off on purpose - so a healthy device can sit for weeks without applying a
# downloaded OS security update, and (before rev 22) without re-arming a broken
# updater. A quiet weekly reboot at 04:00 local keeps the fleet self-healing
# without anyone needing physical access to the remote sites. This is an
# OnCalendar timer, which is immune to the monotonic-timer trap that disabled
# the update timer - and it deliberately omits Persistent= so a device that was
# powered off at 04:00 does NOT reboot the instant it comes back.
cat > /etc/systemd/system/irl-player-reboot.service <<'EOF'
[Unit]
Description=IRL Player weekly scheduled reboot

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl reboot
EOF

cat > /etc/systemd/system/irl-player-reboot.timer <<'EOF'
[Unit]
Description=IRL Player weekly scheduled reboot (Sun 04:00 local)

[Timer]
OnCalendar=Sun *-*-* 04:00:00
# spread the fleet across a window so sites on shared power/uplinks don't all
# drop at the same instant
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF

# --- 15. Remove leftovers from previous installs ------------------------------
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
systemctl enable --now irl-player-watchdog >/dev/null
systemctl enable --now irl-player-netwatch >/dev/null
systemctl enable --now irl-gateway >/dev/null 2>&1 || true
systemctl try-restart irl-gateway >/dev/null 2>&1 || true
systemctl enable --now irl-player-telemetry.timer >/dev/null 2>&1 || true
systemctl enable --now irl-player-screen.timer >/dev/null 2>&1 || true
systemctl enable --now irl-player-reboot.timer >/dev/null 2>&1 || true

log "Starting kiosk ..."
systemctl restart "$SERVICE_NAME"

log "Done. IRL Player will start fullscreen on every boot."
log "Auto-update: checks $BASE_URL/install.sh hourly and reinstalls on change"
log "Watchdog: frozen screen -> player restart, then reboot; OS hang -> hardware reboot"
log "Reboot:  scheduled weekly (Sun 04:00 local) so OS updates apply and timers stay healthy"
log "Hotkey:  Ctrl+Alt+P toggles kiosk (on top) <-> normal console/desktop"
log "Logs:    journalctl -u $SERVICE_NAME -f"
log "Stop:    sudo systemctl stop $SERVICE_NAME"
log "Remove:  curl -fsSL $BASE_URL/uninstall.sh | sudo bash"
