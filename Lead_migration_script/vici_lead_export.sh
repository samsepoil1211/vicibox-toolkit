#!/bin/bash
# =============================================================================
# VICIdial Lead Group Export Script — Full Export
# Exports ALL lead lists and ALL leads from this server
# SOURCE SERVER — READ ONLY — zero deletes, zero changes, live safe
# =============================================================================
# Usage:
#   ./vici_lead_export.sh
#   ./vici_lead_export.sh --outdir /mnt/backup
#   ./vici_lead_export.sh --socket /var/run/mysql/mysql.sock
# =============================================================================

VERSION="2.0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTDIR="/tmp/vici_export_${TIMESTAMP}"
MYSQL_SOCKET="/var/run/mysql/mysql.sock"
MYSQL_USER="root"
MYSQL_DB="asterisk"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir)  OUTDIR="$2";        shift 2 ;;
    --socket)  MYSQL_SOCKET="$2";  shift 2 ;;
    --user)    MYSQL_USER="$2";    shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--outdir /path] [--socket /path/to/mysql.sock] [--user root]"
      echo ""
      echo "Exports ALL lead lists and ALL leads. No arguments required."
      echo "Nothing is deleted or modified on the source server."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# =============================================================================
# HELPERS
# =============================================================================
ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail() { echo -e "  ${RED}✘  $*${RESET}"; exit 1; }
info() { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
log()  { echo -e "  ${DIM}[$(date '+%H:%M:%S')]${RESET} $*"; }

MQ() {
  mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" -s -N "$MYSQL_DB" -e "$1" 2>/dev/null
}

DUMP() {
  # $1 = table, $2 = output file, $3 = optional WHERE clause
  local table="$1"
  local outfile="$2"
  local where_clause="${3:-}"
  local where_arg=""
  [[ -n "$where_clause" ]] && where_arg="--where=$where_clause"

  mysqldump \
    -u "$MYSQL_USER" \
    --socket="$MYSQL_SOCKET" \
    --single-transaction \
    --no-create-info \
    --skip-triggers \
    --compact \
    --extended-insert \
    --quick \
    $where_arg \
    "$MYSQL_DB" "$table" \
    > "$outfile" 2>/dev/null

  return $?
}

# =============================================================================
# HEADER
# =============================================================================
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║      VICIdial Full Lead Export  v${VERSION}                               ║${RESET}"
echo -e "${BOLD}${CYAN}║      SOURCE SERVER — READ ONLY — NO CHANGES MADE                    ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Host   : $(hostname -f 2>/dev/null || hostname)"
echo -e "  Time   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  Output : $OUTDIR"
echo ""

# =============================================================================
# PRE-FLIGHT
# =============================================================================
echo -e "${BOLD}  Pre-flight checks...${RESET}"

# MySQL connection
if ! mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" "$MYSQL_DB" \
     -e "SELECT 1;" &>/dev/null; then
  fail "Cannot connect to MySQL (socket: $MYSQL_SOCKET)"
fi
ok "MySQL connection OK"

# Check mysqldump available
if ! command -v mysqldump &>/dev/null; then
  fail "mysqldump not found"
fi
ok "mysqldump available"

# Count what we're about to export
TOTAL_LISTS=$(MQ "SELECT COUNT(*) FROM vicidial_lists;")
TOTAL_LEADS=$(MQ "SELECT COUNT(*) FROM vicidial_list;")
TOTAL_ALT=$(MQ "SELECT COUNT(*) FROM vicidial_list_alt_phones;" 2>/dev/null || echo "0")

echo ""
echo -e "  ${BOLD}What will be exported:${RESET}"
printf "  %-35s %s\n" "Lead lists (vicidial_lists):"      "$TOTAL_LISTS"
printf "  %-35s %s\n" "Lead records (vicidial_list):"     "$TOTAL_LEADS"
printf "  %-35s %s\n" "Alternate phones:"                 "$TOTAL_ALT"
echo ""

if [[ "$TOTAL_LEADS" -eq 0 ]]; then
  fail "No leads found in vicidial_list — nothing to export"
fi

# Disk space check — estimate 500 bytes per lead
NEEDED_KB=$(( (TOTAL_LEADS * 500) / 1024 ))
AVAIL_KB=$(df -k /tmp | tail -1 | awk '{print $4}')
if (( NEEDED_KB > AVAIL_KB )); then
  warn "Low disk space — needed ~${NEEDED_KB}KB, available ${AVAIL_KB}KB"
  warn "Use --outdir to specify a larger partition"
  read -r -p "  Continue anyway? (yes/NO): " cont
  [[ "$cont" != "yes" ]] && echo "Aborted." && exit 0
fi

# Create output dir
mkdir -p "$OUTDIR" || fail "Cannot create output directory: $OUTDIR"
ok "Output directory created: $OUTDIR"

# =============================================================================
# EXPORT: vicidial_lists (list metadata)
# =============================================================================
echo ""
echo -e "${BOLD}  [1/5] Exporting list metadata (vicidial_lists)...${RESET}"

LISTS_FILE="$OUTDIR/vicidial_lists.sql"
DUMP "vicidial_lists" "$LISTS_FILE"

if [[ -s "$LISTS_FILE" ]]; then
  ok "vicidial_lists → $(wc -l < "$LISTS_FILE") lines, $(du -sh "$LISTS_FILE" | cut -f1)"
else
  fail "vicidial_lists export failed or empty"
fi

# =============================================================================
# EXPORT: vicidial_list (all lead records)
# =============================================================================
echo ""
echo -e "${BOLD}  [2/5] Exporting all leads (vicidial_list)...${RESET}"
info "This may take a few minutes for large datasets..."

LEADS_FILE="$OUTDIR/vicidial_list.sql"
DUMP "vicidial_list" "$LEADS_FILE"

if [[ -s "$LEADS_FILE" ]]; then
  ok "vicidial_list → $TOTAL_LEADS records, $(du -sh "$LEADS_FILE" | cut -f1)"
else
  fail "vicidial_list export failed or empty"
fi

# =============================================================================
# EXPORT: vicidial_list_alt_phones
# =============================================================================
echo ""
echo -e "${BOLD}  [3/5] Exporting alternate phone numbers...${RESET}"

ALT_FILE="$OUTDIR/vicidial_list_alt_phones.sql"
if [[ "$TOTAL_ALT" -gt 0 ]]; then
  DUMP "vicidial_list_alt_phones" "$ALT_FILE"
  if [[ -s "$ALT_FILE" ]]; then
    ok "vicidial_list_alt_phones → $TOTAL_ALT records, $(du -sh "$ALT_FILE" | cut -f1)"
  else
    warn "Alternate phones export empty"
  fi
else
  info "No alternate phone records — skipping"
  touch "$ALT_FILE"
fi

# =============================================================================
# EXPORT: vicidial_lists_custom (custom fields data)
# =============================================================================
echo ""
echo -e "${BOLD}  [4/5] Exporting custom fields...${RESET}"

CUSTOM_EXISTS=$(MQ "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema='$MYSQL_DB'
  AND table_name='vicidial_lists_custom';")

CUSTOM_FILE="$OUTDIR/vicidial_lists_custom.sql"
FIELDS_FILE="$OUTDIR/vicidial_lists_fields.sql"

if [[ "$CUSTOM_EXISTS" -gt 0 ]]; then
  CUSTOM_COUNT=$(MQ "SELECT COUNT(*) FROM vicidial_lists_custom;")
  if [[ "$CUSTOM_COUNT" -gt 0 ]]; then
    DUMP "vicidial_lists_custom" "$CUSTOM_FILE"
    ok "vicidial_lists_custom → $CUSTOM_COUNT records"
  else
    info "vicidial_lists_custom is empty — skipping"
    touch "$CUSTOM_FILE"
  fi

  FIELDS_EXISTS=$(MQ "
    SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema='$MYSQL_DB'
    AND table_name='vicidial_lists_fields';")
  if [[ "$FIELDS_EXISTS" -gt 0 ]]; then
    FIELDS_COUNT=$(MQ "SELECT COUNT(*) FROM vicidial_lists_fields;")
    if [[ "$FIELDS_COUNT" -gt 0 ]]; then
      DUMP "vicidial_lists_fields" "$FIELDS_FILE"
      ok "vicidial_lists_fields → $FIELDS_COUNT records"
    else
      info "vicidial_lists_fields is empty — skipping"
      touch "$FIELDS_FILE"
    fi
  fi
else
  info "No custom field tables found — skipping"
  touch "$CUSTOM_FILE" "$FIELDS_FILE"
fi

# =============================================================================
# WRITE MANIFEST
# =============================================================================
echo ""
echo -e "${BOLD}  [5/5] Writing manifest and checksums...${RESET}"

# Per-list summary for the manifest
LIST_SUMMARY=$(MQ "
  SELECT
    vl.list_id,
    vl.list_name,
    vl.campaign_id,
    vl.active,
    COUNT(vll.lead_id) as lead_count
  FROM vicidial_lists vl
  LEFT JOIN vicidial_list vll ON vl.list_id = vll.list_id
  GROUP BY vl.list_id
  ORDER BY vl.list_id;" 2>/dev/null | \
  awk 'BEGIN{OFS="\t"} {printf "  list_id=%-8s name=%-20s campaign=%-8s active=%s leads=%s\n",$1,$2,$3,$4,$5}')

cat > "$OUTDIR/EXPORT_INFO.txt" << EOF
=============================================================
VICIdial Full Lead Export Package
=============================================================
Export Version  : $VERSION
Source Host     : $(hostname -f 2>/dev/null || hostname)
Export Time     : $(date '+%Y-%m-%d %H:%M:%S %Z')
MySQL Database  : $MYSQL_DB
Total Lists     : $TOTAL_LISTS
Total Leads     : $TOTAL_LEADS
Total Alt Ph.   : $TOTAL_ALT
=============================================================
LIST SUMMARY:
$LIST_SUMMARY
=============================================================
FILES IN THIS PACKAGE:
  vicidial_lists.sql           — list metadata
  vicidial_list.sql            — all lead records
  vicidial_list_alt_phones.sql — alternate phone numbers
  vicidial_lists_custom.sql    — custom field data
  vicidial_lists_fields.sql    — custom field definitions
  checksums.sha256             — integrity verification
  EXPORT_INFO.txt              — this file
=============================================================
IMPORT INSTRUCTIONS:
  1. scp this .tar.gz to destination server
  2. tar -xzf vici_leads_export_*.tar.gz -C /tmp/
  3. chmod +x vici_lead_import.sh
  4. ./vici_lead_import.sh --package /tmp/vici_export_TIMESTAMP
  5. Add --campaign CAMPAIGN_ID to assign to a campaign
  6. Add --dry-run to simulate first
=============================================================
NOTE: Nothing was deleted or modified on the source server.
=============================================================
EOF

ok "EXPORT_INFO.txt written"

# Checksums
(cd "$OUTDIR" && sha256sum ./*.sql > checksums.sha256 2>/dev/null)
ok "SHA256 checksums generated"

# =============================================================================
# COMPRESS
# =============================================================================
echo ""
echo -e "${BOLD}  Compressing package...${RESET}"

PACKAGE="/tmp/vici_leads_export_${TIMESTAMP}.tar.gz"
tar -czf "$PACKAGE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null

if [[ ! -s "$PACKAGE" ]]; then
  fail "Compression failed"
fi

PACKAGE_SIZE=$(du -sh "$PACKAGE" | cut -f1)
ok "Package: $PACKAGE ($PACKAGE_SIZE)"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  EXPORT COMPLETE — SOURCE SERVER UNCHANGED${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  Lists exported  : $TOTAL_LISTS"
echo -e "  Leads exported  : $TOTAL_LEADS"
echo -e "  Package         : $PACKAGE"
echo -e "  Package size    : $PACKAGE_SIZE"
echo ""
echo -e "${BOLD}  Step 1 — Transfer to destination server:${RESET}"
echo -e "  ${DIM}scp $PACKAGE root@DESTINATION_IP:/tmp/${RESET}"
echo ""
echo -e "${BOLD}  Step 2 — On destination server:${RESET}"
echo -e "  ${DIM}tar -xzf /tmp/$(basename "$PACKAGE") -C /tmp/${RESET}"
echo -e "  ${DIM}./vici_lead_import.sh --package $OUTDIR --campaign TARGET_CAMPAIGN_ID${RESET}"
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

exit 0
