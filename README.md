# viofo-sync-addon

A Home Assistant add-on that automatically syncs your VIOFO A329S dashcam — downloading protected (locked) videos to your NAS, deleting them from the camera after verified save, and backing up your camera config whenever settings change.

## Features

- Downloads only protected/locked clips from `DCIM/Movie/RO` on the camera
- Verifies file integrity before deleting from camera after download
- Backs up `viofo_config.ini` to NAS with timestamp whenever settings change
- Fires HA events (`viofo_sync_started`, `viofo_sync_complete`, `viofo_config_changed`) for automations
- Triggered via MQTT — works cleanly with HA arrival automations
- Optionally runs at startup and/or on a schedule, in addition to MQTT trigger
- Dry run mode for safe testing
- All config via the HA UI

---

## Installation

### 1. Add the Repository to Home Assistant

**Settings → Apps → Add-on Store → ⋮ → Repositories**, paste:

```
https://github.com/trevnologies/viofo-sync-addon
```

### 2. Install the Add-on

Search for **VIOFO Sync** in the store and install it.

### 3. Configure the Add-on

Go to the add-on's **Configuration** tab:

| Option | Description | Default |
|--------|-------------|---------|
| `cam_ip` | Your dashcam's reserved DHCP IP | `192.168.1.100` |
| `dest_subdir` | NAS share name (case-sensitive) | `Dashcam` |
| `schedule_interval_minutes` | `0` to disable scheduled syncs, or set a number for periodic syncs | `0` |
| `delete_after_download` | Delete from camera after verified NAS save | `true` |
| `dry_run` | Log what would happen without doing anything | `false` |
| `sync_on_startup` | Run a sync automatically when the add-on starts | `true` |
| `ui_notifications` | Show sync result notifications in the HA UI notification center | `true` |
| `ui_notify_config_change` | Show a notification in the HA UI when a camera config backup is saved | `true` |
| `mqtt_user` | Mosquitto broker username (leave blank for anonymous) | `` |
| `mqtt_pass` | Mosquitto broker password (leave blank for anonymous) | `` |

### 4. Prepare the NAS

The add-on writes to two locations inside your configured share:

```
Dashcam/                          ← downloaded protected video clips
Dashcam/config/                   ← timestamped viofo_config.ini backups
```

### 5. First Run — Test with Dry Run

Start the add-on with `dry_run: true`. Check the **Log** tab to confirm it finds your protected clips and fetches the camera config. Once satisfied, set `dry_run: false` and restart.

---

## Home Assistant Automations

Automation examples are included in `ha_automations_reference.yaml` in this repo. Replace `notify.mobile_app_your_phone` with your actual notification service before importing.

### Sync on arrival

Triggers when you leave home and then enter the dashcam sync zone (e.g. your driveway), so quick trips that never leave the home zone don't trigger a sync. The 5-minute delay gives the dashcam time to connect to Wi-Fi.

```yaml
alias: "Dashcam: Sync on arrival"
description: "When you leave home, waits for him to enter the Dashcam_Sync zone, then triggers a sync via MQTT after a 5-minute delay"
trigger:
  - platform: zone
    entity_id: person.your_name
    zone: zone.home
    event: leave
action:
  - wait_for_trigger:
      - platform: zone
        entity_id: person.your_name
        zone: zone.dashcam_sync
        event: enter
    timeout:
      hours: 12
    continue_on_timeout: false
  - delay:
      minutes: 5
  - action: mqtt.publish
    data:
      topic: viofo/sync/trigger
      payload: run
mode: restart
```

### Notify on sync complete

