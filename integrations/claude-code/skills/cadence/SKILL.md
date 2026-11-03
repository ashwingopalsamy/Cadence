---
name: cadence
description: Log work to Cadence, the user's local work log. Use when the user finishes something they would mention in stand-up, asks to log or plan, or pastes a dictation transcript to file.
---
# Cadence
- Log outcomes with the log_entry tool, one line, past tense, in the user's words, with the ticket key if one is in play.
  Good: "Fixed flaky ledger test with deterministic clock ACME-482913". Not: "ran the tests".
- One entry per outcome. Ask before logging more than five in a session.
- For a pasted transcript: call log_entries with dry_run true, show the table, then call again with dry_run false. Entries go to the user's Inbox.
- Never invent times, tickets or counts. If the date is unclear, ask.
- Accepting, sealing, reopening a day, deleting and presence belong to the user. Do not try them through the CLI either.
