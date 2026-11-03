# Cadence

Cadence is a native macOS app, written in Swift and SwiftUI, that keeps a local work log. It fills itself from what you already do, asks you only for judgment, and turns every workday into evidence a manager's agent can check. It lives in one small circle in your menu bar. (docs/SPEC.md header and section 1)

## Three promises

- **Nothing leaves the Mac.** The app runs in the App Sandbox with no network entitlement, so macOS itself blocks it from opening a connection. The `cadence` binary has no networking code. The only network traffic comes from collector commands you approved, such as `gh` and `curl`. (docs/SPEC.md sections 8 and 13.1)
- **Every claim carries its source.** Collected entries link to the pull request or ticket. Typed entries are labelled self-reported. The proof file says which is which. (docs/SPEC.md header and section 2)
- **Under a minute a day.** Login, PRs, reviews and Claude Code sessions arrive on their own. You plan in the morning and confirm in the evening. (docs/SPEC.md header)

## What it does

- **One circle, a panel, a window.** The menu-bar mark shows how the day is going. A panel shows today's plan first. The full window holds history and insights. (docs/SPEC.md section 1)
- **Collectors fill in, you confirm.** Collectors propose, and you accept with one tap, adjust, or dismiss. (docs/SPEC.md section 2)
- **Evidence, not adjectives.** Each entry has one origin that never changes: observed (the Mac saw it), collected (a source system has it, with a link), agent (written by an agent you connected), or self (you typed it). (docs/SPEC.md section 2)
- **Local and inspectable.** One SQLite file you own, and plain JSON out. Apple frameworks only, inside the app. (docs/SPEC.md section 2)
- **What it tracks.** First and last activity, plan against done, PRs opened, merged and reviewed, initiatives, meetings, leadership signals, on-call and incidents, and GenAI usage. (docs/SPEC.md section 1)
- **What it reads from.** GitHub through your own `gh` CLI, Claude Code hooks and local transcripts, your GenAI usage endpoint, and an import of earlier usage data. (docs/SPEC.md sections 1 and 10)

## Requirements

- macOS 26 (Tahoe). (docs/SPEC.md section 1)
- Swift 6.2 or later, with Apple's Command Line Tools. (docs/SPEC.md section 14.5)
- No admin rights. Nothing needs sudo at any step. (docs/SPEC.md sections 14 and 14.5)
- No Docker, and no Apple account. (docs/SPEC.md section 14)

## Install from source

Cadence is distributed as source only. (docs/SPEC.md section 16)

```sh
xcode-select -p || xcode-select --install     # Command Line Tools; Swift 6.2 or later
git clone https://github.com/OWNER/Cadence.git && cd Cadence
make spike && make test
make install
cadence doctor                                # store, permissions, FileVault, agent, hooks, MCP
claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp
cadence setup claude-code --print             # shows what --apply would add; changes nothing
cadence setup claude-code --apply             # merges the hooks into ~/.claude/settings.json, after a backup
```

`--print` shows what `--apply` would change and changes nothing. (docs/SPEC.md section 9.1)

The make targets (docs/SPEC.md section 14.4):

| Target | What it does |
|---|---|
| `make build`, `make test` | Runs `swift build` and `swift test` |
| `make check` | The gate before every push. See CONTRIBUTING.md |
| `make app` | Release build, then `build/Cadence.app` via `bundle.sh`, signed ad-hoc |
| `make install`, `make uninstall` | Copies the app to `~/Applications`, links `~/.local/bin/cadence` and opens the app once. Uninstall unregisters the login item and agent, and leaves your data |
| `make run` | Runs the app from `build/` against a dev home inside its sandbox container, never your real store |
| `make demo` | Seeds `build/demo-home` with deterministic ACME data for screenshots and snapshots |
| `make snapshots` | Renders key views to PNG in light and dark, at 1x and 2x |
| `make spike` | Runs the platform checks S1 to S9, printing PASS, FAIL or MANUAL with instructions |
| `make guard` | Checks forbidden terms, data-file signatures and secrets in staged files, and installs the git hooks |
| `make sounds` | Regenerates the sound files from `tools/make_sounds.swift` |

## First run

After `make install`, the app opens and walks you through six steps. Each one is useful without the optional steps, and each says what it reads and what it sends: nothing from your log. (docs/SPEC.md section 4.6)

