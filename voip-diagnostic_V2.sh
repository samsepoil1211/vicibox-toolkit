#!/bin/bash
# =========================================================================
# VoIP Diagnostic Tool v2 - Server vs. Client Isolation
# For VICIbox/Asterisk/VICIdial environments
# Usage: ./voip_diag.sh <AGENT_IP> <SIP_EXTENSION> [SIP_CHANNEL_TECH]
# Example: ./voip_diag.sh 192.168.1.50 1001 SIP
#          ./voip_diag.sh 192.168.1.50 1001 PJSIP
# =========================================================================
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <AGENT_IP> <SIP_EXTENSION> [SIP|PJSIP]"
    echo "Example: $0 192.168.1.50 1001 SIP"
    exit 1
fi

AGENT_IP="$1"
SIP_EXT="$2"
CHAN_TECH="${3:-SIP}"   # Default to SIP; pass PJSIP if applicable

PASS=0
WARN=0
FAIL=0

pass()  { echo "  ✅ $*"; ((PASS++)); }
warn()  { echo "  ⚠️  $*"; ((WARN++)); }
fail()  { echo "  ❌ $*"; ((FAIL++)); }
info()  { echo "  ℹ️  $*"; }
hdr()   { echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $*"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

hdr "VoIP Diagnostic for Extension $SIP_EXT at IP $AGENT_IP (Tech: $CHAN_TECH)"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# =========================================================================
# [1] CPU & SYSTEM RESOURCES
# =========================================================================
hdr "[1/7] CPU & System Resources"

LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
CORES=$(nproc)
info "Load Average (1m / 5m): $LOAD1 / $LOAD5 | CPU Cores: $CORES"

if (( $(echo "$LOAD1 > $CORES * 0.85" | bc -l) )); then
    fail "1-min load ($LOAD1) exceeds 85% of core count ($CORES). Asterisk is CPU-starved."
elif (( $(echo "$LOAD5 > $CORES" | bc -l) )); then
    fail "5-min load ($LOAD5) exceeds core count — sustained starvation, not a spike."
else
    pass "Load averages are within safe range."
fi

# Check iowait - requires mpstat (sysstat package)
if command -v mpstat &>/dev/null; then
    IOWAIT=$(mpstat 1 3 | awk '/Average/ {print $6}')
    info "CPU iowait (3s avg): ${IOWAIT}%"
    if (( $(echo "$IOWAIT > 10" | bc -l) )); then
        fail "High iowait ($IOWAIT%). Disk I/O is stalling the kernel, causing audio buffer gaps."
    else
        pass "iowait is normal (${IOWAIT}%)."
    fi
else
    warn "mpstat not found (install sysstat). Cannot check iowait — disk stall is a common cause of audio gaps."
fi

# Check Asterisk process niceness and real-time priority
AST_PID=$(pgrep -x asterisk | head -1)
if [ -n "$AST_PID" ]; then
    AST_NICE=$(cat /proc/$AST_PID/stat | awk '{print $19}')
    AST_RTPRIO=$(chrt -p "$AST_PID" 2>/dev/null | grep -oP 'priority: \K\d+')
    info "Asterisk PID: $AST_PID | Nice: $AST_NICE | RT Priority: ${AST_RTPRIO:-none}"
    if [ "$AST_NICE" -gt 0 ] 2>/dev/null; then
        warn "Asterisk has positive nice value ($AST_NICE). Other processes will deprioritize it."
    fi
    if [ -z "$AST_RTPRIO" ] || [ "$AST_RTPRIO" -eq 0 ] 2>/dev/null; then
        warn "Asterisk is not running with real-time scheduling (chrt). On busy servers this can cause audio frame drops."
    else
        pass "Asterisk is running with RT priority $AST_RTPRIO."
    fi
else
    fail "Asterisk process not found! Is it running?"
fi

# Memory pressure
MEM_AVAIL_MB=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
info "Available RAM: ${MEM_AVAIL_MB} MB"
if [ "$MEM_AVAIL_MB" -lt 256 ]; then
    fail "Less than 256MB RAM available. System may be swapping — severe audio impact."
elif [ "$MEM_AVAIL_MB" -lt 512 ]; then
    warn "Under 512MB RAM available. Watch for swapping under load."
else
    pass "RAM availability is healthy (${MEM_AVAIL_MB}MB free)."
fi

# =========================================================================
# [2] DAHDI TIMING (MeetMe Audio Mixing Engine)
# =========================================================================
hdr "[2/7] DAHDI Timing (MeetMe Audio Clock Source)"

if lsmod | grep -q dahdi; then
    pass "DAHDI module is loaded."
    if [ -d /proc/dahdi ]; then
        SPAN_COUNT=$(ls /proc/dahdi/ 2>/dev/null | wc -l)
        info "DAHDI spans active: $SPAN_COUNT"
    fi

    if command -v dahdi_test &>/dev/null; then
        info "Running dahdi_test -c 100 (this takes ~10 seconds)..."
        DAHDI_OUT=$(dahdi_test -c 100 2>&1)
        DAHDI_SCORE=$(echo "$DAHDI_OUT" | grep -i "worst" | grep -oP '[\d.]+(?=\s*%?)' | tail -1)

        if [ -n "$DAHDI_SCORE" ]; then
            info "DAHDI Worst-case accuracy: ${DAHDI_SCORE}%"
            if (( $(echo "$DAHDI_SCORE < 99.95" | bc -l) )); then
                fail "DAHDI accuracy ${DAHDI_SCORE}% is below 99.95%. MeetMe conference audio will be choppy for ALL agents, not just one."
            elif (( $(echo "$DAHDI_SCORE < 99.98" | bc -l) )); then
                warn "DAHDI accuracy ${DAHDI_SCORE}% is slightly degraded. Monitor under load."
            else
                pass "DAHDI timing is stable at ${DAHDI_SCORE}%."
            fi
        else
            warn "Could not parse DAHDI score. Raw output: $(echo "$DAHDI_OUT" | tail -3)"
        fi
    else
        warn "dahdi_test binary not found. Cannot verify timing accuracy."
    fi
else
    warn "DAHDI module is NOT loaded. If you're using MeetMe conferencing, this is critical — MeetMe requires DAHDI for audio mixing."
    info "Check: lsmod | grep dahdi | modprobe dahdi_dummy (if no physical hardware)"
fi

# =========================================================================
# [3] SIP PEER STATUS & CODEC
# =========================================================================
hdr "[3/7] SIP Peer Status & Codec"

PEER_INFO=$(asterisk -rx "${CHAN_TECH} show peer $SIP_EXT" 2>/dev/null)

if [ -z "$PEER_INFO" ]; then
    fail "No output from 'asterisk -rx ${CHAN_TECH} show peer $SIP_EXT'. Extension may not exist or wrong tech."
else
    SIP_STATUS=$(echo "$PEER_INFO" | grep -i "Status" | head -1 | awk -F: '{print $2}' | xargs)
    SIP_CODEC=$(echo "$PEER_INFO"  | grep -i "Codecs\|Codec" | head -1 | awk -F: '{print $2}' | xargs)
    SIP_QUALIFY=$(echo "$PEER_INFO" | grep -i "Qualify" | head -1 | awk -F: '{print $2}' | xargs)
    SIP_CANREINVITE=$(echo "$PEER_INFO" | grep -iE "Direct|CanReinvite|DirectMedia" | head -1 | awk -F: '{print $2}' | xargs)
    SIP_TRANSPORT=$(echo "$PEER_INFO" | grep -i "Transport" | head -1 | awk -F: '{print $2}' | xargs)
    SIP_JB=$(echo "$PEER_INFO" | grep -i "JitterBuffer\|jitter" | head -1)

    info "Status      : $SIP_STATUS"
    info "Codec(s)    : $SIP_CODEC"
    info "Qualify     : $SIP_QUALIFY"
    info "CanReinvite : $SIP_CANREINVITE"
    info "Transport   : $SIP_TRANSPORT"

    # Check qualify/latency
    if echo "$SIP_QUALIFY" | grep -qi "disable\|no"; then
        warn "Qualify is DISABLED for this peer. You have no RTT baseline. Enable qualify=yes in sip.conf."
    else
        SIP_MS=$(echo "$SIP_STATUS" | grep -oP '\d+(?=ms)')
        if [ -n "$SIP_MS" ]; then
            info "SIP RTT: ${SIP_MS}ms"
            if [ "$SIP_MS" -gt 150 ]; then
                fail "SIP RTT ${SIP_MS}ms is too high. Expect audio delay and potential one-way audio."
            elif [ "$SIP_MS" -gt 80 ]; then
                warn "SIP RTT ${SIP_MS}ms is borderline. Acceptable but watch for spikes."
            else
                pass "SIP RTT ${SIP_MS}ms is healthy."
            fi
        fi
    fi

    # Codec transcoding check
    if echo "$SIP_CODEC" | grep -qi "g729\|g723\|g726\|ilbc"; then
        warn "Peer is using a transcoding codec ($SIP_CODEC). Transcoding adds CPU load per active call and can cause audio degradation under load. Prefer ulaw/alaw."
    elif echo "$SIP_CODEC" | grep -qi "ulaw\|alaw\|g711"; then
        pass "Peer using native G.711 codec — no transcoding overhead."
    fi

    # CanReinvite / Direct Media — critical for RTP path
    if echo "$SIP_CANREINVITE" | grep -qi "yes\|update"; then
        fail "CanReinvite/DirectMedia is ENABLED. RTP is bypassing the Asterisk server — you cannot apply jitter buffer, DENOISE, or diagnose RTP from server side. Disable this in sip.conf (canreinvite=no) or VICIdial carrier settings."
    else
        pass "CanReinvite/DirectMedia is disabled. RTP is flowing through Asterisk (diagnosable)."
    fi

    # Jitter buffer on peer
    if echo "$SIP_PEER_INFO" | grep -qi "jitterbuffer"; then
        info "Jitter buffer config: $SIP_JB"
    fi
fi

# =========================================================================
# [4] ACTIVE CALL RTP STATS (if call in progress)
# =========================================================================
hdr "[4/7] Live RTP Stats (Active Calls)"

ACTIVE_CALLS=$(asterisk -rx "core show channels" 2>/dev/null | grep -i "$SIP_EXT")
if [ -z "$ACTIVE_CALLS" ]; then
    info "No active calls found for extension $SIP_EXT right now."
    info "Run again during a live call to capture RTP stats."
else
    CHAN_NAME=$(asterisk -rx "core show channels" 2>/dev/null | grep "$SIP_EXT" | awk '{print $1}' | head -1)
    info "Active channel: $CHAN_NAME"

    RTP_STATS=$(asterisk -rx "rtp show stats" 2>/dev/null | grep -A20 "$SIP_EXT")
    if [ -n "$RTP_STATS" ]; then
        echo "$RTP_STATS"
    else
        # Try PJSIP endpoint
        PJSIP_STATS=$(asterisk -rx "pjsip show channelstats" 2>/dev/null | grep -A5 "$SIP_EXT")
        [ -n "$PJSIP_STATS" ] && echo "$PJSIP_STATS" || info "No RTP stats available via CLI."
    fi

    # MOS estimation via channel info
    CHAN_STATS=$(asterisk -rx "core show channel $CHAN_NAME" 2>/dev/null)
    RX_JITTER=$(echo "$CHAN_STATS" | grep -i "jitter\|Jitter" | head -1)
    RX_LOST=$(echo "$CHAN_STATS"   | grep -i "lost\|Lost"   | head -1)
    [ -n "$RX_JITTER" ] && info "RTP Jitter : $RX_JITTER"
    [ -n "$RX_LOST"   ] && info "RTP Lost   : $RX_LOST"
fi

# =========================================================================
# [5] NETWORK: ICMP JITTER (Indicative only)
# =========================================================================
hdr "[5/7] ICMP Ping Test (Indicative — not RTP jitter)"

if ping -c 1 -W 1 "$AGENT_IP" &>/dev/null; then
    PING_OUT=$(ping -c 50 -i 0.2 -q "$AGENT_IP" 2>&1)
    PKT_LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
    MDEV=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $5}' 2>/dev/null)
    AVG_RTT=$(echo "$PING_OUT" | tail -1 | awk -F'/' '{print $4}' 2>/dev/null)

    info "ICMP Packet Loss : ${PKT_LOSS}%"
    info "ICMP Avg RTT     : ${AVG_RTT}ms"
    info "ICMP mdev (≈jitter): ${MDEV}ms"
    warn "NOTE: ICMP results are indicative only. UDP/RTP traffic (port 10000-20000) can behave very differently due to QoS/shaping on client routers."

    if [ "${PKT_LOSS:-0}" -gt 2 ]; then
        fail "Packet loss ${PKT_LOSS}% — even ICMP is dropping. Network path is severely degraded."
    elif [ "${PKT_LOSS:-0}" -gt 0 ]; then
        warn "Minor packet loss ${PKT_LOSS}% detected via ICMP."
    else
        pass "Zero ICMP packet loss."
    fi

    if (( $(echo "${MDEV:-0} > 30" | bc -l) )); then
        fail "High ICMP jitter (mdev=${MDEV}ms). Network path is unstable."
    elif (( $(echo "${MDEV:-0} > 15" | bc -l) )); then
        warn "Moderate ICMP jitter (mdev=${MDEV}ms). May impact audio."
    else
        pass "ICMP jitter within acceptable range (mdev=${MDEV}ms)."
    fi
