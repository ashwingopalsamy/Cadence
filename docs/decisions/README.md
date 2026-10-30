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
