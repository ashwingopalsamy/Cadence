# Cadence implementation plan

This file becomes `docs/PLAN.md` in the repo. It is the single list of work that makes `docs/SPEC.md` real. A task is done only when its "Done when" is true and `make check` passes. The project is complete when every task below is ticked, every `verify` tag in the spec has a result in `docs/SPIKES.md`, and the final audit (T5.6) finds no gaps.

## Scope

**In:** everything in `docs/SPEC.md`.

**Out until decided otherwise:** the spec's "Later" list. That covers:

- Foundation Models smart capture and recap prose
- Slack and Outlook counts
- Review turnaround
- Shortcuts and App Intents
- Widgets
- Screen-share detection
- Proofs that start from a checkpoint
- Multiple profiles
- GitHub CI (deferred on 2026-10-30)

When CI comes back, it runs `make check` unchanged.

## Tiers

Every task has a tier. The tier is a floor, not a ceiling: on any doubt, move a task up a tier, never down.

| Tier | Does | Never does |
|---|---|---|
| **planner** | Breaks phases into briefs. Writes interfaces and test lists before a builder starts. Writes critical modules (marked ★) itself. Reviews every diff against the spec. Runs `make check` itself before ticking. | Accepts a pass it did not see. |
| **builder** | Implements one task from one brief, tests first, in the files the brief names. Reports the command output. | Changes the spec, the schema, canonical JSON, hashing, public interfaces, or files outside the brief. If the brief is wrong, it stops and reports. |
| **mechanic** | Does mechanical work from exact instructions: scaffolding, file moves, renames, fixtures from given data, Markdown conversion, string catalogs, license headers, wiring a Makefile target exactly as specified. | Makes decisions with branches in them. Anything ambiguous goes back up. |
| **auditor** | Reviews cold, with fresh context: the code and the spec section, never the planner's conclusion. Reviews every ★ diff and runs each phase audit. | Edits code. Its findings become tasks. |

★ **Critical modules.** The planner writes these, or reviews them line by line, and the auditor reviews them cold. There are 14:

- canonical JSON
- hashing
- schema and migrations
- ledger append
- projection rebuild
- witness codes
- proof export
- MCP protocol negotiation
- envelope ingest
- the collector runner
- map/1 decimal scaling
- app signing and entitlements
- the presence engine
- the findings engine

## Loop for each task

1. Pick the next unticked task whose prerequisites are ticked.
2. **planner or ★ task:** do it directly. **builder or mechanic task:** write a brief, then delegate. The brief covers:
   - goal
   - spec sections
   - files to touch
   - interfaces
   - tests to write
   - the exact command to run
   - "Done when"
   - out of scope
3. Read the diff against the brief and the spec. Run `make check` yourself.
4. If the task is ★, send the diff and its spec section to the auditor. Fix every confirmed finding.
5. Commit with the task ID in the subject (`T1.5: ledger append under BEGIN IMMEDIATE`). Tick the box here. Record any `verify` result in `SPIKES.md`.
6. **Escalation.**
   - A builder task that fails `make check` twice goes up to the planner.
   - A mechanic task that needs a judgement call goes up to the builder.
   - Independent builder tasks can run in parallel in separate worktrees.

## Gates (no CI for now)

| Gate | Runs | Where |
|---|---|---|
| `make check` | `swift build`, `swift test`, Python verifier vectors (valid passes, tampered fails), guard over the tree. On macOS it also runs `make app`, the entitlement and symbol check, and snapshots | Linux in the cloud for core work; your Mac for anything macOS |
| pre-commit | `tools/guard.sh --staged` and the fast core tests | every commit |
| pre-push | `make check` | every push |
| phase audit | auditor compares each spec section in the phase to code and tests, and lists gaps | end of every phase |

