# Manual setup (without the script)

These are the same steps `install-wazuh-agent.sh` runs, for Debian / Ubuntu / Raspberry Pi OS. Replace `<MANAGER_IP>` and `<VERSION>` (e.g. `4.14.9`, which must be ≤ your manager's version).

## 1. Check connectivity

```bash
for p in 1514 1515; do timeout 4 bash -c "</dev/tcp/<MANAGER_IP>/$p" && echo "$p open" || echo "$p CLOSED"; done
```

Both ports must be open. If they're not, fix the network first (see [troubleshooting](troubleshooting.md)).

## 2. Add the Wazuh repository

```bash
sudo apt-get update && sudo apt-get install -y curl gnupg apt-transport-https
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | sudo tee /etc/apt/sources.list.d/wazuh.list
sudo apt-get update
```

## 3. Install the agent and pin the version

```bash
sudo apt-get install -y wazuh-agent=<VERSION>-1
sudo apt-mark hold wazuh-agent
```

> You *can* pass `WAZUH_MANAGER=... WAZUH_AGENT_NAME=... WAZUH_AGENT_GROUP=...` as environment variables to `apt-get install`, and the package's post-install script writes them into `ossec.conf`. This guide edits the file explicitly instead, so you can see exactly what changes.

## 4. Edit `/var/ossec/etc/ossec.conf`

```bash
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak
sudo nano /var/ossec/etc/ossec.conf
```

**a. The `<client>` block.** Replace `MANAGER_IP` and add `<enrollment>`:

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
```

**b. The `<sca>` block.** Make sure it's enabled and lists the policy for your OS:

```bash
ls /var/ossec/ruleset/sca/        # e.g. cis_debian13.yml, cis_ubuntu24-04.yml, cis_rhel9_linux.yml
```

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

## 5. Start the agent

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wazuh-agent
```

## 6. Verify

```bash
sudo grep ^status /var/ossec/var/run/wazuh-agentd.state   # status='connected'
sudo cat /var/ossec/etc/client.keys                        # 002 Raspberry-pi any <key>
sudo head -1 /var/ossec/etc/shared/merged.mg               # #default
sudo grep -E "sca:" /var/ossec/logs/ossec.log | tail -3    # Evaluation finished for policy ...
```

In the dashboard: **Agents management → Summary** shows the agent as **Active** in group `default`. Click the agent, then **Configuration Assessment** to see the CIS score.

## Manual enrollment (alternative)

If you'd rather not use the `<enrollment>` block, request a key once by hand:

```bash
sudo /var/ossec/bin/agent-auth -m <MANAGER_IP> -A Raspberry-pi -G default
sudo systemctl restart wazuh-agent
```
