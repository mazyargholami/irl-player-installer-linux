#!/usr/bin/env bash
#
# IRL Player kiosk uninstaller
#   curl -fsSL https://linux-player.theirlnetwork.com/uninstall.sh | sudo bash
#
set -euo pipefail

SERVICE_NAME="irl-player-kiosk"
KIOSK_USER="irlplayer"

log() { printf '\033[1;32m[irl-player]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo)"; exit 1; }

log "Stopping and removing kiosk service ..."
systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
systemctl disable --now irl-player-hotkey 2>/dev/null || true
systemctl disable --now irl-player-update.timer 2>/dev/null || true
systemctl disable --now irl-player-watchdog 2>/dev/null || true
systemctl disable --now irl-player-netwatch 2>/dev/null || true
systemctl disable --now irl-gateway 2>/dev/null || true
systemctl disable --now irl-player-telemetry.timer 2>/dev/null || true
systemctl disable --now irl-player-screen.timer 2>/dev/null || true
systemctl disable --now irl-player-reboot.timer 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service" \
      /etc/systemd/system/irl-player-hotkey.service \
      /etc/systemd/system/irl-player-update.service \
      /etc/systemd/system/irl-player-update.timer \
      /etc/systemd/system/irl-player-watchdog.service \
      /etc/systemd/system/irl-player-netwatch.service \
      /etc/systemd/system/irl-gateway.service \
      /etc/systemd/system.conf.d/irl-watchdog.conf \
      /etc/apt/apt.conf.d/52irl-unattended-upgrades \
      /etc/apt/apt.conf.d/60irl-auto-upgrades \
      /usr/local/bin/irl-kiosk-toggle \
      /usr/local/bin/irl-kiosk-run \
      /usr/local/bin/irl-hotkeyd \
      /usr/local/bin/irl-update \
      /usr/local/bin/irl-watchdog \
      /usr/local/bin/irl-netwatch \
      /usr/local/bin/irl-gateway-config \
      /usr/local/bin/irl-telemetry \
      /etc/systemd/system/irl-player-telemetry.service \
      /etc/systemd/system/irl-player-telemetry.timer \
      /usr/local/bin/irl-screen \
      /etc/systemd/system/irl-player-screen.service \
      /etc/systemd/system/irl-player-screen.timer \
      /etc/systemd/system/irl-player-reboot.service \
      /etc/systemd/system/irl-player-reboot.timer \
      /var/lock/irl-update.lock
# /opt/irl-gateway includes the per-device mqtt.json credentials — uninstall
# means "back to normal", so the secret goes too
rm -rf /etc/irl-player /var/lib/irl-player /opt/irl-gateway
systemctl daemon-reload

log "Removing irl-player package ..."
# apt-daily/unattended-upgrades may hold the lock right when we run; wait for it
# rather than failing silently.
if ! apt-get -o DPkg::Lock::Timeout=120 remove -y irl-player; then
  log "WARNING: could not remove the irl-player package (apt busy?)."
  log "         Retry later with: sudo apt-get remove irl-player"
fi

if id "$KIOSK_USER" >/dev/null 2>&1; then
  log "Removing user '$KIOSK_USER' ..."
  # The kiosk session may still be tearing down from the service stop above;
  # userdel fails while any of the user's processes live, so kill and retry.
  loginctl terminate-user "$KIOSK_USER" 2>/dev/null || true
  removed=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pkill -KILL -u "$KIOSK_USER" 2>/dev/null || true
    if userdel -r "$KIOSK_USER" 2>/dev/null; then removed=1; break; fi
    sleep 1
  done
  if [ "$removed" = 1 ]; then
    log "User removed."
  else
    log "WARNING: could not remove user '$KIOSK_USER' (processes still running?)."
    log "         Retry later with: sudo userdel -r $KIOSK_USER"
  fi
fi

log "Done. Note: if this Pi previously booted to a desktop, re-enable it with:"
log "  sudo systemctl enable --now lightdm   (or your display manager)"
