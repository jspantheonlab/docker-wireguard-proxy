#!/bin/bash
# Office AI-proxy automation for macOS and Linux (Windows: install.ps1).
#
# Installs:
#   - gost: local proxy on 127.0.0.1:1080 (HTTP + SOCKS5), always running.
#     On the office network, hosts from the office PAC go through the office
#     proxy and everything else is direct. Elsewhere, everything is direct
#     and the office proxy is never contacted.
#   - proxy-auto: watcher that switches gost between those two modes
#     (refreshing its host list from the PAC). If present, it also sets the
#     proxy env in ~/.claude/settings.json and, on macOS, switches the
#     "office local" network location.
#     macOS: launchd agent, runs on every network change.
#     Linux: systemd user service, checks every 15s.
#
# Served by the proxy container's nginx, which fills in PAC_URL. Usage:
#   curl -fsSL http://<server>:<pac port>/install.sh | bash                install or update
#   curl -fsSL http://<server>:<pac port>/install.sh | bash -s uninstall   remove everything
# Running a local copy needs PAC_URL set:
#   PAC_URL=http://<server>:<pac port>/proxy.pac bash client/install.sh
#
# The proxy host/port and host list come from the PAC. Overrides (env vars):
#   PROXY_HOST, PROXY_PORT, OFFICE_NET (IP prefix that counts as "office";
#   default: first three octets of PROXY_HOST), LISTEN, GOST_VERSION

# Braces make bash read the whole script before running any of it, so
# commands that read stdin can't swallow the rest of a piped script.
{
set -eu

PAC_URL=${PAC_URL:-__PAC_URL__}
LISTEN=${LISTEN:-127.0.0.1:1080}
LOC_ON=${LOC_ON:-office local}
LOC_OFF=${LOC_OFF:-Automatic}
GOST_VERSION=${GOST_VERSION:-3.3.1}           # used when downloading gost

OS=$(uname -s)
BIN=$HOME/.local/bin
CONF=$HOME/.config/proxy-auto
case $OS in
  Darwin)
    LOGS=$HOME/Library/Logs
    AGENTS=$HOME/Library/LaunchAgents
    DOMAIN=gui/$(id -u)
    AUTO_LABEL=ai.aidol.proxy-auto
    GOST_LABEL=ai.aidol.gost ;;
  Linux)
    LOGS=${XDG_STATE_HOME:-$HOME/.local/state}/proxy-auto
    UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user ;;
  *) echo "Unsupported OS: $OS (use install.ps1 on Windows)" >&2; exit 1 ;;
esac

say() { printf '==> %s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

uninstall() {
  if [ "$OS" = Darwin ]; then
    launchctl bootout "$DOMAIN/$AUTO_LABEL" 2>/dev/null || true
    launchctl bootout "$DOMAIN/$GOST_LABEL" 2>/dev/null || true
    rm -f "$AGENTS/$AUTO_LABEL.plist" "$AGENTS/$GOST_LABEL.plist"
  else
    systemctl --user disable --now proxy-auto.service proxy-auto-gost.service 2>/dev/null || true
    rm -f "$UNITS/proxy-auto.service" "$UNITS/proxy-auto-gost.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  rm -f "$BIN/proxy-auto"
  rm -rf "$CONF"
  say "Removed proxy-auto. gost itself was left installed."
}

is_gost3() { [ -x "$1" ] && "$1" -V 2>/dev/null | grep -q '^gost 3'; }

# Sets GOST to a gost v3 binary: existing one, Homebrew, or a release download.
install_gost() {
  local g arch os url tmp
  for g in "$BIN/gost" "$(command -v gost || true)"; do
    if [ -n "$g" ] && is_gost3 "$g"; then GOST=$g; return; fi
  done
  if [ "$OS" = Darwin ] && command -v brew >/dev/null; then
    say "Installing gost (Homebrew)"
    brew install gost
    GOST=$(brew --prefix)/bin/gost
    return
  fi
  case $(uname -m) in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "No gost build for $(uname -m); install gost v3 manually and re-run." ;;
  esac
  os=$(echo "$OS" | tr '[:upper:]' '[:lower:]')
  url=https://github.com/go-gost/gost/releases/download/v$GOST_VERSION/gost_${GOST_VERSION}_${os}_${arch}.tar.gz
  say "Downloading gost $GOST_VERSION"
  tmp=$(mktemp -d)
  curl -fsSL "$url" | tar -xz -C "$tmp" gost || { rm -rf "$tmp"; die "Download failed: $url"; }
  install -m 755 "$tmp/gost" "$BIN/gost"
  rm -rf "$tmp"
  GOST=$BIN/gost
}

if [ "${1:-}" = uninstall ]; then
  uninstall
  exit 0
fi

command -v curl >/dev/null || die "curl is required"
case $PAC_URL in
  http://*|https://*) ;;
  *) die "Set PAC_URL, e.g. PAC_URL=http://192.168.50.200:44081/proxy.pac bash install.sh" ;;
