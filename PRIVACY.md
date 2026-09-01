# Privacy

Focusdoro is a local macOS menu-bar timer. It has no backend and does not include analytics or advertising SDKs.

## Data Focusdoro uses

### Todoist

When connected, Focusdoro sends Todoist API v1 requests over HTTPS to fetch tasks, projects, and sections; create or complete tasks when requested; close completed tasks when enabled; and post measured focus-time comments. Your personal Todoist API token is validated then stored only in macOS Keychain. It is not written to preferences, local history, logs, or exported history.

### Local storage

Focusdoro stores non-secret preferences and any in-flight timer deadline in `UserDefaults`. It stores focus-session history locally in Core Data/SQLite at:

```text
~/Library/Application Support/Focusdoro/Focusdoro.sqlite
```

History includes Todoist task and project snapshots, session times, durations, completion state, and Todoist comment status. This supports history, streaks, and retries without another network round trip. Local storage is plaintext to software running as your macOS user and may be included in system backups.

Disconnecting Todoist removes its Keychain token and task cache but keeps local history. To reset Focusdoro local state, quit Focusdoro, remove its `~/Library/Application Support/Focusdoro` directory, then run `defaults delete so.bon.focusdoro` to remove only Focusdoro preferences and any in-flight timer state. This command does not remove other apps' defaults. Remove the Todoist Keychain entry separately in Keychain Access. Removing a token alone does not remove history.

### Notifications and macOS Focus

Focusdoro requests notification permission only when notifications are enabled. Completion notifications hide task names by default. Enabling **Show task names in notifications** can expose task titles on lock screens, Notification Center, screen shares, and any notification surfaces configured by macOS.

Optional macOS Focus integration runs Shortcuts selected by you through `/usr/bin/shortcuts`. Focusdoro does not inspect or control actions inside those shortcuts.

### Update checks

Focusdoro checks public GitHub release metadata at launch and periodically while running. This sends a request to GitHub and may reveal normal network metadata such as IP address and user agent to GitHub and your network provider. Automatic installation is off by default. If you enable it, that setting persists until you disable it.

## No Slack integration

Focusdoro does not connect to Slack, store Slack tokens, or send task data to Slack. A one-time migration may remove a legacy Slack Keychain entry left by older Focusdoro versions; it never reads or sends its value.

## Control choices

Use Settings to manage notification permission, task-name display, update installation, Todoist connection, Focus shortcuts, and local preferences. To remove all local data, follow full reset steps above: quit Focusdoro, remove its Application Support data, run `defaults delete so.bon.focusdoro` to remove its UserDefaults state, and remove any Keychain entry through Keychain Access.
