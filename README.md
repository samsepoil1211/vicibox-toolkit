# ViciBox Toolkit — Firewalld, Cleanup & Wazuh Agent Utilities

All‑in‑one toolkit for maintaining and securing ViciBox 8/9/11 servers.
This repository contains utility scripts to:
- configure firewalld for VICIdial deployments,
- install and configure a Wazuh agent (RPM-based),
- and perform log cleanup for VICIdial-related directories.

Note: An older README referenced a "create_vicidial_users_phones.sh" script. That file is not present in this repository. The current toolkit includes the three scripts listed below. If you need the auto-creator script, please add or retrieve it from the original source.

---

Table of Contents
- Overview
- Files included
- Requirements & Safety
- Quickstart
- Script details
  - Firewalld-template.sh
  - wazuh-agent.sh
  - cleanup.sh
- Non-interactive / Automation tips
- Verification & Troubleshooting
- Contributing
- License

---

## Overview

This toolkit helps ViciBox administrators quickly apply common operational tasks:

- Provision a recommended set of firewall rules for non‑WebRTC and WebRTC ViciBox installs (via firewalld).
- Install and register a Wazuh agent with a manager and add a basic log source / active-response integration.
- Clean up large or junk VICIdial log files based on a configurable threshold.

Each script is designed to be simple to run on the target server, but these are powerful, system-level changes — read the "Requirements & Safety" and "Verification & Troubleshooting" sections before running.

---

## Files included

- Firewalld-template.sh — Interactive firewalld rule applicator with three profiles (VICIdial 8, ViciDial 11 w/ WebRTC, General Purpose).
- wazuh-agent.sh — Installs a Wazuh agent RPM (configured for OpenSUSE by default) and updates /var/ossec/etc/ossec.conf with the manager IP and a log source.
- cleanup.sh — Checks total log size across VICIdial-related directories and deletes common junk logs when a threshold is exceeded.
- README.md — This file.

---

## Requirements & Safety

- Root access is required for all scripts (sudo or login as root).
- Internet access is required when installing packages (firewalld, Wazuh RPM).
- Recommended to perform a complete backup (files, databases, and configs) before running any script that modifies system state.
- Test in a staging environment before applying on production.
- Verify package manager compatibility and adjust the scripts for your distribution if needed.

Distribution compatibility (as scripted):
- Firewalld-template.sh: OpenSUSE / SLES, AlmaLinux / CentOS / RHEL, Debian / Ubuntu.
- wazuh-agent.sh: packaged RPM installation; script assumes RPM-based target (openSUSE path included). Modify for Debian/Ubuntu (deb) as needed.
- cleanup.sh: Works on typical Linux filesystems; determines Apache log directory based on /etc/os-release.

Important safety notes:
- cleanup.sh permanently deletes files that match certain patterns. Review and test with a dry-run before allowing deletion.
- Firewalld script currently adds ports as TCP for all entries — RTP for VoIP/WebRTC typically requires UDP. Review and adapt the script (or run commands manually) to add UDP ports where necessary.

---

## Quickstart

1. Download or clone this repository to your ViciBox server:
   ```
   git clone https://github.com/samsepoil1211/vicibox-toolkit.git
   cd vicibox-toolkit
   ```

2. Inspect each script before running:
   ```
   less Firewalld-template.sh
   less wazuh-agent.sh
   less cleanup.sh
   ```

3. Make scripts executable and run as root:
   ```
   chmod +x *.sh
   sudo ./Firewalld-template.sh
   sudo ./wazuh-agent.sh
   sudo ./cleanup.sh
   ```

---

## Script Details

### 1) Firewalld-template.sh
Purpose:
- Install and enable firewalld if missing.
- Apply one of three profiles:
  - VICIdial 8 (non-WebRTC)
  - VICIdial 11 (with WebRTC)
  - General Purpose Firewall
- Optionally add custom ports interactively.