1. **Welcome.**
2. **Your data.** Where the log lives, and whether FileVault is on.
3. **GitHub.** Approve the exact command the collector runs, or skip.
4. **Claude Code.** `cadence setup claude-code --apply`, or skip.
5. **History.** Import earlier data, labelled backfilled, or skip.
6. **Permissions.** Open at login, and reminders.

Run `cadence doctor` at any time to check the store, permissions, FileVault, the agent, hooks and MCP. (docs/SPEC.md section 14.5)

## The CLI

Five commands to start with. Each one takes `--json` to print one JSON object instead of text. (docs/SPEC.md section 9.5)

```sh
cadence today
cadence log "Merged ACME-482913 retry fix @14:30"
cadence plan add "Draft the idempotency ADR"
cadence standup
cadence export proof --from 2026-10-01 --to 2026-10-31 -o acme.cadence-proof.json
```

- `cadence today` shows today's ring, plan and entries. (docs/SPEC.md section 9.5)
- `cadence log` parses one line and records it. The kind, ticket, time, duration and tags come from the text. (docs/SPEC.md sections 4.3 and 9.5)
- `cadence plan add` adds a task to today's plan. (docs/SPEC.md section 9.5)
- `cadence standup` prints the stand-up text, ending in a witness code. `--copy` also copies it on macOS. (docs/SPEC.md sections 4.5 and 9.5)
- `cadence export proof` writes a proof file. `--from` and `--to` are the first and last days, as YYYY-MM-DD. `-o` names the file, or `-` writes to standard output. (docs/SPEC.md sections 9.5 and 12)

## Claude Code integration

Claude Code can log, plan and read your day. It cannot accept its own proposals, seal a day, delete, change config or touch presence. (docs/SPEC.md sections 9 and 9.4)

- **MCP server.** `cadence mcp` lets Claude Code log entries, plan and read over stdio. It has no listener of any kind. Register it with the `claude mcp add` command above. (docs/SPEC.md sections 1, 9.1 and 9.2)
- **Hooks.** SessionStart and SessionEnd hooks append one line to Cadence's spool in a few milliseconds and exit. Tokens arrive later from the transcripts collector. The hooks block is merged into `~/.claude/settings.json` by `cadence setup claude-code --apply`. (docs/SPEC.md sections 3, 9.1 and 9.3)
- **Skill.** A Claude Code skill in the repository tells Claude Code how to log: one line per outcome, past tense, in your words, with the ticket key when one is in play. It never invents times, tickets or counts. (docs/SPEC.md section 9.4)

## Where your data lives

Everything is in `~/Library/Application Support/Cadence/`. The folder is mode 0700 and its files are mode 0600. (docs/SPEC.md section 7.4)

```
cadence.db        ledger and projections, WAL mode (-wal and -shm beside it)
config.json       your settings: ticket pattern, hosts, collectors, reminders. Never in git
spool/            hook lines waiting to be ingested, one NDJSON file per day
jobs/             requests from the app to the collector agent (backfill, run now)
inbox/            envelopes that failed validation, and the raw output a map could not fully read, kept for inspection
exports/          proof files you exported
backups/          daily VACUUM INTO snapshots: 14 daily, 8 weekly
logs/             collector and agent logs, rotated at 1 MB
```

The folder sits outside iCloud Drive and outside any app container. So the CLI reads it without privacy prompts, and Time Machine backs it up if you use it. FileVault provides encryption at rest. Cadence adds no crypto dependency of its own. (docs/SPEC.md section 7.4)

## Docs

- [docs/SPEC.md](docs/SPEC.md): the specification and the source of truth, including the phases in section 15
- [docs/PLAN.md](docs/PLAN.md): every task with its tier and "done when"
- [docs/SPIKES.md](docs/SPIKES.md): platform checks and their evidence
- [docs/PROOF-FORMAT.md](docs/PROOF-FORMAT.md): the proof file, how to verify it, and what it does not prove
- [docs/COLLECTORS.md](docs/COLLECTORS.md): envelopes, the runner, built-in collectors, maps and imports
- [docs/MCP.md](docs/MCP.md): the MCP server, its tools, resources, prompts and hooks
- [docs/PRIVACY.md](docs/PRIVACY.md): what is never collected, and the permissions the app asks for
- [docs/decisions/README.md](docs/decisions/README.md): settled decisions and their outcomes
- [CONTRIBUTING.md](CONTRIBUTING.md): the build, the gate, the rules and the task workflow
- [SECURITY.md](SECURITY.md): the threat model and how to report a problem privately

## License

Cadence is licensed under Apache-2.0. See [LICENSE](LICENSE). (docs/SPEC.md section 16)
