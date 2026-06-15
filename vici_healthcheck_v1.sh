#!/bin/bash
# =============================================================================
# VICIdial Idle Agent Diagnostic Script
# Issue: 70+ calls showing 200 OK but agents remain idle
# Goal:  Determine → SERVER-SIDE issue or CLIENT-SIDE data/lead issue
# Safe:  READ-ONLY — zero changes, zero impact on live calls
# Compat: VICIbox 11 / Asterisk 13 / openSUSE
# =============================================================================

VERSION="1.0"
REPORT="/tmp/vici_idle_diag_$(date +%Y%m%d_%H%M%S).txt"
LOG_FILE="/var/log/asterisk/full"
VICIDIAL_LOG="/var/log/asterisk/messages"
MYSQL_CMD="mysql -u root --socket=/var/run/mysql/mysql.sock -s -N asterisk"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
MAGENTA='\033[0;35m'
RESET='\033[0m'

# Verdict trackers
SERVER_ISSUES=0
CLIENT_ISSUES=0
declare -a SERVER_FINDINGS=()
declare -a CLIENT_FINDINGS=()
declare -a INFO_FINDINGS=()

# =============================================================================
# HELPERS
# =============================================================================
section() {
  echo ""
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

server_issue() {
  echo -e "  ${RED}[SERVER]${RESET} $1"
  SERVER_FINDINGS+=("$1")
  (( SERVER_ISSUES++ )) || true
}

client_issue() {
  echo -e "  ${YELLOW}[CLIENT/DATA]${RESET} $1"
  CLIENT_FINDINGS+=("$1")
  (( CLIENT_ISSUES++ )) || true
}

ok() {
  echo -e "  ${GREEN}✔${RESET}  $1"
}

info() {
  echo -e "  ${DIM}ℹ${RESET}  $1"
  INFO_FINDINGS+=("$1")
}

warn() {
  echo -e "  ${YELLOW}⚠${RESET}  $1"
}

metric() {
  printf "  ${BOLD}%-42s${RESET} %s\n" "$1" "$2"
}

q() {
  # Safe MySQL query with fallback
  $MYSQL_CMD -e "$1" 2>/dev/null || echo "N/A"
}

# =============================================================================
# HEADER
# =============================================================================
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║     VICIdial Idle Agent Diagnostic — READ ONLY — LIVE SAFE         ║${RESET}"
echo -e "${BOLD}${CYAN}║     Issue: 200 OK calls fired but agents sitting idle               ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo -e "  Host : $(hostname -f 2>/dev/null || hostname)"
echo -e "  Time : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  Mode : READ-ONLY — no changes will be made"
echo ""

# =============================================================================
# 1. AGENT STATUS SNAPSHOT
# =============================================================================
section "1 — AGENT STATUS SNAPSHOT (right now)"

# Total agents logged in
AGENTS_LOGGED=$(q "SELECT COUNT(*) FROM vicidial_live_agents WHERE last_update_time > NOW() - INTERVAL 5 MINUTE;")
metric "Agents logged in (active last 5 min):" "$AGENTS_LOGGED"

# Agent state breakdown
echo ""
echo -e "  ${BOLD}Agent state breakdown:${RESET}"
q "
SELECT
  status,
  COUNT(*) as count,
  ROUND(AVG(TIMESTAMPDIFF(SECOND, last_update_time, NOW())),1) as avg_seconds_in_state
FROM vicidial_live_agents
WHERE last_update_time > NOW() - INTERVAL 10 MINUTE
GROUP BY status
ORDER BY count DESC;
" 2>/dev/null | while IFS=$'\t' read -r status count avg_sec; do
  label=""
  color="$RESET"
  case "$status" in
    READY)       label="waiting for call";  color="$GREEN"  ;;
    INCALL)      label="on a live call";    color="$CYAN"   ;;
    PAUSED)      label="paused/break";      color="$YELLOW" ;;
    DEAD)        label="session dead";      color="$RED"    ;;
    CLOSER)      label="closer agent";      color="$BLUE"   ;;
    QUEUE)       label="in queue";          color="$MAGENTA";;
    *)           label="other"                              ;;
  esac
  printf "  ${color}  %-12s${RESET}  count: %-4s  avg time in state: %s sec  (%s)\n" \
    "$status" "$count" "$avg_sec" "$label"
done

echo ""

