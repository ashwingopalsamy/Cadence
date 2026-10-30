# Decisions

One line per decision in docs/SPEC.md section 17. All six recommendations were accepted on 2026-10-30.

| # | Decision | Outcome |
|---|---|---|
| 1 | End the stand-up with the witness code | Yes, as a last line prefixed `cadence` |
| 2 | Employer policy before publishing code built on the work Mac | Ask before phase 5; build privately meanwhile |
| 3 | Public name | Keep Cadence privately; choose before publishing (T5.4) |
| 4 | Source of truth for AI numbers | Usage endpoint first, then transcripts, then the October import; never summed |
| 5 | Signing | Ad-hoc; switch to a free personal team only if login-item re-approval gets annoying |
| 6 | What "consistency" means | Confirm with the manager at the next 1:1; the summary order follows the answer |

Other settled choices: Apache-2.0 licence (section 16); GitHub CI deferred, `make check` is the gate (docs/PLAN.md).

## Planner decisions after the T1.16/T1.17 audit (2026-10-30)

- The verifier checks every item, seal and witness against the chain, and recomputes the merged PR and review counts. `export_digest` is described as catching accidents only.
- Chain payloads are allow-listed; the owner's free text (day notes, focus, reason and status notes, day labels, collector errors) and unknown event types stay hash-only and are counted.
- A day's first seal stands. `edited` means changed after that seal.
- Workdays before the ledger began are reported as `before_ledger`, not as unsealed.
- Known limit, documented in section 12.4: a short private title can be guessed against its digest. A per-entry salt would fix it and is left for a later decision because it changes the payload format.

## Planner decisions for envelope ingest, T2.6 (2026-10-30)

- `ingest.run` records the window the runner asked for, not the one the header claims. The header must name the collector being run, so one collector cannot write as another.
- A ticket key that opens a collected title moves to the entry's ticket and leaves the title, as in section 7.2.
- Field ownership is read from the ledger: any field an `entry.updated` from the app, the CLI or an agent changed is yours. Collectors and imports never own a field. The ledger itself refuses a collector or import edit to an entry it did not create.
- Collected presence uses source `collected`, is cut at the day boundary, and is written only where no span of that day already is. Spans shorter than a minute are dropped.
- A leave record is ignored once anyone other than that collector has declared the day. The collector may change its own declarations.
- `genai.usage.sessions` may be null when a source does not count sessions. The summary and the proof share one query for AI days.
- Bad links are dropped with a warning and the record is kept. Any other bad field skips the record.
- Each record is written in its own savepoint, so a record the ledger refuses is skipped and the rest of the run stands.
- A second record in one envelope for the same item `source_ref`, usage row or leave day is skipped with a reason, so a rerun of the same envelope writes nothing.
- Links that carry credentials (`user:pass@`) are dropped like any other refused link.

## Planner decisions for the collector runner and maps, T2.7 and T2.10 (2026-10-30)

- The approval digest covers the collector name, the full argv and the env keys and values, not the keys only, so any change asks again. The prompt shows every element quoted. Control, NUL and bidi characters are refused in commands, `gh` and env values. The digest is pinned by a test and agrees with Python.
- Commands run in their own process group. The timeout's SIGTERM and SIGKILL reach everything they started, and anything left when the command exits is killed, so no grandchild can hold a run or its lock open.
- Only the fixed reason (exit status, signal, timeout, cut output) goes into `ingest.run`; stderr stays in `logs/`, because the ledger is permanent and stderr can hold tokens or host names.
- Runs are serial across processes through `locks/runs.lock`, beside the per-collector lock.
- Approvals are read without following symlinks and checked on the open file.
- An envelope with an unreadable header is still kept in `inbox/` (section 10.1 wins over the "writes nothing" of 10.2, which is about the ledger).
- JSON read through a map, and gh output, keep non-integer numbers as text instead of failing or zeroing them.
- A map's `source_ref` is built in one pass, and `%`, `:`, `{` and `}` in field values are percent-encoded, so values can neither inject a placeholder nor collide across a delimiter. When a map skips rows or fails, the collector's raw output is kept beside the inbox copy.

## Planner decisions for MCP, T2.1 to T2.3 (2026-10-30)

