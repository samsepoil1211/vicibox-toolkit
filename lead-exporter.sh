#!/bin/bash

# ============================================================
#  ViciDial Lead Groups Manager
#  - Shows all lead groups and lead counts
#  - Exports leads to CSV (optional)
#  - Deletes all lead groups EXCEPT 998, 999, 1001
# ============================================================

DB_USER="root"
DB_PASS=""
DB_NAME="asterisk"
MYSQL_CMD="mysql -u $DB_USER -p$DB_PASS $DB_NAME"

# Protected lead groups (will NOT be deleted)
PROTECTED_GROUPS="998,999,1001"

# Output CSV file
EXPORT_FILE="/root/vicidial_leads_export_$(date +%Y%m%d_%H%M%S).csv"

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo ""
echo -e "${BOLD}${CYAN}============================================${NC}"
echo -e "${BOLD}${CYAN}   ViciDial Lead Groups Manager            ${NC}"
echo -e "${BOLD}${CYAN}============================================${NC}"
echo ""

# ─── Step 1: Show all lead groups and lead counts ──────────
echo -e "${YELLOW}[INFO]${NC} Fetching lead groups from MySQL..."
echo ""

echo -e "${BOLD}Lead Groups Currently in the Dialer:${NC}"
echo "------------------------------------------------------------"
printf "%-15s %-35s %-12s\n" "LIST_ID" "LIST_NAME" "TOTAL_LEADS"
echo "------------------------------------------------------------"

$MYSQL_CMD -se "
  SELECT vl.list_id, vl.list_name, COUNT(vli.lead_id) as total_leads
  FROM vicidial_lists vl
  LEFT JOIN vicidial_list vli ON vl.list_id = vli.list_id
  GROUP BY vl.list_id, vl.list_name
  ORDER BY vl.list_id;
" | while IFS=$'\t' read -r list_id list_name total_leads; do
    if [[ "$list_id" == "998" || "$list_id" == "999" || "$list_id" == "1001" ]]; then
        printf "${GREEN}%-15s %-35s %-12s [PROTECTED]${NC}\n" "$list_id" "$list_name" "$total_leads"
    else
        printf "%-15s %-35s %-12s\n" "$list_id" "$list_name" "$total_leads"
    fi
done

echo "------------------------------------------------------------"

# ─── Total lead count ──────────────────────────────────────
TOTAL=$($MYSQL_CMD -se "SELECT COUNT(*) FROM vicidial_list;" 2>/dev/null)
echo ""
echo -e "${BOLD}Total leads in dialer: ${CYAN}$TOTAL${NC}"
echo ""

# ─── Step 2: Ask user what to do ───────────────────────────
echo -e "${BOLD}What would you like to do with leads before deletion?${NC}"
echo ""
echo "  [1] Export ALL leads to a consolidated CSV, then delete lead groups"
echo "  [2] Delete lead groups WITHOUT saving (leads will be permanently lost)"
echo "  [3] Exit (do nothing)"
echo ""
read -p "Enter your choice [1/2/3]: " USER_CHOICE

