#!/bin/bash

echo "=== VICIdial Firewalld Setup Utility ==="

# Check if firewalld is installed
if ! command -v firewall-cmd &>/dev/null; then
  echo "🔍 firewalld not found. Installing it..."

  OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release | tr -d '"')
  
  case "$OS_ID" in
    opensuse*|sles*)
      zypper install -y firewalld
      ;;
    almalinux|centos|rhel)
      dnf install -y firewalld
      ;;
    debian|ubuntu)
      apt update && apt install -y firewalld
      ;;
    *)
      echo "❌ Unsupported OS: $OS_ID. Please install firewalld manually."
      exit 1
      ;;
  esac
fi

# Enable and start firewalld
echo "🔧 Enabling and starting firewalld..."
systemctl enable firewalld --now

# Choose profile
echo ""
echo "📌 Choose a firewall rule profile:"
echo "1. VICIdial 8 (non-WebRTC)"
echo "2. VICIdial 11 (with WebRTC)"
echo "3. General Purpose Firewall"
read -p "👉 Enter your choice [1-3]: " CHOICE

# Prompt for custom port input
read -p "🎯 Do you want to add custom ports? [y/N]: " CUSTOM
CUSTOM_PORTS=""
if [[ "$CUSTOM" =~ ^[Yy]$ ]]; then
  read -p "🔢 Enter custom ports (comma-separated, e.g., 9999,8888): " PORT_LIST
  IFS=',' read -ra CUSTOM_ARR <<< "$PORT_LIST"
  for port in "${CUSTOM_ARR[@]}"; do
    firewall-cmd --permanent --add-port="$port"/tcp
    echo "✅ Opened custom TCP port: $port"
  done
fi

# Apply rules based on selected profile
case "$CHOICE" in
  1)
    echo "🔥 Applying VICIdial 8 (non-WebRTC) rules..."
    PORTS=(22 80 443 3306 5060 5061 5038 10000-20000)
    ;;
  2)
    echo "🔥 Applying VICIdial 11 (with WebRTC) rules..."
    PORTS=(22 80 443 3306 5060 5061 8088 8089 10000-20000)
    ;;
  3)
    echo "🌐 Applying General Purpose Firewall rules..."
    PORTS=(22 80 443)
    ;;
  *)
    echo "❌ Invalid choice. Exiting."
    exit 1
    ;;
esac

# Apply ports
for port in "${PORTS[@]}"; do
  firewall-cmd --permanent --add-port=$port/tcp
  echo "✅ Opened TCP port: $port"
done

# Reload firewalld
echo "🔁 Reloading firewalld..."
firewall-cmd --reload

echo "✅ Firewalld rules applied successfully!"
