# Spikes and verify tags

Every platform claim marked (verify) in docs/SPEC.md is answered here with evidence. `make spike` on the Mac prints rows to paste.

| ID | Claim | Spec | Result | Evidence | Date |
|---|---|---|---|---|---|
| S1 | An ad-hoc signed, sandboxed app with the home-relative exception can read and write the store while the CLI writes too | 8.7 | open | - | - |
| S2 | `SMAppService.mainApp` and `.agent` register from `~/Applications` on a managed Mac | 8.7 | open | - | - |
| S3 | Notifications, including text-input actions, work for the ad-hoc app | 8.7 | open | - | - |
| S4 | Idle time and workspace notifications work in the sandbox | 8.7 | open | - | - |
| S5 | `RegisterEventHotKey` works in the sandbox | 8.7 | open | - | - |
| S6 | A Darwin notification posted by the CLI reaches the sandboxed app | 8.7 | open | - | - |
| S7 | Apple Intelligence is enabled on the work Mac | 8.7 | open | - | - |
| S8 | The app builds with Command Line Tools only (`swift build` plus the bundle script) | 8.7 | open | - | - |
| S9 | Claude Code transcript lines carry `message.usage` and `model` as expected | 8.7 | open | - | - |

## Other verify tags

| ID | Claim | Spec | Result | Evidence | Date |
|---|---|---|---|---|---|
| V1 | TaskCompleted field names are not yet confirmed; the hook stores whatever allowlisted fields arrive | 9.3 | open | - | - |
| V2 | Whether contribution lists include private and internal repositories on your Enterprise version needs a check | 10.3 | open | - | - |
| V3 | Lines are deduped by `message.id`, keeping the one with the most output tokens | 10.4 | open | - | - |
| V4 | Accessibility, Input Monitoring: No. Hotkeys and idle time need neither | 13 | open | - | - |
| V5 | Detecting a screen share automatically is later work | 13.1 | open | - | - |
| V0 | `.macOS(.v26)` is the case name in the Swift 6.2 PackageDescription | 14.2 | pass | swift build with swift-6.2.4-RELEASE on Linux resolves Package.swift with platforms: [.macOS(.v26)] | 2026-10-30 |
| V6 | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` reports idle time for any input | 8.4 | open | Planner note: CoreGraphics documents `kCGAnyInputEventType` (`CGEventType(rawValue: ~0)`) as "any input"; `.null` is `kCGEventNull`. Spike S4 samples both and records which one rises. The presence adapter uses whichever S4 proves. | - |
