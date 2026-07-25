#!/usr/bin/env bash

set -eo pipefail

export TZ="America/Los_Angeles"

LOG_PREFIX="[viofo-sync]"
LOCK_FILE="/tmp/viofo_sync.lock"
STATUS_FILE="/tmp/viofo_sync_status.json"
MQTT_TRIGGER_FILE="/tmp/viofo_mqtt_trigger"
OPTIONS_FILE="/data/options.json"

# Global flag set by backup_config, read by run_sync
CONFIG_BACKED_UP=false

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_PREFIX $*"; }

# ─── Read options from /data/options.json ───────────────────────────────────
if [ ! -f "$OPTIONS_FILE" ]; then
    log "ERROR: Options file not found at ${OPTIONS_FILE}"
    exit 1
fi

CAM_IP=$(jq -r '.cam_ip' "$OPTIONS_FILE")
DEST_SUBDIR=$(jq -r '.dest_subdir' "$OPTIONS_FILE")
INTERVAL=$(jq -r '.schedule_interval_minutes' "$OPTIONS_FILE")
DELETE_AFTER=$(jq -r '.delete_after_download' "$OPTIONS_FILE")
DRY_RUN=$(jq -r '.dry_run' "$OPTIONS_FILE")
UI_NOTIFICATIONS=$(jq -r '.ui_notifications // true' "$OPTIONS_FILE")
UI_NOTIFY_CONFIG_CHANGE=$(jq -r '.ui_notify_config_change // true' "$OPTIONS_FILE")
SYNC_ON_STARTUP=$(jq -r '.sync_on_startup // true' "$OPTIONS_FILE")
MQTT_USER=$(jq -r '.mqtt_user // empty' "$OPTIONS_FILE")
MQTT_PASS=$(jq -r '.mqtt_pass // empty' "$OPTIONS_FILE")

CHANNELS=("DCIM/Movie/RO")
DEST_DIR="/share/${DEST_SUBDIR}"
CONFIG_BACKUP_DIR="/share/${DEST_SUBDIR}/config"

log "Starting VIOFO Sync Add-on"
log "Camera IP: ${CAM_IP}"
log "Destination: ${DEST_DIR}"
log "Interval: $([ "$INTERVAL" = "0" ] && echo 'disabled (manual/arrival trigger only)' || echo "${INTERVAL} minutes")"
log "Delete after download: ${DELETE_AFTER}"
log "Dry run: ${DRY_RUN}"
log "UI notifications: ${UI_NOTIFICATIONS}"
log "UI notify config change: ${UI_NOTIFY_CONFIG_CHANGE}"
log "Sync on startup: ${SYNC_ON_STARTUP}"

mkdir -p "$DEST_DIR"
mkdir -p "$CONFIG_BACKUP_DIR"

# ─── Supervisor token ────────────────────────────────────────────────────────
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN:-$(printenv SUPERVISOR_TOKEN 2>/dev/null || echo '')}"
if [ -z "$SUPERVISOR_TOKEN" ]; then
    SUPERVISOR_TOKEN=$(cat /var/run/s6/container_environment/SUPERVISOR_TOKEN 2>/dev/null || echo "")
fi
if [ -n "$SUPERVISOR_TOKEN" ]; then
    log "Supervisor token loaded successfully"
else
    log "WARNING: SUPERVISOR_TOKEN not available, HA events/notifications disabled"
fi

# ─── Helper: fire HA event ───────────────────────────────────────────────────
fire_ha_event() {
    local event_type="$1"
    local payload="$2"
    [ -z "$SUPERVISOR_TOKEN" ] && return 0
    curl -sf \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://supervisor/core/api/events/${event_type}" > /dev/null || \
        log "WARNING: Could not fire HA event ${event_type}"
}