How it works:
- Detects OS via /etc/os-release and uses the appropriate package manager to install firewalld.
- Enables and starts firewalld (`systemctl enable --now firewalld`).
- Adds a set of predefined TCP ports per profile and any custom TCP ports the user inputs.
- Reloads firewalld to apply permanent changes.

Usage:
- Interactive:
  ```
  sudo ./Firewalld-template.sh
  ```
  Follow prompts to select a profile and optionally provide comma-separated custom ports.

Notes, cautions & recommended edits:
- RTP/voice ports (10000‑20000) normally use UDP; the bundled script currently opens these as TCP. To fix, edit the script lines where ports are added and change TCP/UDP as required, or add the UDP range manually:
  ```
  sudo firewall-cmd --permanent --add-port=10000-20000/udp
  firewall-cmd --reload
  ```
- To view rules:
  ```
  firewall-cmd --list-ports
  firewall-cmd --list-all
  ```
- To remove a port:
  ```
  firewall-cmd --permanent --remove-port=5060/tcp
  firewall-cmd --reload
  ```

Example profile port lists (as in script):
- VICIdial 8: 22, 80, 443, 3306, 5060, 5061, 5038, 10000-20000
- VICIdial 11: 22, 80, 443, 3306, 5060, 5061, 8088, 8089, 10000-20000
- General: 22, 80, 443

If you want a non-interactive run, see "Non-interactive / Automation tips".

---

### 2) wazuh-agent.sh
Purpose:
- Install Wazuh agent (RPM) and configure its manager address and a sample localfile for syslog (/var/log/messages).
- Create a small active-response script at /var/ossec/active-response/bin/firewall-drop.sh.

Defaults and assumptions:
- MANAGER_IP is set at top of the script:
  ```
  MANAGER_IP="46.62.174.139"
  ```
  Change this value before running to point at your Wazuh manager.
- Uses RPM install URL (example version in script). Update the URL to a newer Wazuh version if required.

Usage:
1. Edit the manager IP if necessary:
   ```
   sudo sed -i 's/^MANAGER_IP=.*/MANAGER_IP="your.manager.ip"/' wazuh-agent.sh
   ```
   Or open the script and set MANAGER_IP manually.
2. Run the script:
   ```
   chmod +x wazuh-agent.sh
   sudo ./wazuh-agent.sh
   ```

What the script does:
- Imports GPG key for Wazuh packages.
- Installs the RPM (example uses 4.4.5).
- Replaces the <address> element in /var/ossec/etc/ossec.conf with the MANAGER_IP.
- Appends a localfile configuration to collect /var/log/messages.
- Creates an active-response script that appends iptables DROP rules on demand.
- Sets permissions & enables the wazuh-agent systemd service.

Post-install verification:
- Check the service:
  ```
  systemctl status wazuh-agent
  ```
- Check agent logs:
  ```
  tail -n 100 /var/ossec/logs/ossec.log
  ```
- Verify manager is receiving the agent (on manager side) and that /var/ossec/etc/ossec.conf shows your manager IP.

Security & customization:
- The script writes to /var/ossec/etc/ossec.conf — if you have an existing configuration, review merges to avoid malformed XML.
- The active-response script uses iptables. On firewalld systems, iptables rules may be overwritten; consider integrating with firewalld or using nftables if your platform uses nftables backend.
- For Debian/Ubuntu, use the .deb packages and modify install steps accordingly.

---

### 3) cleanup.sh
Purpose:
- Inspect total size of VICIdial-related log directories and delete common "junk" log files if the combined size exceeds a threshold.

Defaults:
- LOGFILE="/cleanup-logs.txt"
- THRESHOLD_MB=500 (500 MB)
- Log directories checked:
  - /var/log/asterisk
  - /var/log/astguiclient
  - Apache log directory (detected from /etc/os-release; defaults to /var/log/httpd)

Behavior:
- Computes total bytes for the configured directories.
- If total > THRESHOLD, deletes files matching patterns:
  - *.log, *.old, *.gz, screenlog.*, agiout.*, safe_*, go_*