## Phase 0 · Bootstrap · v0.0

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T0.1 | Repo tree, `.gitignore` (db, proof, maps, local config, `.claude/settings.local.json`), Apache-2.0 LICENSE, NOTICE, CODE_OF_CONDUCT | mechanic | §14.1, §16 | Tree matches §14.1; `git status` clean |
| [x] T0.2 | `Package.swift` with Linux-safe targets and macOS-only targets behind `#if os(macOS)`; CSQLite module map; empty targets compile | builder | §14.2 | `swift build` passes on Linux and on the Mac |
| [x] T0.3 | Core interfaces: `Clock`, `FileRoots`, `ProcessRunner`, `Store`, `Hasher`, error types, the module boundaries | planner | §8.5, §18 | Protocols compile; the builder briefs below reference them |
| [x] T0.4 | Makefile: build, test, check, app, install, uninstall, run, demo, snapshots, spike, guard, sounds; macOS-only steps skip cleanly on Linux | builder | §14.4 | `make check` green on Linux |
| [x] T0.5 | `tools/guard.sh`: terms from `~/.config/cadence/forbidden.txt`; data-file signatures; secret patterns; `--staged`, `--all`, `--history`; prints file and line, never the term; installs git hooks | builder | §13.1 | Fixture tests pass, including one that proves the term is never printed |
| [x] T0.6 | `tools/verify_proof.py` (from the tested script), `tools/make_vectors.py`, `Tests/Vectors/proofs/{valid,tampered}.json` | mechanic | §12.3 | Valid passes, tampered fails, inside `make check` |
| [x] T0.7 | `docs/SPEC.md` from the blueprint (text only), `docs/SPIKES.md` listing S1 to S9 and every verify tag, `CLAUDE.md` from §18.1, README stub | mechanic | §18 | Every spec section is present; the planner diffs the headings |
| [x] T0.8 | `tools/spike/`: one small check per S1 to S9, printing PASS, FAIL or MANUAL with steps | builder | §8.7 | Runs on the Mac; results go into `SPIKES.md` |

## Phase 1 · Ledger, CLI, proof · v0.1

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T1.1 ★ | Canonical JSON writer (cadence-c14n/1) and `Tests/Vectors/c14n.json`: escapes, Unicode, key order, integers, nesting; rejects floats, non-ASCII keys and integers beyond 2^53 | planner | §7.3, §12.1 | Swift and Python produce identical bytes for every vector |
| [x] T1.2 ★ | SHA-256 behind `Hasher` (CryptoKit or swift-crypto); `data_digest` and event hash; chain vectors | planner | §7.3 | Chain vectors match the Python verifier |
| [x] T1.3 | SQLite wrapper: statements, transactions, WAL, `busy_timeout`, `user_version`, typed rows | builder | §7.3 | Tests on Linux and macOS |
| [x] T1.4 ★ | Schema v1 from the DDL, migration runner, append-only triggers, refusal to write a newer schema | planner | §7.3 | UPDATE and DELETE on events abort; tests cover the version gate |
| [x] T1.5 ★ | Ledger append: `BEGIN IMMEDIATE`, gapless `seq`, `prev`, `hash`, actor; multi-process stress test through the CLI binary | planner | §7.3, §8.2 | 4 processes × 500 appends give a valid chain with no gaps |
| [x] T1.6 | Domain types and enums (kinds, families, origin, status, day kinds); ULID from an injected clock and RNG | builder | §7.1 | Codable round-trip tests |
| [x] T1.7 | Event payload codecs for every type in §7.3 | builder | §7.3 | Golden payload tests |
| [x] T1.8 ★ | Projections: apply each event; `cadence rebuild` gives a byte-identical dump | planner | §7.3 | A property test over random operation sequences passes |
| [x] T1.9 | Time: profile zone, 04:00 boundary, the day of an instant, each day keeping its own zone | builder | §3, §7.1 | Boundary and travel tests |
| [x] T1.10 | Ticket classifier: named groups `key` and `num`, `titleWindow`, `selfInitiated`, generic default | builder | §4.3, §10.3 | Table tests, including all-zero numbers |
| [x] T1.11 | Capture parser: every token rule and the lexicon order, `work.done` included | builder | §4.3 | Table tests mirror every demo example |
| [x] T1.12 | `config/1`: load, validate, defaults, `cadence config get\|set\|path`, 0600 owner check | builder | §7.4 | Bad configs are rejected with clear errors |
| [x] T1.13 | CLI scaffold: `--json` everywhere, exit codes 0 to 4, `CADENCE_HOME` | builder | §9.5 | Exit-code tests |
| [x] T1.14 | Commands: `log`, `plan`, `day`, `today`, `inbox`, `query`, `summary`, `standup`, `rebuild`, `doctor` | builder | §9.5 | Each command has an integration test against a temp home |
| [x] T1.15 | Day mechanics: seal, grace window, after-seal marking, open tasks moving, streaks paused by leave and holidays | builder | §3, §4.5 | Scenario tests, October example included |
| [x] T1.16 ★ | Witness checkpoint event; the code is the first 16 hex characters of the head hash | planner | §4.5, §12.1 | The code appears in stand-up output and verifies |
| [x] T1.17 ★ | `cadence export proof`: chain from genesis, hash-only outside the range, export policies, summary with definitions, witnesses, `export_digest`, embedded verifier and `how_to_verify` | planner | §12 | The Python verifier passes the export; editing one byte fails it |
| [x] T1.18 | `cadence verify FILE [--recompute]` in Swift, matching Python on every vector | builder | §12.3 | Parity tests |
| [x] T1.19 | Backups: daily `VACUUM INTO`, keeping 14 daily and 8 weekly | builder | §7.4 | Retention tests with an injected clock |
| [x] T1.20 | Deterministic ACME demo seed matching the spec's October example data | mechanic | §5 | Seeded totals equal the numbers in the spec |
| [x] T1.21 | Phase 1 audit | auditor | §3, §7, §12 | No open gaps |
| [x] T1.22 | Phase 1 audit follow-ups: `doctor` reports FileVault on macOS (`fdesetup status`); a leave or holiday declared after its grace window is flagged on the day in proofs; plan tasks added after the seal carry an after-seal flag and leave `plan_done`; the demo seed copies a stand-up each workday so its proof carries witness codes | builder | §3, §12, §13.1 | Tests for each; FileVault on the Mac |