# ─── Helper: HA persistent notification ─────────────────────────────────────
ha_notify() {
    local title="$1"
    local message="$2"
    local notification_id="${3:-viofo_sync}"
    [ -z "$SUPERVISOR_TOKEN" ] && return 0
    [ "$UI_NOTIFICATIONS" = "false" ] && return 0
    curl -sf \
        -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"${title}\", \"message\": \"${message}\", \"notification_id\": \"${notification_id}\"}" \
        "http://supervisor/core/api/services/persistent_notification/create" > /dev/null || true
}

# ─── Config backup ───────────────────────────────────────────────────────────
backup_config() {
    local tmp_config="/tmp/viofo_config_latest.ini"
    local last_config="/data/viofo_config_last.ini"

    if ! curl -sf --max-time 10 \
            "http://${CAM_IP}/Config/viofo_config.ini" \
            -o "$tmp_config" 2>/dev/null; then
        log "Config backup: could not fetch viofo_config.ini"
        return 0
    fi

    if [ -f "$last_config" ] && cmp -s "$tmp_config" "$last_config"; then
        log "Config backup: no changes detected"
        return 0
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H%M%S')
    local dest="${CONFIG_BACKUP_DIR}/viofo_config_${timestamp}.ini"

    cp "$tmp_config" "$dest"
    cp "$tmp_config" "$last_config"
    CONFIG_BACKED_UP=true
    log "Config backup: saved viofo_config_${timestamp}.ini"

    fire_ha_event "viofo_config_changed" \
        "{\"file\": \"viofo_config_${timestamp}.ini\", \"timestamp\": \"${timestamp}\"}"
}

# ─── Helper: delete file from camera ─────────────────────────────────────────
delete_from_camera() {
    local channel="$1"
    local filename="$2"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        "http://${CAM_IP}/${channel}/${filename}?del=1" \
        2>/dev/null || echo "000")
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        return 0
    else
        log "WARNING: Delete may have failed for ${filename} — HTTP ${http_code}"
        return 1
    fi
}

# ─── Helper: human-readable trigger label ────────────────────────────────────
trigger_label() {
    case "$1" in
        startup)   echo "Startup" ;;
        arrival)   echo "Arrival" ;;
        scheduled) echo "Scheduled" ;;
        manual)    echo "Manual" ;;
        *)         echo "$1" ;;
    esac
}