- Messages are parsed strictly. A fraction or an integer past 2^53 anywhere in a message is refused as an invalid request with a null id, because the id itself may be that number and could not be echoed faithfully.
- A schema is checked at registration for keyword, type and shape: a keyword needs the type it applies to, `required` names must be properties, bounds are integers. Lengths count code points.
- The 20,000 limit counts the whole encoded result in code points. A tool result loses its structured copy first, then its text is cut; resources and prompts are cut the same way, and the tools and resources keep inside an 18,000 budget so the server rarely has to.
- Naming 2025-11-25 in `_meta` does not stand in for its handshake; `initialize` only agrees to 2025-11-25.
- File and integrity errors reach the client as a generic line; the detail goes to stderr.
- MCP plan tasks carry plan origin `suggested` with actor `mcp`, since plan origin has no agent value; entries carry origin `agent`.
- `query` pages hold at most 200 entries and fewer when a page would pass the size budget; the cursor still walks every entry.
- `standup` over MCP is read-only and writes no witness checkpoint.

## Planner decisions for metrics, T2.21 (2026-10-30)

Readings of section 11.1 where the spec is short. Each takes the most literal reading, and every one is null when there is no data.

- **AI-assisted merges.** Merged PRs are the ones `merged_prs` counts (accepted `pr.merged`, origin collected, source github). The marker is `attrs.ai_assisted` as the GitHub collector recorded it. The share is marked PRs out of merged PRs whose marker is recorded. A merged PR with no recorded marker is neither assisted nor unassisted: it is in neither number and is counted as `unrecorded`, so "out of merged PRs" is never read as "not assisted". All unrecorded is null; no merged PR is a known 0 of 0 with no percentage.
- **Agent-logged entries.** Accepted entries with origin agent. `cadence summary` counts every accepted entry in range, as it does for `entries`; the proof counts the items listed in `days` (accepted, export policy include or digest), as it does for `merged_prs`. Null when the range holds no accepted or listed entry or ends before the ledger began. A real count of 0 is stated as 0.
- **Median session length.** Sessions are the `genai.session` rows whose day is in range, the same set as the session count. Length is `ended_at` minus `started_at` in whole seconds. A session with no end, an unreadable time or an end before its start is not measured, and is not counted as 0. An even count takes the mean of the middle two, rounded down. The output carries the median in seconds, how many sessions were measured, and how many there were. Null when none is measured.
- **Cache reuse.** Cache read tokens divided by input plus cache read tokens, as the table says (cache write is not in it). It is taken over the model rows of the daily pick that report both counters and do not add up to 0, and it is the ratio of the range's totals, not a mean of daily ratios. The days each source supplied are listed. Null when no row qualifies.
- **Model mix.** Each model's output tokens over the total, from the model rows of the daily pick that report output tokens, largest first. It never adds a second source for a day, so its total equals the summary's output tokens. A model recorded as `*` is shown as "unknown model". Null when the total is 0.
- **Percentages** are whole numbers, rounded half up. A share that is not all or nothing never shows as 0% or 100%, so 100% always means every one.

The sentence your review needs (section 11).

- It is built by one function from AI days, the AI-assisted share and the agent-logged count, so `cadence summary` and the proof write the same words. A figure with no data leaves its clause out; a known zero is stated ("Your agent logged 0 entries you accepted."). With no figure at all it is null. When some merged PRs had no recorded marker the clause says so: "67% of the 3 merged PRs with a recorded marker were AI-assisted."
- `cadence summary` writes it for every range, the cycle included, and the human output labels it "The sentence your review needs" with a line saying it is computed from the figures below. JSON has it at `review_sentence`; the new figures sit under `ai` (`assisted_merges`, `agent_entries`, `session_length`, `cache_reuse`, `model_mix`). `ai.sessions` is unchanged.
- The proof summary gains `ai_assisted_merges`, `agent_entries` and `review_sentence`, each with a definition. The definitions say they are computed by Cadence and not recomputed by the verifier, which keeps the section 12 promise that it recomputes only `merged_prs` and `reviews`; `tools/verify_proof.py` and the embedded script are unchanged. A test recounts all three from the exported file alone: item origins, and the marker in each included entry's payload in the chain. Extending the verifier to recompute them is possible later and would need a spec change.
- Proof vectors: `valid.json` carries the new summary entries and its merged PR records `ai_assisted`, which re-hashes the chain, so every vector was regenerated by `tools/make_vectors.py`. `tampered-sentence.json` edits the sentence with a stale digest and must fail. `make check` runs them in Python and with `cadence verify`.