# Agents READY but not getting calls (the core symptom)
AGENTS_READY=$(q "SELECT COUNT(*) FROM vicidial_live_agents WHERE status='READY' AND last_update_time > NOW() - INTERVAL 5 MINUTE;")
AGENTS_INCALL=$(q "SELECT COUNT(*) FROM vicidial_live_agents WHERE status='INCALL' AND last_update_time > NOW() - INTERVAL 5 MINUTE;")
AGENTS_PAUSED=$(q "SELECT COUNT(*) FROM vicidial_live_agents WHERE status='PAUSED' AND last_update_time > NOW() - INTERVAL 5 MINUTE;")

metric "Agents in READY state (should get calls):" "$AGENTS_READY"
metric "Agents in INCALL state:" "$AGENTS_INCALL"
metric "Agents in PAUSED state:" "$AGENTS_PAUSED"

# How long have READY agents been waiting?
echo ""
echo -e "  ${BOLD}READY agents — time waiting (idle duration):${RESET}"
q "
SELECT
  user,
  campaign_id,
  TIMESTAMPDIFF(SECOND, last_update_time, NOW()) as idle_seconds,
  closer_campaigns,
  conf_exten
FROM vicidial_live_agents
WHERE status='READY'
  AND last_update_time > NOW() - INTERVAL 10 MINUTE
ORDER BY idle_seconds DESC
LIMIT 15;
" 2>/dev/null | while IFS=$'\t' read -r user camp idle_sec closer conf; do
  flag=""
  color="$GREEN"
  if (( idle_sec > 120 )); then
    flag="⚠ IDLE TOO LONG"
    color="$RED"
  elif (( idle_sec > 60 )); then
    flag="⚠ elevated wait"
    color="$YELLOW"
  fi
  printf "  ${color}  Agent:%-20s Camp:%-12s Idle:%4ss  Conf:%-8s %s${RESET}\n" \
    "$user" "$camp" "$idle_sec" "$conf" "$flag"
done

# Check if READY agents have valid conference extensions assigned
AGENTS_NO_CONF=$(q "
SELECT COUNT(*) FROM vicidial_live_agents
WHERE status='READY'
  AND (conf_exten IS NULL OR conf_exten='' OR conf_exten='0')
  AND last_update_time > NOW() - INTERVAL 5 MINUTE;
")
if [[ "$AGENTS_NO_CONF" -gt 0 ]] 2>/dev/null; then
  server_issue "$AGENTS_NO_CONF READY agent(s) have NO conference extension assigned — calls cannot be bridged to them"
else
  ok "All READY agents have conference extensions assigned"
fi

# =============================================================================
# 2. LIVE CALL CHANNEL ANALYSIS
# =============================================================================
section "2 — LIVE CALL CHANNEL ANALYSIS (Asterisk)"

# Total channels
TOTAL_CH=$(asterisk -rx "core show channels count" 2>/dev/null | grep -Eo '^[0-9]+' | head -1 || echo "0")
metric "Total active Asterisk channels:" "$TOTAL_CH"

# Channel type breakdown
echo ""
echo -e "  ${BOLD}Channel state breakdown:${RESET}"
asterisk -rx "core show channels" 2>/dev/null | grep -v '^$' | grep -v 'Channel\|active call\|active channel' | \
awk '{print $4}' | sort | uniq -c | sort -rn | while read -r count state; do
  color="$RESET"
  note=""
  case "$state" in
    Up)      color="$GREEN";  note="bridged/active" ;;
    Ring)    color="$YELLOW"; note="ringing at agent/carrier" ;;
    Ringing) color="$YELLOW"; note="outbound ringing" ;;
    Down)    color="$RED";    note="hanging up" ;;
    Rsrvd)   color="$DIM";    note="reserved" ;;
  esac
  printf "  ${color}  %-12s  count: %-5s  (%s)${RESET}\n" "$state" "$count" "$note"
done

# Calls in Up state vs calls actually bridged to agents
CALLS_UP=$(asterisk -rx "core show channels" 2>/dev/null | grep -c ' Up ' || echo "0")
CALLS_BRIDGED=$(asterisk -rx "core show channels" 2>/dev/null | grep -c 'Local/' || echo "0")

metric "Channels in UP state (answered):" "$CALLS_UP"
metric "Local/ channels (agent bridge legs):" "$CALLS_BRIDGED"

# The critical ratio: calls up vs agents in call
echo ""
if [[ "$CALLS_UP" -gt 0 ]] && [[ "$AGENTS_INCALL" -gt 0 ]]; then
  RATIO=$(echo "scale=1; $CALLS_UP / $AGENTS_INCALL" | bc 2>/dev/null || echo "N/A")
  metric "Channels UP per agent INCALL ratio:" "$RATIO"
  if (( $(echo "$RATIO > 3" | bc -l 2>/dev/null || echo 0) )); then
    server_issue "High channel/agent ratio ($RATIO) — many 200 OK calls not reaching agents (routing or conference issue)"
  fi
