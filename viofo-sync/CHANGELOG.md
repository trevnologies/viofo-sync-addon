# Changelog

### 1.8.10

- Added `skip_startup_sync_when_away` config option (default: `true`) — before a startup sync, the add-on now checks the `presence_entity` (default `person.your_name`) via the HA Core API. If it isn't `home`, the startup sync is skipped instead of timing out against a camera that most likely left home too, which was previously firing a spurious "Dashcam Offline — Startup" notification on every reboot while away
- Added `presence_entity` config option (default: `person.your_name`) to control which entity is checked
- If the presence state can't be read (no Supervisor token, entity missing, API error), the add-on fails open and runs the startup sync as before — no new failure mode for setups that don't configure a presence entity

### 1.8.9

- Removed `,complain` from the AppArmor profile — now enforcing rather than just logging
- Added a "Detected N file(s) to sync" log line before downloads start, so it can be compared directly against the downloaded/skipped/errors counts in the final "Sync complete" line
- Sync notifications now show what triggered them — Startup, Arrival, Manual, or Scheduled — in the title
- Added `script.dashcam_trigger_sync` (see `ha_scripts_reference.yaml`) as the single place that publishes sync triggers, so arrival and manual triggers can't be mislabeled by a caller getting the MQTT payload wrong
- Arrival automation and docs updated to call the shared script instead of publishing MQTT directly

### 1.8.8
- Migrated `map` config to the current `type`/`read_only` format — replaces the legacy `share:rw` shorthand with `type: share` / `read_only: false`
- Removed unused `auth_api` and `hassio_api`/`hassio_role: manager` grants — the add-on only ever calls the Home Assistant Core API proxy (fire events, `persistent_notification.create`), so these were unnecessary privilege
- Re-enabled AppArmor (`apparmor: true`), reversing a previous `apparmor: false` override
- Added a custom `apparmor.txt` profile scoped to the add-on's actual file and network access
- Add-on security rating raised from 4 to 6

## 1.8.7
- Added `sync_on_startup` config option (default: true) to control
  whether a sync runs automatically when the add-on starts. Disable
  this if you only want syncs triggered by arrival or MQTT.
- Added `ui_notifications` config option (default: true) to control
  whether sync result notifications (success, partial, error, offline)
  appear as persistent notifications in the HA UI notification center.
- Added `ui_notify_config_change` config option (default: true) to
  independently control whether camera config backup change events
  create a persistent notification in the HA UI.
- Push notifications via HA automations are unaffected by any of
  the above settings.

## 1.8.6
### Fixed
- Add-on no longer crashes silently when the camera's RO folder is empty —
  `grep` returning exit code 1 on zero matches was triggering `set -e` and
  killing the process immediately after the channel scan log line
- Syncs now complete cleanly with a "no new files" result when nothing is
  found on camera

## 1.8.5
### Fixed
- Removed size-based file verification which was causing false mismatches
  and incorrectly deleting NAS files — filename match alone is sufficient
### Changed
- Already-synced files are now identified by filename only, then deleted
  from camera if delete_after_download is enabled

## 1.8.4
### Fixed
- File listing parser now correctly finds all files on camera — previous
  subshell approach silently produced empty output due to pipefail
- Size comparison uses decimal MB (1,000,000 bytes) matching camera reporting
- Widened size match tolerance to 5% for robustness

## 1.8.3
### Fixed
- Camera delete now uses HTTP status code check instead of response body,
  fixing false failure warnings when `?del=1` returns an empty response
- Added debug logging to diagnose file listing parse issues

## 1.8.2
### Fixed
- Camera files now correctly deleted using native `?del=1` endpoint
- Files already on NAS are verified by size and deleted from camera if matched

## 1.8.1
### Fixed
- MQTT password field now masked in HA configuration UI

## 1.8.0
### Added
- MQTT trigger support via Mosquitto — cleaner than polling, instant response
- Camera config (`viofo_config.ini`) backed up to NAS on change with timestamp
- Startup sync runs automatically every time the add-on starts
- Scheduled interval now optional — set to `0` to disable
- Supervisor token loaded from s6 environment for HA event/notification support

### Changed
- Trigger mechanism moved from `input_button` polling to MQTT publish
- Notifications now include config backup status when applicable

## 1.7.x
### Added
- Initial working release
- Protected clip download from `DCIM/Movie/RO`
- Delete from camera after verified NAS save
- HA event firing (`viofo_sync_started`, `viofo_sync_complete`)
- Dry run mode
- Pacific time log timestamps