The optional stand-up line (section 11.2).

- The spec had no key name. It is `genai.standupLine`, a boolean, default `false`, in the `genai` object; section 11.2 now names it. The example config lists only some keys (no `ai`, `genai`, `hosts` or `signals`), so it is unchanged.
- The line follows the counts line: "AI: 4 sessions · 2 of 3 merges AI-assisted". Sessions use the same count as "Claude Code N sessions" on the counts line, which stays as section 4.5 shows it. The merges are the day's merged PRs with a recorded marker. A part with no record is left out, so a day with neither writes no line, never "AI: 0 sessions". Both `cadence standup` and the read-only MCP `standup` tool use it, and the witness code stays the last line.

## Planner decisions for setup and doctor, T2.20 (2026-10-30)

- The hooks block and the skill are embedded as string constants generated by `tools/embed_claude_code.py`, not as SwiftPM resources, because the binary runs alone from `~/.local/bin`. A test compares both constants with `integrations/claude-code` byte for byte.
- `setup claude-code` needs exactly one of `--print` and `--apply`; neither or both is a usage error (exit 1). `--print` builds the same plan `--apply` runs, writes nothing, creates no folder and runs no command.
- The user home is `HOME` when it is an absolute path, otherwise the account's home. Claude Code's files are fixed at `~/.claude/settings.json`, `~/.claude/skills/cadence/SKILL.md` and `~/.claude.json`; `CLAUDE_CONFIG_DIR` is not followed. The CLI tests give every run a throwaway `HOME`.
- Registration follows section 9.1: `claude mcp add --transport stdio --scope user cadence -- <home>/.local/bin/cadence mcp`. `--print` shows the `$HOME` form from the spec; the call passes the expanded path as argv. `claude` is the first executable file with that name in an absolute PATH entry. It runs through `ProcessRunner` with HOME, PATH, LANG and TMPDIR only, plus two variables that ask Claude Code to stay offline, and a 30 second limit.
- Without `claude` on PATH the registration is skipped with a message and the command to run later; the other two steps still happen and the exit code is 0. A `claude` that fails or times out is exit 1, after hooks and skill are in place.
- "Registered" is read from `mcpServers.cadence` in `~/.claude.json`, where `--scope user` writes it. Any entry that runs a program called `cadence` with `mcp` as its first argument counts. A different entry is reported and left alone, never replaced; the message gives `claude mcp remove cadence --scope user`.
- The settings file is edited with an order-preserving JSON reader and writer: keys keep their order, numbers keep their text, and the file is rewritten with a two-space indent. Comments, trailing commas and an empty file are refused with exit 2 and nothing is written, as is a `hooks` that is not an object or an event that is not a list.
- An event counts as set when any command hook under it runs `<path>/cadence hook <that event>`, whatever the path, quoting, timeout or `async`. Such an event is left alone, so a hand-written entry is never duplicated. Otherwise the group from `hooks.json` is appended after the user's own groups.
- The backup `settings.json.cadence-backup` (mode 0600) is written only when the file exists and is about to change, so an idempotent rerun cannot replace the original with the merged file. A later change overwrites it. A settings file that is a symlink stays one; the target is replaced and keeps its mode. A new file is 0600 and a new `~/.claude` is 0700.
- A skill that differs from the embedded one is replaced after a copy to `SKILL.md.cadence-backup` (mode 0600); an identical one is not touched.
- `setup` does not set `cleanupPeriodDays`. It is the owner's retention choice, so `doctor` warns and names the value.
- The new doctor checks only warn, so a Mac without Claude Code still exits 0. A file that cannot be read gives a `warn` that starts with `unknown`, never `ok`.
- Spool backlog: the spec names no threshold, so a waiting line older than 24 hours warns. Backlog counts complete lines past each file's saved offset, because drained files stay 14 days and would otherwise look like a backlog. Age is the time written on the oldest waiting line. An unreadable `state/spool-drain.json` is `unknown`.
- `cleanupPeriodDays` must be at least 400 (section 10.4). Unset warns and names the default of 30; a value that is not a number is `unknown`.
- Hooks and MCP checks also warn when the program they run is missing or not executable. A bare program name or another variable cannot be checked and is not flagged.
- Agent check: off macOS it reports "not applicable on this system" as `ok`. On macOS it asks `launchctl print gui/<uid>/<label>` and warns when the agent is not loaded or its last exit code is not 0. The label is `in.ashwingopalsamy.cadence.agent`; `CADENCE_AGENT_LABEL` overrides it for a build made with another `BUNDLE_PREFIX`. The app registers the agent through SMAppService (T3.13), so a missing plist in `~/Library/LaunchAgents` is not a problem by itself.

