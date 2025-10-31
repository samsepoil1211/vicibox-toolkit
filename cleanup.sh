#!/bin/bash
# -----------------------------------------------------------
# VICIdial Log Cleanup Script (Dynamic for OpenSUSE / Alma / RHEL)
# Author: Debjit (Beltalk Technology)
# -----------------------------------------------------------

LOGFILE="/cleanup-logs.txt"
THRESHOLD_MB=500
THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))

# Detect OS and set Apache log directory
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        opensuse*|sles*)
            APACHE_LOG_DIR="/var/log/apache2"
            ;;
        almalinux*|rhel*|centos*)
            APACHE_LOG_DIR="/var/log/httpd"
            ;;
        *)
            APACHE_LOG_DIR="/var/log/httpd"
            ;;
    esac
else
    APACHE_LOG_DIR="/var/log/httpd"
fi

# Log directories to check
LOG_DIRS=(
    "/var/log/asterisk"
    "/var/log/astguiclient"
    "$APACHE_LOG_DIR"
)

echo "----------------------------------------"
echo "🧹 VICIdial Log Cleanup Script Started"
echo "----------------------------------------"
echo "Detected OS: $ID"
echo "Apache log directory: $APACHE_LOG_DIR"
echo "Threshold: ${THRESHOLD_MB}MB"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

TOTAL_SIZE=0
for DIR in "${LOG_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        DIR_SIZE=$(du -sb "$DIR" | awk '{print $1}')
        TOTAL_SIZE=$((TOTAL_SIZE + DIR_SIZE))
        HUMAN_SIZE=$(du -sh "$DIR" | awk '{print $1}')
        echo "• $DIR → $HUMAN_SIZE"
    fi
done

TOTAL_MB=$(echo "scale=2; $TOTAL_SIZE/1024/1024" | bc)
echo
echo "📦 Total log size: ${TOTAL_MB} MB"

if (( TOTAL_SIZE > THRESHOLD_BYTES )); then
    echo "⚠️  Log size exceeded ${THRESHOLD_MB}MB. Cleaning up..."

    for DIR in "${LOG_DIRS[@]}"; do
        if [ -d "$DIR" ]; then
            # Remove common VICIdial junk log formats
            find "$DIR" -type f \( \
                -name "*.log" -o \
                -name "*.old" -o \
                -name "*.gz" -o \
                -name "screenlog.*" -o \
                -name "agiout.*" -o \
                -name "safe_*" -o \
                -name "go_*" \
            \) -delete
        fi
    done

    echo "✅ All junk logs deleted successfully."
    echo "🕒 Cleanup completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
    echo "✅ Log size under ${THRESHOLD_MB}MB. No cleanup needed."
fi

{
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] OS: $ID | Total Size: ${TOTAL_MB}MB"
    if (( TOTAL_SIZE > THRESHOLD_BYTES )); then
        echo "Action: Deleted all junk log files (*.log, *.gz, *.old, screenlog.*, etc.)"
    else
        echo "Action: No cleanup required"
    fi
    echo "----------------------------------------"
} >> "$LOGFILE"

echo
echo "📝 Log recorded in: $LOGFILE"
echo "----------------------------------------"

