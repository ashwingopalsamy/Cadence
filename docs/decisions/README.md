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