## Phase 2 · Agents and collectors · v0.2

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T2.1 ★ | MCP over stdio: JSON-RPC framing, `initialize` (2025-11-25), stateless 2026-07-28 with `server/discover` and `resultType`, error mapping | planner | §9.2 | Protocol tests for both revisions |
| [x] T2.2 | MCP tools: `log_entry`, `log_entries` (dry run), `plan_add`, `plan_update`, `declare_day`, `get_day`, `query`, `summary`, `standup`; origin agent; 60 per minute | builder | §9.2 | Schema and behaviour tests; there is no tool that deletes, seals, accepts or edits presence |
| [x] T2.3 | MCP resources and prompts, dictation import included | builder | §9.2 | Tests |
| [x] T2.4 | `cadence hook <event>`: allowlisted fields, one `O_APPEND` line to `spool/`, never opens SQLite; plan injection at SessionStart, read-only, 200 ms cap | builder | §9.3 | Under 10 ms in a benchmark test; a test proves no SQLite open |
| [x] T2.5 | Spool drain into `genai.session`, idempotent | builder | §9.3 | Replaying the same spool writes nothing new |
| [x] T2.6 ★ | `envelope/1` validation and ingest: `source_ref` idempotency, per-field ownership, no deletes, after-seal marking, `inbox/` on skips | planner | §10.1 | Tests for every rule in §10.1 |
| [x] T2.7 ★ | Collector runner: argv only, absolute path, env allowlist, placeholders, timeout and kill, stdout and stderr caps, approval digests, 0600 config check, locks, `ingest.run`, the three-failure error state | planner | §10.2 | Security tests: shell metacharacters stay inert, an unapproved command is refused, oversized output is cut |
| [x] T2.8 | GitHub collector through `gh api graphql`: contributions, merged search, pagination, mapping, ticket parsing, AI marker, own-PR skip, author login dropped | builder | §10.3 | Tests against synthetic recorded responses |
| [x] T2.9 | Claude Code transcripts collector: incremental scan, minimal decoder, dedupe by message id, per day and model, sessions and requests, optional price table | builder | §10.4 | Fixture tests; a test proves message content is never decoded |
| [x] T2.10 ★ | `map/1` engine: JSONPath subset, const, default, exact decimal scale, formats, CSV, `source_ref` template | planner | §10.5 | `"0.4213"` scales to 421300 exactly; full table tests |
| [x] T2.11 | `cadence import genai FILE --map --dry-run` with a per-day table and conflicts | builder | §10.6 | Output matches the spec's example shape |
| [x] T2.12 | GenAI daily pick: endpoint, then transcripts, then import; never summed; mismatch flag above 15% | builder | §10.6, §11 | Tests |
| [x] T2.13 | `cadence presence backfill --since`: parse `pmset -g log` (the parser is testable on Linux) | builder | §8.4 | Fixture tests; the command runs on the Mac |
| [x] T2.14 | `cadence collect run --due`: `every` and `at`, 3-day overlap, 7-day backfill chunks, `jobs/`; launchd plist template | builder | §10.2, §14.3 | Scheduling tests with an injected clock |
| [x] T2.15 | `integrations/claude-code`: `hooks.json`, `skills/cadence/SKILL.md`, README | mechanic | §9 | Files match the spec text |
| [x] T2.16 | `examples/`: `config.example.json`, the on-call collector in shell and Python, sample maps with synthetic data | mechanic | §7.4, §10 | The guard is clean and the examples run |
| [ ] T2.17 | On your Mac, local only: maps for your endpoint and October app, backfill from 2026-10-01, totals checked against your app | builder | §10.5, §10.6 | October totals match; nothing is committed |
| [x] T2.18 | Phase 2 audit | auditor | §9 to §11, §13 | No open gaps |
| [x] T2.19 | Phase 2 audit fixes: GenAI overflow, scheduler window after long failure streaks and chunked catch-up, shared link rules for log and MCP, declare_day ownership, dictation prompt markers and size, tool size measured as the server does, README; CLI spool drain on `collect run`, `collect run --since --until`, audit nits | builder | §9, §10 | Each defect has a failing test first; `make check` green |
| [x] T2.20 | `cadence setup claude-code --print\|--apply` (hooks merge, MCP registration, skill copy) and `cadence doctor` checks for the agent, hooks, MCP registration, spool backlog and `cleanupPeriodDays` | builder | §9.1, §10.4, §14.5 | Tests on a temp HOME; `--print` changes nothing |
| [x] T2.21 | Core metrics of §11.1 (AI-assisted merges, agent-logged accepted entries, median session length, cache reuse, model mix) and the review sentence for the cycle recap and proof summary; the opt-in stand-up AI line of §11.2 | builder | §11, §12 | Metric tests on seeded ledgers; the stand-up line is off by default |

