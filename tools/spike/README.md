# Platform spikes (S1 to S9)

Checks for the platform claims in spec 8.7. Run on your Mac with Command Line Tools only. No admin, no network.

    make spike              # or: bash tools/spike/run.sh
    bash tools/spike/s5.sh  # one check on its own

Each check prints exactly one line `S<n> PASS|FAIL|MANUAL|SKIP <summary>`, plus numbered steps for MANUAL.
`run.sh` ends with a "Paste into docs/SPIKES.md" table (date, macOS, Swift). Replace MANUAL with PASS or FAIL
after you follow the steps. The script always exits 0; read the lines.

Environment: `BUNDLE_PREFIX` (default `in.ashwingopalsamy.cadence.spike`), `CLAUDE_PROJECTS_DIR` (S9),
`SPIKE_NO_WAIT=1` (S3 and S5 print MANUAL without waiting for you).

What it touches: a `mktemp -d` directory, `~/Applications/CadenceSpikeS1.app` and `CadenceSpikeS2.app`,
and `~/Library/Application Support/CadenceSpike/<check>-<pid>/` (the folder the sandbox exception allows).
An exit trap unregisters login items and agents and deletes all of it, also after a failure or Ctrl-C.
S8 builds in the repo's normal `.build` and needs dependencies already cached (run `make build` once first).

| Check | What it does | Needs you | PASS means | If FAIL (fallback, spec 8.7) |
|---|---|---|---|---|
| S1 | Sandboxed ad-hoc app and `/usr/bin/sqlite3` both write 50 rows into one WAL database | no | Both row sets present, app reported ok | Ship unsandboxed with the hardened runtime; keep entitlement and symbol checks in `make check` |
| S2 | Registers `SMAppService.mainApp` and `.agent` from `~/Applications`, then unregisters | maybe | Both `enabled` | Both `enabled` or `requiresApproval` gives MANUAL (toggle in System Settings > Login Items). Otherwise a user LaunchAgent plist in `~/Library/LaunchAgents`, written by `make install` |
| S3 | Posts a notification with a text-input action; waits 60 s for your reply | yes | Typed text reached the app | Plain actions plus the capture bar |
| S4 | Two idle samples 3 s apart in the sandbox; subscribes to sleep, wake, lock, session events | 5 s hands off | Idle rose by about 3 s. Lock/unlock via `bash tools/spike/s4.sh watch` | Move sampling into the agent |
| S5 | `RegisterEventHotKey` for Control+Option+K in the sandbox | yes, 20 s | Registered and press delivered | Option-click the dot; Shortcuts app binding |
| S6 | Unsandboxed `notify_post` reaches a sandboxed `notify_register_dispatch` listener within 5 s | no | Listener logged receipt | Poll `PRAGMA data_version` every 2 s while visible, 30 s otherwise |
| S7 | Compiles a `FoundationModels` probe and reads `SystemLanguageModel.default.availability` | no | `.available` | Deterministic parser only; nothing else changes |
| S8 | Reports `xcode-select -p`, builds `CadenceApp` in release with the Command Line Tools toolchain, notes whether `#Preview` compiles | no | Build succeeded with CLT | Install Xcode into `~/Applications` |
| S9 | Scans the 20 newest Claude Code transcripts for structure only (never content) | no | Assistant lines carry `message.usage` and `message.model` | Tokens from the endpoint and import only |

Notes:

- S4 samples both `.null` (what spec 8.4 writes) and `CGEventType(rawValue: ~0)` (any input). If only the second rises,
  update the spec and the presence adapter to use it.
- S9 also reports whether one `message.id` appears on several lines with different `output_tokens`, which is the evidence
  for "dedupe keeping the line with the most output tokens". It prints counts and model ids only.
- Off macOS every check prints `SKIP not macOS`, except S9, which runs wherever the transcripts directory exists.
- Spike sources are in `src/`, one file each, compiled with `xcrun swiftc -swift-version 5`. Bundles are assembled by
  `lib.sh` and signed ad-hoc with `--options runtime`, as in spec 14.3.
