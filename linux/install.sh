#!/usr/bin/env bash
set -Eeuo pipefail

POS_USER=goopter_pos
POS_HOME=/home/$POS_USER
APP_REPO=goopterbiz/goopter_smart_pos
APP_DIR=$POS_HOME/Applications
APP_PATH=$APP_DIR/GoopterSmartPOS.AppImage
APP_DATA_DIR="$POS_HOME/.config/Goopter Smart POS"
SESSION_BIN=/usr/local/bin/goopter-pos-session
STATE_DIR=/var/lib/goopter-pos
LOG_FILE=/var/log/goopter-pos-install.log

GOOPTER_STORE=${GOOPTER_STORE:-}
TS_AUTHKEY=${TS_AUTHKEY:-}
TS_HOSTNAME=${TS_HOSTNAME:-}
TAILSCALE_JOIN=${TAILSCALE_JOIN:-true}
RUSTDESK_RESET_PASSWORD=${RUSTDESK_RESET_PASSWORD:-false}
APP_REINSTALL=${APP_REINSTALL:-false}

RUSTDESK_PASSWORD=""
WORK_DIR=""

log() { printf '%s [goopter-pos] %s\n' "$(date -Is)" "$*"; }
fail() { log "ERROR: $*"; exit 1; }
have_tty() { [[ -r /dev/tty && -w /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

on_error() {
  local rc=$? line=$1
  log "ERROR: command failed at line $line with exit code $rc. Full log: $LOG_FILE"
  exit "$rc"
}

cleanup() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}

preflight() {
  [[ $EUID -eq 0 ]] || fail "run as root: curl -fsSL <url> | sudo bash"
  . /etc/os-release
  [[ "$ID" == ubuntu ]] || fail "Ubuntu is required, found $ID"
  [[ "$(uname -m)" == x86_64 ]] || fail "x86_64 is required, found $(uname -m)"
  for v in TAILSCALE_JOIN RUSTDESK_RESET_PASSWORD APP_REINSTALL; do
    [[ "${!v}" == true || "${!v}" == false ]] || fail "$v must be true or false"
  done
  if [[ -n "$GOOPTER_STORE" && ! "$GOOPTER_STORE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    fail "GOOPTER_STORE must be the store subdomain, for example 'mystore' for mystore.goopter.com"
  fi
  [[ "$VERSION_ID" == 26.04 ]] || log "WARNING: tested on Ubuntu 26.04, this is $VERSION_ID"
  curl -fsS --max-time 15 -o /dev/null https://api.github.com || fail "no Internet access to api.github.com"
  mkdir -p "$STATE_DIR"
  WORK_DIR=$(mktemp -d)
}

configure_tailscale_repo() {
  log "Configuring the Tailscale package repository"
  local codename list=/etc/apt/sources.list.d/tailscale.list f
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" -o "$WORK_DIR/tailscale.gpg"
  install -m 0644 "$WORK_DIR/tailscale.gpg" /usr/share/keyrings/tailscale-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu $codename main" >"$list"
  for f in /etc/apt/sources.list.d/*; do
    if [[ "$f" != "$list" && -f "$f" ]] && grep -q 'pkgs\.tailscale\.com' "$f"; then
      log "Removing duplicate Tailscale source $f"
      rm -f "$f"
    fi
  done
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections
  configure_tailscale_repo
  apt-get update -q
  apt-get install -y -q --no-install-recommends \
    ca-certificates curl jq openssl apparmor tailscale \
    xserver-xorg x11-xserver-utils lightdm lightdm-gtk-greeter openbox \
    dbus-user-session dbus-x11 gnome-keyring libsecret-1-0 \
    libfuse2t64 libnss3 libgtk-3-0t64 libasound2t64 libgbm1 libxss1 libxtst6 libnotify4 xdg-utils \
    cups cups-client \
    fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
}

configure_user() {
  log "Configuring user $POS_USER"
  if ! id "$POS_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$POS_USER"
    passwd --lock "$POS_USER" >/dev/null
  fi
  groupadd -f autologin
  usermod -aG autologin,lp,dialout,audio,video "$POS_USER"
  if id -nG "$POS_USER" | tr ' ' '\n' | grep -qx sudo; then
    gpasswd -d "$POS_USER" sudo >/dev/null
  fi
}

configure_display() {
  log "Configuring LightDM auto-login into the kiosk session"
  install -d /etc/lightdm/lightdm.conf.d
  cat >/etc/lightdm/lightdm.conf.d/50-goopter-pos.conf <<EOF
[Seat:*]
autologin-user=$POS_USER
autologin-user-timeout=0
autologin-session=goopter-pos
user-session=goopter-pos
greeter-session=lightdm-gtk-greeter
xserver-command=X -s 0 -dpms
EOF

  cat >/usr/share/xsessions/goopter-pos.desktop <<EOF
[Desktop Entry]
Name=Goopter Smart POS
Exec=$SESSION_BIN
Type=Application
EOF

  cat >"$SESSION_BIN" <<'EOF'
#!/usr/bin/env bash
APP="$HOME/Applications/GoopterSmartPOS.AppImage"
LOG="$HOME/.local/state/goopter-pos-session.log"
mkdir -p "$(dirname "$LOG")"

export XDG_CURRENT_DESKTOP=GNOME
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "/run/user/$(id -u)/bus" ]]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi
eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)"
export GNOME_KEYRING_CONTROL

xset s off
xset s noblank
xset -dpms
openbox &

while true; do
  while pgrep -u "$(id -u)" -f '/goopter-smart-pos( |$)' >/dev/null; do sleep 2; done
  started=$(date +%s)
  echo "$(date -Is) starting Goopter Smart POS" >>"$LOG"
  "$APP" --password-store=gnome-libsecret >>"$LOG" 2>&1
  echo "$(date -Is) Goopter Smart POS exited with code $?" >>"$LOG"
  if (( $(date +%s) - started < 30 )); then sleep 10; else sleep 2; fi
done
EOF
  chmod 0755 "$SESSION_BIN"

  install -d -o "$POS_USER" -g "$POS_USER" "$POS_HOME/.config" "$POS_HOME/.config/openbox"
  cat >"$POS_HOME/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label=""></menu>
</openbox_menu>
EOF
  chown "$POS_USER:$POS_USER" "$POS_HOME/.config/openbox/menu.xml"

  echo /usr/sbin/lightdm >/etc/X11/default-display-manager
  if systemctl list-unit-files gdm3.service >/dev/null 2>&1; then
    systemctl disable gdm3.service >/dev/null 2>&1 || true
  fi
  systemctl enable --force lightdm.service
  systemctl set-default graphical.target
}

configure_keyring() {
  log "Configuring the unlocked login keyring for terminal sign-in"
  local dir=$POS_HOME/.local/share/keyrings
  install -d -m 0700 -o "$POS_USER" -g "$POS_USER" "$POS_HOME/.local" "$POS_HOME/.local/share" "$dir"
  if [[ -e "$dir/login.keyring" ]]; then
    log "Login keyring already exists, leaving it unchanged"
  else
    cat >"$dir/login.keyring" <<EOF
[keyring]
display-name=login
ctime=$(date +%s)
mtime=0
lock-on-idle=false
lock-after=false
EOF
    echo login >"$dir/default"
    chown "$POS_USER:$POS_USER" "$dir/login.keyring" "$dir/default"
    chmod 0600 "$dir/login.keyring" "$dir/default"
  fi
}

disable_sleep() {
  log "Disabling sleep, suspend and hibernate"
  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null
  install -d /etc/systemd/logind.conf.d
  cat >/etc/systemd/logind.conf.d/50-goopter-pos.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
}

install_app() {
  install -d -o "$POS_USER" -g "$POS_USER" "$APP_DIR"
  if [[ -x "$APP_PATH" && "$APP_REINSTALL" != true ]]; then
    log "Goopter Smart POS is already installed, it updates itself. Set APP_REINSTALL=true to replace it"
    return
  fi
  log "Finding the latest desktop release of $APP_REPO"
  local tag
  tag=$(curl -fsSL "https://api.github.com/repos/$APP_REPO/releases?per_page=30" |
    jq -r '[.[] | select(.draft == false and .prerelease == false and (.tag_name | startswith("desktop/")))]
      | sort_by(.tag_name | sub("^desktop/v\\.?"; "") | split(".") | map(tonumber? // 0)) | last | .tag_name')
  [[ -n "$tag" && "$tag" != null ]] || fail "no published desktop release found in $APP_REPO"
  local base="https://github.com/$APP_REPO/releases/download/$tag"
  curl -fsSL "$base/latest-linux.yml" -o "$WORK_DIR/latest-linux.yml"
  local file sha
  file=$(awk '/^path:/ {print $2}' "$WORK_DIR/latest-linux.yml")
  sha=$(awk '/^sha512:/ {print $2}' "$WORK_DIR/latest-linux.yml")
  [[ "$file" == *.AppImage && -n "$sha" ]] || fail "latest-linux.yml in $tag has no AppImage entry"
  log "Downloading $file from $tag"
  curl -fsSL "$base/$file" -o "$WORK_DIR/app.AppImage"
  [[ "$(openssl dgst -sha512 -binary "$WORK_DIR/app.AppImage" | base64 -w0)" == "$sha" ]] ||
    fail "SHA-512 of $file does not match latest-linux.yml"
  install -o "$POS_USER" -g "$POS_USER" -m 0755 "$WORK_DIR/app.AppImage" "$APP_PATH"
  echo "$tag" >"$STATE_DIR/installed-release"
}

configure_apparmor() {
  log "Allowing the Electron sandbox through AppArmor"
  cat >/etc/apparmor.d/goopter-smart-pos <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile goopter-smart-pos /tmp/.mount_Goopte*/goopter-smart-pos flags=(unconfined) {
  userns,
  include if exists <local/goopter-smart-pos>
}
EOF
  if aa-enabled -q 2>/dev/null; then
    apparmor_parser -r /etc/apparmor.d/goopter-smart-pos
  else
    log "WARNING: AppArmor is not enabled here, the profile loads at next boot"
  fi
}

prefill_store() {
  [[ -n "$GOOPTER_STORE" ]] || return 0
  if [[ -e "$APP_DATA_DIR/store.json" ]]; then
    log "A store is already saved in the app, leaving it unchanged"
    return
  fi
  log "Saving store $GOOPTER_STORE.goopter.com in the app"
  install -d -m 0700 -o "$POS_USER" -g "$POS_USER" "$APP_DATA_DIR"
  printf '{"slug":"%s"}' "$GOOPTER_STORE" >"$APP_DATA_DIR/store.json"
  chown "$POS_USER:$POS_USER" "$APP_DATA_DIR/store.json"
  chmod 0600 "$APP_DATA_DIR/store.json"
}

tailscale_state() {
  tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"' 2>/dev/null || echo Unknown
}

install_tailscale() {
  systemctl enable --now tailscaled.service

  if [[ "$(tailscale_state)" == Running ]]; then
    log "Tailscale is already joined, making sure Tailscale SSH is on"
    tailscale set --ssh
    return
  fi
  if [[ "$TAILSCALE_JOIN" != true ]]; then
    log "WARNING: TAILSCALE_JOIN=false, Tailscale is installed but not joined"
    return
  fi
  if [[ -z "$TS_AUTHKEY" ]] && have_tty; then
    printf 'Tailscale auth key (input hidden): ' >/dev/tty
    read -rs TS_AUTHKEY </dev/tty
    printf '\n' >/dev/tty
  fi
  [[ -n "$TS_AUTHKEY" ]] || fail "TS_AUTHKEY is required to join Tailscale. Set TAILSCALE_JOIN=false to skip"

  local hostname=${TS_HOSTNAME:-pos-${GOOPTER_STORE:-unassigned}-$(cut -c1-6 /etc/machine-id)}
  local keyfile=$WORK_DIR/ts-authkey
  (umask 077 && printf '%s' "$TS_AUTHKEY" >"$keyfile")
  log "Joining Tailscale as $hostname"
  tailscale up --auth-key="file:$keyfile" --ssh --hostname="$hostname"
  rm -f "$keyfile"
}

install_rustdesk() {
  local template=/usr/share/rustdesk/files/systemd/rustdesk.service
  if [[ "$(dpkg-query -W -f='${Status}' rustdesk 2>/dev/null)" != "install ok installed" || ! -f "$template" ]]; then
    log "Installing RustDesk"
    local url
    url=$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest |
      jq -r '[.assets[] | select(.name | test("^rustdesk-[0-9.]+-x86_64\\.deb$"))][0].browser_download_url')
    [[ -n "$url" && "$url" != null ]] || fail "no RustDesk x86_64 .deb found in the latest release"
    curl -fsSL "$url" -o "$WORK_DIR/rustdesk.deb"
    apt-get install -y -q --reinstall "$WORK_DIR/rustdesk.deb"
  fi
  if [[ ! -f /usr/lib/systemd/system/rustdesk.service && ! -f /etc/systemd/system/rustdesk.service ]]; then
    log "Restoring the missing rustdesk.service unit"
    install -m 0644 "$template" /usr/lib/systemd/system/rustdesk.service
    sed -i 's|pkill|/usr/bin/pkill|g' /usr/lib/systemd/system/rustdesk.service
  fi
  local conf
  for conf in /root/.config/rustdesk/RustDesk2.toml /home/*/.config/rustdesk/RustDesk2.toml; do
    if [[ -f "$conf" ]] && grep -q '^stop-service *=' "$conf"; then
      log "Clearing the RustDesk stop-service setting in $conf"
      systemctl stop rustdesk.service 2>/dev/null || true
      sed -i '/^stop-service *=/d' "$conf"
    fi
  done
  systemctl daemon-reload
  systemctl enable --now rustdesk.service
  for _ in $(seq 1 15); do
    systemctl is-active --quiet rustdesk.service && break
    sleep 1
  done
  if ! systemctl is-active --quiet rustdesk.service; then
    log "WARNING: rustdesk.service is not running"
    systemctl status rustdesk.service --no-pager -l || true
    journalctl -u rustdesk.service -n 20 --no-pager || true
  fi

  if [[ -e "$STATE_DIR/rustdesk-password-set" && "$RUSTDESK_RESET_PASSWORD" != true ]]; then
    log "RustDesk password is already set. Set RUSTDESK_RESET_PASSWORD=true to replace it"
    return
  fi
  if ! have_tty; then
    log "WARNING: no terminal to show a new RustDesk password, it was not set. Rerun with RUSTDESK_RESET_PASSWORD=true over Tailscale SSH"
    return
  fi
  for _ in $(seq 1 15); do
    rustdesk --get-id >/dev/null 2>&1 && break
    sleep 2
  done
  RUSTDESK_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16)
  rustdesk --password "$RUSTDESK_PASSWORD" >/dev/null
  touch "$STATE_DIR/rustdesk-password-set"
  log "RustDesk password set. It is shown once at the end and is not logged"
}

validate() {
  log "Validating"
  local failed=0
  check() {
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then
      log "PASS  $name"
    else
      log "FAIL  $name"
      failed=1
    fi
  }
  warn_check() {
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then log "PASS  $name"; else log "WARN  $name"; fi
  }
  not_sudo() { ! id -nG "$POS_USER" | tr ' ' '\n' | grep -qx sudo; }
  lightdm_default() { [[ "$(cat /etc/X11/default-display-manager)" == /usr/sbin/lightdm ]] && systemctl is-enabled lightdm.service; }
  app_ready() { [[ -x "$APP_PATH" && "$(stat -c %U "$APP_PATH")" == "$POS_USER" ]]; }
  sleep_masked() { [[ "$(systemctl is-enabled sleep.target 2>/dev/null)" == masked ]]; }
  apparmor_ok() { ! aa-enabled -q 2>/dev/null || grep -qx 'goopter-smart-pos (unconfined)' /sys/kernel/security/apparmor/profiles; }
  ts_joined() { [[ "$(tailscale_state)" == Running ]]; }
  ts_ssh() { tailscale debug prefs | jq -e '.RunSSH == true'; }
  rd_id() { rustdesk --get-id | grep -Eq '^[0-9]+$'; }

  check "user $POS_USER exists" id "$POS_USER"
  check "user $POS_USER has no sudo" not_sudo
  check "LightDM is the display manager" lightdm_default
  check "kiosk session is installed" test -x "$SESSION_BIN" -a -f /usr/share/xsessions/goopter-pos.desktop
  check "auto-login is configured" grep -q "autologin-user=$POS_USER" /etc/lightdm/lightdm.conf.d/50-goopter-pos.conf
  check "login keyring exists" test -f "$POS_HOME/.local/share/keyrings/login.keyring"
  check "sleep is disabled" sleep_masked
  check "Goopter Smart POS AppImage is installed" app_ready
  check "AppArmor profile is loaded" apparmor_ok
  check "tailscaled is running" systemctl is-active tailscaled.service
  if [[ "$TAILSCALE_JOIN" == true ]]; then
    check "Tailscale is joined" ts_joined
    check "Tailscale SSH is on" ts_ssh
  else
    warn_check "Tailscale is joined" ts_joined
  fi
  check "RustDesk service is running" systemctl is-active rustdesk.service
  warn_check "RustDesk has an ID" rd_id
  warn_check "RustDesk password is set" test -e "$STATE_DIR/rustdesk-password-set"
  return $failed
}

summary() {
  local ts_name ts_ip rd
  ts_name="not joined"
  [[ "$(tailscale_state)" == Running ]] && ts_name=$(tailscale status --json | jq -r '.Self.DNSName')
  ts_ip=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  rd=$(rustdesk --get-id 2>/dev/null || true)
  log "Done. Goopter Smart POS release: $(cat "$STATE_DIR/installed-release" 2>/dev/null || echo unknown)"
  log "Tailscale: $ts_name ${ts_ip:-}"
  log "RustDesk ID: ${rd:-unknown}"
  if [[ -n "$RUSTDESK_PASSWORD" ]]; then
    printf '\nRustDesk ID: %s\nRustDesk password: %s\nRecord both in the merchant record now. The password is not shown again.\n\n' \
      "${rd:-unknown}" "$RUSTDESK_PASSWORD" >/dev/tty
  fi
  log "Reboot to start the kiosk: sudo reboot"
}

main() {
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'on_error $LINENO' ERR
  trap cleanup EXIT
  printf '\n===== %s =====\n' "$(date -Is)"
  log "Goopter Smart POS provisioning started"
  preflight
  install_packages
  configure_user
  configure_display
  configure_keyring
  disable_sleep
  install_app
  configure_apparmor
  prefill_store
  install_tailscale
  install_rustdesk
  if validate; then
    date -Is >"$STATE_DIR/provisioned"
    summary
  else
    fail "validation failed, see the FAIL lines above and $LOG_FILE"
  fi
}

main "$@"