fi

# Check for calls stuck in conference waiting
echo ""
echo -e "  ${BOLD}Calls waiting in VICIdial conference (not yet bridged to agent):${RESET}"
CONF_WAITING=$(asterisk -rx "confbridge list" 2>/dev/null | grep -c 'waiting\|CONF' || echo "0")
asterisk -rx "confbridge list" 2>/dev/null | head -20 || \
  asterisk -rx "meetme list" 2>/dev/null | head -20 || \
  info "Could not list conference rooms (may use different conference backend)"

# =============================================================================
# 3. VICIDIAL HOPPER & LEAD STATUS
# =============================================================================
section "3 — VICIDIAL HOPPER & LEAD QUALITY"

# Hopper size per campaign
echo -e "  ${BOLD}Hopper status per active campaign:${RESET}"
echo ""
q "
SELECT
  vh.campaign_id,
  COUNT(*) as hopper_count,
  vc.dial_status_a,
  vc.dial_status_b,
  vc.dial_status_c,
  vc.hopper_level,
  vc.auto_dial_level
FROM vicidial_hopper vh
JOIN vicidial_campaigns vc ON vh.campaign_id = vc.campaign_id
WHERE vc.active='Y'
GROUP BY vh.campaign_id
ORDER BY hopper_count DESC;
" 2>/dev/null | while IFS=$'\t' read -r camp count stat_a stat_b stat_c hopper_level dial_level; do
  color="$GREEN"
  flag=""
  if (( count < 10 )) 2>/dev/null; then
    color="$RED"
    flag="⚠ HOPPER NEARLY EMPTY"
    client_issue "Campaign '$camp' hopper has only $count leads — dialer will idle agents"
  elif (( count < 50 )) 2>/dev/null; then
    color="$YELLOW"
    flag="⚠ low"
  fi
  printf "  ${color}  Campaign: %-15s  Hopper: %-6s  DialLevel: %-4s  HopperLevel: %-6s  %s${RESET}\n" \
    "$camp" "$count" "$dial_level" "$hopper_level" "$flag"
done

echo ""

# Total hopper
TOTAL_HOPPER=$(q "SELECT COUNT(*) FROM vicidial_hopper;")
metric "Total leads in hopper (all campaigns):" "$TOTAL_HOPPER"

if [[ "$TOTAL_HOPPER" == "0" ]] || [[ "$TOTAL_HOPPER" == "N/A" ]]; then
  client_issue "Hopper is EMPTY — no leads queued for dialing. Agents will sit idle regardless of dial ratio."
fi

# Lead status breakdown in hopper
echo ""
echo -e "  ${BOLD}Hopper lead status breakdown:${RESET}"
q "
SELECT status, COUNT(*) as count
FROM vicidial_hopper
GROUP BY status
ORDER BY count DESC;
" 2>/dev/null | while IFS=$'\t' read -r status count; do
  printf "  ${DIM}  status: %-15s  count: %s${RESET}\n" "$status" "$count"
done

# Check for leads stuck in 'INCALL' status in hopper (should not happen)
STUCK_INCALL=$(q "SELECT COUNT(*) FROM vicidial_hopper WHERE status='INCALL';")
if [[ "$STUCK_INCALL" -gt 0 ]] 2>/dev/null; then
  server_issue "$STUCK_INCALL lead(s) stuck in INCALL status in hopper — VDAD not cleaning up properly"
fi

# =============================================================================
# 4. AMD (ANSWERING MACHINE DETECTION) ANALYSIS
# =============================================================================
section "4 — AMD ANALYSIS (call killer check)"

# AMD results in last 30 minutes from vicidial_log
echo -e "  ${BOLD}Call dispositions in last 30 minutes:${RESET}"
echo ""
q "
SELECT
  status,
  COUNT(*) as count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) as pct
