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
- The user home is `HOME` when it is an absolute path, otherwise the account's home. Claude Code's files are `~/.claude/settings.json`, `~/.claude/skills/cadence/SKILL.md` and `~/.claude.json`, unless `CLAUDE_CONFIG_DIR` names an absolute path (see the T2.19 section below, which replaces the first version of this rule). The CLI tests give every run a throwaway `HOME` and clear `CLAUDE_CONFIG_DIR`.
- Registration follows section 9.1: `claude mcp add --transport stdio --scope user cadence -- <home>/.local/bin/cadence mcp`. `--print` shows the `$HOME` form from the spec; the call passes the expanded path as argv. `claude` is the first executable file with that name in an absolute PATH entry. It runs through `ProcessRunner` with HOME, PATH, LANG and TMPDIR only, plus two variables that ask Claude Code to stay offline, and a 30 second limit.
- Without `claude` on PATH the registration is skipped with a message and the command to run later; the other two steps still happen and the exit code is 0. A `claude` that fails or times out is exit 1, after hooks and skill are in place.
- "Registered" is read from `mcpServers.cadence` in `~/.claude.json`, where `--scope user` writes it. Any entry that runs a program called `cadence` with `mcp` as its first argument counts. A different entry is reported and left alone, never replaced; the message gives `claude mcp remove cadence --scope user`.
- The settings file is edited with an order-preserving JSON reader and writer: keys keep their order, numbers keep their text, and the file is rewritten with a two-space indent. Comments, trailing commas and an empty file are refused with exit 2 and nothing is written, as is a `hooks` that is not an object or an event that is not a list.
- An event counts as set when any command hook under it runs `<path>/cadence hook <that event>`, whatever the path, quoting, timeout or `async`. Such an event is left alone, so a hand-written entry is never duplicated. Otherwise the group from `hooks.json` is appended after the user's own groups.
- The backup `settings.json.cadence-backup` (mode 0600) is written only when the file exists and is about to change, so an idempotent rerun cannot replace the original with the merged file. A later change overwrites it. A settings file that is a symlink stays one; the target is replaced and keeps its mode (read from the target, never from the link). A link that leads nowhere is refused, see the T2.19 section. A new file is 0600 and a new `~/.claude` is 0700.
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
- The scheduler's "today" is the workday by the day boundary (04:00 by default), as everywhere else, so a window that ends "today" still names the previous day until the boundary passes. An explicit `--until` is different: it may be any day up to the calendar today in the profile zone, so `--until` with the date on the clock is not refused as future between midnight and the boundary. A later date is still refused, and the message names the calendar today.
- `collect run --name X --since A --until B` runs exactly that window in 7-day chunks, needs both options, and needs 2000-01-01 <= A <= B <= the calendar today. A backfill start (a `--backfill-from` or the `from` of a job) outside 2000-01-01 through today is refused by the CLI; a job file with such a start is invalid and is deleted like any other invalid job.
- `collect run`, with `--due` or `--name`, drains the hook spool first, after its arguments are checked. A drain that fails prints `cadence: spool drain failed: <reason>` on stderr and collection goes on; the JSON result carries the drain report or the error under `spool`.
- `Journal.planResolve` lets the user change a resolution: the wrap-up deck does (section 4.5 has a three-way toggle, and an earlier test pins it) and so does the CLI, as a manual correction (section 9.5). `cadence plan done`, `slip` and `drop` work on a resolved task again, as before this task. Only the MCP tool `plan_update` passes `replacing: false` and refuses an already resolved task: "task X is already done; a resolved task is not resolved again", because an agent may not overwrite the user's resolution. A task that moved to a later day is refused by every caller.
- MCP reads (`get_day`, `query`, `summary`, `standup`, both resources) and the dry run of `log_entries` use a journal that never writes the genesis event. With no database yet it reads an empty in-memory ledger, so the file is not created either. Every write, including one that is then refused, still starts the ledger under actor `mcp`.
- The `data.uri` of an unknown-resource error is the same printable, 60-character form as its message.

### Final audit fixes, T2.19 (2026-10-30)

