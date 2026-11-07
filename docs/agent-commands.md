# Starting and stopping the Wazuh agent

## Raspberry Pi / Linux (systemd)

| Action | Command |
|---|---|
| Start | `sudo systemctl start wazuh-agent` |
| Stop | `sudo systemctl stop wazuh-agent` |
| Restart (after editing `ossec.conf`) | `sudo systemctl restart wazuh-agent` |
| Status | `sudo systemctl status wazuh-agent` |
| Start at boot | `sudo systemctl enable wazuh-agent` |
| Don't start at boot | `sudo systemctl disable wazuh-agent` |

Wazuh's own control script works too:

```bash
sudo /var/ossec/bin/wazuh-control start     # stop | restart | status
```

Check that it's talking to the manager:

```bash
sudo grep ^status /var/ossec/var/run/wazuh-agentd.state   # status='connected'
sudo tail -f /var/ossec/logs/ossec.log
```

---

## MacBook (macOS)

| Action | Command |
|---|---|
| Start | `sudo /Library/Ossec/bin/wazuh-control start` |
| Stop | `sudo /Library/Ossec/bin/wazuh-control stop` |
| Restart (after editing `ossec.conf`) | `sudo /Library/Ossec/bin/wazuh-control restart` |
| Status | `sudo /Library/Ossec/bin/wazuh-control status` |

The agent starts at boot through a launchd daemon. To turn that off or back on:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.wazuh.agent.plist    # stop + don't start at boot
sudo launchctl bootstrap system /Library/LaunchDaemons/com.wazuh.agent.plist  # start + start at boot again
```

Check that it's talking to the manager:

```bash
sudo grep ^status /Library/Ossec/var/run/wazuh-agentd.state   # status='connected'
sudo tail -f /Library/Ossec/logs/ossec.log
```

---

> A stopped agent shows as **Disconnected** in the dashboard after about a minute. When you start it again it reconnects on its own and runs an SCA scan right away (`scan_on_start`).
