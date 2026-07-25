# VIOFO Sync — Home Assistant Add-on

A Home Assistant add-on that automatically syncs your VIOFO A329S dashcam — downloading protected (locked) clips to your NAS, deleting them from the camera after a verified save, and backing up your camera config whenever settings change.

[![Add to Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https://github.com/trevnologies/viofo-sync-addon)

Or add manually: **Settings → Apps → Add-on Store → ⋮ → Repositories** and paste:
`https://github.com/trevnologies/viofo-sync-addon`

---

## Features

- Downloads only protected/locked clips from `DCIM/Movie/RO` on the camera
- Verifies file integrity before deleting from camera after download
- Backs up `viofo_config.ini` to NAS with timestamp whenever settings change
- Fires HA events (`viofo_sync_started`, `viofo_sync_complete`, `viofo_config_changed`) for automations
- Triggered via MQTT — works cleanly with HA arrival automations
- Optionally runs at startup and/or on a schedule, in addition to MQTT trigger
- Configurable UI notifications — control what appears in the HA notification center
- Dry run mode for safe testing
- All config via the HA UI

---

## Installation

### 1. Add the Repository

Click the button above, or go to **Settings → Apps → Add-on Store → ⋮ → Repositories** and paste:

```
https://github.com/trevnologies/viofo-sync-addon
```

### 2. Install

Search for **VIOFO Sync** in the store and install it.

### 3. Configure

Go to the add-on's **Configuration** tab and set at minimum:

- `cam_ip` — your dashcam's local IP (set a DHCP reservation so this never changes)
- `dest_subdir` — the name of your HA network storage share

### 4. Prepare the NAS

The add-on writes to two locations inside your configured share:

```
Dashcam/              ← downloaded protected video clips
Dashcam/config/       ← timestamped viofo_config.ini backups
```

Create the `Dashcam` folder on your NAS before first run.

### 5. Test with Dry Run

Start the add-on with `dry_run: true`. Check the **Log** tab to confirm it finds your clips and reaches the camera. Once satisfied, set `dry_run: false` and restart.

---

## Home Assistant Automations

Import-ready automation examples are in [`ha_automations_reference.yaml`](ha_automations_reference.yaml). The arrival automation depends on the shared trigger script in [`ha_scripts_reference.yaml`](ha_scripts_reference.yaml) — create that first. Replace the placeholder entity names and notification service with your own before importing.

### Sync on arrival

Triggers when you leave home and then enter a dedicated dashcam sync zone (e.g. your driveway). Quick trips that never leave your home zone don't trigger a sync. The 5-minute delay gives the dashcam time to connect to Wi-Fi.

```yaml
alias: "Dashcam: Sync on arrival"
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
  - action: script.dashcam_trigger_sync
    data:
      source: arrival
mode: restart
```

---

## How It Works

```
VIOFO dashcam (on home Wi-Fi)
        │  HTTP file download + config fetch
        ▼
HA Add-on container
        │  writes protected clips + config backups
        ▼
NAS — Backups/Dashcam/
        ├── clip.MP4
        └── config/viofo_config_YYYY-MM-DD_HHMMSS.ini

HA Automation (leave home → enter dashcam zone + 5 min delay)
        │  script.dashcam_trigger_sync (source: arrival)
        │  └─ mqtt.publish → viofo/sync/trigger
        ▼
Add-on MQTT listener
        │  fires run_sync
        ▼
Add-on fires viofo_sync_complete HA event
        │
        ▼
HA Automation → mobile notification
```

---

## HA Events Fired

| Event | When | Payload fields |
|-------|------|----------------|
| `viofo_sync_started` | Sync begins | `trigger` |
| `viofo_sync_complete` | Sync finishes | `status`, `downloaded`, `deleted`, `skipped`, `errors`, `trigger`, `timestamp` |
| `viofo_config_changed` | Camera settings changed | `file`, `timestamp` |

`status` values: `ok`, `partial`, `error`, `none`, `offline`

---

## Trigger Methods

| Method | How |
|--------|-----|
| Startup | Automatic on add-on start if `sync_on_startup` is enabled |
| Scheduled | Set `schedule_interval_minutes` > `0` |
| Arrival | HA automation calls `script.dashcam_trigger_sync` with `source: arrival` after leaving home and entering the dashcam zone — labeled "Arrival" in notifications and logs |
| Manual | Call `script.dashcam_trigger_sync` (source defaults to `manual`), or publish anything other than `arrival` directly to `viofo/sync/trigger` — labeled "Manual" |

---

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) for the version history.