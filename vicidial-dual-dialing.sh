#!/bin/bash
# ================================================================
# VICIdial Independent Dual Dialing - Final Production Script
# ================================================================
# Version : 1.0
# Purpose : Allows same agent to run TWO browser panels with
#           fully independent dialing and dispo per tab.
#           Audio via physical SIP phone (Eyebeam or any hardphone)
#
# What this does:
#   [1] Auto-detects webroot, DB credentials, server_ip
#   [2] Patches vicidial.php  - disables duplicate session killer
#   [3] Patches vdc_db_query.php - bypasses INCALL dial block
#   [4] Creates _B shadow user (exact clone, same password)
#   [5] Creates _B phone entry (own conf/park extensions)
#   [6] Assigns _B its own conf_exten slot in vicidial_conferences
#   [7] Installs cron - auto-creates _B for any new agent (every 5min)
#
# Usage:
#   bash vicidial_dual_dial.sh            # full setup
#   bash vicidial_dual_dial.sh --sync     # cron uses this
#   bash vicidial_dual_dial.sh --list     # show all _B entries
#   bash vicidial_dual_dial.sh --status   # show patch status
#   bash vicidial_dual_dial.sh --revert   # full rollback
#
# NOTE: Hangup is NOT independent (physical SIP limitation).
#       Dialing, dispo, lead data ARE fully independent per tab.
# ================================================================

SCRIPT_PATH=$(realpath "$0")
LOGFILE="/var/log/vicidial_dual_dial.log"
OFFSET=10000  # Added to dialplan_number, conf, park for _B phone entry
BACKUP_DIR=""

# ================================================================
# LOGGING
# ================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOGFILE"; }

# ================================================================
# STEP 0 - ROOT CHECK
# ================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root. Use: sudo bash $SCRIPT_PATH"
    exit 1
fi

# ================================================================
# AUTO-DETECT WEBROOT
# ================================================================
detect_webroot() {
    for path in \
        /srv/www/htdocs/agc \
        /var/www/html/agc \
        /var/www/vicidial/agc \
        /usr/share/astguiclient/agc \
        /var/www/agc; do
        if [ -f "$path/vicidial.php" ]; then
            echo "$path"
            return 0
        fi
    done
    # fallback: find it
    FOUND=$(find / -maxdepth 8 -name "vicidial.php" 2>/dev/null | grep -v "_orig\|backup\|/mnt/" | head -1)
    if [ -n "$FOUND" ]; then
        echo "$(dirname $FOUND)"
        return 0
    fi
    return 1
}

# ================================================================
# AUTO-DETECT DB CREDENTIALS
# ================================================================
detect_db() {
    # Try common VICIdial credential combos
    for CREDS in "root: " "root:asterisk" "root:vicidial" "cron:1234"; do
        DBUSR=$(echo $CREDS | cut -d: -f1)
        DBPWD=$(echo $CREDS | cut -d: -f2)
        TEST=$(mysql -u"$DBUSR" -p"$DBPWD" asterisk -sNe "SELECT 1;" 2>/dev/null)
        if [ "$TEST" == "1" ]; then
            echo "$DBUSR:$DBPWD"
            return 0
        fi
    done
    # Try reading from VICIdial config
    if [ -f "/etc/astguiclient.conf" ]; then
        DBUSR=$(grep "^VARdbuser" /etc/astguiclient.conf | cut -d= -f2 | tr -d ' ')
        DBPWD=$(grep "^VARdbpass" /etc/astguiclient.conf | cut -d= -f2 | tr -d ' ')
        TEST=$(mysql -u"$DBUSR" -p"$DBPWD" asterisk -sNe "SELECT 1;" 2>/dev/null)
        if [ "$TEST" == "1" ]; then
            echo "$DBUSR:$DBPWD"
            return 0
        fi
    fi
    return 1
}

# ================================================================
# DETECT SERVER IP
# ================================================================
detect_server_ip() {
    # Get from vicidial servers table first
    SIP=$($MYSQL -sNe "SELECT server_ip FROM servers LIMIT 1;" 2>/dev/null)
    if [ -n "$SIP" ]; then echo "$SIP"; return 0; fi
    # fallback to system IP
    hostname -I | awk '{print $1}'
}

