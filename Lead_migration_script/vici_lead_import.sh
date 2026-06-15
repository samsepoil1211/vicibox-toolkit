#!/bin/bash
# =============================================================================
# VICIdial Lead Group Import Script v2.0
# Imports full export package (vicidial_lists.sql + vicidial_list.sql)
# DESTINATION SERVER
# =============================================================================
# Usage:
#   ./vici_lead_import.sh --package /tmp/vici_export_20260615_174551
#   ./vici_lead_import.sh --package /tmp/vici_export_20260615_174551 --campaign 1001
#   ./vici_lead_import.sh --package /tmp/vici_export_20260615_174551 --dry-run
# =============================================================================

VERSION="2.0"
MYSQL_SOCKET="/var/run/mysql/mysql.sock"
MYSQL_USER="cron"
MYSQL_DB="asterisk"
PACKAGE_DIR=""
TARGET_CAMPAIGN=""
DRY_RUN=false
ROLLBACK_SQL="/tmp/vici_import_rollback_$(date +%Y%m%d_%H%M%S).sql"
WORK_DIR="/tmp/vici_import_work_$$"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

LISTS_IMPORTED=0
LEADS_IMPORTED=0

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)   PACKAGE_DIR="$2";      shift 2 ;;
    --campaign)  TARGET_CAMPAIGN="$2";  shift 2 ;;
    --socket)    MYSQL_SOCKET="$2";     shift 2 ;;
    --user)      MYSQL_USER="$2";       shift 2 ;;
    --dry-run)   DRY_RUN=true;          shift   ;;
    --help|-h)
      echo "Usage: $0 --package <dir> [--campaign <id>] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$PACKAGE_DIR" ]] && echo -e "${RED}ERROR: --package is required${RESET}" && exit 1
[[ ! -d "$PACKAGE_DIR" ]] && echo -e "${RED}ERROR: Directory not found: $PACKAGE_DIR${RESET}" && exit 1

# =============================================================================
# HELPERS
# =============================================================================
ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail() { echo -e "  ${RED}✘  $*${RESET}"; echo ""; [[ -f "$ROLLBACK_SQL" ]] && \
         echo -e "${YELLOW}  Rollback available: mysql -u $MYSQL_USER --socket=$MYSQL_SOCKET $MYSQL_DB < $ROLLBACK_SQL${RESET}"; exit 1; }