## Phase 3 · Menu bar · v0.3 (macOS only, on your Mac)

On 2026-11-02 The Coach design was approved and replaced SPEC §4 to §6. T3.3, T3.4 and T3.6 are reopened against it, and T3.21 to T3.34 add the read models and app architecture the new surfaces need.

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T3.1 | Run spikes S1 to S8 and record the results; the planner picks the fallbacks | planner | §8.7 | `SPIKES.md` is complete |
| [x] T3.2 ★ | App shell: accessory app, single instance, `bundle.sh`, Info.plist, entitlements, inside-out ad-hoc signing, `make app`, `install`, `uninstall` | planner | §8.3, §14.3 | Entitlement and symbol check passes; installs without admin |
| [x] T3.3 | Design tokens in Swift for The Coach: colour worlds with the dark rule, work colours, neutrals, the menu-bar OKLCH palette, type roles, spacing, radii, geometry, motion, the SF Symbols map. Reopened 2026-11-02 | builder | §4.1, §5.7, §6 | Snapshot of the token sheet; a test computes contrast for every world in its worst theme |
| [x] T3.4 | Status item and menu-bar mark: one circle, five channels, every state, the OKLCH palette, the interactions, VoiceOver lines and tooltip. Replaces DotState, DotPose and DotRenderer. Reopened 2026-11-02 | builder | §4.1, §5.2 | Snapshots of every state, light and dark; a test that every state is distinct by form alone |
| [x] T3.5 | Store observer: Darwin notification with `PRAGMA data_version` polling as fallback; view models | builder | §8.2 | A CLI write updates the UI within 1 s |
| [x] T3.6 | Tempo: globe, face, limbs, props, every pose of §5.3, composed from the day (level, pace, surface, bubbles, time of day, tada), gesture for 8 beats then held. Replaces the day ring. Reopened 2026-11-02 | builder | §5.3 | Snapshots of every pose; a check that no two moments render the same Tempo |
| [x] T3.7 | Panel: non-activating glass panel, Tempo header, plan first with tick and Undo, log field focused, one action, notes, footer and Day off menu, keys, Esc | builder | §4.2 | Opens in under 100 ms; UI test of every row of the panel table |
| [x] T3.8 | Capture bar: global hotkey, live chips from the core parser, Tab between chips, duplicate link offer, save as self | builder | §4.3 | Parser parity with core tests |
| [x] T3.9 | Morning plan sheet: carried, suggested with reasons, added by you, usual plan size note, Not working today, ⌘↩, `plan.committed` | builder | §4.4 | UI test of the flow |
| [x] T3.10 | Wrap-up: one question at a time, Done, Move to tomorrow with reason, Drop; tiles; stand-up with witness; Copy stand-up and seal; the sealing moment, sound and haptic; yesterday in its grace window | builder | §4.5 | UI test from reminder to sealed in under 60 s |
| [x] T3.11 | Notifications: plan prompt, wrap reminders (16:00, 17:30, 18:00, custom), a source behind, counts instead of titles by default, the app icon; a click opens the right sheet (baseline, S3), and the inline reply is an upgrade checked in the signed app | builder | §4.7 | Scheduling tests; manual check on the Mac |
| [x] T3.12 ★ | Presence engine: idle sampling, workspace events, spans closing after 5 minutes idle, day start; pure logic in Core | planner | §8.4 | Boundary, sleep and wake tests |
| [x] T3.13 | Login item and agent through SMAppService, with the LaunchAgent fallback if S2 fails | builder | §8.1 | Survives logout and login |
| [x] T3.14 | `tools/make_sounds.swift` renders the six sounds from the note table to CAF | mechanic | §5.6 | Files are generated reproducibly |
| [x] T3.15 | Sound player: Off, Subtle and Full; respects mute and Focus | builder | §5.6 | Tests for the level logic |
| [x] T3.16 | Settings: all eight panes, including Sources approval and "Network calls by this app: None" read from the entitlements | builder | §4.6 | UI tests |
| [x] T3.17 | Discreet mode (⌃⌥D) and the full keyboard map | builder | §4.8, §6.7 | Tests |
| [x] T3.18 | App housekeeping: spool drain, backups, agent registration status | builder | §8.1 | Tests |
| [x] T3.19 | String Catalog with every string; a lint that rejects en and em dashes in UI copy | mechanic | §6 | The lint runs in `make check` |
| [ ] T3.20 | Phase 3 audit plus one week of daily use | auditor | §4, §5, §8 | No open gaps; budgets in §8.6 met |
| [x] T3.21 | Rewrite SPEC §4 to §6 and this plan for The Coach design (approved 2026-11-02); reopen T3.3, T3.4 and T3.6 | planner | §4 to §6 | The spec matches the approved prototype; §2, the §3 day rules, §6.6, §6.7, §8 and §12 carry over |
| [x] T3.22 | Retire the superseded ring and dot sheet: `Ring/*`, `CadenceRingTokens`, `DotSheet` and their snapshots and tests. `DayRing` in Core stays for MCP clients | mechanic | §4.1, §5.3 | Builds; nothing references the ring views |
| [x] T3.23 | Usual range read model: items logged per counted workday, the range, usual by now from `occurred_at`, usual plan size; gaps never zeros | builder | §5.1 | Table tests on the October seed |
| [x] T3.24 | Day story: one pure function from the day to state, headline, sentence and voice, in the §5.2 order; a lint that rejects banned words and dashes in its templates | planner | §5.2, §6.6 | Tests for every state and every pair that can collide |
| [x] T3.25 | Weekly series: plan, PRs merged and reviews by week, partial weeks marked | builder | §5.4 | Table tests |
| [x] T3.26 | Day shape by weekday from workdays only, so weekends and days off never leak in | builder | §5.4 | Table tests |
| [x] T3.27 | Log search: `LIKE` over titles, tickets and notes; an index only if the 12-month demo store misses the budget | builder | §4.6, §8.6 | Tests and a timing on the demo store |
| [x] T3.28 | Slip reasons as a fixed chip list; the ledger's free text is unchanged | builder | §4.5 | Tests |
| [x] T3.29 | App read path: each load opens a fresh read connection on a background queue in one read transaction and yields an immutable `Sendable` state; generalises `DayModel` and `DayLoading`; single-flight reloads; Insights cached by `data_version` | planner | §8.2 | No screen can show half a day; tests |
| [x] T3.30 | `AppWriter` actor: the only writer in the app, typed success or failure for every action, immediate reload | planner | §8.2 | Tests for every failure in §4.6 |
| [x] T3.31 | `DayClock`: the 04:00 boundary, reminders and grace-window closes, recomputed on wake, time-zone and clock changes | builder | §3 | Tests with an injected clock |
| [x] T3.32 | Presence adapter: feeds `PresenceEngine` on a serial queue with each event's own time, saves the machine state after each event | builder | §8.4 | Crash recovery test |
| [x] T3.33 | `AppIssue`: typed failures drive the mark, a banner and recovery actions; the failure screens of §4.6; each surface fails alone | builder | §4.6 | A test per failure |
| [x] T3.34 | Logging: `os.Logger` with timings and error codes only, never titles or notes; surfaced in `cadence doctor` | builder | §13 | A test proves no title reaches the log |

