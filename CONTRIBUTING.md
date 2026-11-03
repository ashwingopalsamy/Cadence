# Contributing

docs/SPEC.md is the source of truth. Read the relevant section before changing behaviour. (CLAUDE.md)

This page covers the build and gate, the hard rules, the copy rules, and how work is organised. It converts docs/SPEC.md sections 6.6, 14, 15 and 15.1, and it applies the working rules in CLAUDE.md. If the two disagree, the spec wins.

## Build and test

- Swift 6.2 or later. On Linux, `libsqlite3-dev` is required for the CSQLite module. (CLAUDE.md)
- The core, ingest, MCP and CLI build and test on Linux. The SwiftUI app builds on macOS. (docs/SPEC.md section 14)
- `make build` runs `swift build`, and `make test` runs `swift test`. (docs/SPEC.md section 14.4)
- `make test` covers the core, ingest and MCP tests, and it also runs on Linux. (CLAUDE.md)

## The gate

`make check` is the gate before every push. There is no GitHub CI for now. When CI comes back, its only job is to run the same target. (docs/SPEC.md section 14.6)

| Step | Linux | macOS |
|---|---|---|
| `swift build` and `swift test` | Core, Ingest, MCP, CLI | Everything, the app included |
| Proof vectors | `verify_proof.py` passes `valid.json` and fails `tampered.json`. `cadence verify` agrees on both | Same as Linux |
| `tools/guard.sh --all` | Forbidden terms, data-file signatures, secrets | Same as Linux |
| Copy lint | No en or em dashes in UI strings | Same as Linux |
| `make app` and `check_entitlements.sh` | Skipped | Sandbox on, no network keys, no socket or URLSession symbols in either binary |
| `make snapshots` | Skipped | Key views in light and dark, at 1x and 2x, compared with the last accepted set |

## Guard and git hooks

- `make guard` checks forbidden terms, data-file signatures and secrets in staged files, and installs the git hooks. (docs/SPEC.md sections 14.4 and 14.6)
- The pre-commit hook runs the guard on staged files and the fast core tests. The pre-push hook runs `make check`. (docs/SPEC.md section 14.6)
- The guard reads its forbidden-terms list from `~/.config/cadence/forbidden.txt`, which is never committed. When it finds a problem, it reports the file and line and never prints the term. (docs/SPEC.md section 13.1)
- The guard also rejects files whose content starts with `cadence.proof/1`, `envelope/1` or the SQLite header. (docs/SPEC.md section 13.1)

## Hard rules (CLAUDE.md)

- No network code in the app or the `cadence` binary. Network happens only in collector commands the user approved.
- No admin rights, no Docker, no dependencies beyond swift-argument-parser and swift-crypto (Linux only).
- Never commit work-log data, real config, map files or proof files. Examples use ACME and example.com only.
- No employer names, hosts, ticket prefixes or data anywhere in the repository. Run `make guard` before every commit.
- The ledger is append-only: no UPDATE or DELETE on events. Projections must rebuild byte for byte.
- Any change to canonical JSON or hashing needs new vectors in `Tests/Vectors` and a passing `tools/verify_proof.py`.
- Origin (observed, collected, agent, self) is set once and never changes.

## Copy rules (docs/SPEC.md section 6.6)

UI copy follows these rules.

- Sentence case everywhere. Plain, specific and on the user's side. Use the first person where it is the user's journal, as in "You reviewed on 18 of 19 workdays". Every screen leads with one plain sentence, and detail follows.
- No en or em dashes in the interface. Ranges read "1 to 28 Oct" in sentences. In compact labels they read "1 - 28 Oct".
- Unknown is "-". A lower bound is "≥". An approximation is "≈". Never print 0 for something that was not recorded.
- Use these words: Seal, Wrap up, Found today, Beyond the plan, Move to tomorrow, Assigned, Self-started, Backfilled, After wrap-up, Usual range. Never "productivity", "score", "missed" or "you failed". "Behind" only ever describes a data source.
- Times and dates follow the system locale. Weeks start on Monday. Figures are tabular.
- Provenance is a footnote or a quiet badge, never a celebratory pill such as "Verified!". A proof says what it does not prove.

## Tests first for Core

Core is the `CadenceCore` module. It holds the domain types, the store and migrations, the ledger, canonical JSON, projections, the capture parser, the presence engine, insights, findings, and proof export and verify. (docs/SPEC.md section 8.5)

Tests come first for Core: write them before the code they check. (CLAUDE.md; docs/SPEC.md section 15.1)

## Commits and tasks

- One `docs/PLAN.md` task per commit, with its task ID in the subject, for example `T1.5: ledger append under BEGIN IMMEDIATE`. (CLAUDE.md; docs/SPEC.md section 18)
- `make check` is green before a push. (docs/SPEC.md section 18)

## Task tiers in docs/PLAN.md

`docs/PLAN.md` is the work list. Every task has a tier and a "done when". (docs/SPEC.md sections 1 and 15.1)

Each task has one of four tiers (docs/SPEC.md section 15.1):

- **Planner.** Writes the briefs and interfaces, writes the critical modules, reviews every diff against the spec, and runs `make check` itself. A task is ticked only after that.
- **Builder.** Implements one brief at a time, tests first.
- **Mechanic.** Does fully specified mechanical work.
- **Auditor.** Reviews with fresh context: every critical diff, and each finished phase against the spec.

Critical modules are marked ★ in `docs/PLAN.md`. There are 14: canonical JSON, hashing, schema, ledger append, projections, witness, proof export, MCP protocol, envelope ingest, collector runner, decimal mapping, app signing, presence and findings. (docs/SPEC.md section 15.1; CLAUDE.md) Every ★ diff gets a cold review from the auditor. (CLAUDE.md)

A phase ends with an audit of its spec sections, and its gaps become tasks. (CLAUDE.md) The project is complete when every task is ticked, every verify tag has a result in docs/SPIKES.md, and a final audit finds no gaps. (docs/SPEC.md section 15.1)

## Demo data

Screenshots and snapshot tests use only the deterministic ACME demo data from `make demo`. (docs/SPEC.md sections 14.4 and 16)

## Good first contributions

New collectors are a good place to start. The envelope format and the runner are in docs/COLLECTORS.md. (docs/SPEC.md section 16 plans "good first collector" issues.)