FROM vicidial_log
WHERE call_date > NOW() - INTERVAL 30 MINUTE
GROUP BY status
ORDER BY count DESC
LIMIT 20;
" 2>/dev/null | while IFS=$'\t' read -r status count pct; do
  color="$RESET"
  note=""
  case "$status" in
    SALE|CALLBK|DNC)    color="$GREEN"  ;;
    DROP|ABAND|AFTHRS)  color="$RED";   note="← dropped/abandoned" ;;
    AM|AA|AMD)          color="$YELLOW"; note="← answering machine detected" ;;
    DNCL|DCBK)         color="$DIM"    ;;
    N|NA)               color="$DIM";   note="← no answer" ;;
    INCALL)             color="$CYAN"   ;;
  esac
  printf "  ${color}  %-10s  count: %-6s  pct: %-6s  %s${RESET}\n" \
    "$status" "$count" "${pct}%" "$note"
done

echo ""

# AMD kill rate
AMD_KILLS=$(q "SELECT COUNT(*) FROM vicidial_log WHERE status IN ('AM','AA','AMD','MACHINE') AND call_date > NOW() - INTERVAL 30 MINUTE;" 2>/dev/null || echo "0")
TOTAL_ANSWERED=$(q "SELECT COUNT(*) FROM vicidial_log WHERE call_date > NOW() - INTERVAL 30 MINUTE;" 2>/dev/null || echo "0")
DROP_COUNT=$(q "SELECT COUNT(*) FROM vicidial_log WHERE status IN ('DROP','ABAND') AND call_date > NOW() - INTERVAL 30 MINUTE;" 2>/dev/null || echo "0")

metric "AMD kills (last 30 min):" "$AMD_KILLS"
metric "DROP/ABANDON (last 30 min):" "$DROP_COUNT"
metric "Total call records (last 30 min):" "$TOTAL_ANSWERED"

if [[ "$TOTAL_ANSWERED" -gt 0 ]] && [[ "$AMD_KILLS" -gt 0 ]]; then
  AMD_PCT=$(echo "scale=1; $AMD_KILLS * 100 / $TOTAL_ANSWERED" | bc 2>/dev/null || echo "N/A")
  metric "AMD kill rate:" "${AMD_PCT}%"
  if (( $(echo "$AMD_PCT > 60" | bc -l 2>/dev/null || echo 0) )); then
    client_issue "AMD killing ${AMD_PCT}% of answered calls — lead list is heavily machine/voicemail (data quality issue)"
  elif (( $(echo "$AMD_PCT > 40" | bc -l 2>/dev/null || echo 0) )); then
    warn "AMD kill rate elevated: ${AMD_PCT}% — check lead list quality"
    client_issue "High AMD rate (${AMD_PCT}%) — significant portion of leads are non-human answers"
  else
    ok "AMD kill rate acceptable: ${AMD_PCT}%"
  fi
fi

if [[ "$DROP_COUNT" -gt 0 ]] && [[ "$TOTAL_ANSWERED" -gt 0 ]]; then
  DROP_PCT=$(echo "scale=1; $DROP_COUNT * 100 / $TOTAL_ANSWERED" | bc 2>/dev/null || echo "N/A")
  metric "Drop/abandon rate:" "${DROP_PCT}%"
  if (( $(echo "$DROP_PCT > 5" | bc -l 2>/dev/null || echo 0) )); then
    server_issue "Drop rate ${DROP_PCT}% exceeds FTC limit (5%) — calls answered but no agent available fast enough"
  else
    ok "Drop rate within acceptable range: ${DROP_PCT}%"
  fi
fi

# =============================================================================
# 5. DIAL RATIO & AGENT MATH
# =============================================================================
section "5 — DIAL RATIO vs AGENT AVAILABILITY MATH"

echo -e "  ${BOLD}Active campaign settings:${RESET}"
echo ""
q "
SELECT
  campaign_id,
  campaign_name,
  active,
  dial_status_a,
  auto_dial_level,
  hopper_level,
  available_only_ratio_tally,
  dial_timeout,
  answering_machine_detection,
  am_message_exten,
  drop_call_seconds,
  safe_harbor_exten
FROM vicidial_campaigns
WHERE active='Y'
ORDER BY campaign_id;
" 2>/dev/null | while IFS=$'\t' read -r cid cname active stat_a dial_level hopper_level avail_tally timeout amd am_exten drop_sec safe_harbor; do
  echo -e "  ${BOLD}${CYAN}Campaign: $cid — $cname${RESET}"
  metric "    Active:" "$active"
  metric "    Auto dial level (ratio):" "$dial_level"
  metric "    Hopper level:" "$hopper_level"
  metric "    Dial timeout:" "${timeout}s"
  metric "    AMD mode:" "$amd"
  metric "    AM message extension:" "$am_exten"
  metric "    Drop call seconds:" "${drop_sec}s"
  metric "    Available only ratio tally:" "$avail_tally"

  # Flag dangerous dial ratio
  if (( $(echo "$dial_level > 3" | bc -l 2>/dev/null || echo 0) )); then
    warn "    Dial ratio $dial_level:1 is aggressive — expect high drops if agent count fluctuates"
  fi

  # Check if AMD is off but calls are going to AM_MESSAGE_EXTEN
  if [[ "$amd" == "N" ]] && [[ -n "$am_exten" ]] && [[ "$am_exten" != "none" ]]; then
    info "    AMD is OFF but am_message_exten is set — machines may get dead air"
  fi

  echo ""