Planner decisions on the second audit. Each defect has a test that failed before the fix.

- **Links that lead nowhere.** `~/.claude/settings.json` and the skill file are the user's, and a symbolic link in either place may point into a dotfiles repo. A link that works is followed: its target is edited, the link stays, and the target's mode is kept (modes are read with `stat`, so a link's own mode, always 0777, is never taken; with no mode to read the file is 0600). A link whose target is missing, or whose links loop, is refused by `--print` and `--apply` alike, with exit 2 and the message "~/.claude/settings.json is a symbolic link to X that does not lead to a file; point it at a real file or remove it, then run this again" (a loop says "that loops"). The check runs while the plan is built, so nothing is written: no hooks, no skill, no backup, no folder. `doctor` reports such a link as `unknown` and says why, not as a missing file.
- **`CLAUDE_CONFIG_DIR`.** When it is set to an absolute path, setup and doctor use that folder in place of `~/.claude`, so the settings, the backup and `skills/cadence/SKILL.md` live there, and the MCP registration is read from `<folder>/.claude.json` instead of `~/.claude.json`. Setup passes the variable on to `claude mcp add`, so `claude` records the registration in the file doctor reads. An empty value is the same as unset. A relative value, or one starting with `~`, is not followed: setup uses `~/.claude` and says so in a note. The hooks still run `$HOME/.local/bin/cadence`, which does not move. The `claudeCode.projectsDir` of the transcripts collector is a config value and does not follow the variable. The integration README says all of this.
- **`claude` gets absolute PATH entries only.** Relative entries and empty ones are dropped from the PATH handed to `claude mcp add`, as they already were when looking for `claude`; with none left the PATH is `/usr/bin:/bin`.
- **A store with no genesis event.** The MCP read journal does not write one, so `Summary` has no ledger start. Every day in the range is then before the ledger, as on a fresh CLI home, and no past workday reads as unsealed ("You sealed 0 of 3 counted workdays" is gone). The sealed workdays figure is unknown and `before_ledger` equals the workdays. The proof is unchanged: an export always opens the journal the usual way, so its chain has a genesis event.
- **Large counters.** `GenAIMetrics` and the summary text sum with saturating arithmetic: cache read, input and output totals stop at `Int64.max`, and so does the denominator printed in the cache reuse line. Percentages are taken over 128-bit figures built from the same rows, so a total cut at the limit does not turn 50% into 100%; a share that is not all or nothing is still never 0% or 100%.
- **Markers in the proof.** `ai_assisted_merges` reads the marker from the entry's payload in the file, which only an entry accepted with export policy `include` carries. A merged PR kept as a digest stub is listed in `merged_prs` but its marker is unrecorded, so it is in neither number of the share and is counted in `unrecorded`. The definition says so. The proof vectors are synthetic and were not affected, so they were not regenerated; `tools/verify_proof.py` passes on all of them.
- **`agent_entries` in the proof counts listed items only,** so it can differ from `cadence summary`, which counts every accepted entry in the range (excluded and digest ones included). The definition says so.
- **Spool backlog.** A spool folder that is there but cannot be listed, and a spool file that cannot be read, give `unknown` (a warning) instead of `ok`. A folder that is not there is still an empty spool. With some files readable the detail also says how many lines wait in the others.
- **`profile.backfillFrom`** is held to the same floor as a backfill job and `--since`: 2000-01-01. An earlier date is a config error, "profile.backfillFrom: must not be before 2000-01-01".

## Planner decisions from the Mac spikes (2026-11-01)

- S3: the ad-hoc spike app never appeared in Notifications settings. Notifications are designed around a plain notification whose click opens the capture bar; the inline text-input reply of section 4.7 is an upgrade, checked in the real signed app under T3.11 and dropped if it does not work there.
- S7: Apple Intelligence does not run on the work Mac. The deterministic parser is the only capture path, and Foundation Models stays in the "Later" list.
- S4: lock, unlock, sleep and wake notifications all arrive in the sandbox, and idle time for any input (`CGEventType(rawValue: ~0)`) works there. The presence adapter uses any input, not `.null` (V6). S5 and S6 pass, so the hotkey and the store-changed Darwin notification need no fallback.
- S8: `#Preview` needs Xcode's macro plugins, so previews stay out of code that the Command Line Tools build compiles.

## Planner decisions for the day story, T3.24 (2026-11-02)

- `DayStory` takes plain counts and flags read by the caller, so it stays pure and testable without a store. The usual range arrives as `usualByNow` from the rhythm model (T3.23).
- Sick leave is declared leave labelled "sick", which is what the panel's Day off menu writes. The ledger's day kinds do not change.
- Past the learning period with no range (no counted day yet in the window) the day reads "Right in your rhythm." with "N items logged so far." and makes no comparison.
- A late addition is named as an item, not by its kind: "One item arrived after your wrap-up."
- `CopyRules.allows` checks whole words, so "dismissed" or "scored" inside a title never trips "missed" or "score".

## Planner decisions for the findings engine, T4.5 (2026-10-31)

Reviewed cold on 2026-11-02. Slip reasons are free text in the ledger, so the plan finding names only the fixed chips of T3.28 and counts anything else as "for another reason": a typed reason never reaches the sentence. "Nothing beyond the plan was logged." is written only when no kind beyond the plan exists in the range (meetings led, decisions challenged, mentoring, incidents, discussions, initiatives, docs written); otherwise a range with none of the presence kinds gets no presence finding. The trend reads "rose across 3 weeks", since three points are two rises.

Sections 5.4 and 5.5 give the recap sentences and two rules (no "best since", no trend from two points) but no thresholds, cap or order. These fill the gaps.

- **Templates.** Reworded on 2026-11-02 to the recap frames of The Coach (section 5.5): delivery ("You merged 4 PRs, reviewed 12 and raised 3 discussions."; the range is the recap caption, so no "Week 44" prefix), plan ("78% of your plan got done. 14 of 18 tasks. 3 slipped: 2 reprioritised and 1 blocked."), beyond the plan ("Led 2 meetings, challenged 1 decision and mentored twice. On call Tue to Wed, with 1 incident.") and AI ("19 Claude Code sessions. Across 4 of 4 workdays. 2 of your 4 merged PRs were AI-assisted."), plus review cadence ("You reviewed on 18 of 19 workdays this month."). Three more answer section 5.4: the plan trend, the self-started share ("3 of 14 merged PRs were self-started.") and day shape ("Your usual day ran from 09:53 to 17:49, over 19 days.", where usual is the median). The recap's delivered titles are a list, not a computed figure, and are left to T4.6. "1 was dropped" is not written yet: the summary does not count dropped tasks.
- **Order, cap and ties.** Each kind gives at most one finding, always in one fixed order: delivery, plan, plan trend, presence, AI, self-initiated, day shape, review cadence. There is no ranking, so no tie to break and no cap beyond the eight kinds. Slip reasons are listed by count, largest first, then by name; "unspecified" reads "with no reason".
- **Unknown is not zero.** A clause whose figure is null is left out, and a finding with no known figure is not written. A known zero is stated ("raised 0 discussions", "None slipped.", "Nothing beyond the plan was logged."). Beyond the plan leaves out parts with a count of 0. Review cadence counts reviews on counted workdays over counted workdays; "Claude Code on" uses AI days over AI counted days, as the review sentence does. Merged PRs with no recorded AI marker are named: "2 of your 3 merged PRs with a recorded marker were AI-assisted."
- **Trend.** One trend only: plan done by Monday-based week, clipped to the range, over counted workdays. A week is a point when it has at least 5 counted planned tasks; a thinner week or a week with none is no point and ends the run. Only the run that ends at the latest week counts. It needs at least 3 points, each step strictly the same direction (an equal step ends the run), and at least 5 percentage points between its first and last point. Text: "Plan done rose across 3 weeks: 80%, 89%, 92%." Weekly percentages use the same rounding as every other share.
- **On call.** Days in range whose day row is marked on call, known only when entries are. One run of consecutive days reads "Tue to Wed" when the range lies in one week and "27 to 28 Oct" (or "30 Oct to 1 Nov") otherwise; days that are not consecutive read "on 3 days". Incidents follow on call ("On call Tue to Wed, with 1 incident."), or read "Handled 2 incidents." with no on call.
- **Copy guard.** `Findings.lint` rejects "best since" in any case and anything `CopyRules` rejects (en and em dashes, "productivity", "score", "missed", "you failed"); a finding that fails it is dropped, and a test runs it over every finding the October seed produces for the week, month, cycle, one custom range and every single day.
- **Where findings appear.** `Summary.findings`, so `cadence summary` (human, under "Findings" after the headline; "Findings: none for this range." when there are none) and `--json` (`findings`: kind, text and the figures the text states), and the MCP `summary` tool and week resource through the shared summary. The proof file is unchanged: section 12.1 has no findings, so no vectors were needed.

## Planner decisions for the app read and write paths, T3.29 and T3.30 (2026-11-02)

- Each load reads `Journal.dayContext` inside one read transaction on a fresh read-only connection: the day view, whether the plan is committed, the plan and the carried tasks kept apart, found entries, late additions, AI sessions, the inbox count, the rhythm, the last unsealed workday and the wrap-up reminders. `DayStory` is told from it, with what only the app knows (paused, a source behind, an import, setup) added on top. Every surface reads that one story.
- Before the plan is committed, carried tasks wait outside it and tasks added by hand form it. Once committed, every task of the day is the plan. The morning sheet drops the carried tasks the person did not pick.
- The last workday is reported only when it is unsealed, had an entry or a task, and lies after the ledger began.
- A store that does not exist yet is a first run, not a store problem. `StoreFailure.kind` sorts every other failure into the screens of section 4.6; a write the ledger refused is `invalid`, never a store problem.
- `AppWriter` is the app's only writer: one actor, one connection opened on first use with the ledger projector, folders made 0700 as the CLI makes them, and the store-changed notification posted after every commit. A failed I/O drops the connection so the next write reopens it.
- The panel's Undo (section 4.2) holds a tick for its 4 seconds and writes it when they pass, when the panel closes or when the app quits, because the ledger has no reopen event and adding one would change the proof format. If that write fails, the row returns to open and the failure shows.

## Planner decisions on search, logs and the docs (2026-11-02)

- MCP `query` search covers titles and tickets only, never private notes, so an agent cannot learn which entries have a note containing a word. The CLI and the app, which are the person's own surfaces, also search notes (T3.27).
- The app's own system log (`os.Logger`, subsystem the bundle id) records timings and error codes only, never titles, notes or any entry text (T3.34). Collector stderr is separate: it goes to `logs/` and can hold host names, as the T2.7 decision says.
- Claude Code is set up with `cadence setup claude-code --print` and `--apply` (section 9.1); section 14.5 now says so.
- SECURITY.md covers the threat model only; the employer-policy question of section 17 is a private decision and stays out of public docs.

## Planner decisions from the phase audit (2026-11-02)

- Once a wrap-up reminder has passed on an unsealed day with a plan, the panel offers Wrap up even when a state that outranks wrap-up due leads (still learning, first sync, a source behind, on call, the last workday open or closed). Days off, paused, first run and a store problem still offer nothing.
- Reminder times are read from the day boundary, so between midnight and 04:00 the evening's reminders have still passed.
- The last workday leads the day only until today has a committed plan, a plan task or an item; its card stays in Today while its grace window is open.
- A carried task left unpicked in the morning plan is dropped on today but is not part of today's plan; the summary still counts it as dropped, which is what plan accuracy measures.
- "Capture paused" is a file in `state/` that the collector agent reads, so collectors stop with presence, and a relaunch keeps the pause.
- In-app sounds: `capture.saved` after a line you log, `day.start` when the day's first activity appears, `agent.logged` when an agent's entry appears, each once per moment.
- Open for the presence engine (★): after a zone change, a night owl past the old zone's 04:00 starts the next day by the previous day's own zone, and that day row is created in the old zone. The soak records it as a known issue. The writer itself now follows a config change at once.
- Insights for a whole cycle read in about 200 ms on a 12-month store (the weekly series runs one summary per week). They load off the main thread, show skeleton lines past 100 ms (section 6.5), and are cached by data version, so this is accepted; §8.6 sets no Insights budget.
- First sync running is a collector backfill of more than one 7-day chunk. The scheduler writes `state/backfill.json` (months, workdays done, workdays in range, last update) after each chunk and removes it at the end; the app reads it on each store change and every 5 s while one runs. A file not updated for 15 minutes is a run that died. A CSV import is one transaction, so it never shows as a first sync.
- Increase Contrast: hairlines (`line`) strengthen through the colour token, the usual-range band and hatched bars gain an edge, and the menu-bar mark uses its own palette. Tempo gets no outline, which the character's no-outline rule forbids; its coral body already contrasts with every colour world's ground.

## Planner decisions on kind dots and contrast (2026-11-03)

- Work-colour dots keep the hexes of section 6.2. In the light theme, and in both themes under Increase Contrast, a dot gains a hairline edge in `ink`, which carries the mark at 3:1 or more on `card`, `canvas` and `track`; the colour inside still names the kind beside its word. The dark theme needs no edge, since every dark work colour passes 3:1 on its grounds.

## Planner decisions for the narrower Today snapshots, T4.1 (2026-11-03)

- Every day state of section 5.2 (the 23 drawn at full width) is also snapshotted at 900, 680 and the compact 420, in light and dark. Section 4.6 designs three widths and a compact layout, and a state that only holds at full width has not been checked.
- The narrower widths are recorded at 1x only; full width keeps 1x and 2x. The 23 states at three widths in two themes are 138 files at 1x and would be 276 at both scales, and a layout does not depend on pixel density.
- File names follow the existing ones: `<state>-<width>-<light|dark>@1x.png`, with width `full`, `900`, `680` or `compact`. In rhythm at 680 and compact keep their names and lose their 2x pair.
- T4.1's line in docs/PLAN.md already says "at three widths and compact", so it is unchanged.

## Planner decisions for the app icon, T4.19 (2026-11-03)

- The app icon is App/Cadence.icon, an Icon Composer document compiled by actool in scripts/bundle.sh into Assets.car and Cadence.icns.

## Planner decisions for reopening a sealed day, T4.18 (2026-11-03)

- A day can be reopened at any time, however old, and sealed again. The ledger stays append-only: `day.reopened` is one more event with the payload `{day}` and no free text, written only by the app and the CLI. The ledger refuses it from any other actor, and no MCP tool reopens a day.
- Any seal counts for the streak, the summary, Insights and the proof, whenever it was made. A seal made after the grace window used to be kept but not counted; that rule is gone, and a late seal of a gap day joins the runs on both sides of it. The grace window now only decides when an unsealed day stops being open: for reminders, "yesterday still open" and late leave or holiday declarations, and for when an unsealed day breaks the streak. A reopened day that is not sealed again breaks the streak once its window has closed, until it is sealed again.
- The projection reads a day as sealed by the first `day.sealed` after its last `day.reopened`; a seal while the day is sealed still changes nothing. This supersedes "A day's first seal stands" (2026-10-30). Reopening clears the "after wrap-up" marks of the day's entries. A plan task's mark is derived from the day's seal event, so it clears with the seal and nothing else is stored.
- The proof uses the current seal for `seal_ev`, `sealed_at` and `edited`, and lists `day.reopened` events in the chain with their payloads. The proof format is unchanged (`cadence.proof/1`): the verifiers only check that `seal_ev` is a `day.sealed` of that day and that `sealed_at` matches its time, so the verifiers, the `days` shape and the existing vectors are untouched. `valid-reopen.json` is a new vector: seal, edit, reopen, change, seal again.
- This supersedes the sentence of 2026-11-02 that the ledger has no reopen event and that adding one would change the proof format. A day now has one, and the format did not change. A task tick still has no reopen event, so the panel's Undo (section 4.2) holds the tick for its 4 seconds as before.
- An older binary ignores `day.reopened` as an unknown type, so it would still show the day as sealed. The app, the CLI and the MCP server ship together.