esac
PAC=$(curl -fsS -m 10 --noproxy '*' "$PAC_URL") ||
  die "Can't fetch $PAC_URL. Run this on the office network."
# PAC line: var PROXY = "PROXY host:port";
# PAC_PROXY is what the office PAC names; proxy-auto checks for it to tell
# the real office network from a lookalike.
PAC_PROXY=$(printf '%s\n' "$PAC" | sed -n 's/.*"PROXY \([^:"]*:[0-9]*\)".*/\1/p' | head -1)
[ -n "$PAC_PROXY" ] || die "Couldn't find 'PROXY host:port' in $PAC_URL"
PROXY_HOST=${PROXY_HOST:-${PAC_PROXY%:*}}
PROXY_PORT=${PROXY_PORT:-${PAC_PROXY##*:}}
OFFICE_NET=${OFFICE_NET:-${PROXY_HOST%.*}.}
say "Office proxy: $PROXY_HOST:$PROXY_PORT (office network: $OFFICE_NET*)"

if [ "$OS" = Linux ]; then
  command -v ip >/dev/null || die "iproute2 ('ip' command) is required"
  # Shells without a login session (some SSH/sudo setups) lack this.
  if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
  fi
  systemctl --user show-environment >/dev/null 2>&1 ||
    die "A systemd user session is required (systemctl --user). On a headless machine, run
  sudo loginctl enable-linger $USER
then log in again and re-run this script."
fi

mkdir -p "$BIN" "$CONF" "$LOGS"
install_gost
if ! command -v jq >/dev/null; then
  if [ "$OS" = Darwin ] && command -v brew >/dev/null; then
    brew install jq
  else
    say "jq not found: Claude Code settings won't be updated (install jq and re-run to enable)"
  fi
fi

say "Writing config to $CONF"
cat > "$CONF/config" <<EOF
PROXY_HOST="$PROXY_HOST"
PROXY_PORT="$PROXY_PORT"
PAC_PROXY="$PAC_PROXY"
PAC_URL="$PAC_URL"
OFFICE_NET="$OFFICE_NET"
LOC_ON="$LOC_ON"
LOC_OFF="$LOC_OFF"
LOG="$LOGS/proxy-auto.log"
EOF

# gost runs gost.yaml, which proxy-auto keeps as a copy of one of these.
cat > "$CONF/gost-office.yaml" <<EOF
# Generated by proxy-auto install.sh. Office mode: hosts in hosts.txt go
# through the office proxy; everything else connects directly.
services:
- name: local
  addr: $LISTEN
  handler: { type: auto, chain: office }
  listener: { type: tcp }
chains:
- name: office
  hops:
  - name: hop-0
    bypass: office-hosts
    nodes:
    - name: office-proxy
      addr: $PROXY_HOST:$PROXY_PORT
      connector: { type: http }
      dialer: { type: tcp }
bypasses:
- name: office-hosts
  whitelist: true
  reload: 60s
  file:
    path: $CONF/hosts.txt
EOF

cat > "$CONF/gost-direct.yaml" <<EOF
# Generated by proxy-auto install.sh. Direct mode (off the office network):
# everything connects directly.
services:
- name: local
  addr: $LISTEN
  handler: { type: auto }
  listener: { type: tcp }
EOF
# Start direct; proxy-auto switches to office mode if we're there.
cp "$CONF/gost-direct.yaml" "$CONF/gost.yaml"
rm -f "$CONF/ai.aidol.gost.plist"   # from older macOS versions

say "Installing $BIN/proxy-auto"
cat > "$BIN/proxy-auto" <<'SCRIPT'
#!/bin/bash
# Toggle the office AI proxy setup (macOS + Linux). Installed by
# proxy-auto install.sh.
# On (office) when this machine's IP starts with $OFFICE_NET, the PAC at
# $PAC_URL names $PAC_PROXY, AND the proxy port is reachable:
#   - gost: switch between office mode (PAC hosts via the office proxy) and
#     direct mode; refresh its hosts from the PAC
#   - Claude Code: add/remove proxy env in ~/.claude/settings.json (if present)
#   - macOS: switch network location to $LOC_ON (only if it exists)
#
#   proxy-auto                 check once (macOS launchd runs this on network change)
#   proxy-auto watch           check every 15s (Linux systemd service)
#   proxy-auto refresh-hosts   re-sync the host list from the PAC

CONF=$HOME/.config/proxy-auto
. "$CONF/config"
HOSTS=$CONF/hosts.txt
SETTINGS=$HOME/.claude/settings.json
OS=$(uname -s)
PATH=/usr/sbin:/usr/bin:/bin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# PAC HOST_PATTERNS_STR -> one gost matcher per line ("*.x" -> ".x", which
# gost treats as x and all its subdomains, same as the PAC).
refresh_hosts() {
  local tmp
  tmp=$(mktemp "$HOSTS.XXXXXX") || return 1
  curl -fsS -m 5 --noproxy '*' "$PAC_URL" 2>/dev/null |
    sed -n 's/.*HOST_PATTERNS_STR *= *"\([^"]*\)".*/\1/p' |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^\*\./\./' |
    grep -v '^$' | sort -u > "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"; log "hosts: could not read $PAC_URL, keeping current list"; return 1
  fi
  if cmp -s "$tmp" "$HOSTS"; then
    rm -f "$tmp"; touch "$HOSTS"
  else
    mv "$tmp" "$HOSTS" && log "hosts: updated from PAC ($(wc -l < "$HOSTS" | tr -d ' ') entries)"
  fi
}

local_ip() {
  if [ "$OS" = Darwin ]; then
    local ifc
    ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$ifc" ] && ipconfig getifaddr "$ifc" 2>/dev/null
  else
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'
  fi
}

# Only the office PAC server serves a PAC naming our proxy; a lookalike
# network on the same subnet (e.g. a home router) won't. A few tries, since
# this can run while a new network is still coming up.
office_pac() {
  local i
  for i in 1 2 3; do
    curl -fsS -m 3 --noproxy '*' "$PAC_URL" 2>/dev/null |
      grep -qF "\"PROXY $PAC_PROXY\"" && return 0
    [ $i = 3 ] || sleep 1
  done
  return 1
}

reachable() {
  if [ "$OS" = Darwin ]; then
    nc -z -G 1 "$PROXY_HOST" "$PROXY_PORT" 2>/dev/null
  else
    timeout 2 bash -c "exec 3<>/dev/tcp/$PROXY_HOST/$PROXY_PORT" 2>/dev/null
  fi
}

# 0 = on, 1 = off, 2 = no IP yet (leave things alone; avoids flapping
# when a location switch briefly drops the address)
proxy_wanted() {
  local ip i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ip=$(local_ip)
    [ -n "$ip" ] && break
    sleep 1
  done
  [ -z "$ip" ] && return 2
  case $ip in "$OFFICE_NET"*) office_pac && reachable ;; *) return 1 ;; esac
}

