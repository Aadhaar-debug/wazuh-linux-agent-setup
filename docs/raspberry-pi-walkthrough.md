# Walkthrough: Raspberry Pi as a Wazuh agent

A record of setting up a real Raspberry Pi as a Wazuh agent, including the problems hit along the way. IPs are replaced with placeholders.

## Environment

| | |
|---|---|
| **Agent** | Raspberry Pi, Debian GNU/Linux 13 (trixie), kernel 6.18 `rpt-rpi-v8`, **arm64** |
| **Manager** | Wazuh **4.14.9** all-in-one (manager + indexer + dashboard) in a VMware Fusion VM on a Mac |
| **Goal** | Agent named "Raspberry pi", group `default`, status Active, SCA enabled |

Find the manager version without logging in. The dashboard login page embeds it:

```bash
curl -sk https://<MANAGER_IP>/app/login | grep -oE 'wazuhVersion&quot;:&quot;[0-9.]+'
# wazuhVersion&quot;:&quot;4.14.9
```

---

## Step 1: Connect to the Pi and gather facts

```bash
ssh pi@<PI_IP>
uname -a; cat /etc/os-release; dpkg --print-architecture   # arm64, Debian 13
```

## Step 2: Check the Pi can reach the manager ❌ (problem 1)

```bash
for p in 1514 1515; do timeout 4 bash -c "</dev/tcp/<MANAGER_IP>/$p" && echo "$p open" || echo "$p closed"; done
# 1514 closed
# 1515 closed
```

The Mac could reach the VM, but the Pi couldn't. The VM was on VMware Fusion's **NAT** network (`vmnet8`, a `192.168.147.0/24` subnet that exists only inside the Mac). The Pi was on the home LAN.

**Fix:** switch the VM's adapter to **Bridged → Autodetect**, then reboot or renew DHCP. The VM got a LAN address, found by scanning for the enrollment port:

```bash
for i in $(seq 1 254); do (nc -z -w1 <LAN_PREFIX>.$i 1515 2>/dev/null && echo "<LAN_PREFIX>.$i has 1515 open") & done; wait
```

After that, both ports were open from the Pi.

## Step 3: Install the agent ❌ (problem 2)

`apt` failed immediately:

```
E: dpkg was interrupted, you must manually run 'sudo dpkg --configure -a'
Setting up wazuh-dashboard (4.14.10-1) ...
chown: invalid user: 'wazuh-dashboard:wazuh-dashboard'
```

Looking closer, the Pi had the remains of an earlier attempt to install the Wazuh **server** on it:

```
ii  filebeat         7.10.2-2
iF  wazuh-dashboard  4.14.10-1      <- half-configured
ii  wazuh-indexer    4.14.9-1
ii  wazuh-manager    4.14.9-1       <- conflicts with wazuh-agent
```

Their files (`/var/ossec`, `/var/lib/wazuh-indexer`, `/etc/filebeat`) were already gone and all the services were dead. Only the dpkg records remained, and their removal scripts failed (exit 127) because the binaries they call no longer existed. The fix was to replace the broken `prerm`/`postrm` scripts with no-ops (backed up to `/root`) and purge the packages. The exact commands are in [troubleshooting.md](troubleshooting.md#wazuh-manager-already-installed--dpkg-errors-when-installing-the-agent).

Then the agent was installed at the manager's exact version and pinned:

```bash
sudo apt-get install -y wazuh-agent=4.14.9-1
sudo apt-mark hold wazuh-agent
```

## Step 4: Enroll with the name "Raspberry pi" ❌ (problem 3)

```bash
sudo /var/ossec/bin/agent-auth -m <MANAGER_IP> -A "Raspberry pi" -G default
# agent-auth: ERROR: Invalid agent name "Raspberry pi". Please pick a valid name.
```

Wazuh doesn't allow spaces in agent names. The closest valid name, **`Raspberry-pi`**, was used instead.

## Step 5: Configure `ossec.conf` and start the agent ✅

```bash
sudo ./install-wazuh-agent.sh -m <MANAGER_IP> -n Raspberry-pi -g default -v 4.14.9
```

Output:

```
==> 1/6 Pre-flight: checking connectivity to manager <MANAGER_IP>
  port 1514 reachable
  port 1515 reachable
==> 2/6 Adding the Wazuh package repository and installing wazuh-agent 4.14.9
wazuh-agent set on hold.
==> 3/6 Configuring /var/ossec/etc/ossec.conf (manager address, enrollment name/group)
==> 4/6 Enabling Security Configuration Assessment (SCA)
==> 5/6 Enabling and starting wazuh-agent
==> 6/6 Verifying
  agentd status : connected
  client.keys   : 002 Raspberry-pi
sca: INFO: Starting evaluation of policy: '/var/ossec/ruleset/sca/cis_debian13.yml'
sca: INFO: Evaluation finished for policy '/var/ossec/ruleset/sca/cis_debian13.yml'
sca: INFO: Security Configuration Assessment scan finished. Duration: 23 seconds.
Done. Agent 'Raspberry-pi' is connected to <MANAGER_IP> in group 'default'.
```

The resulting `ossec.conf` blocks:

```xml
<client>
  <server>
    <address><MANAGER_IP></address>
    <port>1514</port>
    <protocol>tcp</protocol>
  </server>
  <enrollment>
    <enabled>yes</enabled>
    <manager_address><MANAGER_IP></manager_address>
    <port>1515</port>
    <agent_name>Raspberry-pi</agent_name>
    <groups>default</groups>
  </enrollment>
  <config-profile>debian, debian13</config-profile>
  <notify_time>20</notify_time>
  <time-reconnect>60</time-reconnect>
  <auto_restart>yes</auto_restart>
  <crypto_method>aes</crypto_method>
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

## Step 6: Verify ✅

```bash
$ systemctl is-enabled wazuh-agent; systemctl is-active wazuh-agent
enabled
active

$ sudo grep ^status /var/ossec/var/run/wazuh-agentd.state
status='connected'

$ sudo head -1 /var/ossec/etc/shared/merged.mg     # shared config pushed by the manager for the agent's group
#default

$ sudo grep "Connected to the server" /var/ossec/logs/ossec.log | tail -1
wazuh-agentd: INFO: (4102): Connected to the server ([<MANAGER_IP>]:1514/tcp).
```

In the dashboard, **Agents management** shows `Raspberry-pi` (ID 002) as **Active** in group **default**. Its **Configuration Assessment** tab shows the *CIS Debian Linux 13 Benchmark* results.

## Lessons

1. Check **network reachability first**. A NAT'd server VM is the most common reason an agent never shows up.
2. Read the **manager version** before installing, and pin the agent to it.
3. **No spaces** in agent names.
4. A host can be a manager *or* an agent, not both. Clean up failed server installs before installing the agent.