done

# Agent vs dial ratio math
echo -e "  ${BOLD}Dial ratio math (right now):${RESET}"
echo ""
q "
SELECT
  vla.campaign_id,
  COUNT(CASE WHEN vla.status='READY' THEN 1 END) as ready_agents,
  COUNT(CASE WHEN vla.status='INCALL' THEN 1 END) as incall_agents,
  COUNT(*) as total_agents,
  vc.auto_dial_level
FROM vicidial_live_agents vla
JOIN vicidial_campaigns vc ON vla.campaign_id = vc.campaign_id
WHERE vla.last_update_time > NOW() - INTERVAL 5 MINUTE
  AND vc.active = 'Y'
GROUP BY vla.campaign_id;
" 2>/dev/null | while IFS=$'\t' read -r camp ready incall total dial_level; do
  expected_calls=$(echo "scale=0; $ready * $dial_level" | bc 2>/dev/null || echo "N/A")
  echo -e "  ${BOLD}Campaign $camp:${RESET}"
  metric "    READY agents:" "$ready"
  metric "    INCALL agents:" "$incall"
  metric "    Total agents:" "$total"
  metric "    Dial ratio setting:" "${dial_level}:1"
  metric "    Expected calls in flight:" "$expected_calls"
  echo ""

  if [[ "$ready" == "0" ]] && [[ "$total" -gt 0 ]] 2>/dev/null; then
    server_issue "Campaign $camp: $total agents logged in but ZERO in READY state — all paused or stuck"
  fi
done

# =============================================================================
# 6. VICIDIAL AUTO-DIAL DAEMON HEALTH
# =============================================================================
section "6 — VICIDIAL DAEMON (VDAD) HEALTH"

# Find the actual daemon process name on this system
echo -e "  ${BOLD}VICIdial daemon processes:${RESET}"
ps aux | grep -E 'VDAD|vicidial_auto|AST_auto|manager_send|FastAGI|ip_relay' | grep -v grep | \
while read -r line; do
  echo -e "  ${GREEN}✔${RESET}  $line"
done

VDAD_COUNT=$(ps aux | grep -E 'VDAD|vicidial_auto|AST_auto' | grep -v grep | wc -l)
if (( VDAD_COUNT == 0 )); then
  server_issue "No VICIdial auto-dial daemon (VDAD) running — dialer is completely stopped"
else
  ok "$VDAD_COUNT VDAD process(es) running"
fi

# FastAGI server (handles call routing logic)
FASTAGI_COUNT=$(ps aux | grep -i 'FastAGI\|fastagi' | grep -v grep | wc -l)
if (( FASTAGI_COUNT == 0 )); then
  server_issue "FastAGI server not running — VICIdial cannot execute call routing scripts"
  info "Fix: check vicidial cron for FastAGI server startup"
else
  ok "FastAGI server running ($FASTAGI_COUNT process[es])"
fi

# Manager (AMI) connection
echo ""
echo -e "  ${BOLD}Asterisk Manager Interface (AMI) — VDAD connection:${RESET}"
AMI_CONNECTED=$(asterisk -rx "manager show connected" 2>/dev/null | grep -c 'vicidial\|VDAD\|cron' || echo "0")
asterisk -rx "manager show connected" 2>/dev/null | grep -v '^$' | head -10 | while read -r line; do
  echo -e "  ${DIM}  $line${RESET}"
done

if [[ "$AMI_CONNECTED" -eq 0 ]]; then
  server_issue "No VICIdial AMI connections detected — VDAD cannot control Asterisk call routing"
else
  ok "VICIdial AMI connections active: $AMI_CONNECTED"
fi

# Check VDAD log for errors in last 5 minutes
echo ""
echo -e "  ${BOLD}Recent VDAD errors (last 5 min from Asterisk log):${RESET}"
VDAD_ERRORS=$(grep -i 'VDAD\|vicidial.*error\|auto_dial.*error\|hopper.*error' \
  /var/log/asterisk/full 2>/dev/null | \
  awk -v d="$(date -d '5 minutes ago' '+%b %_d %H:%M' 2>/dev/null || date -v-5M '+%b %_d %H:%M' 2>/dev/null)" \
  '$0 > d' | tail -10)