- Logs the action to /cleanup-logs.txt.

Usage:
```
chmod +x cleanup.sh
sudo ./cleanup.sh
```

Dry-run recommendation:
- Before running deletion, do a dry-run find to list candidates:
  ```
  for DIR in /var/log/asterisk /var/log/astguiclient /var/log/httpd; do
    if [ -d "$DIR" ]; then
      echo ">>> $DIR"
      find "$DIR" -type f \( -name "*.log" -o -name "*.old" -o -name "*.gz" -o -name "screenlog.*" -o -name "agiout.*" -o -name "safe_*" -o -name "go_*" \)
    fi
  done
  ```
- To safely archive instead of deleting, create a tarball:
  ```
  sudo tar -czvf /root/vicidial-logs-backup-$(date +%F).tgz /var/log/asterisk /var/log/astguiclient /var/log/httpd
  ```

Caution:
- This script deletes files permanently. Review patterns and directories before running on production.

Customization:
- Change THRESHOLD_MB at the top of the script.
- Add/exclude patterns or directories by editing LOG_DIRS or the find() expression.

---

## Non-interactive / Automation tips

- Firewalld-template.sh: To script non-interactive behavior, export variables or modify the script to accept CLI args. Example quick wrapper (pseudo):
  ```
  # Example: apply profile 2 and open custom ports 9999,8888
  echo -e "2\nY\n9999,8888\n" | sudo ./Firewalld-template.sh
  ```
  Or edit the script to read ENV vars:
  - PROFILE=2
  - CUSTOM_PORTS="9999,8888"

- wazuh-agent.sh: export MANAGER_IP before running or edit the variable:
  ```
  sudo MANAGER_IP=1.2.3.4 ./wazuh-agent.sh
  ```
  (The script currently reads MANAGER_IP as a shell variable inside the file; to accept env vars you can modify the script to use ${MANAGER_IP:-46.62.174.139}.)

- cleanup.sh: Set THRESHOLD_MB via an environment var if you modify the script to read it from the environment:
  ```
  THRESHOLD_MB=1000 sudo ./cleanup.sh
  ```

---

## Verification & Troubleshooting

General checks after running scripts:
- Firewalld:
  - List active ports:
    ```
    firewall-cmd --list-ports
    firewall-cmd --list-all
    ```
  - Check service:
    ```
    systemctl status firewalld
    journalctl -u firewalld -n 200
    ```
- Wazuh agent:
  - service: `systemctl status wazuh-agent`
  - agent logs: `/var/ossec/logs/ossec.log`
  - confirm /var/ossec/etc/ossec.conf contains the correct manager IP
- Cleanup:
  - Check /cleanup-logs.txt for a record of actions
  - If deletion was performed, verify disk usage:
    ```
    du -sh /var/log/asterisk /var/log/astguiclient /var/log/httpd
    df -h /
    ```

Common issues:
- "firewall-cmd: command not found" — firewalld installation failed or package manager mismatch. Install firewalld with your native package manager.
- Wazuh RPM fails — missing dependencies or network issues. Check internet connectivity, change RPM URL to a valid version, or use the distribution-specific repository installation steps from Wazuh docs.
- cleanup.sh deletes more than expected — ensure you ran a dry-run and backed up logs first. Restore from backups if required.

---

## Missing/Deprecated Items

- The previous README referenced a script named create_vicidial_users_phones.sh which is not present in this repository. If you expect that functionality, locate the original script source or create one and place it in the repo. Do not run scripts assuming user/phone creation is included here — it is not.

---

## Contributing

- Please open issues or PRs for:
  - Adding the missing create_vicidial_users_phones.sh script or linking to it.
  - Fixing the firewalld RTP ports to use UDP.
  - Adding Debian/Ubuntu install flow for the Wazuh agent (.deb).
  - Making scripts accept CLI args or environment variables for automation.
