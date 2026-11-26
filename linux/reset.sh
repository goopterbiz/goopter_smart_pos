#!/usr/bin/env bash
set -Eeuo pipefail

POS_USER=goopter_pos
POS_HOME=/home/$POS_USER
APP_PATH=$POS_HOME/Applications/GoopterSmartPOS.AppImage
APP_DATA_DIR="$POS_HOME/.config/Goopter Smart POS"
KEYRING_DIR=$POS_HOME/.local/share/keyrings
STATE_DIR=/var/lib/goopter-pos
LOG_FILE=/var/log/goopter-pos-install.log

log() { printf '%s [goopter-pos-reset] %s\n' "$(date -Is)" "$*"; }
fail() { log "ERROR: $*"; exit 1; }

on_error() {
  local rc=$? line=$1
  log "ERROR: command failed at line $line with exit code $rc. Full log: $LOG_FILE"
  exit "$rc"
}

stop_app() {
  log "Stopping Goopter Smart POS"
  if systemctl is-active --quiet lightdm.service; then
    systemctl stop lightdm.service
  fi
  id "$POS_USER" >/dev/null 2>&1 || return 0
  loginctl terminate-user "$POS_USER" 2>/dev/null || true
  for _ in $(seq 1 15); do
    pgrep -u "$POS_USER" >/dev/null || break
    sleep 1
  done
  pkill -KILL -u "$POS_USER" 2>/dev/null || true
  sleep 1
  if pgrep -u "$POS_USER" -f '/goopter-smart-pos( |$)' >/dev/null; then
    fail "Goopter Smart POS is still running"
  fi
  log "Goopter Smart POS is stopped"
}

remove_path() {
  if [[ -e "$1" ]]; then
    rm -rf "$1"
    log "Removed $1"
  else
    log "Not present: $1"
  fi
}

main() {
  [[ $EUID -eq 0 ]] || fail "run as root: curl -fsSL <url> | sudo bash"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'on_error $LINENO' ERR
  printf '\n===== %s reset =====\n' "$(date -Is)"
  stop_app
  remove_path "$APP_PATH"
  remove_path "$APP_DATA_DIR"
  remove_path "$KEYRING_DIR"
  remove_path "$STATE_DIR"
  log "Reset done. The screen stays on the text console until the installer runs and the till reboots"
  log "Next: curl -fsSL https://install.goopter.com/linux | sudo bash"
}

main "$@"