## Planner decisions for phase 2 audit fixes, T2.19 (2026-10-30)

Notes from the builder where the spec is silent. The planner confirms or changes them.

- Counters read from a file can reach 2^53 - 1, so the distance between two sources is computed in 128 bits. A distance too large for Int64 stops at `Int64.max`, and sums of counters and the summary's token total stop at their limits instead of trapping.
- One link rule (`LinkRule`) serves `cadence log --link`, the MCP tools and envelope links: `https`, or `http` on a host in `config.hosts` as section 10.1 says; a host; at most 2,048 characters; no user name or password; no spaces, control or bidi characters. With the default config this is what the CLI and MCP did before, and `http` on a configured host now passes there too. A link typed into the entry text that fails the rule is left out of the entry, while one given as a field is refused with the reason.
- `declare_day` refuses when the latest `day.declared` for that day came from any actor other than `mcp`, including collectors and the app, and says who ("the user" for the app and the CLI). The check sits in `Journal.declare` for actor `mcp`, inside the write transaction. The CLI and the app keep replacing whatever is there; the agent may change its own declaration.
- The dictation prompt carries the transcript as one canonical JSON string on its last line, with no start or end markers. Its size is measured, not capped at a fixed length: quotes, backslashes and control characters cost two to seven characters each once encoded, so the prompt is refused when its whole encoded message would pass 20,000 characters, with a message that says to paste the text in the next message instead. About 18,600 plain characters fit.
- The server counts `resultType: "complete"`, which `handle` adds after the cut, in its size, so a result that passes is within 20,000 characters as sent. Tools measure with the server's own `size` of the whole encoded result; the 18,000 tool budget stays as the margin.
- `standup` over MCP shows the first N bullets of Done and of Next, the same N for both, where N is the largest that fits, and then one bullet saying how many were left out ("12 more not shown; use query for this date"). The structured copy holds the same text. A stand-up that fits is returned whole.
- The scheduler reads the last run, and every distinct `until` of the successful runs, with no row limit; the incremental window starts 3 days before the furthest successful `until`, so a run over an older window does not move it back. A window longer than 7 days, such as after three weeks offline, runs in 7-day chunks oldest first and stops at the first failure, as a backfill does. `runIncremental` returns the steps.
- The scheduler's "today" is the workday by the day boundary (04:00 by default), as everywhere else, so a window that ends "today" still names the previous day until the boundary passes.
- `collect run --name X --since A --until B` runs exactly that window in 7-day chunks, needs both options, and needs 2000-01-01 <= A <= B <= today. A backfill start (a `--backfill-from` or the `from` of a job) outside 2000-01-01 through today is refused by the CLI; a job file with such a start is invalid and is deleted like any other invalid job.
- `collect run`, with `--due` or `--name`, drains the hook spool first, after its arguments are checked. A drain that fails prints `cadence: spool drain failed: <reason>` on stderr and collection goes on; the JSON result carries the drain report or the error under `spool`.
- `Journal.planResolve` still lets the wrap-up deck change a resolution (section 4.5 has a three-way toggle, and an earlier test pins it). The CLI and `plan_update` pass `replacing: false` and refuse an already resolved task: "task X is already done; a resolved task is not resolved again". Confirm that the CLI should refuse as well.
- MCP reads (`get_day`, `query`, `summary`, `standup`, both resources) and the dry run of `log_entries` use a journal that never writes the genesis event. With no database yet it reads an empty in-memory ledger, so the file is not created either. Every write, including one that is then refused, still starts the ledger under actor `mcp`.
- The `data.uri` of an unknown-resource error is the same printable, 60-character form as its message.