- Coding style: POSIX-compatible Bash, favor `set -euo pipefail` for hardened scripts, and document any destructive changes clearly.

---

## License

This repository does not include an explicit license file. If you intend to reuse or redistribute these scripts, add a LICENSE file (MIT, Apache‑2.0, etc.) to clarify terms.

---

If you want, I can:
- Add non-interactive flags to the scripts,
- Convert the firewalld port additions to include UDP for RTP ranges,
- Produce a safe test run wrapper (dry-run) for the cleanup script,
- Or prepare a separate script/template for installing the create_vicidial_users_phones.sh if you provide its original source or desired behavior.


# VICIdial Independent Dual Dialing

Enable two fully independent agent panel sessions on a single VICIdial server — same agent, two browser tabs, independent dialing and dispo per tab.

Built for physical SIP phone setups (Eyebeam, X-Lite, or any hardphone).

---

## What This Does

By default, VICIdial blocks duplicate agent logins with a session killer — opening a second tab logs out the first. This script removes that restriction and sets up a shadow `_B` account for each agent, giving each tab its own independent Asterisk conference slot, dial session, and dispo workflow.

| Feature | Status |
|---|---|
| Dialing | ✅ Independent per tab |
| Dispo | ✅ Independent per tab |
| Lead data / script | ✅ Independent per tab |
| Pause / Ready | ✅ Independent per tab |
| Hangup | ❌ Not independent (SIP phone hardware limitation) |

> **Why hangup is not independent:** Both tabs share the same physical SIP channel on Asterisk (`SIP/1001-xxxx`). When either tab sends a hangup command, Asterisk drops the physical call — both tabs detect it. This is a hardware-level limitation of running one SIP account on one phone. It cannot be fixed in software without two separate SIP registrations.

---

## Requirements

- VICIdial 2.x (tested on 2.14-725c)
- OpenSUSE Leap 15 / CentOS / Debian (any standard Linux)
- Asterisk with `chan_sip` or `chan_pjsip`
- Physical SIP phone per agent (Eyebeam, X-Lite, Zoiper, or hardphone)
- Root access on the VICIdial server
- MySQL / MariaDB access

---

## How It Works

### PHP Patches (3 changes)

**`vicidial.php` — Session killer disabled**
VICIdial tracks duplicate logins via `$vlaLIaffected_rows`. When a second login is detected, this counter triggers a session kill popup. The patch forces this counter to always return `0`, so the second tab loads normally.

**`vicidial.php` — Disabled session popup suppressed**
The `AgenTDisablEBoX` JavaScript div that overlays the panel when a session is killed is suppressed so it never fires.

**`vdc_db_query.php` — INCALL block bypassed**
VICIdial blocks dial actions when `vla_status = 'INCALL'` to prevent double-dialing on the same session. Since `_B` is a separate DB record, this block is bypassed with `&& false` so the second tab can dial freely.

### Database Changes (3 additions per agent)

**`vicidial_users`** — A `_B` clone of each agent is created with identical permissions and the same password. Example: agent `1001` → shadow `1001_B`.

**`phones`** — A `_B` phone entry is created with offset conference and park extension numbers (`original + 10000`) so each session has its own Asterisk conference space.

**`vicidial_conferences`** — A free conference slot is assigned to `SIP/1001_B` so VICIdial can place the `_B` session into its own Asterisk conference bridge at login.

### Cron Job

A cron job is installed at `/etc/cron.d/vicidial_dual_dial` that runs every 5 minutes. Any new agent created in VICIdial automatically gets a `_B` account within 5 minutes — no manual action needed.

---

## Installation

### On a fresh server (no previous patches)

```bash
chmod +x vicidial_dual_dial.sh
bash vicidial_dual_dial.sh
```

The script auto-detects:
- VICIdial webroot path
- MySQL credentials (tries common VICIdial defaults, then reads `/etc/astguiclient.conf`)
- Server IP from the `servers` table

