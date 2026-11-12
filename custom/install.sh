#!/usr/bin/env bash
# Installs or updates the custom-metrics build of Beszel under /opt on a
# systemd Linux host. Run as root from the directory that holds the binaries
# made by custom/build.sh (beszel_linux_<arch>, beszel-agent_linux_<arch>).
#
#   install.sh hub   [--port 8090] [--bin PATH]
#   install.sh agent [--key KEY] [--token TOKEN] [--hub-url URL] [--port 45876] [--bin PATH]
#   install.sh all   [agent options]     # hub + agent on this host
#
# A fresh agent install needs the hub's public key: --key, or, when the hub
# is installed on this host, it is read from the hub's data directory.
# On an existing install, only the given options are changed in the unit.
# The binaries are built with no_self_update, so the upstream daily updater
# (which would replace this build with vanilla Beszel) is switched off.
set -euo pipefail

HUB_DIR=/opt/beszel
HUB_KEY=$HUB_DIR/beszel_data/id_ed25519
AGENT_DIR=/opt/beszel-agent
AGENT_DATA=/var/lib/beszel-agent
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# hub_pubkey prints the public key of the hub on this host. The hub writes
# its key pair on first start, so wait a little for it.
hub_pubkey() {
  local i
  [ -x "$HUB_DIR/beszel" ] || return 1 # no hub on this host
  for i in $(seq 1 15); do
    [ -f "$HUB_KEY" ] && break
    sleep 1
  done
  [ -f "$HUB_KEY" ] || return 1
  command -v ssh-keygen >/dev/null 2>&1 ||
    die "ssh-keygen not found (apt install openssh-client) or pass --key"
  ssh-keygen -y -f "$HUB_KEY"
}

detect_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) echo amd64 ;;
  aarch64 | arm64) echo arm64 ;;
  armv7l | armv6l) echo arm ;;
  *) die "unsupported architecture $(uname -m)" ;;
  esac
}

ensure_user() {
  if ! id beszel >/dev/null 2>&1; then
    info "Creating system user beszel"
    useradd --system --home-dir /nonexistent --shell /bin/false beszel
  fi
}

# install_binary SRC DEST: atomic replace, keeping the previous one as DEST.bak.
install_binary() {
  local src=$1 dest=$2 tmp
  [ -f "$src" ] || die "binary not found: $src"
  "$src" -v >/dev/null 2>&1 ||
    die "$src does not run on this host (wrong architecture?)"
  mkdir -p "$(dirname "$dest")"
  [ -f "$dest" ] && cp -p "$dest" "$dest.bak"
  tmp=$(mktemp "$dest.XXXXXX")
  install -m 755 "$src" "$tmp"
  mv -f "$tmp" "$dest"
  info "Installed $dest ($("$dest" -v 2>/dev/null || true))"
}

# disable_updater NAME: turn off the upstream daily updater for beszel-NAME.
disable_updater() {
  local name=$1
  if [ -f "/etc/systemd/system/beszel-$name-update.timer" ]; then
    info "Disabling beszel-$name-update.timer (would install vanilla Beszel)"
    systemctl disable --now "beszel-$name-update.timer" >/dev/null 2>&1 || true
  fi
  # cron ignores files in /etc/cron.d whose names contain a dot
  if [ -f "/etc/cron.d/beszel-$name" ]; then
    info "Disabling /etc/cron.d/beszel-$name"
    mv -f "/etc/cron.d/beszel-$name" "/etc/cron.d/beszel-$name.disabled"
  fi
}

# set_env UNIT NAME VALUE: set or add Environment="NAME=VALUE" in a unit file.
set_env() {
  local unit=$1 name=$2 value=$3 esc
  esc=$(printf '%s' "$value" | sed 's/[\\|&]/\\&/g')
  if grep -q "^Environment=\"$name=" "$unit"; then
    sed -i "s|^Environment=\"$name=.*\"|Environment=\"$name=$esc\"|" "$unit"
  else
    sed -i "/^\[Service\]/a Environment=\"$name=$esc\"" "$unit"
  fi
}

restart_and_check() {
  local svc=$1
  systemctl daemon-reload
  systemctl enable --quiet "$svc"
  systemctl restart "$svc"
  sleep 2
  if [ "$(systemctl is-active "$svc")" != active ]; then
    systemctl status --no-pager "$svc" || true
    die "$svc is not running; see journalctl -u $svc"
  fi
  info "$svc is running"
}

