# Cadence

Local-only macOS work log. docs/SPEC.md is the source of truth; read the relevant section before changing behaviour.

## Hard rules
- No network code in the app or the cadence binary. Network happens only in collector commands the user approved.
- No admin rights, no Docker, no dependencies beyond swift-argument-parser and swift-crypto (Linux only).
- Never commit work-log data, real config, map files or proof files. Examples use ACME and example.com only.
- No employer names, hosts, ticket prefixes or data anywhere in the repo. Run `make guard` before every commit.
- The ledger is append-only: no UPDATE or DELETE on events. Projections must rebuild byte for byte.
- Any change to canonical JSON or hashing needs new vectors in Tests/Vectors and a passing tools/verify_proof.py.
- Origin (observed, collected, agent, self) is set once and never changes.

## Commands
- make test        core, ingest and MCP tests (also run on Linux)
- make check       the gate before every push: build, tests, proof vectors, guard; on macOS also app, entitlements, snapshots
- make app         build/Cadence.app, ad-hoc signed
- make run         the app against build/dev-home, never the real store
- make install     ~/Applications/Cadence.app and ~/.local/bin/cadence
- make spike       platform checks S1 to S9
- make guard       forbidden terms, data files and secrets; installs the git hooks

## Style
- UI copy: sentence case, finding first, no en or em dashes, unknown is not zero.
- Glass only on floating chrome (status panel, capture bar, sheets). Content stays matte.
- Every chart ships with a table twin and a VoiceOver summary.
- Tests first for Core. One docs/PLAN.md task per commit, with its ID in the subject.

## How work happens
- docs/PLAN.md is the work list. Every task has a tier: planner, builder, mechanic or auditor. ★ marks critical modules.
- The planner writes a brief for each builder or mechanic task, delegates it, reviews the diff against the spec and runs make check itself.
- If the cadence-builder, cadence-mechanic and cadence-auditor agents are installed, delegate by tier. If not, do the task yourself to the same standard.
- Never tick a task on a subagent's word alone. Every ★ diff gets a cold review from the auditor.
- A phase ends with an audit of its spec sections. Its gaps become tasks.

## Toolchain notes
- Swift 6.2 or later. On Linux, `libsqlite3-dev` is required for the CSQLite module.
- The protocol the spec calls `Hasher` is `ContentHasher` in code, so it does not shadow `Swift.Hasher`.