set_system() {  # $1 = on|off (macOS only)
  [ "$OS" = Darwin ] || return 0
  scselect 2>/dev/null | grep -qF "($LOC_ON)" || return 0
  local want cur
  if [ "$1" = on ]; then want=$LOC_ON; else want=$LOC_OFF; fi
  cur=$(scselect 2>/dev/null | awk -F'[()]' '/^ \*/{print $2}')
  [ "$cur" = "$want" ] && return 0
  if scselect "$want" >/dev/null 2>&1; then
    log "system: location $cur -> $want"
  else
    log "system: FAILED to switch location to $want"
  fi
}

set_claude() {  # $1 = on|off
  [ -f "$SETTINGS" ] && command -v jq >/dev/null || return 0
  local p="http://$PROXY_HOST:$PROXY_PORT" filter tmp
  if [ "$1" = on ]; then
    filter='.env = ((.env // {}) + {HTTP_PROXY: $p, HTTPS_PROXY: $p, NO_PROXY: "localhost,127.0.0.1,::1,.local"})'
  else
    filter='del(.env.HTTP_PROXY, .env.HTTPS_PROXY, .env.NO_PROXY) | if .env == {} then del(.env) else . end'
  fi
  tmp=$(mktemp "$SETTINGS.XXXXXX") || return 1
  if jq --indent 2 --arg p "$p" "$filter" "$SETTINGS" > "$tmp" && jq empty "$tmp" 2>/dev/null; then
    if cmp -s "$tmp" "$SETTINGS"; then
      rm -f "$tmp"
    else
      mv "$tmp" "$SETTINGS" && log "claude settings: proxy $1"
    fi
  else
    rm -f "$tmp"; log "claude settings: FAILED to set proxy $1"
  fi
}