install_hub() {
  local port=8090 port_set=false bin="" unit=/etc/systemd/system/beszel-hub.service
  while [ $# -gt 0 ]; do
    case "$1" in
    --port) port=$2; port_set=true; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option for hub: $1" ;;
    esac
  done
  bin=${bin:-$SCRIPT_DIR/beszel_linux_$(detect_arch)}

  ensure_user
  disable_updater hub
  systemctl stop beszel-hub.service >/dev/null 2>&1 || true
  install_binary "$bin" "$HUB_DIR/beszel"
  chown -R beszel:beszel "$HUB_DIR"

  if [ ! -f "$unit" ]; then
    info "Creating $unit"
    cat >"$unit" <<EOF
[Unit]
Description=Beszel Hub Service
After=network.target

[Service]
ExecStart=$HUB_DIR/beszel serve --http "0.0.0.0:$port"
WorkingDirectory=$HUB_DIR
User=beszel
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  elif $port_set; then
    sed -i "s|--http \"[^\"]*\"|--http \"0.0.0.0:$port\"|" "$unit"
  fi
  restart_and_check beszel-hub.service
  local key
  if key=$(hub_pubkey); then
    info "Hub public key (KEY for agents):"
    echo "    $key"
  fi
}

install_agent() {
  local port="" key="" token="" hub_url="" bin="" unit=/etc/systemd/system/beszel-agent.service
  while [ $# -gt 0 ]; do
    case "$1" in
    -p | --port) port=$2; shift 2 ;;
    -k | --key) key=$2; shift 2 ;;
    -t | --token) token=$2; shift 2 ;;
    -u | --hub-url) hub_url=$2; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option for agent: $1" ;;
    esac
  done
  bin=${bin:-$SCRIPT_DIR/beszel-agent_linux_$(detect_arch)}
  if [ ! -f "$unit" ] && [ -z "$key" ]; then
    key=$(hub_pubkey) || die "fresh agent install needs --key (the hub's public key)"
    info "Using the public key of the hub on this host"
  fi

  ensure_user
  for group in docker disk systemd-journal; do
    getent group "$group" >/dev/null 2>&1 && usermod -aG "$group" beszel
  done
  disable_updater agent
  systemctl stop beszel-agent.service >/dev/null 2>&1 || true
  install_binary "$bin" "$AGENT_DIR/beszel-agent"

  if [ ! -f "$unit" ]; then
    info "Creating $unit"
    cat >"$unit" <<EOF
[Unit]
Description=Beszel Agent Service
Wants=network-online.target
After=network-online.target

[Service]
Environment="PORT=${port:-45876}"
Environment="KEY=$key"
Environment="TOKEN=$token"
Environment="HUB_URL=$hub_url"
ExecStart=$AGENT_DIR/beszel-agent
User=beszel
SupplementaryGroups=systemd-journal
Restart=on-failure
RestartSec=5
StateDirectory=beszel-agent

# Security/sandboxing settings. PrivateTmp hides /tmp from the agent:
# keep custom metric .prom files out of /tmp.
KeyringMode=private
LockPersonality=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
PrivateTmp=yes
RemoveIPC=yes
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
    getent group systemd-journal >/dev/null 2>&1 || sed -i '/^SupplementaryGroups=/d' "$unit"
  else
    [ -n "$port" ] && set_env "$unit" PORT "$port"
    [ -n "$key" ] && set_env "$unit" KEY "$key"
    [ -n "$token" ] && set_env "$unit" TOKEN "$token"
    [ -n "$hub_url" ] && set_env "$unit" HUB_URL "$hub_url"
  fi

  # Custom metrics: a directory for producers and a starter config.
  mkdir -p "$AGENT_DATA/metrics"
  chmod 755 "$AGENT_DATA/metrics"
  if [ ! -f "$AGENT_DATA/config.yml" ]; then
    info "Creating $AGENT_DATA/config.yml"
    cat >"$AGENT_DATA/config.yml" <<EOF
# Custom metrics: the agent reads *.prom files (Prometheus text format).
# Producers write a temp file not ending in .prom, then rename it over the
# real one, and rewrite it every cycle (samples older than max_age are dropped).
metrics:
  # max_series: 64
  # max_age: 2m
  # counters: rate
  sources:
    - path: $AGENT_DATA/metrics
      # include: ["myapp_*"]
      # chart: {title: "My metrics", description: "..."}
EOF
    chmod 644 "$AGENT_DATA/config.yml"
  fi
  restart_and_check beszel-agent.service
  if journalctl -u beszel-agent.service --since "-1min" 2>/dev/null | grep -q "Custom metrics config loaded"; then
    info "Custom metrics config loaded"
  fi
}

[ $# -ge 1 ] || usage 1
case "$1" in -h | --help | help) usage ;; esac
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

cmd=$1
shift
case "$cmd" in
hub) install_hub "$@" ;;
agent) install_agent "$@" ;;
all)
  install_hub
  install_agent "$@"
  info "In the hub UI, add this system with host localhost and the agent port (default 45876)"
  ;;
-h | --help | help) usage ;;
*) usage 1 ;;
esac