else
    warn "Agent IP $AGENT_IP is not responding to ICMP ping."
    warn "This is common — many OS firewalls and routers block ICMP. This does NOT mean RTP will fail."
    info "Action: Check agent-side firewall, or use iperf3 -u for real UDP path testing."
fi

# =========================================================================
# [6] UDP/RTP PORT REACHABILITY
# =========================================================================
hdr "[6/7] RTP Port Reachability (UDP)"

if command -v nc &>/dev/null; then
    # Test a few RTP ports with nc (UDP mode) - non-blocking
    info "Testing UDP RTP ports 10000, 10002, 10004 toward agent..."
    for PORT in 10000 10002 10004; do
        NC_RESULT=$(echo "" | nc -u -w 1 "$AGENT_IP" "$PORT" 2>&1)
        # nc -u to UDP doesn't confirm receipt, just checks if we can send
        info "  UDP $PORT → $AGENT_IP : sent (no ICMP reject means port may be open)"
    done
    warn "True UDP RTP verification requires iperf3 or Wireshark on the agent end. nc -u cannot confirm receipt."
else
    warn "nc (netcat) not available. Skipping UDP port test."
fi

# Check Asterisk RTP port config
RTP_START=$(grep -E "^rtpstart" /etc/asterisk/rtp.conf 2>/dev/null | awk -F= '{print $2}' | xargs)
RTP_END=$(grep -E "^rtpend"   /etc/asterisk/rtp.conf 2>/dev/null | awk -F= '{print $2}' | xargs)
info "Asterisk RTP port range: ${RTP_START:-unknown} – ${RTP_END:-unknown}"
if [ -n "$RTP_START" ]; then
    pass "rtp.conf found. Ensure firewall allows UDP $RTP_START–$RTP_END bidirectionally."
