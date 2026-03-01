#!/bin/bash
# =========================================================================
# VoIP Diagnostic Tool - Server vs. Client Isolation
# =========================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <AGENT_IP> <SIP_EXTENSION>"
    echo "Example: $0 192.168.1.50 1001"
    exit 1
fi

AGENT_IP=$1
SIP_EXT=$2

echo "========================================================================="
echo " Starting VoIP Diagnostic for Extension $SIP_EXT at IP $AGENT_IP"
echo "========================================================================="

# ---------------------------------------------------------
# 1. SERVER END: Check CPU & Load Average
# ---------------------------------------------------------
echo -e "\n[1/4] Checking Server Load (CPU Starvation Test)..."
LOAD=$(awk '{print $1}' /proc/loadavg)
CORES=$(nproc)
echo "Current Server Load Average (1-min): $LOAD"
echo "Total CPU Cores: $CORES"

if (( $(echo "$LOAD > $CORES" | bc -l) )); then
    echo "❌ WARNING: Server load exceeds available cores. Asterisk is starving for CPU."
else
    echo "✅ Server load is healthy. Asterisk has enough resources to process audio."
fi

# ---------------------------------------------------------
# 2. SERVER END: Check DAHDI Timing (MeetMe Audio Mixing)
# ---------------------------------------------------------
echo -e "\n[2/4] Checking DAHDI Timing Accuracy..."
if command -v dahdi_test &> /dev/null; then
    # Run a quick 3-pass test and extract the worst score
    DAHDI_SCORE=$(dahdi_test -c 3 | grep "Worst" | awk '{print $NF}' | tr -d '%')
    echo "DAHDI Timing Accuracy: $DAHDI_SCORE%"
    
    if (( $(echo "$DAHDI_SCORE < 99.98" | bc -l) )); then
         echo "❌ WARNING: DAHDI timing is dropping below 99.98%. This causes choppy audio in conferences."
    else
         echo "✅ DAHDI timing is stable."
    fi
else
    echo "⚠️ dahdi_test command not found. Skipping timing check."
fi

# ---------------------------------------------------------
# 3. NETWORK END: SIP Latency Check
# ---------------------------------------------------------
echo -e "\n[3/4] Checking SIP Latency to Agent Softphone..."
SIP_STATUS=$(asterisk -rx "sip show peer $SIP_EXT" | grep "Status" | awk '{print $3, $4}')
echo "SIP Status/Ping: $SIP_STATUS"

# ---------------------------------------------------------
# 4. NETWORK END: Jitter and Packet Loss Test
# ---------------------------------------------------------
echo -e "\n[4/4] Running 50-packet aggressive ping test to Agent IP..."
echo "(This measures network jitter and packet loss. Please wait ~10 seconds...)"

PING_RESULT=$(ping -c 50 -i 0.2 -q "$AGENT_IP" 2>&1)

if [[ $PING_RESULT == *"100% packet loss"* ]] || [[ $PING_RESULT == *"Destination Host Unreachable"* ]]; then
    echo "❌ CRITICAL: 100% Packet Loss. The agent IP is unreachable or blocking ICMP ping."
else
    # Extract packet loss percentage and jitter (mdev)
    PKT_LOSS=$(echo "$PING_RESULT" | grep -oP '\d+(?=% packet loss)')
    RTT_STATS=$(echo "$PING_RESULT" | tail -1 | awk -F '/' '{print $5}')
    
    echo "Packet Loss: $PKT_LOSS%"
    echo "Network Jitter (mdev): $RTT_STATS ms"

    if [ "$PKT_LOSS" -gt 1 ]; then
        echo "❌ WARNING: Network is dropping packets. Audio will break regardless of server health."
    elif (( $(echo "$RTT_STATS > 20" | bc -l) )); then
        echo "❌ WARNING: High jitter detected. The network routing is unstable."
    else
        echo "✅ Network path is clean. Low jitter and zero packet loss."
    fi
fi

echo -e "\n========================================================================="
echo " Diagnostic Complete."
echo "========================================================================="
