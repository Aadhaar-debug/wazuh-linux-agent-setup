#!/usr/bin/env bash
#
# install-wazuh-agent.sh — install, enroll and configure a Wazuh agent on Linux
#
# Supports Debian/Ubuntu/Raspberry Pi OS (apt) and RHEL/CentOS/Rocky/Alma/Fedora/Amazon Linux (dnf/yum).
# Works on amd64/x86_64 and arm64/aarch64 (e.g. Raspberry Pi 3/4/5 running a 64-bit OS).
#
# Usage:
#   sudo ./install-wazuh-agent.sh -m <manager-ip> [-n <agent-name>] [-g <group>] [-v <version>] [-p <enroll-password>]
#
# Example:
#   sudo ./install-wazuh-agent.sh -m 192.168.1.50 -n Raspberry-pi -g default -v 4.14.9
#
set -euo pipefail

MANAGER=""
AGENT_NAME="$(hostname)"
GROUP="default"
VERSION=""          # empty = latest 4.x. Must be <= your manager's version.
ENROLL_PASS=""      # only needed if the manager uses password-based enrollment
SCA_INTERVAL="12h"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "m:n:g:v:p:i:h" opt; do
  case "$opt" in
    m) MANAGER="$OPTARG" ;;
    n) AGENT_NAME="$OPTARG" ;;
    g) GROUP="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    p) ENROLL_PASS="$OPTARG" ;;
    i) SCA_INTERVAL="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -n "$MANAGER" ] || { echo "ERROR: -m <manager-ip> is required"; usage; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)"; exit 1; }

# The Wazuh manager only accepts agent names made of letters, digits, '.', '-' and '_'
# (no spaces), 2-128 characters long.
if ! [[ "$AGENT_NAME" =~ ^[A-Za-z0-9._-]{2,128}$ ]]; then
  echo "ERROR: invalid agent name '$AGENT_NAME'. Use only letters, digits, '.', '-', '_' (no spaces)."
  echo "       e.g. '${AGENT_NAME// /-}'"
  exit 1
