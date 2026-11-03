# Privacy

Cadence keeps counts, timestamps and titles that you can see and edit. It never reads content, keystrokes, app names or prompts. The app runs in the App Sandbox with no network entitlement, so the operating system stops it from reaching out. (docs/SPEC.md section 13)

This page converts docs/SPEC.md section 13, with details from sections 4.7, 4.8, 6.7, 7.1, 7.4, 8.3, 10.2, 11.2 and 13.1. If the two disagree, the spec wins. The threats and their mitigations are in SECURITY.md.

## Never collected (docs/SPEC.md section 13)

- Keystrokes, key counts and mouse movement. Presence uses idle seconds only.
- App names, window titles, URLs, browser history and screenshots.
- Message or email content from any tool. Slack and Outlook are out of v1. If they arrive later, they bring counts only.
- Prompts, AI responses, code, diffs and PR bodies. A PR body is read for an AI marker and then dropped.
- Other people's names or logins.

Also, prompts, responses, code and file names are never stored, and working folders become project aliases (docs/SPEC.md section 11.2). Presence spans hold timestamps only, never app names or window titles (docs/SPEC.md section 7.1).

## Permissions the app asks for (docs/SPEC.md section 13)

| Permission | Asked for |
|---|---|
| Notifications | Yes, on the first wrap-up reminder |
| Login item and background agent | Yes, listed in System Settings, General, Login Items |
| Accessibility, Input Monitoring | No. Hotkeys and idle time need neither. Not yet verified on a Mac (docs/SPIKES.md) |
| Full Disk Access | No |
| Calendars, Contacts | No |
| Network | None for the app. The CLI has no network code |
| Admin password | Never |

## No network, and how macOS enforces it (docs/SPEC.md sections 8.3, 13.1 and 14.6)

- The app runs in the App Sandbox with no network keys. `com.apple.security.network.client` and `com.apple.security.network.server` are deliberately absent, so any connection attempt fails at the operating system level.
- `make check` fails if a network key ever appears. The check is `tools/check_entitlements.sh`.
- The `cadence` binary has no networking code. `make check` inspects the imported symbols of both binaries for URLSession, Network.framework and socket calls.
- The CLI and the collector agent are signed with the hardened runtime and no entitlements.
- Network traffic comes only from collector commands you approved, which run tools such as `gh` or `curl`. The agent reads their JSON from stdout. A collector you approve can send anything you let it.
- Telemetry: none. There are no analytics, no update checks and no crash upload. Crashes stay in the local DiagnosticReports folder.

The app's entitlements (docs/SPEC.md section 8.3):

```
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array><string>/Library/Application Support/Cadence/</string></array>
<!-- deliberately absent:
     com.apple.security.network.client
     com.apple.security.network.server -->
```

## Discreet mode (docs/SPEC.md sections 4.8, 6.7 and 13.1)

- Discreet mode is set with `⌃⌥D`.
- Titles become "Task 1" and "Item 1". Ticket keys and Tempo are hidden, and the menu-bar mark shows the ring only. It is meant for screen sharing.
- The panel and the window replace titles while discreet mode is on.
- Detecting a screen share automatically is later work. It is not yet built.
- The risk that remains: a shared window while discreet mode is off.

## Notifications show counts, not titles (docs/SPEC.md sections 4.7 and 13.1)

- Notification text shows counts, never titles, by default, so a screen share does not show work detail.
- "Show task titles in notifications" is an opt-in.

## Logs (docs/SPEC.md sections 7.4, 10.2 and 18)

The app's own system log records timings and error codes only, never titles, notes or any entry text. Collector output to stderr is kept separately in `logs/` and can include host names.

- Collector and agent logs live in `logs/`, which is rotated at 1 MB.
- For each collector run, the last 64 KB of stderr goes to `logs/`.
- A failed collector run writes an `ingest.run` record with the error.
- Entry titles are never logged at info level.

## Exports (docs/SPEC.md sections 12.2 and 13.1)

- Exports happen only when you ask.
- A proof file holds private notes and items marked private as hashes only. Its own text explains what it does and does not prove. See PROOF-FORMAT.md.

## Data at rest (docs/SPEC.md sections 7.4 and 13.1)

- The store lives in `~/Library/Application Support/Cadence/`, outside iCloud Drive and outside any app container. The folder is mode 0700, and its files are mode 0600.
- FileVault provides encryption at rest. Cadence adds no crypto dependency of its own.
- `cadence doctor` reports whether FileVault is on.