# ================================================================
# INITIALISE - detect everything
# ================================================================
init() {
    log "=== Initialising ==="

    WEBROOT=$(detect_webroot)
    if [ -z "$WEBROOT" ]; then
        err "Cannot find vicidial.php. Aborting."
        exit 1
    fi
    log "Webroot: $WEBROOT"

    DB_CREDS=$(detect_db)
    if [ -z "$DB_CREDS" ]; then
        err "Cannot connect to MySQL. Check credentials. Aborting."
        exit 1
    fi
    DBUSR=$(echo $DB_CREDS | cut -d: -f1)
    DBPWD=$(echo $DB_CREDS | cut -d: -f2)
    MYSQL="mysql -u$DBUSR -p$DBPWD asterisk"
    log "DB user: $DBUSR"

    SERVER_IP=$(detect_server_ip)
    log "Server IP: $SERVER_IP"

    MAIN_PHP="$WEBROOT/vicidial.php"
    QUERY_PHP="$WEBROOT/vdc_db_query.php"
}

# ================================================================
# LIST
# ================================================================
if [ "$1" == "--list" ]; then
    init
    echo ""
    echo "=== _B Shadow Users ==="
    $MYSQL -e "SELECT user, full_name, user_group, active FROM vicidial_users WHERE user LIKE '%_B' ORDER BY user;"
    echo ""
    echo "=== _B Shadow Phones ==="
    $MYSQL -e "SELECT extension, dialplan_number, conf_on_extension, park_on_extension, active FROM phones WHERE extension LIKE '%_B' ORDER BY extension;"
    echo ""
    echo "=== _B Conf Slots ==="
    $MYSQL -e "SELECT conf_exten, extension, server_ip FROM vicidial_conferences WHERE extension LIKE '%SIP/%_B%' OR extension LIKE '%1001_B%' ORDER BY conf_exten;"
    echo ""
    exit 0
fi

# ================================================================
# STATUS - show what patches are applied
# ================================================================
if [ "$1" == "--status" ]; then
    init
    echo ""
    echo "=== Patch Status ==="
    grep -q "DUAL_DIAL_PATCH" "$MAIN_PHP" && \
        echo "[PATCHED] vicidial.php - session killer disabled" || \
        echo "[NOT PATCHED] vicidial.php"
    grep -q "DUAL_DIAL_PATCH" "$QUERY_PHP" && \
        echo "[PATCHED] vdc_db_query.php - INCALL block bypassed" || \
        echo "[NOT PATCHED] vdc_db_query.php"
    COUNT=$($MYSQL -sNe "SELECT COUNT(*) FROM vicidial_users WHERE user LIKE '%_B';")
    echo "[DB] _B shadow users: $COUNT"
    COUNT=$($MYSQL -sNe "SELECT COUNT(*) FROM phones WHERE extension LIKE '%_B';")
    echo "[DB] _B phone entries: $COUNT"
    CRON_FILE="/etc/cron.d/vicidial_dual_dial"
    [ -f "$CRON_FILE" ] && echo "[CRON] Installed: $CRON_FILE" || echo "[CRON] Not installed"
    echo ""
    exit 0
fi