fi
[[ "$GROUP" =~ ^[A-Za-z0-9._,-]+$ ]] || { echo "ERROR: invalid group '$GROUP'"; exit 1; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
OSSEC=/var/ossec
CONF=$OSSEC/etc/ossec.conf

# ---------------------------------------------------------------------------
log "1/6 Pre-flight: checking connectivity to manager $MANAGER"
for port in 1514 1515; do
  if timeout 5 bash -c "</dev/tcp/$MANAGER/$port" 2>/dev/null; then
    echo "  port $port reachable"
  else
    echo "  ERROR: cannot reach $MANAGER:$port."
    echo "  Fix networking first (firewall, VM in NAT mode instead of bridged, wrong IP)."
    exit 1
  fi
done

if command -v dpkg >/dev/null && dpkg -l wazuh-manager 2>/dev/null | grep -q '^[ih]i'; then
  echo "  ERROR: wazuh-manager is installed on this host. It conflicts with wazuh-agent."
  echo "  See docs/troubleshooting.md -> 'wazuh-manager already installed'."
  exit 1
fi

# ---------------------------------------------------------------------------
log "2/6 Adding the Wazuh package repository and installing wazuh-agent ${VERSION:-latest}"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl gnupg apt-transport-https >/dev/null
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import >/dev/null 2>&1
  chmod 644 /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
  apt-get update -qq
  apt-mark unhold wazuh-agent >/dev/null 2>&1 || true
  if [ -n "$VERSION" ]; then apt-get install -y wazuh-agent="${VERSION}-1"; else apt-get install -y wazuh-agent; fi
  apt-mark hold wazuh-agent    # stop apt upgrades from moving the agent past the manager version
elif command -v dnf >/dev/null || command -v yum >/dev/null; then
  PM=$(command -v dnf || command -v yum)
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  cat > /etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF
  if [ -n "$VERSION" ]; then "$PM" install -y "wazuh-agent-${VERSION}-1"; else "$PM" install -y wazuh-agent; fi
  # keep the agent from being upgraded past the manager
  grep -q '^exclude=wazuh-agent' /etc/yum.repos.d/wazuh.repo || echo 'exclude=wazuh-agent' >> /etc/yum.repos.d/wazuh.repo
else
  echo "ERROR: unsupported package manager (need apt, dnf or yum)"; exit 1
fi

# ---------------------------------------------------------------------------
log "3/6 Configuring $CONF (manager address, enrollment name/group)"
cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"

EXTRA_LINES=""
if [ -n "$ENROLL_PASS" ]; then
  echo "$ENROLL_PASS" > $OSSEC/etc/authd.pass
  chmod 640 $OSSEC/etc/authd.pass; chown root:wazuh $OSSEC/etc/authd.pass
  EXTRA_LINES=$'\n'"      <authorization_pass_path>etc/authd.pass</authorization_pass_path>"
fi

# Keep the OS-specific config profile the package generated (e.g. "debian, debian13")
PROFILE=$(grep -m1 -oP '<config-profile>\K[^<]+' "$CONF" 2>/dev/null || true)
PROFILE_LINE=""
[ -n "$PROFILE" ] && PROFILE_LINE=$'\n'"    <config-profile>${PROFILE}</config-profile>"

XML_NAME="$AGENT_NAME"

CLIENT_BLOCK=$(cat <<EOF
  <client>
    <server>
      <address>${MANAGER}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>${MANAGER}</manager_address>
      <port>1515</port>
      <agent_name>${XML_NAME}</agent_name>
      <groups>${GROUP}</groups>${EXTRA_LINES}
    </enrollment>${PROFILE_LINE}
    <notify_time>20</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <crypto_method>aes</crypto_method>
  </client>
EOF
)

# ---------------------------------------------------------------------------
log "4/6 Enabling Security Configuration Assessment (SCA)"
# Pick the CIS policy files shipped for this OS (e.g. cis_debian13.yml). If none match,
# SCA still runs every policy found in ruleset/sca automatically.
POLICIES=""
for f in $OSSEC/ruleset/sca/*.yml; do
  [ -e "$f" ] || continue
  POLICIES+="      <policy enabled=\"yes\">ruleset/sca/$(basename "$f")</policy>"$'\n'
done

SCA_BLOCK=$(cat <<EOF
  <sca>
    <enabled>yes</enabled>
    <scan_on_start>yes</scan_on_start>
    <interval>${SCA_INTERVAL}</interval>
    <skip_nfs>yes</skip_nfs>
    <policies>
${POLICIES%$'\n'}
    </policies>
  </sca>
EOF
)

# Replace the first <client> and <sca> blocks in place (perl handles multi-line safely).
CLIENT_BLOCK="$CLIENT_BLOCK" SCA_BLOCK="$SCA_BLOCK" perl -0pi -e '
  s{^[ \t]*<client>.*?</client>[ \t]*}{$ENV{CLIENT_BLOCK}}sm;
  if (m{<sca>}) { s{^[ \t]*<sca>.*?</sca>[ \t]*}{$ENV{SCA_BLOCK}}sm }
  else          { s{(</ossec_config>)}{$ENV{SCA_BLOCK}\n\n$1}s }
' "$CONF"

# Sanity-check the blocks we wrote. (Don't run a strict XML parser over the whole file:
# Wazuh's own default <command> entries contain raw '&&', which Wazuh accepts but xmllint rejects.)
for tag in client enrollment sca policies; do
  [ "$(grep -c "<$tag>" "$CONF")" -ge 1 ] && [ "$(grep -c "</$tag>" "$CONF")" -ge 1 ] \
    || { echo "  ERROR: <$tag> block missing after edit; restoring backup"; cp -a "$(ls -t $CONF.bak.* | head -1)" "$CONF"; exit 1; }
done
echo "  <client>, <enrollment> and <sca> blocks written"

# ---------------------------------------------------------------------------
log "5/6 Enabling and starting wazuh-agent"
systemctl daemon-reload
systemctl enable wazuh-agent >/dev/null 2>&1
systemctl restart wazuh-agent

# ---------------------------------------------------------------------------
log "6/6 Verifying"
for _ in $(seq 1 30); do
  STATE=$(grep -oP "^status='\K[^']+" $OSSEC/var/run/wazuh-agentd.state 2>/dev/null || true)
  [ "$STATE" = "connected" ] && break
  sleep 2
done
echo "  agentd status : ${STATE:-unknown}"
echo "  client.keys   : $(cut -d' ' -f1,2 $OSSEC/etc/client.keys 2>/dev/null || echo 'not enrolled')"
grep -E "sca:|wazuh-modulesd:sca" $OSSEC/logs/ossec.log | tail -3 || true

if [ "${STATE:-}" = "connected" ]; then
  echo -e "\n\033[1;32mDone. Agent '$AGENT_NAME' is connected to $MANAGER in group '$GROUP'.\033[0m"
else
  echo -e "\n\033[1;33mAgent installed but not connected yet. Check: tail -f $OSSEC/logs/ossec.log\033[0m"
  exit 2
fi