else
    warn "Could not read /etc/asterisk/rtp.conf. Confirm RTP port range manually."
fi

# =========================================================================
# [7] JITTER BUFFER CONFIG FOR THIS PEER
# =========================================================================
hdr "[7/7] Jitter Buffer Configuration"

# Check global jitter buffer in sip.conf
JB_ENABLE=$(grep -E "^jbenable"  /etc/asterisk/sip.conf 2>/dev/null | awk -F= '{print $2}' | xargs)
JB_FORCE=$(grep -E "^jbforce"   /etc/asterisk/sip.conf 2>/dev/null | awk -F= '{print $2}' | xargs)
JB_IMPL=$(grep -E "^jbimpl"     /etc/asterisk/sip.conf 2>/dev/null | awk -F= '{print $2}' | xargs)
JB_MAX=$(grep -E "^jbmaxsize"   /etc/asterisk/sip.conf 2>/dev/null | awk -F= '{print $2}' | xargs)

info "sip.conf jitter buffer settings:"
info "  jbenable  = ${JB_ENABLE:-not set}"
info "  jbforce   = ${JB_FORCE:-not set}"
info "  jbimpl    = ${JB_IMPL:-not set (default: fixed)}"
info "  jbmaxsize = ${JB_MAX:-not set (default: 200ms)}"

