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



