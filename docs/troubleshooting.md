# Troubleshooting

Logs on the agent: `sudo tail -f /var/ossec/logs/ossec.log`
Connection state: `sudo cat /var/ossec/var/run/wazuh-agentd.state`

---

## Agent can't reach the manager (VM behind NAT)

**Symptom:** the pre-flight says `cannot reach <ip>:1514`, or the log shows `(1216): Unable to connect to '[x.x.x.x]:1514/tcp'`, and the agent stays *Never connected* / *Disconnected*.

**Cause:** the Wazuh server VM uses NAT/Shared networking. In VMware Fusion that's `vmnet8`, a private subnet such as `192.168.147.0/24`. In VirtualBox it's the `10.0.2.x` NAT. Only the host machine can reach that subnet, so a Raspberry Pi or another PC on your LAN cannot.

**Fix (recommended): bridge the VM**

1. Power on the VM. In VMware Fusion, open *Virtual Machine → Settings → Network Adapter* and choose **Bridged Networking → Autodetect** (or the specific interface, e.g. Wi-Fi). In VirtualBox, choose *Settings → Network → Attached to: Bridged Adapter*.
2. Renew the VM's IP by rebooting it, or run `sudo systemctl restart NetworkManager` / `sudo dhclient -r && sudo dhclient`.
3. Get the new LAN IP with `ip -4 addr`, or from another machine on the LAN:
   ```bash
   for i in $(seq 1 254); do (nc -z -w1 192.168.1.$i 1515 2>/dev/null && echo "192.168.1.$i") & done; wait
   ```
4. Use that IP as the manager address.

> **Autodetect vs a specific interface:** Autodetect bridges to whichever interface the host is actively using. If the host switches between Wi-Fi and Ethernet, the VM follows and may get a new IP. Choose a specific interface if you want it to stay put.

> **After changing the server's IP:** if the all-in-one install used the old IP in `/etc/wazuh-indexer/opensearch.yml`, `/etc/filebeat/filebeat.yml` or `/etc/wazuh-dashboard/opensearch_dashboards.yml`, the dashboard ↔ indexer link may break. Agents talk directly to the manager on 1514/1515, so they aren't affected. Reserving a DHCP lease for the VM in your router keeps the IP stable.

**Alternative (keep NAT):** forward TCP 1514 and 1515 from the host to the VM. In Fusion, add them under `[incomingtcp]` in `/Library/Preferences/VMware Fusion/vmnet8/nat.conf` and restart VMware networking. Then point the agent at the *host's* LAN IP.

**Also check the server firewall:**
```bash
sudo firewall-cmd --list-ports            # RHEL family
sudo ufw status                           # Ubuntu
# open if needed:
sudo firewall-cmd --permanent --add-port=1514/tcp --add-port=1515/tcp && sudo firewall-cmd --reload
```

---

## `Invalid agent name "Raspberry pi"`

```
agent-auth: ERROR: Invalid agent name "Raspberry pi". Please pick a valid name.
```

Agent names may only contain **letters, digits, `.`, `-` and `_`**, and must be 2–128 characters long. Spaces aren't allowed. Use `Raspberry-pi` or `Raspberry_pi`. The script checks this before doing anything.

---

## `Duplicate agent name` / agent re-installed with the same name

The manager already has an agent with that name, e.g. from a previous install. Either:

- remove the old agent on the manager with `sudo /var/ossec/bin/manage_agents -r <ID>` (or via the dashboard), then restart the agent, or
- enable `<force><enabled>yes</enabled></force>` inside `<auth>` on the manager to let re-enrollment replace it.

---

## Agent newer than the manager

The manager refuses agents running a newer version than itself, and the agent never shows as Active. The manager's `ossec.log` shows a version-mismatch message for that agent.

Install the agent at the manager's exact version, e.g. `-v 4.14.9`. The script runs `apt-mark hold` (apt) or adds `exclude=wazuh-agent` (yum/dnf) so system updates don't upgrade it later. Upgrade the manager first, then agents. You can upgrade agents remotely from the dashboard.

---

## `wazuh-manager already installed` / dpkg errors when installing the agent

`wazuh-agent` and `wazuh-manager` conflict. You can't have both on one host. On the Raspberry Pi in this guide, an earlier attempt to install the *server* had left `wazuh-manager`, `wazuh-indexer`, `filebeat` and a half-configured `wazuh-dashboard` registered in dpkg. Their files were already deleted, so every `apt` command failed with:

```
E: dpkg was interrupted, you must manually run 'sudo dpkg --configure -a' to correct the problem.
chown: invalid user: 'wazuh-dashboard:wazuh-dashboard'
installed wazuh-manager package pre-removal script subprocess returned error exit status 127
```

**Fix.** Do this only if you're sure the host should *not* be a Wazuh server:

```bash
# Maintainer scripts fail because their files are gone; replace them with no-ops (backups kept in /root)
for p in wazuh-manager wazuh-indexer filebeat wazuh-dashboard; do
  for s in prerm postrm; do
    f=/var/lib/dpkg/info/$p.$s
    [ -f "$f" ] && sudo cp "$f" /root/$p.$s.bak && printf '#!/bin/sh\nexit 0\n' | sudo tee "$f" >/dev/null
  done
done
sudo systemctl disable --now wazuh-manager wazuh-indexer filebeat wazuh-dashboard 2>/dev/null
sudo dpkg --purge wazuh-manager wazuh-indexer filebeat wazuh-dashboard
sudo dpkg --configure -a
```

Then rerun the installer.

---

## Agent connects but SCA shows nothing

- Check `grep sca: /var/ossec/logs/ossec.log`. You should see `Starting evaluation of policy` and then `Evaluation finished`.
- Check that `<sca><enabled>yes</enabled>` is set and the listed policy file exists in `/var/ossec/ruleset/sca/`.
- If your OS has no matching CIS policy (no `.yml` in that folder), copy a suitable one from the manager's `/var/ossec/ruleset/sca/` or write a custom policy.
- Results reach the dashboard a minute or two after the scan finishes. Refresh *Configuration Assessment*.
- Force a fresh scan with `sudo systemctl restart wazuh-agent` (`scan_on_start` is `yes`).

---

## Agent shows "Disconnected" after a while

- The manager IP changed (e.g. DHCP on a bridged VM). Update `<address>` and `<manager_address>`, then restart the agent.
- The host went to sleep (VM on a laptop).
- The time is badly skewed. Check that NTP works: `timedatectl`.