info() { echo -e "  ${CYAN}ℹ${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
log()  { echo -e "  ${DIM}[$(date '+%H:%M:%S')]${RESET} $*"; }
dry()  { echo -e "  ${YELLOW}[DRY-RUN]${RESET}  $*"; }

MQ() {
  # Write query — skipped in dry-run
  [[ "$DRY_RUN" == true ]] && dry "SQL: $1" && return 0
  mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" -s -N "$MYSQL_DB" -e "$1" 2>/dev/null
}

MR() {
  # Read-only query — always executes
  mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" -s -N "$MYSQL_DB" -e "$1" 2>/dev/null
}

MF() {
  # Import a SQL file
  [[ "$DRY_RUN" == true ]] && dry "Would import file: $1 ($(wc -l < "$1") lines)" && return 0
  mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" "$MYSQL_DB" < "$1" 2>/tmp/vici_mf_err_$$.txt
  local rc=$?
  [[ -s /tmp/vici_mf_err_$$.txt ]] && warn "MySQL message: $(head -1 /tmp/vici_mf_err_$$.txt)"
  rm -f /tmp/vici_mf_err_$$.txt
  return $rc
}

cleanup() {
  rm -rf "$WORK_DIR"
  rm -f /tmp/vici_mf_err_$$.txt
}
trap cleanup EXIT

# =============================================================================
# HEADER
# =============================================================================
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║      VICIdial Lead Import  v${VERSION}  — DESTINATION SERVER              ║${RESET}"
[[ "$DRY_RUN" == true ]] && \
echo -e "${BOLD}${YELLOW}║      *** DRY RUN — NO CHANGES WILL BE MADE ***                     ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Host     : $(hostname -f 2>/dev/null || hostname)"
echo -e "  Time     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo -e "  Package  : $PACKAGE_DIR"
echo -e "  MySQL    : $MYSQL_USER @ $MYSQL_SOCKET"
[[ -n "$TARGET_CAMPAIGN" ]] && echo -e "  Campaign : $TARGET_CAMPAIGN"
echo ""

# =============================================================================
# PRE-FLIGHT
# =============================================================================
echo -e "${BOLD}  Pre-flight checks...${RESET}"

# MySQL connection
if ! mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" "$MYSQL_DB" \
     -e "SELECT 1;" &>/dev/null; then
  # Try root fallback
  if mysql -u root --socket="$MYSQL_SOCKET" "$MYSQL_DB" \
       -e "SELECT 1;" &>/dev/null; then
    warn "cron user failed, falling back to root"
    MYSQL_USER="root"
  else
    fail "Cannot connect to MySQL with user '$MYSQL_USER' or 'root'"
  fi
fi
ok "MySQL connection OK (user: $MYSQL_USER)"

# Required files
for f in vicidial_lists.sql vicidial_list.sql; do
  [[ -f "$PACKAGE_DIR/$f" ]] || fail "Required file missing: $PACKAGE_DIR/$f"
  [[ -s "$PACKAGE_DIR/$f" ]] || fail "File is empty: $PACKAGE_DIR/$f"
done
ok "Required package files present"

# Checksum
if [[ -f "$PACKAGE_DIR/checksums.sha256" ]]; then
  if (cd "$PACKAGE_DIR" && sha256sum -c checksums.sha256 &>/dev/null); then
    ok "Package checksum verified"
  else
    warn "Checksum mismatch — package may be incomplete"
    read -r -p "  Continue anyway? (yes/NO): " cont
    [[ "$cont" != "yes" ]] && echo "Aborted." && exit 0
  fi
else
  warn "No checksum file — skipping integrity check"
fi

# Show package info
echo ""
echo -e "  ${BOLD}Package info:${RESET}"
grep -E 'Source Host|Export Time|Total Lists|Total Leads' \
  "$PACKAGE_DIR/EXPORT_INFO.txt" 2>/dev/null | \
  while read -r line; do echo -e "  ${DIM}  $line${RESET}"; done

# Target campaign check
if [[ -n "$TARGET_CAMPAIGN" ]]; then
  CAMP_EXISTS=$(MR "SELECT COUNT(*) FROM vicidial_campaigns WHERE campaign_id='$TARGET_CAMPAIGN';")
  [[ "$CAMP_EXISTS" -eq 0 ]] && fail "Campaign '$TARGET_CAMPAIGN' not found on destination"
  ok "Target campaign '$TARGET_CAMPAIGN' exists"
fi

# Count what's coming in
PKG_LISTS=$(grep -c '^INSERT' "$PACKAGE_DIR/vicidial_lists.sql" 2>/dev/null || echo "0")
PKG_LEADS=$(grep -c '^INSERT' "$PACKAGE_DIR/vicidial_list.sql" 2>/dev/null || echo "0")
echo ""
echo -e "  ${BOLD}Package contains:${RESET}"
printf "  %-35s %s\n" "List records:" "$PKG_LISTS INSERT blocks"
printf "  %-35s %s\n" "Lead records:" "$PKG_LEADS INSERT blocks (each block = multiple rows)"

# Disk space check on destination
LEADS_FILE_SIZE=$(du -sk "$PACKAGE_DIR/vicidial_list.sql" | cut -f1)
AVAIL_KB=$(df -k /tmp | tail -1 | awk '{print $4}')
if (( LEADS_FILE_SIZE * 2 > AVAIL_KB )); then
  warn "Low disk space in /tmp — work files need ~$((LEADS_FILE_SIZE * 2 / 1024))MB"
fi

# =============================================================================
# COLLISION CHECK — what list_ids exist in package vs destination
# =============================================================================
echo ""
echo -e "${BOLD}  Checking for list_id collisions...${RESET}"

# Extract list_ids from the export SQL
PKG_LIST_IDS=$(grep -oP "(?<=list_id=')[0-9]+" "$PACKAGE_DIR/vicidial_lists.sql" 2>/dev/null | \
               sort -u || \
               grep -oE "\([0-9]+," "$PACKAGE_DIR/vicidial_lists.sql" | \
               tr -d '(,' | sort -u)

COLLISION_FOUND=false
declare -A LIST_ID_MAP  # src_id → dest_id

for src_id in $PKG_LIST_IDS; do
  EXISTS=$(MR "SELECT COUNT(*) FROM vicidial_lists WHERE list_id='$src_id';")
  if [[ "$EXISTS" -gt 0 ]]; then
    MAX_ID=$(MR "SELECT MAX(list_id) FROM vicidial_lists;")
    NEW_ID=$(( MAX_ID + 1 ))
    warn "list_id $src_id exists on destination → remapping to $NEW_ID"
    LIST_ID_MAP[$src_id]=$NEW_ID
    COLLISION_FOUND=true
    # Bump max for next collision
    MQ "INSERT INTO vicidial_lists (list_id, list_name, campaign_id, active) VALUES ('$NEW_ID','__placeholder__','000','N');" 2>/dev/null || true
  else
    LIST_ID_MAP[$src_id]=$src_id
    ok "list_id $src_id — available"
  fi
done

# Clean up placeholder rows
for src_id in "${!LIST_ID_MAP[@]}"; do
  dest_id="${LIST_ID_MAP[$src_id]}"
  MQ "DELETE FROM vicidial_lists WHERE list_id='$dest_id' AND list_name='__placeholder__';" 2>/dev/null || true
done

# =============================================================================
# CONFIRMATION
# =============================================================================
if [[ "$DRY_RUN" == false ]]; then
  echo ""
  echo -e "  ${YELLOW}Ready to import into destination database.${RESET}"
  echo -e "  ${GREEN}Rollback script will be created before any data is written.${RESET}"
  read -r -p "  Proceed? (yes/NO): " confirm
  [[ "$confirm" != "yes" ]] && echo "Aborted." && exit 0
fi

mkdir -p "$WORK_DIR"

# =============================================================================
# STEP 1: PREPARE ROLLBACK SCRIPT
# =============================================================================
echo ""
echo -e "${BOLD}  [1/5] Preparing rollback script...${RESET}"

MAX_LEAD_BEFORE=$(MR "SELECT IFNULL(MAX(lead_id),0) FROM vicidial_list;")

if [[ "$DRY_RUN" == false ]]; then
  cat > "$ROLLBACK_SQL" << RBEOF
-- VICIdial Import Rollback
-- Generated: $(date)
-- Run: mysql -u $MYSQL_USER --socket=$MYSQL_SOCKET $MYSQL_DB < $ROLLBACK_SQL
START TRANSACTION;
-- Remove all imported leads
DELETE FROM vicidial_list WHERE lead_id > $MAX_LEAD_BEFORE;
-- Remove all imported alt phones
DELETE FROM vicidial_list_alt_phones WHERE lead_id > $MAX_LEAD_BEFORE;
-- Remove imported lists
RBEOF

  for src_id in "${!LIST_ID_MAP[@]}"; do
    dest_id="${LIST_ID_MAP[$src_id]}"
    echo "DELETE FROM vicidial_lists WHERE list_id = '$dest_id';" >> "$ROLLBACK_SQL"
    echo "DELETE FROM vicidial_hopper WHERE list_id = '$dest_id';" >> "$ROLLBACK_SQL"
  done

  echo "COMMIT;" >> "$ROLLBACK_SQL"
  ok "Rollback script: $ROLLBACK_SQL"
fi

# =============================================================================
# STEP 2: IMPORT vicidial_lists (metadata)
# =============================================================================
echo ""
echo -e "${BOLD}  [2/5] Importing list metadata (vicidial_lists)...${RESET}"

LISTS_WORK="$WORK_DIR/vicidial_lists_import.sql"
cp "$PACKAGE_DIR/vicidial_lists.sql" "$LISTS_WORK"

# Remap any colliding list_ids
for src_id in "${!LIST_ID_MAP[@]}"; do
  dest_id="${LIST_ID_MAP[$src_id]}"
  if [[ "$src_id" != "$dest_id" ]]; then
    sed -i "s/,'${src_id}',/,'${dest_id}',/g;
            s/list_id='${src_id}'/list_id='${dest_id}'/g" "$LISTS_WORK"
    log "Remapped list_id $src_id → $dest_id in metadata"
  fi
done

# Override campaign_id if target specified
if [[ -n "$TARGET_CAMPAIGN" ]]; then
  # This replaces the campaign_id column value in INSERT rows
  # vicidial_lists column order: list_id, list_name, campaign_id, active, ...
  python3 - "$LISTS_WORK" "$TARGET_CAMPAIGN" << 'PYEOF'
import sys, re

infile = sys.argv[1]
campaign = sys.argv[2]

lines = open(infile).readlines()
out = []
for line in lines:
    if line.startswith('INSERT'):
        # Replace 3rd value in each VALUES tuple (campaign_id)
        # Pattern: (list_id,'name','campaign_id','active',...)
        line = re.sub(
            r"(\(\d+,'[^']*',)'[^']*'",
            lambda m: m.group(1) + "'" + campaign + "'",
            line
        )
    out.append(line)

open(infile, 'w').writelines(out)
print("campaign_remap_done")
PYEOF
  info "campaign_id overridden to: $TARGET_CAMPAIGN"
fi

# Reset cache fields and lastcalldate — fresh start on destination
sed -i \
  "s/cache_count=[0-9]*/cache_count=0/g;
   s/cache_count_new=[0-9]*/cache_count_new=0/g;
   s/cache_count_dialable_new=[0-9]*/cache_count_dialable_new=0/g" \
  "$LISTS_WORK"

# Use INSERT IGNORE to be safe
sed -i 's/^INSERT INTO /INSERT IGNORE INTO /g' "$LISTS_WORK"

MF "$LISTS_WORK"
LISTS_IMPORTED=$(MR "SELECT COUNT(*) FROM vicidial_lists WHERE list_id IN \
  ($(echo "${LIST_ID_MAP[@]}" | tr ' ' ','));")
ok "List metadata imported: $LISTS_IMPORTED lists"

# =============================================================================
# STEP 3: IMPORT vicidial_list (lead records) in chunks
# =============================================================================
echo ""
echo -e "${BOLD}  [3/5] Importing lead records (vicidial_list)...${RESET}"
info "File size: $(du -sh "$PACKAGE_DIR/vicidial_list.sql" | cut -f1) — importing in chunks"

LEADS_WORK="$WORK_DIR/vicidial_list_prep.sql"
cp "$PACKAGE_DIR/vicidial_list.sql" "$LEADS_WORK"

# Remap list_ids in leads file
for src_id in "${!LIST_ID_MAP[@]}"; do
  dest_id="${LIST_ID_MAP[$src_id]}"
  if [[ "$src_id" != "$dest_id" ]]; then
    log "Remapping list_id $src_id → $dest_id in leads file..."
    sed -i "s/,'${src_id}',/,'${dest_id}',/g" "$LEADS_WORK"
  fi
done

# Reset called_since_last_reset = N for all leads (fresh start)
# Column 10 of 35 in vicidial_list — positional INSERT, no column names
# Using python3 for reliable tuple-level replacement on large files
log "Resetting called_since_last_reset to N (column 10, positional)..."

RESET_OUT="${LEADS_WORK}.reset"
python3 << PYEOF
import re, sys

infile  = '${LEADS_WORK}'
outfile = '${RESET_OUT}'
col_idx = 9   # 0-based index for column 10 (called_since_last_reset)
fixed   = 0
errors  = 0

def reset_col10(tuple_str):
    """Parse one VALUES tuple and set position 9 to 'N'."""
    # Remove outer parens
    inner = tuple_str[1:-1]
    # Split carefully respecting quoted strings
    parts = []
    buf   = ''
    depth = 0
    in_q  = False
    esc   = False
    for ch in inner:
        if esc:
            buf += ch
            esc = False
        elif ch == '\\\\':
            buf += ch
            esc = True
        elif ch == "'" and not in_q:
            in_q = True
            buf += ch
        elif ch == "'" and in_q:
            in_q = False
            buf += ch
        elif ch == ',' and not in_q and depth == 0:
            parts.append(buf)
            buf = ''
        else:
            buf += ch
    parts.append(buf)

    if len(parts) > col_idx:
        parts[col_idx] = "'N'"
    return '(' + ','.join(parts) + ')'

with open(infile, 'r', errors='replace') as fin, \
     open(outfile, 'w') as fout:
    for line in fin:
        if line.startswith('INSERT'):
            # Find VALUES(...),(...)  portion
            val_start = line.index(' VALUES ') + 8
            prefix    = line[:val_start]
            rest      = line[val_start:].rstrip('\n;')
            # Split into individual row tuples at ),( boundary
            tuples    = re.split(r'\),\(', rest)
            new_tuples = []
            for i, t in enumerate(tuples):
                if i == 0:
                    t = t.lstrip('(')
                if i == len(tuples)-1:
                    t = t.rstrip(')')
                t = '(' + t + ')'
                try:
                    new_tuples.append(reset_col10(t))
                    fixed += 1
                except Exception:
                    new_tuples.append(t)
                    errors += 1
            fout.write(prefix + ','.join(new_tuples) + ';\n')
        else:
            fout.write(line)

print(f"RESET_DONE: {fixed} rows fixed, {errors} errors")
PYEOF

RESET_STATUS=$?
if [[ -s "$RESET_OUT" ]] && [[ $RESET_STATUS -eq 0 ]]; then
  mv "$RESET_OUT" "$LEADS_WORK"
  ok "called_since_last_reset reset to N for all rows"
else
  warn "Python reset failed — importing without reset (called_since_last_reset unchanged)"
  rm -f "$RESET_OUT"
fi

# Use INSERT IGNORE
sed -i 's/^INSERT INTO /INSERT IGNORE INTO /g' "$LEADS_WORK"

# Split into 10000-line chunks and import
CHUNK_DIR="$WORK_DIR/chunks"
mkdir -p "$CHUNK_DIR"
split -l 10000 "$LEADS_WORK" "$CHUNK_DIR/chunk_"
TOTAL_CHUNKS=$(ls "$CHUNK_DIR/" | wc -l)
CHUNK_NUM=0

if [[ "$DRY_RUN" == true ]]; then
  dry "Would import $TOTAL_CHUNKS chunks from leads file"
else
  for chunk in "$CHUNK_DIR"/chunk_*; do
    (( CHUNK_NUM++ )) || true
    printf "\r  ${CYAN}  Chunk %d / %d ...${RESET}   " "$CHUNK_NUM" "$TOTAL_CHUNKS"
    mysql -u "$MYSQL_USER" --socket="$MYSQL_SOCKET" "$MYSQL_DB" \
      < "$chunk" 2>/dev/null
  done
  echo ""

  LEADS_IMPORTED=$(MR "SELECT COUNT(*) FROM vicidial_list WHERE lead_id > $MAX_LEAD_BEFORE;")
  ok "Lead records imported: $LEADS_IMPORTED"
fi

# =============================================================================
# STEP 4: IMPORT ALT PHONES (if present)
# =============================================================================
echo ""
echo -e "${BOLD}  [4/5] Importing alternate phone numbers...${RESET}"

ALT_FILE="$PACKAGE_DIR/vicidial_list_alt_phones.sql"
if [[ -s "$ALT_FILE" ]]; then
  ALT_WORK="$WORK_DIR/alt_phones.sql"
  sed 's/^INSERT INTO /INSERT IGNORE INTO /g' "$ALT_FILE" > "$ALT_WORK"
  MF "$ALT_WORK"
  ok "Alternate phones imported"
else
  info "No alternate phone records in package — skipping"
fi

# =============================================================================
# STEP 5: REBUILD CACHE + ACTIVATE LISTS
# =============================================================================
echo ""
echo -e "${BOLD}  [5/5] Rebuilding list cache and activating lists...${RESET}"

for src_id in "${!LIST_ID_MAP[@]}"; do
  dest_id="${LIST_ID_MAP[$src_id]}"

  # Count actual leads for this list
  LIST_LEAD_COUNT=$(MR "SELECT COUNT(*) FROM vicidial_list WHERE list_id='$dest_id';")

  # Update cache so hopper loader sees the list
  MQ "
    UPDATE vicidial_lists
    SET
      cache_count                = $LIST_LEAD_COUNT,
      cache_count_new            = $LIST_LEAD_COUNT,
      cache_count_dialable_new   = $LIST_LEAD_COUNT,
      cache_date                 = NOW(),
      list_lastcalldate          = NULL,
      active                     = 'Y'
    WHERE list_id = '$dest_id';"

  LIST_NAME=$(MR "SELECT list_name FROM vicidial_lists WHERE list_id='$dest_id';")
  ok "List $dest_id ($LIST_NAME) — cache updated, $LIST_LEAD_COUNT leads, active=Y"
done

# =============================================================================
# OPTIONAL: SEED HOPPER
# =============================================================================
echo ""
read -r -p "  Seed hopper now for immediate dialing? (yes/NO): " seed_hop
if [[ "$seed_hop" == "yes" ]]; then
  for src_id in "${!LIST_ID_MAP[@]}"; do
    dest_id="${LIST_ID_MAP[$src_id]}"
    CAMP=$(MR "SELECT campaign_id FROM vicidial_lists WHERE list_id='$dest_id';")
    if [[ -n "$CAMP" ]] && [[ "$CAMP" != "000" ]]; then
      MQ "
        INSERT INTO vicidial_hopper
          (lead_id, phone_number, list_id, campaign_id, status, priority)
        SELECT
          lead_id, phone_number, '$dest_id', '$CAMP', 'READY', 0
        FROM vicidial_list
        WHERE list_id = '$dest_id'
          AND status = 'NEW'
          AND called_since_last_reset = 'N'
        LIMIT 1000;"
      HOPPER_COUNT=$(MR "SELECT COUNT(*) FROM vicidial_hopper WHERE list_id='$dest_id';")
      ok "Seeded $HOPPER_COUNT leads into hopper for list $dest_id → campaign $CAMP"
    else
      warn "List $dest_id has no campaign assigned — hopper seed skipped"
      info "Assign campaign in VICIdial Admin UI, then hopper will auto-fill"
    fi
  done
fi

# =============================================================================
# VERIFICATION
# =============================================================================
echo ""
echo -e "${BOLD}  Verification:${RESET}"
for src_id in "${!LIST_ID_MAP[@]}"; do
  dest_id="${LIST_ID_MAP[$src_id]}"
  VLEADS=$(MR "SELECT COUNT(*) FROM vicidial_list WHERE list_id='$dest_id';")
  VCACHE=$(MR "SELECT cache_count_dialable_new FROM vicidial_lists WHERE list_id='$dest_id';")
  VCAMP=$(MR "SELECT campaign_id FROM vicidial_lists WHERE list_id='$dest_id';")
  VACTIVE=$(MR "SELECT active FROM vicidial_lists WHERE list_id='$dest_id';")
  VHOPPER=$(MR "SELECT COUNT(*) FROM vicidial_hopper WHERE list_id='$dest_id';")
  VNAME=$(MR "SELECT list_name FROM vicidial_lists WHERE list_id='$dest_id';")
  echo ""
  echo -e "  ${BOLD}List $dest_id — $VNAME${RESET}"
  printf "  ${GREEN}✔${RESET}  %-30s %s\n" "Leads imported:"    "$VLEADS"
  printf "  ${GREEN}✔${RESET}  %-30s %s\n" "Cache dialable:"    "$VCACHE"
  printf "  ${GREEN}✔${RESET}  %-30s %s\n" "Campaign:"          "$VCAMP"
  printf "  ${GREEN}✔${RESET}  %-30s %s\n" "Active:"            "$VACTIVE"
  printf "  ${GREEN}✔${RESET}  %-30s %s\n" "Leads in hopper:"   "$VHOPPER"
done

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
[[ "$DRY_RUN" == true ]] && \
  echo -e "${BOLD}  DRY RUN COMPLETE — nothing was written${RESET}" || \
  echo -e "${BOLD}  IMPORT COMPLETE${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
[[ "$DRY_RUN" == false ]] && echo -e "  Leads imported  : $LEADS_IMPORTED"
[[ "$DRY_RUN" == false ]] && echo -e "  Rollback script : $ROLLBACK_SQL"
echo ""
if [[ "$DRY_RUN" == false ]]; then
  echo -e "${BOLD}  To rollback everything:${RESET}"
  echo -e "  ${DIM}mysql -u $MYSQL_USER --socket=$MYSQL_SOCKET $MYSQL_DB < $ROLLBACK_SQL${RESET}"
fi
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

exit 0
