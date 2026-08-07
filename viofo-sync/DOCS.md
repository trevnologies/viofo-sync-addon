# VIOFO Sync

Downloads protected (locked) clips from your VIOFO dashcam to your NAS over Wi-Fi, deletes them from the camera after a verified save, and backs up your camera config whenever settings change.

---

## Configuration

| Option | Description | Default |
|--------|-------------|---------|
| `cam_ip` | Local IP of your dashcam. Set a DHCP reservation so this never changes. | `192.168.1.100` |
| `dest_subdir` | Name of your HA network storage share (case-sensitive). Clips are written to `Backups/<dest_subdir>/` on your NAS. | `Dashcam` |
| `schedule_interval_minutes` | How often to run a scheduled sync. Set to `0` to disable — rely on arrival trigger or manual MQTT only. | `0` |
| `delete_after_download` | Delete each file from the camera SD card after it is verified saved to the NAS. | `true` |
| `dry_run` | Log what would happen without downloading or deleting anything. Use this to verify your setup before going live. | `false` |
| `sync_on_startup` | Run a sync automatically each time the add-on starts. | `true` |
| `skip_startup_sync_when_away` | Before a startup sync, check `presence_entity` in HA. If it isn't `home`, skip the startup sync instead of trying (and failing) to reach a camera that most likely left with you. If the state can't be read, the startup sync runs anyway. | `true` |
| `presence_entity` | The `person.*` entity checked by `skip_startup_sync_when_away`. | `person.trevor` |
| `ui_notifications` | Show sync results (success, partial, error, offline) as persistent notifications in the HA UI notification center. | `true` |
| `ui_notify_config_change` | Show a notification in the HA UI when a camera config backup is saved and no new clips were found. | `true` |
| `mqtt_user` | Mosquitto broker username. Leave blank for anonymous connections. | `` |
| `mqtt_pass` | Mosquitto broker password. Leave blank for anonymous connections. | `` |

---

## How to Trigger a Sync

| Method | How |
|--------|-----|
| Startup | Automatic on add-on start if `sync_on_startup` is enabled — skipped if `skip_startup_sync_when_away` is enabled and `presence_entity` isn't `home` |
| Scheduled | Set `schedule_interval_minutes` > `0` |
| Arrival | HA automation calls `script.dashcam_trigger_sync` with `source: arrival` after you leave home and enter your dashcam sync zone — labeled "Arrival" in notifications and logs |
| Manual | Call `script.dashcam_trigger_sync` (source defaults to `manual`), or publish anything other than `arrival` directly to `viofo/sync/trigger` — labeled "Manual" |

---

## HA Events

The add-on fires these events that your HA automations can listen to:

| Event | Fired when | Payload |
|-------|-----------|---------|
| `viofo_sync_started` | A sync begins | `trigger` |
| `viofo_sync_complete` | A sync finishes | `status`, `downloaded`, `deleted`, `skipped`, `errors`, `trigger`, `timestamp` |
| `viofo_config_changed` | Camera settings backup is saved | `file`, `timestamp` |

`status` values: `ok`, `partial`, `error`, `none`, `offline`

---

## MQTT

The add-on subscribes to `viofo/sync/trigger` on the local Mosquitto broker (`core-mosquitto`). The payload determines how the sync is labeled in notifications, logs, and events: `arrival` is labeled "Arrival," anything else is labeled "Manual." Rather than publishing directly, call the `script.dashcam_trigger_sync` helper (see `ha_scripts_reference.yaml`) so the payload is always set correctly. The listener is automatically restarted if it dies.

---

## NAS File Layout

```
Dashcam/
├── 2026_0419_214423_000054PF.MP4   ← protected clips
├── 2026_0420_060803_000091PF.MP4
└── config/
    └── viofo_config_2026-04-20_060803.ini   ← timestamped config backups
```

Config backups are only written when the camera settings have actually changed. The comparison reference persists across add-on restarts at `/data/viofo_config_last.ini`.

---

## Example Automations

See `ha_automations_reference.yaml` and `ha_scripts_reference.yaml` in the [GitHub repository](https://github.com/trevnologies/viofo-sync-addon) for ready-to-import examples covering the shared trigger script, arrival sync, sync result notifications, and config change notifications.