if [ "${JB_ENABLE:-no}" = "yes" ]; then
    pass "Jitter buffer is enabled."
    if [ "${JB_IMPL:-fixed}" = "fixed" ]; then
        warn "Jitter buffer is using 'fixed' implementation. For variable network conditions (remote agents, VPNs, ISP routing), 'adaptive' is preferred."
        info "Fix: Set 'jbimpl=adaptive' and 'jbmaxsize=400' in [general] section of sip.conf, then 'asterisk -rx sip reload'."
    else
        pass "Jitter buffer implementation: $JB_IMPL."
    fi
    if [ -n "$JB_MAX" ] && [ "$JB_MAX" -lt 300 ] 2>/dev/null; then
        warn "jbmaxsize=${JB_MAX}ms may be too small for remote/WFH agents. Consider 300–500ms."
    fi
else
    fail "Jitter buffer is DISABLED (jbenable=no or not set). This is the most common server-side cause of audio breaks for remote agents."
    info "Fix: Add to /etc/asterisk/sip.conf [general]:"
    info "     jbenable=yes"
    info "     jbforce=yes"
    info "     jbimpl=adaptive"
    info "     jbmaxsize=400"
    info "Then run: asterisk -rx 'sip reload'"
fi

# =========================================================================
# SUMMARY
# =========================================================================
hdr "DIAGNOSTIC SUMMARY"
echo "  ✅ PASS : $PASS"
echo "  ⚠️  WARN : $WARN"
echo "  ❌ FAIL : $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "  🔴 RESULT: Critical issues found. Address FAILs before investigating network."
elif [ "$WARN" -gt 0 ]; then
    echo "  🟡 RESULT: No critical failures, but warnings may explain intermittent audio issues."
else
    echo "  🟢 RESULT: Server-side looks clean. Issue is likely client-side (agent NIC, ISP, codec, softphone)."
fi

echo ""
echo "  NEXT STEPS IF ISSUE PERSISTS:"
echo "  1. Run this script DURING a live call to capture live RTP stats [Section 4]"
echo "  2. Capture Wireshark/tcpdump on server: tcpdump -i any -nn udp portrange $RTP_START-$RTP_END -w /tmp/rtp_${SIP_EXT}.pcap"
echo "  3. Have agent run iperf3 test: iperf3 -u -c <server_ip> -b 200k -t 30 (simulates RTP load)"
echo "  4. Check agent-side: NIC driver, OS jitter buffer, softphone codec settings, VPN overhead"
echo "  5. Check carrier RTP path: asterisk -rx 'sip show peers' for carrier RTT during call"
echo ""
echo "  Diagnostic complete: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
