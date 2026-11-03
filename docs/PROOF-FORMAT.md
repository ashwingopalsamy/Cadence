# The proof file

A proof file is one JSON file that carries the hash chain, the days, the witnesses and its own verifier. It shows that the log is consistent and in order, that every item matches its own events, and that each item is honestly labelled, with links to check against the source. It does not prove that self-reported work happened, and the file says so.

This page converts docs/SPEC.md sections 12 to 12.4. If the two disagree, the spec wins.

## Three properties

- **A chain that holds.** Every event links to the one before it. Change, drop or reorder one and the verifier names it.
- **Links to check.** Collected items point at their source, such as a pull request. A reviewer opens a few links on the company network, and nothing leaves that network.
- **Labels that do not move.** Observed, collected, agent and self are fixed at creation. Edits after sealing are counted, not hidden.

## The file (docs/SPEC.md section 12.1)

The top level of a proof file has this shape. Arrays and long values are shortened.

```json
{
  "format": "cadence.proof/1",
  "generated_at": "2026-10-30T09:12:00+05:30",
  "generator": "Cadence 0.4.0",
  "subject": { "name": "Your Name", "role": "Software Engineer" },
  "range": { "from": "2026-10-01", "to": "2026-10-29", "tz": "Asia/Kolkata" },
  "how_to_verify": "…plain-language steps, shown in 12.2…",
  "verifier_py": "…the script in 12.3, verbatim…",
  "summary": {
    "sealed_workdays": { "value": 19, "of": 19, "before_ledger": 0, "definition": "Workdays that are wrapped up, whenever the wrap-up was made, counted from the day the ledger began; …" },
    "plan_done":       { "value": 61, "of": 73, "after_seal": 2, "definition": "Planned tasks on counted workdays marked done by the end of their day; …" },
    "merged_prs":      { "value": 14, "assigned": 11, "self_initiated": 3, "definition": "Merged PRs authored, from the GitHub collector; …" },
    "reviews":         { "value": 47, "definition": "Review entries, one per PR per day" },
    "ai_days":         { "value": 17, "of": 19, "definition": "Counted workdays with an AI coding session or usage record, from the first day any AI source recorded" },
    "ai_assisted_merges": { "value": 9, "of": 14, "percent": 64, "unrecorded": 0, "definition": "Merged PRs listed in days that recorded an AI marker, out of listed merged PRs with a recorded marker; …" },
    "agent_entries":   { "value": 31, "definition": "Items listed in days with origin agent, which is self-reported; …" },
    "review_sentence": { "text": "AI on 17 of 19 workdays. 64% of merged PRs were AI-assisted. Your agent logged 31 entries you accepted.", "definition": "Written from the figures beside it and computed by Cadence; …" },
    "private_events":  { "value": 3, "definition": "Events in range exported as hashes only: private notes and reasons, entries marked digest or exclude, and entries not accepted" }
  },
  "days": [ … ],
  "chain": { "algo": "sha256", "c14n": "cadence-c14n/1", "events": [ … ] },
  "witnesses": [ { "date": "2026-10-28", "code": "3f9ac21e77b01d4e", "where": "stand-up message" } ],
  "checks": ["export_digest", "sequence", "links", "payload_digests", "event_hashes", "references", "witnesses"],
  "export_digest": "sha256 of the canonical file without this field"
}
```