```yaml
alias: "Dashcam: Notify on sync result"
trigger:
  - platform: event
    event_type: viofo_sync_complete
action:
  - choose:
      - conditions:
          - condition: template
            value_template: >
              {{ trigger.event.data.status == 'ok'
                 and trigger.event.data.downloaded | int > 0 }}
        sequence:
          - service: notify.mobile_app_your_phone
            data:
              title: "✅ Dashcam Sync"
              message: >
                Downloaded {{ trigger.event.data.downloaded }} protected
                clip(s) to NAS.
                {% if trigger.event.data.deleted | int > 0 %}
                Cleared {{ trigger.event.data.deleted }} from camera.
                {% endif %}
      - conditions:
          - condition: template
            value_template: "{{ trigger.event.data.status == 'offline' }}"
        sequence:
          - service: notify.mobile_app_your_phone
            data:
              title: "🔴 Dashcam Offline"
              message: >
                Camera wasn't reachable during
                {{ trigger.event.data.trigger }} sync.
      - conditions:
          - condition: template
            value_template: >
              {{ trigger.event.data.status in ['error', 'partial'] }}
        sequence:
          - service: notify.mobile_app_your_phone
            data:
              title: "⚠️ Dashcam Sync Issue"
              message: >
                {{ trigger.event.data.downloaded }} clip(s) downloaded,
                {{ trigger.event.data.errors }} error(s).
                Check the VIOFO Sync add-on logs.
mode: queued
max: 5
```

### Notify on config change

```yaml
alias: "Dashcam: Notify on config change"
trigger:
  - platform: event
    event_type: viofo_config_changed
action:
  - service: notify.mobile_app_your_phone
    data:
      title: "📷 Dashcam Config Changed"
      message: "Settings backup saved: {{ trigger.event.data.file }}"
mode: single
```

---

## How It Works

```
VIOFO A329S (on home WiFi)
        │  HTTP file download + config fetch
        ▼
HA Add-on container
        │  writes protected clips + config backups
        ▼
Synology NAS — Backups/Dashcam/
        ├── 2026_0419_214423_000054PF.MP4
        ├── 2026_0420_060803_000091PF.MP4
        └── config/
            └── viofo_config_2026-04-20_060803.ini

HA Automation (leave home → wait for dashcam zone entry + 5 min delay)
        │  mqtt.publish → viofo/sync/trigger
        ▼
Add-on MQTT listener (mosquitto_sub)
        │  fires run_sync
        ▼
Add-on fires viofo_sync_complete HA event
        │
        ▼
HA Automation → Mobile notification
```

---

## Trigger Methods

| Method | How |
|--------|-----|
| Startup | Optional — runs when the add-on starts if `sync_on_startup` is enabled |
| Scheduled | Set `schedule_interval_minutes` > `0` |
| Arrival | HA automation publishes to `viofo/sync/trigger` via MQTT after leaving home and entering the dashcam sync zone |
| Manual | Publish any message to MQTT topic `viofo/sync/trigger` |

---

## NAS File Layout

| Path | Contents |
|------|----------|
| `Dashcam/*.MP4` | Downloaded protected video clips |
| `Dashcam/config/viofo_config_YYYY-MM-DD_HHMMSS.ini` | Timestamped camera settings backups |

Config backups are only written when the settings have actually changed. A comparison reference is kept at `/data/viofo_config_last.ini` inside the add-on and persists across restarts.

---

## HA Events Fired

| Event | When | Payload fields |
|-------|------|----------------|
| `viofo_sync_started` | Sync begins | `trigger` |
| `viofo_sync_complete` | Sync finishes | `status`, `downloaded`, `deleted`, `skipped`, `errors`, `trigger`, `timestamp` |
| `viofo_config_changed` | Camera settings changed | `file`, `timestamp` |

`status` values: `ok`, `partial`, `error`, `none`, `offline`

---

## MQTT Topics

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `viofo/sync/trigger` | HA → Add-on | Trigger a sync run |

The add-on subscribes to `viofo/sync/trigger` on the local Mosquitto broker (`core-mosquitto`). Any message payload triggers a sync. If the MQTT listener dies it is automatically restarted.

---

## Camera HTTP API

The A329S serves files over HTTP at its local IP. Protected clips live at `DCIM/Movie/RO/`. Deletion uses the native RPC command: `/?custom=1&cmd=3019&str=/path/file.MP4` which returns `<Status>0</Status>` on success. Camera config is fetched from `Config/viofo_config.ini`.