if [[ -n "$VDAD_ERRORS" ]]; then
  echo "$VDAD_ERRORS" | while read -r line; do
    echo -e "  ${RED}  $line${RESET}"
  done
  server_issue "VDAD errors found in recent Asterisk log"
else
  ok "No VDAD errors in recent log"
fi

# =============================================================================
# 7. CONFERENCE / BRIDGE ROUTING CHECK
# =============================================================================
section "7 — CONFERENCE BRIDGE ROUTING"

# Conference rooms in use
echo -e "  ${BOLD}Active conference rooms (where calls wait for agents):${RESET}"
CONF_OUTPUT=$(asterisk -rx "meetme list" 2>/dev/null || asterisk -rx "confbridge list" 2>/dev/null || echo "")
if [[ -n "$CONF_OUTPUT" ]]; then
  echo "$CONF_OUTPUT" | head -20 | while read -r line; do
    echo -e "  ${DIM}  $line${RESET}"
  done
else
  info "No active conference rooms detected right now"
fi

# Check conference extension assignment in DB
CONF_EXTEN_ISSUES=$(q "
SELECT COUNT(*) FROM vicidial_conf_extensions
WHERE extension_status != 'idle'
  AND last_update < NOW() - INTERVAL 10 MINUTE;
" 2>/dev/null || echo "0")

TOTAL_CONF=$(q "SELECT COUNT(*) FROM vicidial_conf_extensions;" 2>/dev/null || echo "N/A")
IDLE_CONF=$(q "SELECT COUNT(*) FROM vicidial_conf_extensions WHERE extension_status='idle';" 2>/dev/null || echo "N/A")
INUSE_CONF=$(q "SELECT COUNT(*) FROM vicidial_conf_extensions WHERE extension_status='LIA';" 2>/dev/null || echo "N/A")

metric "Total conference extensions:" "$TOTAL_CONF"
metric "Idle (available):" "$IDLE_CONF"
metric "In use (LIA):" "$INUSE_CONF"

if [[ "$CONF_EXTEN_ISSUES" -gt 0 ]] 2>/dev/null; then
  server_issue "$CONF_EXTEN_ISSUES conference extension(s) stuck in non-idle state — may block agent bridging"
fi

if [[ "$IDLE_CONF" == "0" ]] 2>/dev/null; then
  server_issue "No idle conference extensions available — calls cannot be bridged to agents"
fi

# =============================================================================
# 8. LEAD DATA QUALITY ANALYSIS
# =============================================================================
section "8 — LEAD DATA QUALITY (client-side signals)"

echo -e "  ${BOLD}Lead phone number quality in hopper:${RESET}"
echo ""

# Leads with invalid/short phone numbers
INVALID_PHONES=$(q "
SELECT COUNT(*) FROM vicidial_list vl
JOIN vicidial_hopper vh ON vl.lead_id = vh.lead_id
WHERE LENGTH(REGEXP_REPLACE(vl.phone_number, '[^0-9]', '')) < 10;
" 2>/dev/null || echo "0")

# Leads with DNC status
DNC_IN_HOPPER=$(q "
SELECT COUNT(*) FROM vicidial_hopper
WHERE status='DNC';
" 2>/dev/null || echo "0")

# Leads already called today
CALLED_TODAY=$(q "
SELECT COUNT(*) FROM vicidial_log
WHERE call_date > CURDATE()
  AND status NOT IN ('DROP','ABAND');
" 2>/dev/null || echo "N/A")

# Leads with no local time (timezone issues)
TZ_ISSUES=$(q "
SELECT COUNT(*) FROM vicidial_list vl
JOIN vicidial_hopper vh ON vl.lead_id = vh.lead_id
WHERE vl.called_count > 3;
" 2>/dev/null || echo "0")

metric "Invalid phone numbers in hopper:" "$INVALID_PHONES"
metric "DNC entries in hopper:" "$DNC_IN_HOPPER"
metric "Calls completed today:" "$CALLED_TODAY"
metric "Leads called 3+ times already:" "$TZ_ISSUES"

if [[ "$INVALID_PHONES" -gt 0 ]] 2>/dev/null; then
  client_issue "$INVALID_PHONES leads in hopper have invalid phone numbers — wasted dials, no answer"
fi
if [[ "$DNC_IN_HOPPER" -gt 0 ]] 2>/dev/null; then
  client_issue "$DNC_IN_HOPPER DNC entries in hopper — compliance risk + wasted agent time"
fi
if [[ "$TZ_ISSUES" -gt 50 ]] 2>/dev/null; then
  client_issue "$TZ_ISSUES leads already called 3+ times — exhausted list, low contact rate expected"
fi

# Call result pattern — are calls consistently not being answered?
echo ""
echo -e "  ${BOLD}Call outcome pattern (last 1 hour):${RESET}"
q "
SELECT
  status,
  COUNT(*) as count
FROM vicidial_log
WHERE call_date > NOW() - INTERVAL 1 HOUR
GROUP BY status
ORDER BY count DESC
LIMIT 15;
" 2>/dev/null | while IFS=$'\t' read -r status count; do
  note=""
  color="$DIM"
  case "$status" in
    N|NA|NOAN)   color="$YELLOW"; note="no answer — normal if dialing mobile/cell" ;;
    BUSY)        color="$YELLOW"; note="busy signal" ;;
    AM|MACHINE)  color="$YELLOW"; note="answering machine" ;;
    DROP|ABAND)  color="$RED";    note="answered but dropped — no agent" ;;
    INCALL)      color="$CYAN";   note="currently active" ;;
    SALE|CALLBK) color="$GREEN";  note="converted" ;;
    DNCL)        color="$DIM";    note="do not call list" ;;
  esac
  printf "  ${color}  %-10s  %-6s  %s${RESET}\n" "$status" "$count" "$note"
