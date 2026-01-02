#!/bin/bash
# Wazuh Agent Setup for ViciBox (OpenSUSE)
MANAGER_IP="46.62.174.139"

echo "--- Importing Wazuh GPG Key ---"
rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

echo "--- Installing Wazuh Agent ---"
# Fixed: changed -Ivh to -ivh
rpm -ivh https://packages.wazuh.com/4.x/yum/wazuh-agent-4.4.5-1.x86_64.rpm

# Wait for installation to settle
sleep 2

if [ ! -d "/var/ossec" ]; then
    echo "ERROR: Wazuh Agent failed to install. Please check internet connectivity."
    exit 1
fi

echo "--- Configuring Manager Connection ---"
sed -i "s/<address>.*<\/address>/<address>$MANAGER_IP<\/address>/" /var/ossec/etc/ossec.conf

echo "--- Adding Log Source for /var/log/messages ---"
cat << 'EOF' >> /var/ossec/etc/ossec.conf
<ossec_config>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/messages</location>
  </localfile>
</ossec_config>
EOF

echo "--- Creating Active Response Script ---"
mkdir -p /var/ossec/active-response/bin
cat << 'EOF' > /var/ossec/active-response/bin/firewall-drop.sh
#!/bin/sh
ACTION=$1; USER=$2; IP=$3
if [ "x${IP}" = "x-" ]; then exit 0; fi
case "${ACTION}" in
    add)
        iptables -I INPUT -s "${IP}" -j DROP
        echo "$(date) Added block for ${IP}" >> /var/ossec/logs/active-responses.log ;;
    delete)
        iptables -D INPUT -s "${IP}" -j DROP
        echo "$(date) Removed block for ${IP}" >> /var/ossec/logs/active-responses.log ;;
esac
EOF

echo "--- Setting Permissions ---"
chmod 755 /var/ossec/active-response/bin/firewall-drop.sh
chown root:wazuh /var/ossec/active-response/bin/firewall-drop.sh

echo "--- Enabling and Starting Agent ---"
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

echo "--- Done! Agent is running ---"
