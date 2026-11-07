# My lab: registering a Mac and a Raspberry Pi with a Wazuh server VM

This is a record of how I connected two machines, my **MacBook (Apple silicon)** and a **Raspberry Pi**, as agents of a **Wazuh 4.14.9** all-in-one server running in a VMware Fusion VM on that same Mac. Both agents have **Security Configuration Assessment (SCA)** turned on. IP addresses are placeholders.

```
            Home LAN (<LAN>/24)
 ┌──────────────────────────────────────────────────────────┐
 │                                                          │
 │  MacBook (macOS 27, arm64)          Raspberry Pi         │
 │  agent 001 "tweakMacOS"             agent 002 "Raspberry-pi"
 │  ┌───────────────────────────┐      Debian 13, arm64     │
 │  │ VMware Fusion             │           │               │
 │  │  Ubuntu 26.04 VM (bridged)│◄──────────┘ 1514/1515 tcp │
 │  │  <MANAGER_IP>             │◄──── Mac agent 1514/1515  │
 │  │  wazuh-manager  4.14.9    │                           │
 │  │  wazuh-indexer  4.14.9    │                           │
 │  │  wazuh-dashboard (443)    │                           │
 │  └───────────────────────────┘                           │
 └──────────────────────────────────────────────────────────┘
```

| Agent | ID | OS | Group | SCA policy |
|---|---|---|---|---|
| `tweakMacOS` | 001 | macOS 27.2, arm64 | `default` | `cis_apple_macOS_26.x.yml` |
| `Raspberry-pi` | 002 | Debian 13 (trixie), arm64 | `default` | `cis_debian13.yml` |

---

## 0. Make the server reachable: bridge the VM

At first the VM used VMware's **NAT** network (`vmnet8`, a private `192.168.147.0/24` subnet). The Mac could reach it, but the Raspberry Pi couldn't, because the Pi is on the home LAN.

**VMware Fusion → Virtual Machine → Settings → Network Adapter → Bridged Networking → Autodetect**, then reboot the VM so it gets a LAN address from the router.

To find the VM's new IP, I scanned for the enrollment port:

```bash
for i in $(seq 1 254); do (nc -z -G1 -w1 <LAN_PREFIX>.$i 1515 2>/dev/null && echo "<LAN_PREFIX>.$i") & done; wait
```

Then I updated the stale address the dashboard uses in its "Deploy new agent" commands:

```bash
sudo sed -i 's/^enrollment.dns: .*/enrollment.dns: "<MANAGER_IP>"/' \
  /usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml
```

> **Tip:** reserve the VM's IP in the router (a DHCP reservation). Otherwise every agent breaks when it changes.

---

## 1. Raspberry Pi → agent `Raspberry-pi`

```bash
# copy the script to the Pi, then on the Pi:
sudo ./install-wazuh-agent.sh -m <MANAGER_IP> -n Raspberry-pi -g default -v 4.14.9
```

Problems along the way. Details are in [raspberry-pi-walkthrough.md](raspberry-pi-walkthrough.md).

1. **The VM was in NAT mode**, so the Pi couldn't reach ports 1514/1515. Fixed by bridging (step 0).
2. **Leftover Wazuh *server* packages** on the Pi (`wazuh-manager`, `wazuh-indexer`, `filebeat` and a broken `wazuh-dashboard`) blocked `apt` and conflict with `wazuh-agent`. I purged them.
3. **`Invalid agent name "Raspberry pi"`**: spaces aren't allowed, so the agent is called `Raspberry-pi`.

Resulting `ossec.conf` (relevant parts):

```xml
<client>
  <server><address><MANAGER_IP></address><port>1514</port><protocol>tcp</protocol></server>
  <enrollment>
    <enabled>yes</enabled>
    <manager_address><MANAGER_IP></manager_address>
    <port>1515</port>
    <agent_name>Raspberry-pi</agent_name>
    <groups>default</groups>
  </enrollment>
  <config-profile>debian, debian13</config-profile>
  ...
</client>
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>12h</interval>
  <skip_nfs>yes</skip_nfs>
  <policies>
    <policy enabled="yes">ruleset/sca/cis_debian13.yml</policy>
  </policies>
</sca>
```

Result:

```
wazuh-agentd: INFO: (4102): Connected to the server ([<MANAGER_IP>]:1514/tcp).
sca: INFO: Evaluation finished for policy '/var/ossec/ruleset/sca/cis_debian13.yml'
```

