# Security

This page covers how to report a security problem, what the app may and may not do, and Cadence's threat model. It converts docs/SPEC.md sections 8.3, 10.2, 13 and 13.1, and section 16 for reporting. If the two disagree, the spec wins.

## Reporting a problem

Report security problems privately by opening a private security advisory on the repository. (docs/SPEC.md section 16)

In scope: data leaving the Mac, chain integrity, and collector execution. (docs/SPEC.md section 16)

## What the app may do

- Run in the App Sandbox. Its entitlements allow read and write access to the files you select and to the Cadence folder under Application Support. (docs/SPEC.md section 8.3)
- Run as a login item and a background agent, which you can see in System Settings under General, Login Items. (docs/SPEC.md section 13)
- Read idle time for any input without Accessibility permission (docs/SPEC.md section 8.4). This is not yet verified on a Mac (docs/SPIKES.md).
- Register global hotkeys, which needs no Accessibility permission. (docs/SPEC.md section 4.8)
- Post notifications. (docs/SPEC.md section 4.7)
- Run a collector command, but only the exact command you approved. The first run of a command, and any run after it changes, shows the exact argv and environment keys and asks. The agent checks each run against the digest of what you approved. (docs/SPEC.md section 10.2)

## What the app may not do

- Open a network connection. The app has no network entitlement, so macOS blocks any attempt at the operating system level. The `cadence` binary has no networking code. (docs/SPEC.md sections 8.3 and 13.1)
- Read keystrokes, key counts, mouse movement, app names, window titles, URLs, browser history or screenshots. (docs/SPEC.md section 13)
- Read prompts, AI responses, code, diffs or PR bodies. A PR body is read in memory for an AI marker, and then dropped. (docs/SPEC.md section 13)
- Ask for an admin password, or for Full Disk Access, Calendars or Contacts. (docs/SPEC.md section 13)
- Run a collector command that changed since you approved it. The agent refuses anything other than what you approved. (docs/SPEC.md section 10.2)
- Let an MCP tool delete, seal, accept or change presence. Agents can log, but accepting, sealing, deleting and presence belong to you. (docs/SPEC.md sections 9 and 13.1)

## Collector commands (docs/SPEC.md sections 10.2, 10.3 and 10.5)

- A collector is an argv array, never a shell. The first element is an absolute path.
- The environment is fixed: `PATH`, `HOME`, `LANG`, `TZ`, and the keys listed in the collector's `env`. Nothing else is inherited.
- Each run has a 60 second limit, then SIGTERM, then SIGKILL after 5 seconds.
- `config.json` must be owned by you and have mode 0600. Otherwise collectors are disabled, and `cadence doctor` says why.
- Cadence never sees a token. The GitHub collector reuses the login that `gh` already has. The usage endpoint's token sits in a 0600 file that `curl` reads, so it never enters Cadence or its config.

## Threat model (docs/SPEC.md section 13.1)

| Threat | Mitigation | What remains |
|---|---|---|
| Work data leaves the Mac | App sandbox with no network entitlement. The `cadence` binary links no networking code, and `make check` inspects the binary's imported symbols for URLSession, Network.framework and socket calls. Collectors are commands you approved. Exports happen only when you ask | A collector you approve can send anything you let it |
| Employer names or hosts land in the public repo | Examples use ACME and example.com. `tools/guard.sh` reads a forbidden-terms list from `~/.config/cadence/forbidden.txt`, which is never committed, and fails with file and line without printing the term. It runs as a pre-commit hook, inside `make check`, and over the full history before publishing | Terms you forget to list |
| Your work log ends up in git | The store lives outside the repository. `.gitignore` covers `*.db`, `*.cadence-proof.json`, `maps/` and local config. The guard also rejects files whose content starts with `cadence.proof/1`, `envelope/1` or the SQLite header | Data pasted into an issue by hand |
| Collector command abuse | argv only, absolute path, fixed environment, approval by digest, and a config that must be yours with mode 0600 | Malware already running as you can edit anything you can |
| Prompt injection through PR titles or entries returned to agents | MCP results return entries as data fields, and tool descriptions state the content is user data. No MCP tool can delete, seal, accept or change presence. Agent writes are labelled agent and rate-limited to 60 a minute | An agent can still log misleading entries, labelled as agent |
| Screen sharing and lock screen | Notifications show counts, not titles, unless you turn titles on. Discreet mode (⌃⌥D) replaces titles in the panel and window. Detecting a screen share automatically is later work | A shared window while discreet mode is off |
| Lost or stolen laptop | FileVault for data at rest. Files are 0600 in a 0700 folder. `cadence doctor` reports whether FileVault is on | An unlocked, unattended Mac |
| A rewritten history | Hash chain, witnesses, edit counts after sealing, and the limits stated in the proof itself | A full rebuild before the first witness |
| Supply chain | Two Apple packages only, pinned in `Package.resolved`. When CI is added, its actions are pinned to commit SHAs. No binaries downloaded at build time. Sounds are generated by a script in the repository | Toolchain trust |
| Telemetry | None. No analytics, no update checks, no crash upload. Crashes stay in the local DiagnosticReports folder | None |

The proof file is tamper-evident, not tamper-proof. Its limits are stated in PROOF-FORMAT.md (docs/SPEC.md section 12.2).
