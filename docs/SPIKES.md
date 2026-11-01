# Spikes and verify tags

Every platform claim marked (verify) in docs/SPEC.md is answered here with evidence. `make spike` on the Mac prints rows to paste.

| ID | Claim | Spec | Result | Evidence | Date |
|---|---|---|---|---|---|
| S1 | An ad-hoc signed, sandboxed app with the home-relative exception can read and write the store while the CLI writes too | 8.7 | pass | macOS 27.2, Swift 6.4.2: sandboxed app and CLI both wrote (app=50, cli=50), journal=wal, sandbox-env=yes | 2026-11-01 |
| S2 | `SMAppService.mainApp` and `.agent` register from `~/Applications` on a managed Mac | 8.7 | pass | mainApp=enabled, agent=enabled | 2026-11-01 |
| S3 | Notifications, including text-input actions, work for the ad-hoc app | 8.7 | fail, decided | The ad-hoc spike app never appeared in Notifications settings, so no notification showed. Decision (Ashwin): the baseline is a plain notification whose click opens the capture bar; the inline text-input reply is an upgrade, verified later in the real signed app under T3.11 | 2026-11-01 |
| S4 | Idle time and workspace notifications work in the sandbox | 8.7 | pass | Hands-off sample: idle for any input rose from 8.06 s to 11.21 s over 3 s inside the sandbox, subscribed=8. Manual watch run: com.apple.screenIsLocked, com.apple.screenIsUnlocked, NSWorkspaceWillSleepNotification, NSWorkspaceScreensDidSleepNotification, NSWorkspaceScreensDidWakeNotification and NSWorkspaceDidWakeNotification all arrive | 2026-11-01 |
| S5 | `RegisterEventHotKey` works in the sandbox | 8.7 | pass | RegisterEventHotKey registered Ctrl+Opt+K inside the sandbox and the press was delivered | 2026-11-01 |
| S6 | A Darwin notification posted by the CLI reaches the sandboxed app | 8.7 | pass | A Darwin notification posted by an unsandboxed process reached the sandboxed listener (CFNotificationCenter Darwin center) | 2026-11-01 |
| S7 | Apple Intelligence is enabled on the work Mac | 8.7 | skipped, decided | unavailable: modelNotReady. Decision (Ashwin): Apple Intelligence will not run on this Mac. The deterministic parser is the only capture path; Foundation Models stays out of scope, as PLAN.md already says | 2026-11-01 |
| S8 | The app builds with Command Line Tools only (`swift build` plus the bundle script) | 8.7 | pass | swift build -c release --product CadenceApp with DEVELOPER_DIR=/Library/Developer/CommandLineTools. #Preview needs Xcode macros, so previews stay out of the CLT build | 2026-11-01 |
| S9 | Claude Code transcript lines carry `message.usage` and `model` as expected | 8.7 | pass | files=20, assistant_lines=2737, usage=89%, model=89% | 2026-11-01 |

## Other verify tags

| ID | Claim | Spec | Result | Evidence | Date |
|---|---|---|---|---|---|
| V1 | TaskCompleted field names are not yet confirmed; the hook stores whatever allowlisted fields arrive | 9.3 | open | - | - |
| V2 | Whether contribution lists include private and internal repositories on your Enterprise version needs a check | 10.3 | open | - | - |
| V3 | Lines are deduped by `message.id`, keeping the one with the most output tokens | 10.4 | open | - | - |
| V4 | Accessibility, Input Monitoring: No. Hotkeys and idle time need neither | 13 | open | - | - |
| V5 | Detecting a screen share automatically is later work | 13.1 | open | - | - |
| V0 | `.macOS(.v26)` is the case name in the Swift 6.2 PackageDescription | 14.2 | pass | swift build with swift-6.2.4-RELEASE on Linux resolves Package.swift with platforms: [.macOS(.v26)] | 2026-10-30 |
| V6 | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` reports idle time for any input | 8.4 | pass, use any input | The presence adapter queries `CGEventType(rawValue: ~0)` (kCGAnyInputEventType), which S4 proved rises with no input. `.null` is kCGEventNull and is not an idle measure (it read about 83 minutes while the user was typing) | 2026-11-01 |
