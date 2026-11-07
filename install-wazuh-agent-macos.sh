#!/bin/bash
#
# install-wazuh-agent-macos.sh — install (or repoint), enroll and configure a Wazuh agent on macOS
#
# Works on Apple silicon (arm64) and Intel Macs. If the agent is already installed it is kept
# and only reconfigured, e.g. after the manager's IP changed.
#
# Usage:
#   sudo ./install-wazuh-agent-macos.sh -m <manager-ip> [-n <agent-name>] [-g <group>] [-v <version>]
#
# Example:
#   sudo ./install-wazuh-agent-macos.sh -m 192.168.1.50 -n tweakMacOS -g default -v 4.14.9
#
set -euo pipefail

MANAGER=""
AGENT_NAME=""       # empty = keep the name already registered in client.keys, else LocalHostName
GROUP="default"
VERSION="4.14.9"    # must be <= the manager version
SCA_INTERVAL="12h"
OSSEC=/Library/Ossec
CONF=$OSSEC/etc/ossec.conf

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
while getopts "m:n:g:v:i:h" opt; do
  case "$opt" in
    m) MANAGER="$OPTARG" ;; n) AGENT_NAME="$OPTARG" ;; g) GROUP="$OPTARG" ;;
    v) VERSION="$OPTARG" ;; i) SCA_INTERVAL="$OPTARG" ;; *) usage ;;
  esac
done
[ -n "$MANAGER" ] || { echo "ERROR: -m <manager-ip> is required"; usage; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo"; exit 1; }
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
log "1/6 Pre-flight: checking connectivity to manager $MANAGER"
for port in 1514 1515; do
  nc -z -G 5 "$MANAGER" "$port" >/dev/null 2>&1 && echo "  port $port reachable" \
    || { echo "  ERROR: cannot reach $MANAGER:$port (firewall? manager VM in NAT mode?)"; exit 1; }
done

# ---------------------------------------------------------------------------
log "2/6 Installing wazuh-agent $VERSION (skipped if already installed)"
if pkgutil --pkg-info com.wazuh.pkg.wazuh-agent >/dev/null 2>&1; then
  echo "  already installed: $(pkgutil --pkg-info com.wazuh.pkg.wazuh-agent | awk '/version/{print $2}')"
else
  ARCH=$( [ "$(uname -m)" = "arm64" ] && echo arm64 || echo intel64 )
  PKG="/tmp/wazuh-agent-${VERSION}-1.${ARCH}.pkg"
  curl -fsSL -o "$PKG" "https://packages.wazuh.com/4.x/macos/wazuh-agent-${VERSION}-1.${ARCH}.pkg"
  installer -pkg "$PKG" -target /
  rm -f "$PKG"
fi

# ---------------------------------------------------------------------------
log "3/6 Configuring $CONF (manager address, enrollment name/group)"
if [ -z "$AGENT_NAME" ]; then
  AGENT_NAME=$(awk 'NR==1{print $2}' $OSSEC/etc/client.keys 2>/dev/null || true)
  [ -n "$AGENT_NAME" ] || AGENT_NAME=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
fi
[[ "$AGENT_NAME" =~ ^[A-Za-z0-9._-]{2,128}$ ]] || { echo "ERROR: invalid agent name '$AGENT_NAME' (letters, digits, . - _ only)"; exit 1; }
echo "  agent name: $AGENT_NAME   group: $GROUP"

cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"
PROFILE=$(sed -n 's:.*<config-profile>\(.*\)</config-profile>.*:\1:p' "$CONF" | head -1)
PROFILE_LINE=""; [ -n "$PROFILE" ] && PROFILE_LINE=$'\n'"    <config-profile>${PROFILE}</config-profile>"

CLIENT_BLOCK="  <client>
    <server>
      <address>${MANAGER}</address>
      <port>1514</port>
      <protocol>tcp</protocol>
    </server>
    <enrollment>
      <enabled>yes</enabled>
      <manager_address>${MANAGER}</manager_address>
      <port>1515</port>
      <agent_name>${AGENT_NAME}</agent_name>
      <groups>${GROUP}</groups>
    </enrollment>${PROFILE_LINE}
    <notify_time>20</notify_time>
    <time-reconnect>60</time-reconnect>
    <auto_restart>yes</auto_restart>
    <crypto_method>aes</crypto_method>
  </client>"

# ---------------------------------------------------------------------------
log "4/6 Enabling Security Configuration Assessment (SCA)"
POLICIES=""
for f in $OSSEC/ruleset/sca/cis_apple_macOS*.yml; do     # macOS CIS policies only
  [ -e "$f" ] || continue
  POLICIES+="      <policy enabled=\"yes\">ruleset/sca/$(basename "$f")</policy>"$'\n'
done
[ -n "$POLICIES" ] || echo "  WARNING: no cis_apple_macOS*.yml policy found in $OSSEC/ruleset/sca"
SCA_BLOCK="  <sca>
    <enabled>yes</enabled>
    <scan_on_start>yes</scan_on_start>
    <interval>${SCA_INTERVAL}</interval>
    <skip_nfs>yes</skip_nfs>
    <policies>
${POLICIES%$'\n'}
    </policies>
  </sca>"

CLIENT_BLOCK="$CLIENT_BLOCK" SCA_BLOCK="$SCA_BLOCK" /usr/bin/perl -0pi -e '
  s{^[ \t]*<client>.*?</client>[ \t]*}{$ENV{CLIENT_BLOCK}}sm;
  if (m{<sca>}) { s{^[ \t]*<sca>.*?</sca>[ \t]*}{$ENV{SCA_BLOCK}}sm }
  else          { s{(</ossec_config>)}{$ENV{SCA_BLOCK}\n\n$1}s }
' "$CONF"

# ---------------------------------------------------------------------------
log "5/6 Restarting the agent"
$OSSEC/bin/wazuh-control restart >/dev/null

# ---------------------------------------------------------------------------
log "6/6 Verifying"
STATE=""
for _ in $(seq 1 30); do
  STATE=$(sed -n "s/^status='\(.*\)'/\1/p" $OSSEC/var/run/wazuh-agentd.state 2>/dev/null || true)
  [ "$STATE" = "connected" ] && break
  sleep 2
done
echo "  agentd status : ${STATE:-unknown}"
echo "  client.keys   : $(awk '{print $1, $2}' $OSSEC/etc/client.keys 2>/dev/null || echo 'not enrolled')"
sleep 15
grep -E "sca: INFO: (Starting evaluation|Evaluation finished)" $OSSEC/logs/ossec.log | tail -2 || true

if [ "$STATE" = "connected" ]; then
  echo -e "\n\033[1;32mDone. Agent '$AGENT_NAME' is connected to $MANAGER in group '$GROUP'.\033[0m"
else
  echo -e "\n\033[1;33mAgent configured but not connected yet. Check: sudo tail -f $OSSEC/logs/ossec.log\033[0m"
  exit 2
fi
