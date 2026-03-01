#!/bin/bash
# =========================================================================
# Vicidial Safe Deep Clean & Optimization Script
# =========================================================================

echo "Developed solely for Beltalk Technologies by Debjit"
echo "Starting Vicidial Deep Clean and Optimization..."
echo "WARNING: Ensure no active calls are currently routing."
sleep 3

# 1. Clean Up Old Logs (Older than 14 days)
# This clears out massive text logs that bog down disk IO.
echo "[1/4] Cleaning up old system and Asterisk logs..."
find /var/log/asterisk -type f -name "*.txt" -mtime +14 -exec rm -f {} \;
find /var/log/asterisk -type f -name "*.gz" -mtime +14 -exec rm -f {} \;
find /var/log/astguiclient -type f -mtime +14 -exec rm -f {} \;

# Note: Change 'apache2' to 'httpd' if you are on AlmaLinux/CentOS
find /var/log/apache2 -type f -name "*.log.*" -mtime +14 -exec rm -f {} \; 

# 2. Clear Old PHP Sessions
# Stale sessions can cause the agent interface to feel sluggish.
echo "[2/4] Clearing stale PHP sessions..."
if [ -d /var/lib/php/sessions ]; then
    find /var/lib/php/sessions -type f -mtime +2 -exec rm -f {} \;
elif [ -d /var/lib/php/session ]; then
    find /var/lib/php/session -type f -mtime +2 -exec rm -f {} \;
fi

# 3. Clean Temporary Files
echo "[3/4] Cleaning /tmp directory..."
find /tmp -type f -mtime +5 -exec rm -f {} \;

# 4. Optimize the Database Using Vicidial's Native Script
# This is the most important step for the "factory reset" speed. 
# It reclaims fragmented space without deleting your records.
echo "[4/4] Running Vicidial Native Database Optimization..."
if [ -f /usr/share/astguiclient/AST_DB_optimize.pl ]; then
    /usr/share/astguiclient/AST_DB_optimize.pl --debug
else
    echo "Warning: AST_DB_optimize.pl not found in /usr/share/astguiclient/."
    echo "Skipping native DB optimization."
fi

echo "========================================================================="
echo "Cleanup finished! The server has been optimized."
echo "Recommendation: Reload Asterisk and restart your web server manually if needed."
echo "========================================================================="