# ─── Main sync function ──────────────────────────────────────────────────────
run_sync() {
    local trigger_source="${1:-scheduled}"
    local trigger_desc
    trigger_desc=$(trigger_label "$trigger_source")

    if [ -f "$LOCK_FILE" ]; then
        log "Sync already in progress, skipping (triggered by: ${trigger_source})"
        return 0
    fi

    touch "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' RETURN

    CONFIG_BACKED_UP=false

    log "Starting sync (triggered by: ${trigger_source})"
    fire_ha_event "viofo_sync_started" "{\"trigger\": \"${trigger_source}\"}"

    local downloaded=0
    local deleted=0
    local skipped=0
    local errors=0
    local total_found=0

    # ── Check camera reachability ──────────────────────────────────────────
    if ! curl -sf --max-time 5 "http://${CAM_IP}/" > /dev/null 2>&1; then
        log "Camera offline or unreachable at ${CAM_IP}"
        fire_ha_event "viofo_sync_complete" \
            "{\"status\": \"offline\", \"trigger\": \"${trigger_source}\", \"downloaded\": 0, \"deleted\": 0, \"skipped\": 0, \"errors\": 0}"
        ha_notify "🚗 Dashcam Offline — ${trigger_desc}" \
            "Could not reach camera at ${CAM_IP}."
        return 0
    fi

    log "Camera is online at ${CAM_IP}"
    backup_config

    # ── Scan channels first, so we know the total before downloading ──────
    declare -A channel_file_lists

    for channel in "${CHANNELS[@]}"; do
        log "Scanning channel: ${channel}"

        listing=$(curl -sf --max-time 10 "http://${CAM_IP}/${channel}/" 2>/dev/null || true)

        if [ -z "$listing" ]; then
            log "No listing returned for ${channel} — channel may be empty or not exist"
            continue
        fi

        # Build file list as plain variable to avoid subshell scope issues
        file_list=$(echo "$listing" | grep -oE 'href="/DCIM/Movie/RO/[^"?#]+\.MP4"' | \
            sed 's|href="/DCIM/Movie/RO/||; s|"||g' | sort || true)

        channel_file_lists["$channel"]="$file_list"

        channel_count=0
        [ -n "$file_list" ] && channel_count=$(printf '%s\n' "$file_list" | grep -c .)
        total_found=$((total_found + channel_count))
        log "Found ${channel_count} file(s) in ${channel}"
    done

    log "Detected ${total_found} file(s) to sync"

    # ── Download using each channel's already-fetched listing ─────────────
    for channel in "${CHANNELS[@]}"; do
        file_list="${channel_file_lists[$channel]:-}"
        [ -z "$file_list" ] && continue

        while IFS= read -r filename; do
            [ -z "$filename" ] && continue

            local_path="${DEST_DIR}/${filename}"

            if [ -f "$local_path" ]; then
                log "Already on NAS, skipping: ${filename}"
                skipped=$((skipped + 1))
                if [ "$DELETE_AFTER" = "true" ]; then
                    if delete_from_camera "$channel" "$filename"; then
                        log "Deleted already-synced file from camera: ${filename}"
                        deleted=$((deleted + 1))
                    else
                        errors=$((errors + 1))
                    fi
                fi
                continue
            fi

            if [ "$DRY_RUN" = "true" ]; then
                log "[DRY RUN] Would download: ${channel}/${filename}"
                downloaded=$((downloaded + 1))
                continue
            fi

            log "Downloading: ${channel}/${filename}"
            tmp_path="${local_path}.tmp"

            curl_error=$(curl -f \
                    --max-time 300 \
                    --retry 2 \
                    --retry-delay 3 \
                    "http://${CAM_IP}/${channel}/${filename}" \
                    -o "$tmp_path" 2>&1) || true
            curl_exit=$?

            if [ $curl_exit -eq 0 ]; then
                if [ -s "$tmp_path" ]; then
                    mv "$tmp_path" "$local_path"
                    file_size=$(du -sh "$local_path" | cut -f1)
                    log "Saved: ${filename} (${file_size})"
                    downloaded=$((downloaded + 1))

                    if [ "$DELETE_AFTER" = "true" ]; then
                        if delete_from_camera "$channel" "$filename"; then
                            log "Deleted from camera: ${filename}"
                            deleted=$((deleted + 1))
                        else
                            errors=$((errors + 1))
                        fi
                    fi
                else
                    rm -f "$tmp_path"
                    log "ERROR: Zero-byte file for ${filename}"
                    errors=$((errors + 1))
                fi
            else
                rm -f "$tmp_path"
                log "ERROR: Download failed for ${filename} — ${curl_error}"
                errors=$((errors + 1))
            fi

        done <<< "$file_list"
    done

    # ── Determine status ───────────────────────────────────────────────────
    local status
    if [ "$errors" -gt 0 ] && [ "$downloaded" -eq 0 ]; then
        status="error"
    elif [ "$errors" -gt 0 ]; then
        status="partial"
    elif [ "$downloaded" -eq 0 ]; then
        status="none"
    else
        status="ok"
    fi

    cat > "$STATUS_FILE" <<EOF
{
  "status": "${status}",
  "downloaded": ${downloaded},
  "deleted": ${deleted},
  "skipped": ${skipped},
  "errors": ${errors},
  "trigger": "${trigger_source}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    log "Sync complete — downloaded: ${downloaded}, deleted: ${deleted}, skipped: ${skipped}, errors: ${errors}"
    fire_ha_event "viofo_sync_complete" "$(cat "$STATUS_FILE")"

    # ── Notifications ──────────────────────────────────────────────────────
    if [ "$status" = "ok" ] && [ "$downloaded" -gt 0 ]; then
        local msg="Downloaded ${downloaded} protected clip(s) to NAS."
        [ "$deleted" -gt 0 ] && msg="${msg} Cleared ${deleted} from camera."
        [ "$CONFIG_BACKED_UP" = "true" ] && msg="${msg} Camera config backup saved."
        ha_notify "✅ Dashcam Sync Complete — ${trigger_desc}" "$msg"
    elif [ "$status" = "none" ] && [ "$CONFIG_BACKED_UP" = "true" ] && [ "$UI_NOTIFY_CONFIG_CHANGE" = "true" ]; then
        ha_notify "📷 Dashcam Config Changed — ${trigger_desc}" \
            "No new clips found, but camera config backup was saved." \
            "viofo_config"
    elif [ "$status" = "partial" ]; then
        local msg="Downloaded ${downloaded} clip(s) but encountered ${errors} error(s). Check add-on logs."
        [ "$CONFIG_BACKED_UP" = "true" ] && msg="${msg} Camera config backup saved."
        ha_notify "⚠️ Dashcam Sync Partial — ${trigger_desc}" "$msg" "viofo_sync_warning"
    elif [ "$status" = "error" ]; then
        ha_notify "❌ Dashcam Sync Failed — ${trigger_desc}" \
            "Sync encountered ${errors} error(s) with no successful downloads. Check add-on logs." \
            "viofo_sync_error"
    fi
}

# ─── MQTT listener ───────────────────────────────────────────────────────────
start_mqtt_listener() {
    log "Starting MQTT listener on topic: viofo/sync/trigger"
    (
        mosquitto_sub \
            -h core-mosquitto \
            -t "viofo/sync/trigger" \
            ${MQTT_USER:+-u "$MQTT_USER"} \
            ${MQTT_PASS:+-P "$MQTT_PASS"} | \
        while IFS= read -r payload; do
            printf '%s' "$payload" > "$MQTT_TRIGGER_FILE"
        done
    ) &
    MQTT_PID=$!
    log "MQTT listener started (PID: ${MQTT_PID})"
}

# ─── Main loop ───────────────────────────────────────────────────────────────
INTERVAL_SECONDS=$((INTERVAL * 60))

# Run once at startup (if enabled)
if [ "$SYNC_ON_STARTUP" = "true" ]; then
    run_sync "startup"
else
    log "Skipping startup sync (sync_on_startup is disabled)"
fi
last_run=$(date +%s)

# Start MQTT listener
start_mqtt_listener

log "Entering main loop. Interval: $([ "$INTERVAL" = "0" ] && echo 'disabled (manual/arrival trigger only)' || echo "${INTERVAL} minutes")"

while true; do
    now=$(date +%s)

    # Check for MQTT trigger
    if [ -f "$MQTT_TRIGGER_FILE" ]; then
        mqtt_payload=$(cat "$MQTT_TRIGGER_FILE" 2>/dev/null || echo "")
        rm -f "$MQTT_TRIGGER_FILE"
        if [ "$mqtt_payload" = "arrival" ]; then
            log "MQTT trigger received (payload: arrival)"
            run_sync "arrival"
        else
            log "MQTT trigger received (payload: ${mqtt_payload:-<none>})"
            run_sync "manual"
        fi
        last_run=$(date +%s)

    # Scheduled interval (if enabled)
    elif [ "$INTERVAL" != "0" ] && [ $((now - last_run)) -ge "$INTERVAL_SECONDS" ]; then
        run_sync "scheduled"
        last_run=$(date +%s)
    fi

    # Restart MQTT listener if it died
    if ! kill -0 "$MQTT_PID" 2>/dev/null; then
        log "WARNING: MQTT listener died, restarting"
        start_mqtt_listener
    fi

    sleep 10
done