done

# =============================================================================
# 9. SIP TRUNK CAPACITY CHECK
# =============================================================================
section "9 — SIP TRUNK CAPACITY vs CALL VOLUME"

echo -e "  ${BOLD}SIP registration status:${RESET}"
asterisk -rx "sip show registry" 2>/dev/null | grep -v '^$' | head -20 | while read -r line; do
  if echo "$line" | grep -qi 'Registered'; then
    echo -e "  ${GREEN}  $line${RESET}"
  elif echo "$line" | grep -qi 'Failed\|Timeout\|No Auth'; then
    echo -e "  ${RED}  $line${RESET}"
    server_issue "SIP trunk registration failed: $line"
  else
    echo -e "  ${DIM}  $line${RESET}"
  fi
done

echo ""
echo -e "  ${BOLD}SIP peer status (carriers):${RESET}"
asterisk -rx "sip show peers" 2>/dev/null | grep -v '^$' | grep -v 'Name\|sip peer' | head -20 | \
while read -r line; do
  if echo "$line" | grep -qi 'OK'; then
    echo -e "  ${GREEN}  $line${RESET}"
  elif echo "$line" | grep -qi 'UNREACHABLE\|UNKNOWN'; then
    echo -e "  ${RED}  $line${RESET}"
  else
    echo -e "  ${DIM}  $line${RESET}"
  fi
done

# =============================================================================
# 10. TIMING ANALYSIS — 200 OK TO AGENT BRIDGE TIME
# =============================================================================
section "10 — CALL FLOW TIMING ANALYSIS"

echo -e "  ${BOLD}Recent call flow from Asterisk log (last 50 lines, filtered):${RESET}"
echo ""

# Show the actual call flow — dial → 200 OK → bridge → agent
grep -E 'ANSWER|200 OK|AGI|BRIDGE|CONF|agent|DIAL|pickup|CONNECT' \
  /var/log/asterisk/full 2>/dev/null | tail -50 | \
  grep -v 'DEBUG\|VERBOSE' | tail -20 | while read -r line; do
  if echo "$line" | grep -qi '200 OK\|ANSWER'; then
    echo -e "  ${GREEN}  $line${RESET}"
  elif echo "$line" | grep -qi 'BRIDGE\|CONNECT\|pickup'; then
    echo -e "  ${CYAN}  $line${RESET}"
  elif echo "$line" | grep -qi 'CONF\|agent'; then
    echo -e "  ${MAGENTA}  $line${RESET}"
  else
    echo -e "  ${DIM}  $line${RESET}"
  fi
done

# Check for AGI script errors (FastAGI is what routes calls to agents)
echo ""
echo -e "  ${BOLD}AGI script errors (recent — these cause calls to not reach agents):${RESET}"
AGI_ERRORS=$(grep -i 'AGI.*error\|AGI.*failed\|AGI.*connect\|AGI.*timeout' \
  /var/log/asterisk/full 2>/dev/null | tail -10)