## Phase 4 · Insights · v0.4

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T4.1 | Window: toolbar with Today, Log, Insights, Recap, Proof, Inbox and Settings; Today in every state of §5.2 at three widths and compact | builder | §4.6 | UI tests and snapshots |
| [x] T4.2 | Insights: Week, Month and Cycle chapters with table twins and VoiceOver summaries; too little data | builder | §5.4 | Snapshots and an accessibility audit |
| [x] T4.3 | Streak road and milestones (the sound plays once); the streak can be hidden | builder | §5.4 | Tests |
| [x] T4.4 | Charts: rhythm band, plan weeks, consistency calendar, split bar, week bars, strata, slip reasons, day shape, count tiles; each with a table twin | builder | §5.1, §5.4 | Snapshots and table tests |
| [x] T4.5 ★ | Findings engine: templates and thresholds; no trend from fewer than 3 points; never "best since" | planner | §5.4, §5.5 | Table tests against the October seed |
| [x] T4.6 | Recaps: weekly, monthly, cycle and since my last 1:1, frames with Tempo poses, paged with the arrow keys, copy as text | builder | §5.5 | UI tests |
| [x] T4.7 | Inbox: accept, edit, dismiss, accept all, origin kept, empty state | builder | §4.6 | Tests |
| [x] T4.8 | Proof export UI (⌘E): range, redaction, verify in the app | builder | §12 | The export passes the Python verifier |
| [x] T4.9 | Snapshot suite with ImageRenderer: every day state and surface, light and dark, 1x and 2x | mechanic | §14.4 | `make snapshots` |
| [x] T4.11 | Log: search, filters by kind and origin, entry detail with origin and version history, nothing matches | builder | §4.6 | UI tests |
| [x] T4.12 | First run: the six steps with their poses, each optional step skippable | builder | §4.6 | UI test from an empty store |
| [x] T4.13 | Fault injection: every row of the §4.6 failure table run for real against a temp store | builder | §4.6, §8 | Each failure shows its screen and loses nothing |
| [x] T4.14 | Soak: a scripted multi-day run with an injected clock across boundaries, sleep, a time-zone change and thousands of CLI writes | builder | §3, §8 | No crash, no drift; projections still rebuild byte for byte |
| [x] T4.15 | Budgets measured against a 12-month demo store: panel under 100 ms, idle CPU, memory | builder | §8.6 | Every budget met |
| [x] T4.10 | Phase 4 audit and accessibility pass: VoiceOver, Reduce Motion, contrast, keyboard | auditor | §5, §6.7 | No open gaps |
| [x] T4.16 | Focus rings only on the focused control, and the 1:1 date opens a calendar popover | designer | §6.7 | No ring without keyboard focus; arrows still step days |
| [x] T4.17 | Log a review or merge by hand: a kind chip in the log fields, and links shown and clickable | builder | §4.2, §4.6 | Parser, link edit and UI tests |
| [x] T4.18 ★ | Reopen a sealed day and seal it again, with history, in the ledger, CLI and app | planner | §3, §7.3, §12 | Reopen and reseal tested; projections rebuild byte for byte; proof vectors pass |
| [x] T4.19 | App icon from App/Cadence.icon, compiled by actool in the bundle script | mechanic | §14.4 | `make app` shows the icon |

## Phase 5 · Open-source ready · v1.0

| ID | Task | Tier | Spec | Done when |
|---|---|---|---|---|
| [x] T5.1 | README, CONTRIBUTING, SECURITY.md, and the PROOF-FORMAT, COLLECTORS, MCP and PRIVACY docs | mechanic | §16 | The planner reviews them against the spec |
| [ ] T5.2 | `make demo`, screenshots and screen recording from demo data only | builder | §16 | Shows no real data |
| [x] T5.3 | `guard --history` over every commit; decide whether to publish a fresh history | planner | §16 | Clean |
| [ ] T5.4 | Apply the name decision (renames are mechanic work once you decide) | mechanic | §17 | Builds and tests pass |
| [ ] T5.5 | Fresh clone to a running app on a clean macOS account in under 10 minutes | planner | §15 | Timed run recorded |
| [ ] T5.6 | Final audit: spec against implementation, every verify tag resolved | auditor | all | No open gaps. Only then is Cadence 100% |

## Counts

| Tier | Tasks |
|---|---|
| planner | 22, of which 14 are critical (★) |
| builder | 67 |
| mechanic | 12 |
| auditor | 5 phase audits, plus a cold review of every ★ diff |
