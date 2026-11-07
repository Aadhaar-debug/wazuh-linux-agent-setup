# Wazuh Linux Agent Setup

Install, enroll and configure a **Wazuh agent** on any Linux machine with one script. That includes Raspberry Pi, Debian/Ubuntu and RHEL-family systems, on x86_64 or arm64. The agent is enrolled into a group, shows as **Active** in the Wazuh dashboard, and has **Security Configuration Assessment (SCA)** enabled with the CIS policy for its OS.

Tested end-to-end on a **Raspberry Pi (Debian 13 "trixie", arm64)** against a **Wazuh 4.14.9** all-in-one server running in a VMware Fusion VM.

---

## Contents

| Path | What it is |
|------|------------|
| [`install-wazuh-agent.sh`](install-wazuh-agent.sh) | One-shot Linux installer: repo → package → `ossec.conf` → enroll → start → verify |
| [`install-wazuh-agent-macos.sh`](install-wazuh-agent-macos.sh) | macOS equivalent (Apple silicon & Intel). Installs the `.pkg` if missing, or repoints an existing agent |
| [`docs/my-lab-registration.md`](docs/my-lab-registration.md) | How I registered my **Mac and Raspberry Pi** with my Wazuh VM, with SCA on both. Includes the NAT→bridged fix and the Docker-vs-native conflict |
| [`config/ossec.conf.agent-example`](config/ossec.conf.agent-example) | The `<client>` and `<sca>` blocks the script writes, annotated |
| [`docs/raspberry-pi-walkthrough.md`](docs/raspberry-pi-walkthrough.md) | Step-by-step record of setting up a real Raspberry Pi, including the problems hit and how they were fixed |
| [`docs/manual-setup.md`](docs/manual-setup.md) | The same steps done by hand, without the script |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Common failures (agent never connects, invalid name, VM in NAT mode, dpkg conflicts…) |

---

## Prerequisites

1. **A running Wazuh manager.** Note its version, either in the dashboard under *☰ → About* or by running `/var/ossec/bin/wazuh-control info` on the server. **The agent version must be ≤ the manager version.**
2. **Network reachability from the agent to the manager:**
   | Port | Proto | Purpose |
   |------|-------|---------|
   | 1514 | TCP | Agent ↔ manager event/communication channel |
   | 1515 | TCP | Agent enrollment (`wazuh-authd`) |

   > ⚠️ If the manager is a VM, its network adapter must be **Bridged**, not NAT/Shared. A NAT'd VM (e.g. `192.168.x.x` on VMware's `vmnet8`) is only reachable from the host, so other machines on your LAN can't connect to it. See [troubleshooting](docs/troubleshooting.md#agent-cant-reach-the-manager-vm-behind-nat).
3. `root`/`sudo` on the agent machine and outbound HTTPS to `packages.wazuh.com`.

Quick reachability check from the agent:

```bash
for p in 1514 1515; do timeout 4 bash -c "</dev/tcp/<MANAGER_IP>/$p" && echo "$p open" || echo "$p CLOSED"; done
```

---

## Quick start

```bash
git clone https://github.com/Aadhaar-debug/wazuh-linux-agent-setup.git
cd wazuh-linux-agent-setup
sudo ./install-wazuh-agent.sh -m <MANAGER_IP> -n Raspberry-pi -g default -v 4.14.9
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-m` | Manager IP/hostname (**required**) | — |
| `-n` | Agent name shown in the dashboard | `$(hostname)` |
| `-g` | Agent group(s), comma-separated | `default` |
| `-v` | Agent version to install (match your manager) | latest 4.x |
| `-p` | Enrollment password, if the manager has `<use_password>yes</use_password>` | none |
| `-i` | SCA scan interval | `12h` |

### macOS

```bash
sudo ./install-wazuh-agent-macos.sh -m <MANAGER_IP> -n tweakMacOS -g default -v 4.14.9
```

This takes the same flags (`-m -n -g -v -i`). If the Mac is already registered and you leave out `-n`, it keeps the existing agent name. It enables SCA with the bundled `cis_apple_macOS_*.yml` policy.

> **Agent names cannot contain spaces.** Allowed characters are letters, digits, `.`, `-` and `_`. The manager rejects `Raspberry pi` with `Invalid agent name`, so use `Raspberry-pi`.

Successful output ends with:

```
==> 6/6 Verifying
  agentd status : connected
  client.keys   : 002 Raspberry-pi
sca: INFO: Starting evaluation of policy: '/var/ossec/ruleset/sca/cis_debian13.yml'
sca: INFO: Evaluation finished for policy '/var/ossec/ruleset/sca/cis_debian13.yml'
Done. Agent 'Raspberry-pi' is connected to <MANAGER_IP> in group 'default'.
```

---

## What the script does

1. **Pre-flight:** it checks that TCP 1514/1515 on the manager are reachable and that `wazuh-manager` is *not* installed locally (the two packages conflict).
2. **Installs the package:** it adds the official Wazuh GPG key and repo, installs `wazuh-agent` at the pinned version, then **holds** it so routine `apt upgrade` / `dnf update` runs can't move it past the manager.
3. **Configures `/var/ossec/etc/ossec.conf`.** It backs up the file to `ossec.conf.bak.<timestamp>` first, then:
   - sets `<client><server><address>` to the manager
   - adds an `<enrollment>` block with `agent_name` and `groups`, so the agent auto-enrolls on start
   - keeps the OS `<config-profile>` the package generated
4. **Enables SCA.** It writes an `<sca>` block with `enabled`, `scan_on_start` and the interval, and explicitly lists every CIS policy shipped for the OS (e.g. `cis_debian13.yml`).
5. **Validates the XML** (if `xmllint` is present), then `systemctl enable --now wazuh-agent`.
6. **Verifies:** it waits for `status='connected'` in `wazuh-agentd.state`, then prints the agent ID and the SCA log lines.

The resulting config blocks are in [`config/ossec.conf.agent-example`](config/ossec.conf.agent-example).

---

## Verifying in the Wazuh dashboard

1. **Agents management → Summary.** The agent appears with status **Active**, plus its OS, version and the group `default`.
2. Click the agent, then **Configuration Assessment**. You'll see the *CIS Debian Linux 13 Benchmark* policy with pass/fail counts and a score. The first scan runs right after the agent starts, then every 12 h.
3. Optional, from the manager CLI:
   ```bash
   sudo /var/ossec/bin/agent_control -l          # list agents and status
   sudo /var/ossec/bin/agent_groups -l -g default # agents in the default group
   ```

On the agent itself:

```bash
sudo grep ^status /var/ossec/var/run/wazuh-agentd.state   # status='connected'
sudo head -1 /var/ossec/etc/shared/merged.mg               # #default  -> group config received
sudo grep sca: /var/ossec/logs/ossec.log | tail             # SCA scan activity
```

---

## Uninstall

```bash
# Debian/Ubuntu
sudo apt-mark unhold wazuh-agent && sudo apt-get purge -y wazuh-agent && sudo rm -rf /var/ossec
# RHEL family
sudo dnf remove -y wazuh-agent && sudo rm -rf /var/ossec
```

Then remove the agent on the manager: `sudo /var/ossec/bin/manage_agents -r <ID>`, or use *Agents management* in the dashboard.

## License

MIT
