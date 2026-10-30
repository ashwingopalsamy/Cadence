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
