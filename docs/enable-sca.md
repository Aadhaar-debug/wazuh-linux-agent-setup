# Enabling SCA (Security Configuration Assessment) on the agents

SCA checks a machine against a hardening benchmark, such as **CIS Debian 13** on the Raspberry Pi or **CIS Apple macOS** on the Mac. Results appear in the Wazuh dashboard under each agent's **Configuration Assessment** tab: a score, every passed and failed check, and how to fix each failure.

SCA is configured in the agent's `ossec.conf`. There are two ways to do it:

- [**Option A: on each agent**](#option-a-enable-sca-on-each-agent) by editing its `ossec.conf`. This is what this repo's scripts do, and what was done on the Pi and the Mac.
- [**Option B: centrally from the manager**](#option-b-enable-sca-centrally-from-the-manager) for a whole group at once.

| | Raspberry Pi / Linux | macOS |
|---|---|---|
| Config file | `/var/ossec/etc/ossec.conf` | `/Library/Ossec/etc/ossec.conf` |
| Policies folder | `/var/ossec/ruleset/sca/` | `/Library/Ossec/ruleset/sca/` |
| Log | `/var/ossec/logs/ossec.log` | `/Library/Ossec/logs/ossec.log` |
| Restart | `sudo systemctl restart wazuh-agent` | `sudo /Library/Ossec/bin/wazuh-control restart` |
| Policy used here | `cis_debian13.yml` | `cis_apple_macOS_26.x.yml` |

---

## Option A: enable SCA on each agent

### Raspberry Pi (Linux)

**1. See which SCA policies the agent shipped with.** The package installs the ones that match the OS:

```bash
sudo ls /var/ossec/ruleset/sca/
# cis_debian13.yml
```

**2. Back up the config, then open it:**

```bash
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak
sudo nano /var/ossec/etc/ossec.conf
```

**3. Find the `<sca>` block** (in nano, press `Ctrl+W` and search for `<sca>`). Make it look like this:

```xml
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

If there's no `<sca>` block, paste it in just before the last `</ossec_config>`. Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

**4. Restart the agent:**

```bash
sudo systemctl restart wazuh-agent
```

**5. Check that the scan ran:**

```bash
sudo grep "sca:" /var/ossec/logs/ossec.log | tail -5
```

You should see:

```
sca: INFO: Starting evaluation of policy: '/var/ossec/ruleset/sca/cis_debian13.yml'
sca: INFO: Evaluation finished for policy '/var/ossec/ruleset/sca/cis_debian13.yml'
sca: INFO: Security Configuration Assessment scan finished. Duration: 23 seconds.
```

### MacBook (macOS)

**1. See which SCA policies the agent shipped with:**

```bash
sudo ls /Library/Ossec/ruleset/sca/
# cis_apple_macOS_26.x.yml
# sca_distro_independent_linux.yml   <- Linux-only. The Mac agent skips it, so don't list it
```

**2. Back up the config, then open it:**

```bash
sudo cp /Library/Ossec/etc/ossec.conf /Library/Ossec/etc/ossec.conf.bak
sudo nano /Library/Ossec/etc/ossec.conf
```

**3. Find the `<sca>` block** (`Ctrl+W`, search `<sca>`). Make it look like this:

```xml
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

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

**4. Restart the agent:**

```bash
sudo /Library/Ossec/bin/wazuh-control restart
```

**5. Check that the scan ran:**

```bash
sudo grep "sca:" /Library/Ossec/logs/ossec.log | tail -5
```

You should see:

```
sca: INFO: Loaded policy '/Library/Ossec/ruleset/sca/cis_apple_macOS_26.x.yml'
sca: INFO: Evaluation finished for policy '/Library/Ossec/ruleset/sca/cis_apple_macOS_26.x.yml'
sca: INFO: Security Configuration Assessment scan finished. Duration: 7 seconds.
```

> **macOS 27 note:** Wazuh 4.14.9 ships the CIS policy for macOS **26.x**. It loads and runs on macOS 27, but a few checks may not match the newer OS exactly.

### Or let the scripts do it

Both scripts write the same `<sca>` block automatically. They pick up every CIS policy that matches the OS:

```bash
sudo ./install-wazuh-agent.sh       -m <MANAGER_IP> -n Raspberry-pi -g default   # Linux / Pi
sudo ./install-wazuh-agent-macos.sh -m <MANAGER_IP> -g default                   # macOS
```

---

## What each setting means

| Setting | Value | Meaning |
|---|---|---|
| `<enabled>` | `yes` | Turns the SCA module on |
| `<scan_on_start>` | `yes` | Runs a scan as soon as the agent starts or restarts |
| `<interval>` | `12h` | Runs again every 12 hours. Accepts `s`, `m`, `h`, `d`, `w` (e.g. `30m`, `1d`) |
| `<skip_nfs>` | `yes` | Skips network-mounted filesystems when checking files |
| `<policy enabled="yes">` | path | A policy file to run. The path is relative to the agent's install folder. Set `enabled="no"` to turn one off |

---

## Option B: enable SCA centrally from the manager

Instead of editing every agent, you can push the SCA settings to everyone in a group from the **Wazuh server VM**. Edit the group's shared config:

```bash
sudo nano /var/ossec/etc/shared/default/agent.conf
```

```xml
<!-- Linux agents in the group -->
<agent_config os="Linux">
  <sca>
    <enabled>yes</enabled>
    <scan_on_start>yes</scan_on_start>
    <interval>12h</interval>
    <skip_nfs>yes</skip_nfs>
  </sca>
</agent_config>

<!-- macOS agents in the group -->
<agent_config os="Darwin">
  <sca>
    <enabled>yes</enabled>
    <scan_on_start>yes</scan_on_start>
    <interval>12h</interval>
  </sca>
</agent_config>
```

Check the file and apply it:

```bash
sudo /var/ossec/bin/verify-agent-conf
sudo systemctl restart wazuh-manager
```

You can also do this from the dashboard under **☰ → Agents management → Groups → default → Files → agent.conf → Edit**.

Agents in the `default` group download the new config within a minute or two. With `<auto_restart>yes</auto_restart>` (the default) they restart and apply it on their own. With no `<policies>` list, each agent runs every policy in its own `ruleset/sca/` folder that fits its OS.

---

## See the results in the dashboard

1. Open `https://<MANAGER_IP>` and log in.
2. Go to **☰ → Agents management → Summary**, then click the agent (`Raspberry-pi` or `tweakMacOS`).
3. Open the **Configuration Assessment** tab. You'll see:
   - the policy name, e.g. *CIS Debian Linux 13 Benchmark*
   - **Passed / Failed / Not applicable** counts and a **score**. The Pi's first scan was 77 / 101 / 29, a score of 43%
   - every check, with its rationale and the exact remediation steps
4. After fixing something, restart the agent to re-scan immediately, or wait for the next 12 h run.

---

## Troubleshooting SCA

| Symptom | Fix |
|---|---|
| No `sca:` lines in the log | `<enabled>` isn't `yes`, or the agent wasn't restarted after editing |
| `Skipping policy '...': 'Check Linux version.'` | That policy is for a different OS. Remove it from `<policies>` |
| `Policy file not found` | The `<policy>` path is wrong. Check it with `ls <agent dir>/ruleset/sca/` |
| Agent won't start after editing | Typo in the XML. Restore `ossec.conf.bak`, then redo the edit carefully |
| Dashboard shows no SCA data | The agent must be **Active**. Wait 1–2 min after the scan finishes, then refresh |
| Want a scan right now | Restart the agent (`scan_on_start` is `yes`) |