gost_restart() {
  if [ "$OS" = Darwin ]; then
    # Not loaded (e.g. mid-install): it reads gost.yaml when it starts.
    launchctl print "gui/$(id -u)/ai.aidol.gost" >/dev/null 2>&1 || return 0
    launchctl kickstart -k "gui/$(id -u)/ai.aidol.gost"
  else
    systemctl --user restart proxy-auto-gost.service
  fi
}

# gost always runs so 127.0.0.1:1080 keeps working everywhere; only its
# config changes. It's restarted only when the mode actually changes.
set_gost() {  # $1 = on|off
  local mode=direct
  if [ "$1" = on ]; then
    mode=office
    # Re-sync hosts on entering the office and at least hourly while there.
    if ! cmp -s "$CONF/gost-office.yaml" "$CONF/gost.yaml" ||
       [ -z "$(find "$HOSTS" -mmin -60 2>/dev/null)" ]; then
      refresh_hosts
    fi
  fi
  cmp -s "$CONF/gost-$mode.yaml" "$CONF/gost.yaml" && return 0
  cp "$CONF/gost-$mode.yaml" "$CONF/gost.yaml"
  if gost_restart >/dev/null 2>&1; then
    log "gost: $mode mode"
  else
    log "gost: FAILED to restart in $mode mode"
  fi
}

check() {
  local state
  proxy_wanted
  case $? in
    0) state=on ;;
    1) state=off ;;
    *) return 0 ;;
  esac
  set_system $state
  set_claude $state
  set_gost $state
}

case ${1:-check} in
  refresh-hosts) refresh_hosts ;;
  watch) while :; do check; sleep 15; done ;;
  *) check ;;
esac
SCRIPT
chmod +x "$BIN/proxy-auto"

say "Fetching host list from $PAC_URL"
"$BIN/proxy-auto" refresh-hosts || die "No host list found in $PAC_URL"

say "Installing background services"
if [ "$OS" = Darwin ]; then
  mkdir -p "$AGENTS"
  cat > "$AGENTS/$GOST_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$GOST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$GOST</string>
    <string>-C</string>
    <string>$CONF/gost.yaml</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>$LOGS/gost.log</string>
</dict>
</plist>
EOF
  cat > "$AGENTS/$AUTO_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AUTO_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN/proxy-auto</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!-- Also re-check every 5 min, in case a check failed mid network change. -->
  <key>StartInterval</key>
  <integer>300</integer>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
EOF
  # Restart both so an update picks up new config. Pick the mode while gost
  # is stopped, so it starts once in the right mode (launchd delays a quick
  # second restart by ~10s).
  launchctl bootout "$DOMAIN/$GOST_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$AUTO_LABEL" 2>/dev/null || true
  "$BIN/proxy-auto" || true
  launchctl bootstrap "$DOMAIN" "$AGENTS/$GOST_LABEL.plist"
  launchctl bootstrap "$DOMAIN" "$AGENTS/$AUTO_LABEL.plist"
  LOG_HINT="$LOGS/proxy-auto.log, $LOGS/gost.log"
else
  mkdir -p "$UNITS"
  cat > "$UNITS/proxy-auto-gost.service" <<EOF
[Unit]
Description=gost local proxy (mode switched by proxy-auto)

[Service]
ExecStart=$GOST -C $CONF/gost.yaml
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  cat > "$UNITS/proxy-auto.service" <<EOF
[Unit]
Description=Switch gost between office and direct mode

[Service]
ExecStart=$BIN/proxy-auto watch
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable proxy-auto-gost.service proxy-auto.service >/dev/null 2>&1
  systemctl --user restart proxy-auto-gost.service
  systemctl --user restart proxy-auto.service
  LOG_HINT="$LOGS/proxy-auto.log, journalctl --user -u proxy-auto-gost"
fi

sleep 3
if cmp -s "$CONF/gost-office.yaml" "$CONF/gost.yaml"; then
  say "Done. gost is running on $LISTEN in office mode (PAC hosts via $PROXY_HOST:$PROXY_PORT)."
else
  say "Done. gost is running on $LISTEN in direct mode (not on the office network)."
fi
echo "    Use http://$LISTEN or socks5h://$LISTEN in your apps."
echo "    Logs: $LOG_HINT"
exit 0
}