The manager shows `ID: 002, Name: Raspberry-pi, Active`, and the first SCA run on the CIS Debian Linux 13 benchmark scored **77 passed / 101 failed / 29 not applicable, 43%**.

---

## 2. MacBook → agent `tweakMacOS`

The Mac already had **wazuh-agent 4.14.9** installed and registered as agent 001, but it pointed at the VM's **old NAT address**, so it showed *Disconnected*. The macOS script keeps the existing registration in `/Library/Ossec/etc/client.keys` and only rewrites the config:

```bash
sudo ./install-wazuh-agent-macos.sh -m <MANAGER_IP> -g default
#   (-n is optional: it reuses the name already in client.keys, here "tweakMacOS")
```

On a Mac without the agent, the same script first downloads and installs `wazuh-agent-<version>-1.arm64.pkg` (or `.intel64.pkg`) from `packages.wazuh.com`.

Resulting `/Library/Ossec/etc/ossec.conf` (relevant parts):

```xml
<client>
  <server><address><MANAGER_IP></address><port>1514</port><protocol>tcp</protocol></server>
  <enrollment>
    <enabled>yes</enabled>
    <manager_address><MANAGER_IP></manager_address>
    <port>1515</port>
    <agent_name>tweakMacOS</agent_name>
    <groups>default</groups>
  </enrollment>
  <config-profile>darwin, darwin27, darwin27.2</config-profile>
  ...
</client>
<sca>
  <enabled>yes</enabled>
  <scan_on_start>yes</scan_on_start>
  <interval>12h</interval>
  <skip_nfs>yes</skip_nfs>
  <policies>
    <policy enabled="yes">ruleset/sca/cis_apple_macOS_26.x.yml</policy>
  </policies>
</sca>
```

Result:

```
status='connected'
sca: INFO: Loaded policy '/Library/Ossec/ruleset/sca/cis_apple_macOS_26.x.yml'
sca: INFO: Evaluation finished for policy '/Library/Ossec/ruleset/sca/cis_apple_macOS_26.x.yml'
sca: INFO: Security Configuration Assessment scan finished. Duration: 7 seconds.
```

> The agent ships a CIS benchmark for **macOS 26.x**. On macOS 27 it still loads and runs, but some checks may not match the newer OS exactly. Use a 27.x policy once Wazuh ships one.

Useful macOS agent commands:

```bash
sudo /Library/Ossec/bin/wazuh-control status | restart
sudo cat /Library/Ossec/var/run/wazuh-agentd.state | grep ^status
sudo tail -f /Library/Ossec/logs/ossec.log
```

---

## 3. The server stopped: two Wazuh installs fighting

Later the dashboard stopped showing data. The cause:

- I had been trying the **Docker/Podman single-node** deployment (`~/wazuh-docker/single-node`) on the same VM, and ran `sudo systemctl stop wazuh-manager` to make room for it.
- The container stack's certificate generator failed (`ERROR: certificates were not created`), so its indexer and dashboard never started. But its **manager container grabbed ports 1514/1515/55000**.
- So the native manager was stopped, the container manager was half-working, and the agents disconnected.

How I fixed it, keeping the native install:

```bash
sudo podman stop single-node-wazuh.manager-1 single-node-wazuh.indexer-1 single-node-wazuh.dashboard-1
sudo systemctl start wazuh-manager
sudo /var/ossec/bin/wazuh-control status          # all daemons running
sudo ss -ltnp | grep -E ':(1514|1515|55000)\b'     # owned by wazuh-remoted / wazuh-authd / python3 (API)
```

(The containers use `restart=always`, but `podman-restart.service` is disabled, so they don't come back at boot. Run only one Wazuh deployment per VM.)

---

## 4. Verify everything

On the manager:

```bash
sudo /var/ossec/bin/agent_control -l
# expected:
#   ID: 000, Name: <server>    , Active/Local
#   ID: 001, Name: tweakMacOS  , Active
#   ID: 002, Name: Raspberry-pi, Active
sudo /var/ossec/bin/agent_groups -l -g default    # both agents in 'default'
sudo filebeat test output                          # talk to server... OK
```

In the dashboard (`https://<MANAGER_IP>`), open **Agents management → Summary**. Both agents are **Active** in group `default`. Click an agent, then **Configuration Assessment**, to see its CIS policy, score and the failed checks with remediation steps.