### On a server with previous manual patches applied

Run with `--revert` first to clean up, then run fresh:

```bash
bash vicidial_dual_dial.sh --revert
bash vicidial_dual_dial.sh
```

---

## Usage

### Agent Login Instructions

| | Tab 1 | Tab 2 |
|---|---|---|
| **Browser** | Chrome (normal) | Chrome Incognito (`Ctrl+Shift+N`) |
| **Username** | `1001` | `1001_B` |
| **Password** | same as normal | same as normal |
| **Phone Extension** | `1001` | `1001_B` |
| **Campaign** | any | any |

Both tabs connect to the **same physical Eyebeam/SIP phone** for audio. Each tab dials, tracks, and dispos its own calls completely independently.

---

## Commands

```bash
# Full setup (first run)
bash vicidial_dual_dial.sh

# Check patch status
bash vicidial_dual_dial.sh --status

# List all _B shadow users and phone entries
bash vicidial_dual_dial.sh --list

# Sync only — create _B for any new agents (cron uses this)
bash vicidial_dual_dial.sh --sync

# Full rollback — removes all patches and _B entries
bash vicidial_dual_dial.sh --revert
```

---

## Multi-Server Deployment

To deploy on multiple servers, copy the script to each server and run it. The script is fully self-contained and auto-detects all settings per server.

```bash
# Example: deploy to multiple servers via SSH
for SERVER in dial226 dial755 dial151; do
    scp vicidial_dual_dial.sh root@$SERVER:/root/
    ssh root@$SERVER "bash /root/vicidial_dual_dial.sh"
done
```

---

## Rollback

To fully revert all changes on any server:

```bash
bash vicidial_dual_dial.sh --revert
```

This will:
- Restore original `vicidial.php` and `vdc_db_query.php` from backup
- Delete all `_B` users from `vicidial_users`
- Delete all `_B` entries from `phones`
- Clear `_B` conf slot assignments in `vicidial_conferences`
- Remove the cron job

Backups are stored at `/root/vicidial_dual_dial_backup_YYYYMMDD_HHMMSS/`.

---

## Files Modified

| File | Change |
|---|---|
| `/srv/www/htdocs/agc/vicidial.php` | 3 line patches |
| `/srv/www/htdocs/agc/vdc_db_query.php` | 1 line patch |
| `vicidial_users` (DB table) | `_B` rows added |
| `phones` (DB table) | `_B` rows added |
| `vicidial_conferences` (DB table) | `_B` conf slots assigned |
| `/etc/cron.d/vicidial_dual_dial` | Cron job installed |

> Webroot path auto-detected. Default above is for OpenSUSE Leap 15. On CentOS/Debian the path is typically `/var/www/html/agc`.

---

## Tested On

| Component | Version |
|---|---|
| VICIdial | 2.14-725c BUILD: 260529-0914 |
| OS | OpenSUSE Leap 15 |
| Asterisk | 16.x with chan_sip |
| SIP Phone | Eyebeam (physical) |
| Browser | Chrome 125+ |

---

## Known Limitations

- **Hangup is shared** — dropping a call from either tab ends the physical call on the SIP phone. Both tabs detect the hangup event. This is a physical SIP channel limitation and cannot be resolved in software with a single SIP registration.
- **VICIdial updates** — updates to `vicidial.php` or `vdc_db_query.php` will overwrite the patches. Re-run the script after any VICIdial upgrade. The `_B` DB entries and cron job are unaffected by upgrades.
- **WebRTC softphone not supported** — this script is designed for physical SIP phones only. WebRTC (VICIphone) does not support dual registration on the same SIP extension.
- **Username length** — agent usernames longer than 18 characters are skipped (VICIdial `user` field is `varchar(20)`, `_B` suffix requires 2 extra characters).

---

## License

MIT License. Free to use, modify, and distribute.

---

## Author

Built for VICIdial production environments running physical SIP phone infrastructure.
Tested and validated on live production servers.