if [[ -n "$AGI_ERRORS" ]]; then
  echo "$AGI_ERRORS" | while read -r line; do
    echo -e "  ${RED}  $line${RESET}"
  done
  server_issue "AGI errors detected — call routing scripts failing, calls not being sent to agents"
else
  ok "No AGI errors in recent log"
fi

# =============================================================================
# FINAL VERDICT
# =============================================================================
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  DIAGNOSTIC VERDICT — $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

echo -e "  ${RED}${BOLD}SERVER-SIDE ISSUES ($SERVER_ISSUES found):${RESET}"
if (( SERVER_ISSUES == 0 )); then
  echo -e "  ${GREEN}  ✔ None detected${RESET}"
else
  for f in "${SERVER_FINDINGS[@]}"; do
    echo -e "  ${RED}  ✘ $f${RESET}"
  done
fi

echo ""
echo -e "  ${YELLOW}${BOLD}CLIENT/DATA-SIDE ISSUES ($CLIENT_ISSUES found):${RESET}"
if (( CLIENT_ISSUES == 0 )); then
  echo -e "  ${GREEN}  ✔ None detected${RESET}"
else
  for f in "${CLIENT_FINDINGS[@]}"; do
    echo -e "  ${YELLOW}  ⚠ $f${RESET}"
  done
fi

echo ""
echo -e "${BOLD}  ROOT CAUSE ASSESSMENT:${RESET}"
echo ""

if (( SERVER_ISSUES > 0 )) && (( CLIENT_ISSUES == 0 )); then
  echo -e "  ${RED}${BOLD}  ⛔  PRIMARY CAUSE: SERVER-SIDE${RESET}"
  echo -e "  ${RED}      Calls are being fired and answered (200 OK) but the server${RESET}"
  echo -e "  ${RED}      is failing to route them to agents due to infrastructure issues.${RESET}"
elif (( CLIENT_ISSUES > 0 )) && (( SERVER_ISSUES == 0 )); then
  echo -e "  ${YELLOW}${BOLD}  📋  PRIMARY CAUSE: CLIENT/DATA-SIDE${RESET}"
  echo -e "  ${YELLOW}      Server is functioning correctly. Agents are idle because${RESET}"
  echo -e "  ${YELLOW}      the lead data is exhausted, poor quality, or AMD is killing${RESET}"
  echo -e "  ${YELLOW}      too many calls before they reach agents.${RESET}"
elif (( SERVER_ISSUES > 0 )) && (( CLIENT_ISSUES > 0 )); then
  echo -e "  ${MAGENTA}${BOLD}  ⚠  MIXED CAUSE: BOTH SERVER AND CLIENT/DATA ISSUES${RESET}"
  echo -e "  ${MAGENTA}      Address server issues first, then re-evaluate data quality.${RESET}"
else
  echo -e "  ${GREEN}${BOLD}  ✅  NO CLEAR ROOT CAUSE FOUND${RESET}"
  echo -e "  ${GREEN}      No definitive issues detected by automated checks.${RESET}"
  echo -e "  ${GREEN}      Recommend manual review of Asterisk full log and campaign dial ratio.${RESET}"
  echo ""
  echo -e "  ${DIM}  Manual checks to try:${RESET}"
  echo -e "  ${DIM}    asterisk -rx 'core show channels verbose'${RESET}"
  echo -e "  ${DIM}    tail -f /var/log/asterisk/full | grep -E 'BRIDGE|CONF|AGI|agent'${RESET}"
  echo -e "  ${DIM}    watch -n2 'mysql -u root --socket=/var/run/mysql/mysql.sock asterisk \${RESET}"
  echo -e "  ${DIM}      -e \"SELECT status,count(*) FROM vicidial_live_agents GROUP BY status;\"'${RESET}"
fi

echo ""
echo -e "  ${DIM}Full report saved: $REPORT${RESET}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# Save report
{
  echo "VICIdial Idle Agent Diagnostic — $(date)"
  echo "Host: $(hostname -f)"
  echo ""
  echo "SERVER ISSUES ($SERVER_ISSUES):"
  printf '  %s\n' "${SERVER_FINDINGS[@]:-None}"
  echo ""
  echo "CLIENT/DATA ISSUES ($CLIENT_ISSUES):"
  printf '  %s\n' "${CLIENT_FINDINGS[@]:-None}"
  echo ""
  echo "INFO:"
  printf '  %s\n' "${INFO_FINDINGS[@]:-None}"
} > "$REPORT"

exit 0
