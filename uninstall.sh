#!/usr/bin/env bash
#
# IRL Player kiosk uninstaller
#   curl -fsSL https://mazyargholami.github.io/irl-player-installer-linux/uninstall.sh | sudo bash
#
set -euo pipefail

SERVICE_NAME="irl-player-kiosk"
KIOSK_USER="irlplayer"

log() { printf '\033[1;32m[irl-player]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo)"; exit 1; }

log "Stopping and removing kiosk service ..."
systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
systemctl disable --now irl-player-hotkey 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service" \
      /etc/systemd/system/irl-player-hotkey.service \
      /usr/local/bin/irl-kiosk-toggle \
      /usr/local/bin/irl-hotkeyd
systemctl daemon-reload

log "Removing irl-player package ..."
apt-get remove -y irl-player 2>/dev/null || true

if id "$KIOSK_USER" >/dev/null 2>&1; then
  log "Removing user '$KIOSK_USER' ..."
  userdel -r "$KIOSK_USER" 2>/dev/null || true
fi

log "Done. Note: if this Pi previously booted to a desktop, re-enable it with:"
log "  sudo systemctl enable --now lightdm   (or your display manager)"