- **Chain.** Every event from genesis to the last one before export, in order. Outside the range, events carry hashes only. Inside the range, payloads are allow-listed: day marks, presence spans, plan tasks, seals, reopenings, witnesses and AI usage carry theirs. Free text that is the owner's own stays hash-only: day notes and focus lines, reason notes, status notes, day labels and collector errors. So does any event type the exporter does not know. Entries carry their payload only when accepted with export policy `include`. Notes default to `digest`. An event belongs to the day its subject names, or to the current day of the entry, task or session it is about. A year is roughly 10,000 to 20,000 events. Items appear both in `days` and in the chain, so expect 10 to 17 MB. How each event is hashed is defined in docs/SPEC.md section 7.3.
- **Redaction is visible.** An item with policy `exclude` is left out of `days`, but its event stays in the chain as hash-only. `summary.private_events` counts every hash-only event in range.
- **Seals.** A day's seal is its current seal, the first `day.sealed` after its last `day.reopened`. Reopenings are listed in the chain with their times, and the seals before them stay in it. Any seal counts for `sealed_workdays`, whenever it was made. `edited` means an `entry.updated` after the current seal. Status changes are not edits.
- **Days before the ledger.** Workdays before the ledger began, such as a backfill, are not counted as unsealed. `sealed_workdays.before_ledger` reports them.
- **Summary.** Every number carries a definition, so an agent reading the file does not have to guess what it means. The verifier recomputes `merged_prs` and `reviews` from the items. The other numbers are computed by Cadence. That includes `ai_assisted_merges`, `agent_entries` and `review_sentence` (docs/SPEC.md section 11). Their figures can still be counted from the file: `origin` on the items, and `attrs.ai_assisted` in each included entry's payload in the chain. A figure with no record is null, and a clause of the sentence with no figure is left out.
- **Witnesses.** These are the codes that ended your stand-up messages. Slack sets those message timestamps, not you, so each one shows that the chain up to that event existed by then.
- **Canonical JSON.** Must match byte for byte across Swift and Python. Keys are ASCII and sorted. `"` and `\` are escaped, as are `\b \f \n \r \t`. Other characters below U+0020 become lowercase `\u00xx`. Everything else is raw UTF-8, `/` included. Integers stay within ±2^53, and there are no floats. Shared vectors in `Tests/Vectors/c14n.json` run in both the Swift tests and the Python verifier inside `make check`.

## How to verify (docs/SPEC.md section 12.2)

The file carries these steps in its `how_to_verify` field.

1. Save `verifier_py` from the file as `verify.py` and run `python3 verify.py THIS_FILE` (Python 3.8 or later, standard library only). PASS means the event chain is complete and in order, and every item, seal, witness and the merged PR and review counts match the events in the chain. The other summary numbers are computed by Cadence from the same days. Their definitions are next to them.
2. Spot-check items with origin `collected`. Open a few links on the company network and compare title, date and state.
3. Match witness codes to the last line of the person's stand-up messages for those dates. A match shows the log up to that point existed at the message's time.
4. Treat origin `self` and `agent` items as self-reported: plausible, not proven. Items flagged `after_seal` were added after that day's wrap-up, and items flagged `edited` were changed after it. A day flagged `declared_late` was marked leave or holiday after its grace window had closed. Plan tasks added after a wrap-up are left out of `plan_done` and counted in its `after_seal`.
5. This file is tamper-evident, not tamper-proof: its owner could have rebuilt the whole chain before the first witness. Witnesses narrow that window. `export_digest` catches accidental edits only, since anyone can recompute it.
6. Private notes and items marked private are in the chain as hashes only. The summary counts them as `private_events`. Hash-only events still show their type, subject and recorded time.

The verifier also requires that a day's `seal_ev` is that day's current seal, the first `day.sealed` after its last `day.reopened`, read from the chain's event types and subjects, which hash-only events keep. A day that cites a seal a reopening superseded fails, and so does a day with a current seal that shows none.

From the CLI (docs/SPEC.md section 9.5):

- `cadence export proof --from --to [-o FILE]` writes a proof file.
- `cadence verify FILE [--recompute]` checks a proof file. `--recompute` also reports what it could not recompute: hash-only events in range, whose payloads stay on the owner's Mac. Items are always re-derived from their events.

## The verifier (docs/SPEC.md section 12.3)

`tools/verify_proof.py` is the verifier. It is about 130 lines of Python 3 that use only the standard library. Each proof file embeds the same script as `verifier_py`, so a file can be checked without this repository. The repository tests the script against a valid and a tampered proof vector (docs/SPEC.md section 14.6).

It recomputes the export digest, the sequence and links of each event, each payload digest and event hash, every item against its events, every seal (the cited event must be the day's current seal), the merged PR and review counts, and every witness. It warns when recorded times go backwards.

From a checkout of the repository:

```sh
python3 tools/verify_proof.py acme.cadence-proof.json
```

A passing run looks like this:

```
cadence.proof/1  2026-10-01 .. 2026-10-29  (Asia/Kolkata)
chain   1912 events, head 4be0c19a2271f3d8
items   214: agent 31, collected 118, observed 22, self 43
links   118 items carry a source link to check
witness 19 codes, all found in chain
warn    event 1204: recorded time goes backwards (clock change?)
RESULT  PASS: the chain is complete and in order, and every item, seal and witness matches it
```

The same file after one title was edited fails like this:

```
cadence.proof/1  2026-10-01 .. 2026-10-29  (Asia/Kolkata)
chain   1912 events, head 4be0c19a2271f3d8
items   214: agent 31, collected 118, observed 22, self 43
links   118 items carry a source link to check
witness 19 codes, all found in chain
FAIL    export_digest does not match the file: it was edited after export
FAIL    event 1388: payload changed after it was recorded
FAIL    2026-10-28: item 1f07a9c2e4b1d530 title does not match its events
RESULT  FAIL
```

## What it proves and what it does not (docs/SPEC.md section 12.4)

| Proves | Does not prove |
|---|---|
| Every item, seal and witness matches the chain, so no title, origin, link or seal was edited after recording without rebuilding the chain | That self-reported work happened |
| No event was changed, dropped or reordered without rebuilding everything after it | That the owner did not rebuild the whole chain before the first witness |
| The log up to each witness existed by that stand-up message | Who wrote it. There are no keys, by design. Identity comes from your manager receiving it from you |
| Which items came from the Mac, a collector, an agent or you, and which changed after sealing | That a collected item is still accurate. That is what the links are for |
| The merged PR and review counts match the items | The other summary numbers, which Cadence computes from the same days |
| Private items are present, counted and unchanged | Their text. A short private title with a guessable shape could be found by trying candidates against its digest. Keep anything sensitive out of titles |
| Nothing about events outside the range beyond their hashes | That their type, subject and recorded time are hidden. Those stay visible so the chain can be checked |

Signing keys were left out on purpose. A key on the same laptop proves only that the laptop signed. It adds key management to an open-source project, and it would read as more certainty than the design has. Witnesses held by a third party do that job better.