# ================================================================
# REVERT
# ================================================================
if [ "$1" == "--revert" ]; then
    init
    echo ""
    read -p "REVERT ALL changes? This removes patches + all _B users/phones. Type YES: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then echo "Aborted."; exit 0; fi

    # Restore PHP files from latest backup
    LATEST=$(ls -dt /root/vicidial_dual_dial_backup_* 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        cp "$LATEST/vicidial.php" "$MAIN_PHP" && log "Restored vicidial.php from $LATEST"
        cp "$LATEST/vdc_db_query.php" "$QUERY_PHP" && log "Restored vdc_db_query.php from $LATEST"
    else
        err "No backup found. Manually remove DUAL_DIAL_PATCH lines."
    fi

    # Remove _B DB entries
    UC=$($MYSQL -sNe "SELECT COUNT(*) FROM vicidial_users WHERE user LIKE '%_B';")
    PC=$($MYSQL -sNe "SELECT COUNT(*) FROM phones WHERE extension LIKE '%_B';")
    $MYSQL -e "DELETE FROM vicidial_users WHERE user LIKE '%_B';"
    $MYSQL -e "DELETE FROM phones WHERE extension LIKE '%_B';"
    $MYSQL -e "UPDATE vicidial_conferences SET extension='' WHERE extension LIKE 'SIP/%_B';"
    log "Removed $UC _B users, $PC _B phones, cleared _B conf slots."

    # Remove cron
    rm -f /etc/cron.d/vicidial_dual_dial
    log "Cron removed."

    echo ""
    echo "REVERT COMPLETE. Server is back to original state."
    echo ""
    exit 0
fi

# ================================================================
# SYNC FUNCTION - create _B for any agent that doesn't have one
# ================================================================
sync_agents() {
    AGENTS=$($MYSQL -sNe "
    SELECT user FROM vicidial_users
    WHERE active='Y'
    AND user_level BETWEEN 1 AND 4
    AND user NOT LIKE '%_B'
    AND LENGTH(user) <= 18
    ORDER BY user;")

    [ -z "$AGENTS" ] && log "No eligible agents found." && return

    CREATED=0
    SKIPPED=0

    for AGENT in $AGENTS; do
        SHADOW="${AGENT}_B"
        SIP_SHADOW="SIP/${SHADOW}"

        # --- vicidial_users clone ---
        EXISTS=$($MYSQL -sNe "SELECT COUNT(*) FROM vicidial_users WHERE user='$SHADOW';")
        if [ "$EXISTS" -eq 0 ]; then
            $MYSQL -e "
            INSERT INTO vicidial_users (
                user, pass, full_name, user_level, user_group,
                phone_login, phone_pass, delete_users, delete_user_groups,
                delete_lists, delete_campaigns, delete_ingroups,
                delete_remote_agents, load_leads, campaign_detail,
                ast_admin_access, ast_delete_phones, delete_scripts,
                modify_leads, hotkeys_active, change_agent_campaign,
                agent_choose_ingroups, closer_campaigns,
                scheduled_callbacks, agentonly_callbacks, agentcall_manual,
                vicidial_recording, vicidial_transfers, delete_filters,
                alter_agent_interface_options, closer_default_blended,
                delete_call_times, modify_call_times, modify_users,
                modify_campaigns, modify_lists, modify_scripts,
                modify_filters, modify_ingroups, modify_usergroups,
                modify_remoteagents, modify_servers, view_reports,
                vicidial_recording_override, alter_custdata_override,
                qc_enabled, qc_user_level, qc_pass, qc_finish, qc_commit,
                add_timeclock_log, modify_timeclock_log, delete_timeclock_log,
                alter_custphone_override, vdc_agent_api_access,
                modify_inbound_dids, delete_inbound_dids, active,
                alert_enabled, download_lists, agent_shift_enforcement_override,
                export_reports, delete_from_dnc, email, user_code, territory,
                allow_alerts, agent_choose_territories, custom_one, custom_two,
                custom_three, custom_four, custom_five, voicemail_id,
                agent_call_log_view_override, callcard_admin,
                agent_choose_blended, realtime_block_user_info,
                custom_fields_modify, force_change_password,
                agent_lead_search_override, modify_shifts, modify_phones,
                modify_carriers, modify_labels, modify_statuses,
                modify_voicemail, modify_audiostore, modify_moh, modify_tts,
                preset_contact_search, modify_contacts, modify_same_user_level,
                admin_hide_lead_data, admin_hide_phone_data, agentcall_email,
                modify_email_accounts, alter_admin_interface_options,
                max_inbound_calls, modify_custom_dialplans,
                wrapup_seconds_override, modify_languages, selected_language,
                user_choose_language, ignore_group_on_search, api_list_restrict,
                api_allowed_functions, lead_filter_id, admin_cf_show_hidden,
                agentcall_chat, user_hide_realtime, access_recordings,
                modify_colors, user_nickname, user_new_lead_limit, api_only_user,
                modify_auto_reports, modify_ip_lists, ignore_ip_list,
                ready_max_logout, export_gdpr_leads, pause_code_approval,
                max_hopper_calls, max_hopper_calls_hour, mute_recordings,
                hide_call_log_info, next_dial_my_callbacks,
                max_inbound_filter_enabled, status_group_id,
                two_factor_override, manual_dial_filter, user_location,
                download_invalid_files, user_group_two, modify_dial_prefix,
                inbound_credits, hci_enabled, manual_dial_lead_id,
                modify_settings_containers
            )
            SELECT
                '$SHADOW', pass, CONCAT(SUBSTRING(full_name,1,47),' (B)'),
                user_level, user_group,
                phone_login, phone_pass, delete_users, delete_user_groups,
                delete_lists, delete_campaigns, delete_ingroups,
                delete_remote_agents, load_leads, campaign_detail,
                ast_admin_access, ast_delete_phones, delete_scripts,
                modify_leads, hotkeys_active, change_agent_campaign,
                agent_choose_ingroups, closer_campaigns,
                scheduled_callbacks, agentonly_callbacks, agentcall_manual,
                vicidial_recording, vicidial_transfers, delete_filters,
                alter_agent_interface_options, closer_default_blended,
                delete_call_times, modify_call_times, modify_users,
                modify_campaigns, modify_lists, modify_scripts,
                modify_filters, modify_ingroups, modify_usergroups,
                modify_remoteagents, modify_servers, view_reports,
                vicidial_recording_override, alter_custdata_override,
                qc_enabled, qc_user_level, qc_pass, qc_finish, qc_commit,
                add_timeclock_log, modify_timeclock_log, delete_timeclock_log,
                alter_custphone_override, vdc_agent_api_access,
                modify_inbound_dids, delete_inbound_dids, active,
                alert_enabled, download_lists, agent_shift_enforcement_override,
                export_reports, delete_from_dnc, email, user_code, territory,
                allow_alerts, agent_choose_territories, custom_one, custom_two,
                custom_three, custom_four, custom_five, voicemail_id,
                agent_call_log_view_override, callcard_admin,
                agent_choose_blended, realtime_block_user_info,
                custom_fields_modify, force_change_password,
                agent_lead_search_override, modify_shifts, modify_phones,
                modify_carriers, modify_labels, modify_statuses,
                modify_voicemail, modify_audiostore, modify_moh, modify_tts,
                preset_contact_search, modify_contacts, modify_same_user_level,
                admin_hide_lead_data, admin_hide_phone_data, agentcall_email,
                modify_email_accounts, alter_admin_interface_options,
                max_inbound_calls, modify_custom_dialplans,
                wrapup_seconds_override, modify_languages, selected_language,
                user_choose_language, ignore_group_on_search, api_list_restrict,
                api_allowed_functions, lead_filter_id, admin_cf_show_hidden,
                agentcall_chat, user_hide_realtime, access_recordings,
                modify_colors, user_nickname, user_new_lead_limit, api_only_user,
                modify_auto_reports, modify_ip_lists, ignore_ip_list,
                ready_max_logout, export_gdpr_leads, pause_code_approval,
                max_hopper_calls, max_hopper_calls_hour, mute_recordings,
                hide_call_log_info, next_dial_my_callbacks,
                max_inbound_filter_enabled, status_group_id,
                two_factor_override, manual_dial_filter, user_location,
                download_invalid_files, user_group_two, modify_dial_prefix,
                inbound_credits, hci_enabled, manual_dial_lead_id,
                modify_settings_containers
            FROM vicidial_users WHERE user='$AGENT';
            " 2>>/dev/null && log "USER: $SHADOW created" || log "USER: $SHADOW failed"
        fi

        # --- phones table clone ---
        EXISTS_PHONE=$($MYSQL -sNe "SELECT COUNT(*) FROM phones WHERE extension='$SHADOW';")
        HAS_PHONE=$($MYSQL -sNe "SELECT COUNT(*) FROM phones WHERE extension='$AGENT' AND active='Y';")

        if [ "$EXISTS_PHONE" -eq 0 ] && [ "$HAS_PHONE" -gt 0 ]; then
            ORIG_DIALPLAN=$($MYSQL -sNe "SELECT dialplan_number FROM phones WHERE extension='$AGENT' LIMIT 1;")
            ORIG_CONF=$($MYSQL -sNe "SELECT conf_on_extension FROM phones WHERE extension='$AGENT' LIMIT 1;")
            ORIG_PARK=$($MYSQL -sNe "SELECT park_on_extension FROM phones WHERE extension='$AGENT' LIMIT 1;")
            ORIG_VPARK=$($MYSQL -sNe "SELECT VICIDIAL_park_on_extension FROM phones WHERE extension='$AGENT' LIMIT 1;")
            ORIG_REC=$($MYSQL -sNe "SELECT recording_exten FROM phones WHERE extension='$AGENT' LIMIT 1;")
            ORIG_VM=$($MYSQL -sNe "SELECT voicemail_exten FROM phones WHERE extension='$AGENT' LIMIT 1;")

            NEW_DIALPLAN=$ORIG_DIALPLAN
            NEW_CONF=$ORIG_CONF
            NEW_PARK=$ORIG_PARK
            NEW_VPARK=$ORIG_VPARK
            NEW_REC=$ORIG_REC
            NEW_VM=$ORIG_VM

            [[ "$ORIG_DIALPLAN" =~ ^[0-9]+$ ]] && NEW_DIALPLAN=$((ORIG_DIALPLAN + OFFSET))
            [[ "$ORIG_CONF" =~ ^[0-9]+$ ]]     && NEW_CONF=$((ORIG_CONF + OFFSET))
            [[ "$ORIG_PARK" =~ ^[0-9]+$ ]]     && NEW_PARK=$((ORIG_PARK + OFFSET))
            [[ "$ORIG_VPARK" =~ ^[0-9]+$ ]]    && NEW_VPARK=$((ORIG_VPARK + OFFSET))
            [[ "$ORIG_REC" =~ ^[0-9]+$ ]]      && NEW_REC=$((ORIG_REC + OFFSET))
            [[ "$ORIG_VM" =~ ^[0-9]+$ ]]       && NEW_VM=$((ORIG_VM + OFFSET))

            $MYSQL -e "
            INSERT INTO phones SELECT
                '$SHADOW','$NEW_DIALPLAN','$SHADOW',
                phone_ip, computer_ip, server_ip,
                '$SHADOW', pass, status, active, phone_type,
                CONCAT(SUBSTRING(fullname,1,47),' (B)'),
                company, picture, messages, old_messages,
                protocol, local_gmt, ASTmgrUSERNAME, ASTmgrSECRET,
                login_user, login_pass, login_campaign,
                '$NEW_PARK','$NEW_CONF','$NEW_VPARK',
                VICIDIAL_park_on_filename, monitor_prefix,
                '$NEW_REC','$NEW_VM',
                voicemail_dump_exten, ext_context,
                dtmf_send_extension, call_out_number_group,
                client_browser, install_directory,
                local_web_callerID_URL, VICIDIAL_web_URL,
                AGI_call_logging_enabled, user_switching_enabled,
                conferencing_enabled, admin_hangup_enabled,
                admin_hijack_enabled, admin_monitor_enabled,
                call_parking_enabled, updater_check_enabled,
                AFLogging_enabled, QUEUE_ACTION_enabled,
                CallerID_popup_enabled, voicemail_button_enabled,
                enable_fast_refresh, fast_refresh_rate,
                enable_persistant_mysql, auto_dial_next_number,
                VDstop_rec_after_each_call,
                DBX_server, DBX_database, DBX_user, DBX_pass, DBX_port,
                DBY_server, DBY_database, DBY_user, DBY_pass, DBY_port,
                outbound_cid, enable_sipsak_messages,
                email, template_id, conf_override, phone_context,
                phone_ring_timeout, conf_secret,
                delete_vm_after_email, is_webphone,
                use_external_server_ip, codecs_list, codecs_with_template,
                webphone_dialpad, on_hook_agent, webphone_auto_answer,
                voicemail_timezone, voicemail_options, user_group,
                voicemail_greeting, voicemail_dump_exten_no_inst,
                voicemail_instructions, on_login_report,
                unavail_dialplan_fwd_exten, unavail_dialplan_fwd_context,
                nva_call_url, nva_search_method, nva_error_filename,
                nva_new_list_id, nva_new_phone_code, nva_new_status,
                webphone_dialbox, webphone_mute, webphone_volume,
                webphone_debug, outbound_alt_cid, conf_qualify,
                webphone_layout, mohsuggest, peer_status, ping_time,
                webphone_settings
            FROM phones WHERE extension='$AGENT';
            " 2>>/dev/null && log "PHONE: $SHADOW created (conf=$NEW_CONF)" || log "PHONE: $SHADOW failed"
        fi

        # --- vicidial_conferences slot ---
        # Check which conf_table is in use
        CONF_ENGINE=$($MYSQL -sNe "SELECT conf_engine FROM servers WHERE server_ip='$SERVER_IP' LIMIT 1;" 2>/dev/null)
        if [ "$CONF_ENGINE" == "CONFBRIDGE" ]; then
            CONF_TABLE="vicidial_confbridges"
        else
            CONF_TABLE="vicidial_conferences"
        fi

        # Check if _B already has a conf slot
        EXISTS_CONF=$($MYSQL -sNe "
        SELECT COUNT(*) FROM $CONF_TABLE
        WHERE server_ip='$SERVER_IP'
        AND (extension='SIP/$SHADOW' OR extension='$SHADOW');")

        if [ "$EXISTS_CONF" -eq 0 ]; then
            # Find a free conf slot
            FREE_CONF=$($MYSQL -sNe "
            SELECT conf_exten FROM $CONF_TABLE
            WHERE server_ip='$SERVER_IP'
            AND (extension='' OR extension IS NULL)
            ORDER BY conf_exten
            LIMIT 1;")

            if [ -n "$FREE_CONF" ]; then
                $MYSQL -e "
                UPDATE $CONF_TABLE
                SET extension='SIP/$SHADOW'
                WHERE conf_exten='$FREE_CONF'
                AND server_ip='$SERVER_IP';" 2>>/dev/null
                log "CONF: $SHADOW assigned conf_exten=$FREE_CONF (table=$CONF_TABLE)"
                CREATED=$((CREATED + 1))
            else
                log "CONF: WARNING - No free conf slot for $SHADOW in $CONF_TABLE"
            fi
        else
            SKIPPED=$((SKIPPED + 1))
        fi

    done

    log "Sync done. Created: $CREATED | Skipped: $SKIPPED"
    echo ""
    echo "  Agents created : $CREATED"
    echo "  Agents skipped : $SKIPPED (already existed)"
}

# ================================================================
# SYNC ONLY MODE (cron)
# ================================================================
if [ "$1" == "--sync" ]; then
    init
    sync_agents
    exit 0
fi

# ================================================================
# FULL SETUP (default - first run)
# ================================================================
init

echo ""
echo "========================================================"
echo "  VICIdial Independent Dual Dialing - Setup"
echo "========================================================"
echo "  Webroot   : $WEBROOT"
echo "  DB User   : $DBUSR"
echo "  Server IP : $SERVER_IP"
echo "========================================================"
echo ""

# Already fully patched check
if grep -q "DUAL_DIAL_PATCH" "$MAIN_PHP" && grep -q "DUAL_DIAL_PATCH" "$QUERY_PHP"; then
    log "PHP files already patched. Running agent sync only."
    sync_agents
    echo ""
    echo "Run: bash $SCRIPT_PATH --status  to verify everything."
    exit 0
fi

# --- Backup ---
BACKUP_DIR="/root/vicidial_dual_dial_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$MAIN_PHP"  "$BACKUP_DIR/vicidial.php"
cp "$QUERY_PHP" "$BACKUP_DIR/vdc_db_query.php"
log "Backup: $BACKUP_DIR"

# --- Patch 1: vicidial.php - session killer ---
echo "[1/4] Patching vicidial.php - session killer..."
KILLER_LINE=$(grep -n "vlaLIaffected_rows = mysqli_affected_rows" "$MAIN_PHP" | head -1 | cut -d: -f1)
if [ -z "$KILLER_LINE" ]; then
    err "Cannot find session killer line. Check vicidial.php manually."
else
    sed -i "${KILLER_LINE}s/.*/   \$vlaLIaffected_rows = 0; \/\/ DUAL_DIAL_PATCH/" "$MAIN_PHP"
    log "Session killer disabled at line $KILLER_LINE"
    echo "     OK"
fi

# --- Patch 2: vicidial.php - AgenTDisablEBoX popup ---
echo "[2/4] Patching vicidial.php - disabled session popup..."
DISABLE_LINES=$(grep -n "showDiv('AgenTDisablEBoX')" "$MAIN_PHP" | cut -d: -f1)
for LN in $DISABLE_LINES; do
    sed -i "${LN}s/showDiv('AgenTDisablEBoX')/\/\/ DUAL_DIAL_PATCH showDiv_disabled/" "$MAIN_PHP"
done
[ -n "$DISABLE_LINES" ] && log "Popup suppressed" && echo "     OK" || echo "     WARN: lines not found - skipped"

# --- Patch 3: vdc_db_query.php - INCALL block ---
echo "[3/4] Patching vdc_db_query.php - INCALL block..."
if grep -q "DUAL_DIAL_PATCH" "$QUERY_PHP"; then
    echo "     Already patched - skipped"
else
    sed -i "s/if (\$vla_status == 'INCALL')/if (\$vla_status == 'INCALL' \&\& false) \/\/ DUAL_DIAL_PATCH/" "$QUERY_PHP"
    if grep -q "DUAL_DIAL_PATCH" "$QUERY_PHP"; then
        log "INCALL block bypassed in vdc_db_query.php"
        echo "     OK"
    else
        err "vdc_db_query.php patch failed - check manually"
        echo "     FAILED - check log"
    fi
fi

# --- Step 4: Agent sync ---
echo "[4/4] Creating _B shadow agents..."
sync_agents

# --- Install cron ---
CRON_FILE="/etc/cron.d/vicidial_dual_dial"
if [ ! -f "$CRON_FILE" ]; then
    echo "*/5 * * * * root bash $SCRIPT_PATH --sync >> $LOGFILE 2>&1" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    log "Cron installed: $CRON_FILE"
fi

# --- Verify ---
echo ""
echo "========================================================"
echo "  SETUP COMPLETE"
echo "========================================================"
echo ""
echo "  Backup     : $BACKUP_DIR"
echo "  Log        : $LOGFILE"
echo "  Cron       : /etc/cron.d/vicidial_dual_dial (every 5 min)"
echo ""
echo "  HOW TO USE:"
echo "  Tab 1 (Chrome normal) : Login as 1001   → phone ext: 1001"
echo "  Tab 2 (Incognito)     : Login as 1001_B  → phone ext: 1001_B"
echo "  ✓ Dialing   - INDEPENDENT per tab"
echo "  ✓ Dispo     - INDEPENDENT per tab"
echo "  ✓ Lead data - INDEPENDENT per tab"
echo "  ✗ Hangup    - NOT independent (SIP phone limitation)"
echo ""
echo "  NEW AGENTS: _B created automatically within 5 minutes"
echo ""
echo "  bash $SCRIPT_PATH --status   # verify patches"
echo "  bash $SCRIPT_PATH --list     # show all _B entries"
echo "  bash $SCRIPT_PATH --revert   # full rollback"
echo "========================================================"
