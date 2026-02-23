#!/bin/bash
# -----------------------------------------------------------
# VICIdial Log & Database Cleanup Script 
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
    "/var/log/amd"
)

echo "----------------------------------------"
echo "🧹 VICIdial System Cleanup Script Started"
echo "----------------------------------------"
echo "Detected OS: $ID"
echo "Apache log directory: $APACHE_LOG_DIR"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

# --- Phase 1: File System Cleanup ---
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
echo "📦 Total file log size: ${TOTAL_MB} MB"

if (( TOTAL_SIZE > THRESHOLD_BYTES )); then
    echo "⚠️  File log size exceeded ${THRESHOLD_MB}MB. Cleaning up files..."

    for DIR in "${LOG_DIRS[@]}"; do
        if [ -d "$DIR" ]; then
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
    echo "✅ All junk file logs deleted."
else
    echo "✅ File log size under ${THRESHOLD_MB}MB. No file cleanup needed."
fi

# --- Phase 2: MySQL Archive Truncation ---
echo
echo "🗄️  Wiping MySQL Archive Tables..."
mysql -e "
TRUNCATE TABLE asterisk.call_log_archive;
TRUNCATE TABLE asterisk.vicidial_log_archive;
TRUNCATE TABLE asterisk.vicidial_log_extended_archive;
TRUNCATE TABLE asterisk.vicidial_dial_log_archive;
TRUNCATE TABLE asterisk.vicidial_dial_cid_log_archive;
TRUNCATE TABLE asterisk.vicidial_carrier_log_archive;
TRUNCATE TABLE asterisk.vicidial_agent_log_archive;
TRUNCATE TABLE asterisk.vicidial_agent_visibility_log_archive;
TRUNCATE TABLE asterisk.vicidial_amd_log_archive;
"
echo "✅ MySQL Archive tables successfully truncated."

# --- Phase 3: Logging ---
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] OS: $ID | Total File Size: ${TOTAL_MB}MB"
    if (( TOTAL_SIZE > THRESHOLD_BYTES )); then
        echo "Action: Deleted file logs and truncated MySQL archives."
    else
        echo "Action: Truncated MySQL archives only (File logs under threshold)."
    fi
    echo "----------------------------------------"
} >> "$LOGFILE"

echo
echo "🕒 Cleanup completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "📝 Log recorded in: $LOGFILE"
echo "----------------------------------------"