case $USER_CHOICE in

  # ──────────────────────────────────────────────────────────
  1)
    echo ""
    echo -e "${YELLOW}[INFO]${NC} Exporting all leads to: ${CYAN}$EXPORT_FILE${NC}"

    # Write CSV header
    $MYSQL_CMD -se "
      SELECT 'list_id','phone_number','first_name','last_name','email',
             'address1','city','state','postal_code','status',
             'entry_date','last_local_call_time','called_count'
    " | tr '\t' ',' > "$EXPORT_FILE"

    # Write data rows
    $MYSQL_CMD -se "
      SELECT
        list_id, phone_number,
        IFNULL(first_name,''), IFNULL(last_name,''), IFNULL(email,''),
        IFNULL(address1,''), IFNULL(city,''), IFNULL(state,''),
        IFNULL(postal_code,''), IFNULL(status,''),
        IFNULL(entry_date,''), IFNULL(last_local_call_time,''),
        IFNULL(called_count,0)
      FROM vicidial_list
      ORDER BY list_id;
    " | tr '\t' ',' >> "$EXPORT_FILE"

    LINE_COUNT=$(wc -l < "$EXPORT_FILE")
    echo -e "${GREEN}[SUCCESS]${NC} Export complete! ${LINE_COUNT} rows written to:"
    echo -e "  ${BOLD}$EXPORT_FILE${NC}"
    echo ""

    # Proceed to deletion
    echo -e "${YELLOW}[INFO]${NC} Proceeding to delete lead groups (except ${GREEN}998, 999, 1001${NC})..."
    echo ""

    # Final confirmation
    GROUPS_TO_DELETE=$($MYSQL_CMD -se "
      SELECT GROUP_CONCAT(list_id) FROM vicidial_lists
      WHERE list_id NOT IN ($PROTECTED_GROUPS);
    ")

    if [[ -z "$GROUPS_TO_DELETE" || "$GROUPS_TO_DELETE" == "NULL" ]]; then
      echo -e "${GREEN}[INFO]${NC} No lead groups to delete. All existing groups are protected."
      exit 0
    fi

    echo -e "${RED}[WARNING]${NC} The following list IDs will be PERMANENTLY DELETED:"
    echo -e "  ${RED}${BOLD}$GROUPS_TO_DELETE${NC}"
    echo ""
    read -p "Type YES to confirm permanent deletion: " CONFIRM

    if [[ "$CONFIRM" == "YES" ]]; then
      echo ""
      echo -e "${YELLOW}[INFO]${NC} Deleting leads from vicidial_list..."
      $MYSQL_CMD -e "DELETE FROM vicidial_list WHERE list_id NOT IN ($PROTECTED_GROUPS);"
      echo -e "${GREEN}[DONE]${NC} Leads deleted."

      echo -e "${YELLOW}[INFO]${NC} Deleting lead groups from vicidial_lists..."
      $MYSQL_CMD -e "DELETE FROM vicidial_lists WHERE list_id NOT IN ($PROTECTED_GROUPS);"
      echo -e "${GREEN}[DONE]${NC} Lead groups deleted."

      # Also clean up related AMD log entries for deleted lists
      echo -e "${YELLOW}[INFO]${NC} Cleaning up vicidial_amd_log entries..."
      $MYSQL_CMD -e "DELETE FROM vicidial_amd_log WHERE lead_id NOT IN (SELECT lead_id FROM vicidial_list);" 2>/dev/null
      echo -e "${GREEN}[DONE]${NC} AMD log cleaned."

      echo ""
      echo -e "${BOLD}${GREEN}============================================${NC}"
      echo -e "${BOLD}${GREEN}   All done! Summary:${NC}"
      echo -e "${GREEN}   - Leads exported to: $EXPORT_FILE${NC}"
      echo -e "${GREEN}   - Deleted list IDs:  $GROUPS_TO_DELETE${NC}"
      echo -e "${GREEN}   - Protected lists:   $PROTECTED_GROUPS${NC}"
      echo -e "${BOLD}${GREEN}============================================${NC}"
    else
      echo -e "${YELLOW}[ABORTED]${NC} Deletion cancelled. No changes made."
    fi
    ;;

  # ──────────────────────────────────────────────────────────
  2)
    echo ""
    GROUPS_TO_DELETE=$($MYSQL_CMD -se "
      SELECT GROUP_CONCAT(list_id) FROM vicidial_lists
      WHERE list_id NOT IN ($PROTECTED_GROUPS);
    ")

    if [[ -z "$GROUPS_TO_DELETE" || "$GROUPS_TO_DELETE" == "NULL" ]]; then
      echo -e "${GREEN}[INFO]${NC} No lead groups to delete."
      exit 0
    fi

    echo -e "${RED}[WARNING]${NC} The following list IDs will be PERMANENTLY DELETED (NO backup):"
    echo -e "  ${RED}${BOLD}$GROUPS_TO_DELETE${NC}"
    echo ""
    read -p "Type YES to confirm permanent deletion WITHOUT export: " CONFIRM

    if [[ "$CONFIRM" == "YES" ]]; then
      echo ""
      echo -e "${YELLOW}[INFO]${NC} Deleting leads from vicidial_list..."
      $MYSQL_CMD -e "DELETE FROM vicidial_list WHERE list_id NOT IN ($PROTECTED_GROUPS);"
      echo -e "${GREEN}[DONE]${NC} Leads deleted."

      echo -e "${YELLOW}[INFO]${NC} Deleting lead groups from vicidial_lists..."
      $MYSQL_CMD -e "DELETE FROM vicidial_lists WHERE list_id NOT IN ($PROTECTED_GROUPS);"
      echo -e "${GREEN}[DONE]${NC} Lead groups deleted."

      echo -e "${YELLOW}[INFO]${NC} Cleaning up vicidial_amd_log entries..."
      $MYSQL_CMD -e "DELETE FROM vicidial_amd_log WHERE lead_id NOT IN (SELECT lead_id FROM vicidial_list);" 2>/dev/null
      echo -e "${GREEN}[DONE]${NC} AMD log cleaned."

      echo ""
      echo -e "${BOLD}${GREEN}============================================${NC}"
      echo -e "${BOLD}${GREEN}   Deletion complete!${NC}"
      echo -e "${GREEN}   - Deleted list IDs: $GROUPS_TO_DELETE${NC}"
      echo -e "${GREEN}   - Protected lists:  $PROTECTED_GROUPS${NC}"
      echo -e "${BOLD}${GREEN}============================================${NC}"
    else
      echo -e "${YELLOW}[ABORTED]${NC} Deletion cancelled. No changes made."
    fi
    ;;

  # ──────────────────────────────────────────────────────────
  3)
    echo ""
    echo -e "${YELLOW}[EXIT]${NC} No changes made. Goodbye!"
    exit 0
    ;;

  *)
    echo -e "${RED}[ERROR]${NC} Invalid choice. Exiting."
    exit 1
    ;;
esac

echo ""
