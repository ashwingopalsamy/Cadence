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
