# Collectors

A collector is any command that prints one envelope of JSON lines. Cadence runs it, validates every record, dedupes by source ref and writes what passes with origin `collected`. Network access lives in tools you already trust, like `gh` and `curl`, never in Cadence. (docs/SPEC.md section 10)

This page converts docs/SPEC.md sections 10 to 10.7. If the two disagree, the spec wins.

## Envelope (docs/SPEC.md section 10.1)

An envelope is UTF-8 JSON lines. The first line is the header. Each line after it is one record.

```json
{"cadence":"envelope/1","collector":"github","run":"01JBY0M8R2","generated_at":"2026-10-29T16:10:02+05:30","window":{"since":"2026-10-26","until":"2026-10-29"}}
{"type":"item","source_ref":"github:PR_kwDOAbc123:merged","kind":"pr.merged","occurred_at":"2026-10-29T16:02:11+05:30","title":"ACME-482913 Ship retry budget for capture path","links":[{"kind":"pr","url":"https://git.example.com/acme/ledger-core/pull/412"}],"attrs":{"repo":"acme/ledger-core","number":412,"additions":184,"deletions":37,"ai_assisted":true}}
{"type":"item","source_ref":"github:PRR_kwDOAbc777","kind":"review.given","occurred_at":"2026-10-29T11:20:40+05:30","title":"ACME-000000 Idempotency keys for refunds","links":[{"kind":"pr","url":"https://git.example.com/acme/refunds/pull/88"}],"attrs":{"repo":"acme/refunds","number":88,"state":"APPROVED","comments":4}}
{"type":"genai.usage","source_ref":"claude-code:2026-10-28:model-a","day":"2026-10-28","tool":"claude-code","model":"model-a","sessions":5,"requests":212,"tokens":{"in":48210,"out":96115,"cache_read":8120400,"cache_write":402118}}
{"type":"presence.span","source_ref":"powerlog:2026-10-05T09:12","start":"2026-10-05T09:12:00+05:30","end":"2026-10-05T19:40:00+05:30"}
{"type":"leave","source_ref":"leave:2026-10-23","day":"2026-10-23","kind":"leave_planned","label":"Planned leave"}
```

| Record | Required | Optional | Becomes |
|---|---|---|---|
| `item` | source_ref, kind, title, occurred_at or day | ticket (otherwise parsed from the title), links, attrs, duration_s, quantity, tags | `entry.created`, later `entry.updated` |
| `genai.usage` | source_ref, day, tool | model, sessions, requests, tokens.in, out, cache_read, cache_write, cost_micros, estimated (true when the cost came from a price table) | One `genai_usage` row for that source |
| `presence.span` | source_ref, start, end | none | Fills gaps only. Never overrides spans the Mac observed |
| `leave` | source_ref, day, kind | label | `day.declared`, only if you have not declared that day yourself |

### Validation

- UTF-8, one JSON object per line, at most 10 MB and 20,000 records. Unknown record types and unknown top-level fields are rejected.
- Times are RFC 3339 with an offset. `day` is `YYYY-MM-DD` in your profile zone. Numbers are non-negative integers, and money is micro-dollars.
- Titles lose control characters and are cut at 200 characters. `attrs` is flat, holds strings, integers and booleans, and stays under 2 KB.
- Links must be `https`, or `http` on a host in `config.hosts`. Anything else, `javascript:` included, is dropped with a warning.
- A bad record is skipped and counted in `ingest.run`. When any record is skipped, the whole envelope is kept in `inbox/` so you can see why.

### Idempotency and ownership

- The same `source_ref` with the same content writes nothing. Changed content writes `entry.updated` with actor `collector:<name>`.
- A collector only edits entries it created, and only fields you have not touched. Once you edit a title, that field is yours, and later collector changes to it are ignored.
- Collectors never delete. A PR that was opened and later closed keeps its `pr.opened` entry. You can dismiss it.
- Collected entries arrive accepted, because each carries a link to its source. If the day is already sealed, they are marked **after wrap-up** and listed under "Since you sealed".

## Runner (docs/SPEC.md section 10.2)

| Rule | Detail |
|---|---|
| When | `cadence collect run --due` from the agent every 15 minutes, at login, and whenever the app drops a job in `jobs/` ("Run now", backfill). Each collector sets `every` or `at` |
| Window | `since` is the last successful `until` minus 3 days, so late merges and edited reviews are caught. `until` is now. Backfill from `profile.backfillFrom` runs in 7-day chunks |
| Execution | An argv array, never a shell. The first element is an absolute path. `{since}` and `{until}` are replaced inside argv elements only. stdin is closed and the working directory is the Cadence folder |
| Environment | `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `LANG`, `TZ`, plus the keys listed in the collector's `env`. Nothing else is inherited |
| Limits | 60 s, then SIGTERM, then SIGKILL after 5 s. stdout is capped at 10 MB. The last 64 KB of stderr goes to `logs/` |
| Approval | The first time a command runs, or after it changes, the app shows the exact argv and env keys and asks. It stores a digest of what you approved, and the agent refuses anything else |
| Config safety | `config.json` must be owned by you and mode 0600. Otherwise collectors are disabled and `cadence doctor` says why |
| Failure | A non-zero exit, a timeout or an unreadable header writes nothing except an `ingest.run` with the error. The menu-bar mark shows a source behind only after three failures in a row for the same collector |
| Concurrency | One run per collector at a time, guarded by a lock file. Runs are serial in v1 |
| Jobs | The app writes a file ending `.json`, owned by you with mode 0600, into `jobs/`: `{"job":"run","name":"github"}` or `{"job":"backfill","name":"github","from":"2026-10-01"}` (`from` is optional). The agent handles files oldest first and deletes each one once it ran or was refused. A file that is anything else is rejected and deleted. A job that met a busy lock stays for the next run. Windows are whole days (YYYY-MM-DD) in the profile zone. A collector with neither `every` nor `at` runs only when asked by name |

## GitHub (built in) (docs/SPEC.md section 10.3)

`cadence collector github --since A --until B` runs `gh api graphql` with `GH_HOST` from the collector's env. That works against GitHub Enterprise Server and github.com, and it reuses the login `gh` already has. Cadence never sees a token.

Contributions and reviews come from a paged contributions query, 100 at a time. Merged PRs come from search, because contributions are keyed by creation date. The queries are in docs/SPEC.md section 10.3.

| On GitHub | Entry | Time | Notes |
|---|---|---|---|
| A PR you opened | `pr.opened` | createdAt | Drafts included, `attrs.draft` |
| A PR of yours merged | `pr.merged` | mergedAt | From search, deduped against `pr.opened` by PR id |
| A review you submitted | `review.given` | submittedAt | One entry per PR per day. `attrs.reviews` counts repeats and `attrs.comments` counts comments. Reviews on your own PRs are skipped. The PR author's login is used for that check and then discarded |

- **Tickets.** `tickets.pattern` runs over the first `titleWindow` characters of the title. A number matching `selfInitiated` (all zeros by default) makes the PR self-initiated and puts it in the Initiative family. No match means no ticket, shown as "untracked" without judgement.
- **AI-assisted.** True when the PR body contains one of the configured `ai.markers`, matched case-insensitively. The default markers are listed in docs/SPEC.md section 10.3. The body is read in memory and dropped. Only the boolean is stored.
- **Needs a check.** Whether contribution lists include private and internal repositories on your GitHub Enterprise Server version is not yet verified (docs/SPEC.md section 10.3). If they do not, the fallback is search: `is:pr author:LOGIN created:A..B` and `is:pr reviewed-by:LOGIN updated:A..B`, then the viewer's reviews per PR.

## Claude Code transcripts (built in) (docs/SPEC.md section 10.4)

The collector reads `~/.claude/projects/*/*.jsonl` incrementally, remembering each file's size and modification time. Its decoder reads only these fields, so nothing else is parsed into memory as data: `message.id`, `message.model`, `message.usage` (input, output, cache creation and cache read tokens), `timestamp` and `sessionId`.

- Streaming can write several lines for one message. Lines are deduplicated by `message.id`, keeping the one with the most output tokens. This is not yet verified on a Mac (docs/SPIKES.md, spike S9).
- Totals are computed per local day and model, with sessions (distinct session ids) and requests (distinct message ids). They are emitted with source ref `claude-code:DAY:MODEL`. A re-read updates the same rows.
- Cost is not computed unless you keep a price table in `config.genai.prices`. The table maps a model name to `{"in", "out", "cache_read", "cache_write"}`, each a whole number of micro-dollars per million tokens. A key left out counts as 0, and a model with no entry gets no cost. Cost is computed with integer arithmetic only, and a cost from the table is labelled estimated. Your endpoint's cost always wins.
- Run it as `cadence collector claude-code-transcripts --since DAY --until DAY [--name NAME] [--projects-dir DIR]`. Per-message figures from every file are cached in `state/`. Unchanged files are not read again, each day's totals stay complete, and totals survive Claude Code deleting old transcripts.

Claude Code deletes transcripts older than `cleanupPeriodDays`, which is 30 by default. Set `"cleanupPeriodDays": 400` in `~/.claude/settings.json` to keep them longer. Once Cadence has collected a day, its totals live in the ledger, and later deletion no longer matters.

## Usage endpoint (docs/SPEC.md section 10.5)

The endpoint is just a command, `curl` in the example config (docs/SPEC.md section 7.4), and its output is not an envelope. A map file turns any JSON or CSV into `genai.usage` records. If the endpoint needs a token, `curl` reads the header from a 0600 file with `-H @/Users/you/.config/cadence/usage.header`, so the token never enters Cadence or its config.

A map is written on your Mac from a real sample by Claude Code, and it is never committed:

```json
{
  "cadence": "map/1",
  "input": "json",
  "produces": "genai.usage",
  "records": "$.data[*]",
  "fields": {
    "day":                { "path": "$.date", "format": "yyyy-MM-dd" },
    "tool":               { "const": "claude-code" },
    "model":              { "path": "$.model", "default": "*" },
    "requests":           { "path": "$.request_count" },
    "tokens.in":          { "path": "$.input_tokens" },
    "tokens.out":         { "path": "$.output_tokens" },
    "tokens.cache_read":  { "path": "$.cache_read_tokens", "default": 0 },
    "tokens.cache_write": { "path": "$.cache_creation_tokens", "default": 0 },
    "cost_micros":        { "path": "$.cost_usd", "scale": 1000000 }
  },
  "source_ref": "genai-endpoint:{day}:{tool}:{model}"
}
```

- **Paths** are a small JSONPath subset: `$`, `.key`, `['key']`, `[n]` and `[*]`. There are no filters and no scripts. An index has no leading zeros.
- **Formats** for days and times are `yyyy-MM-dd`, `iso8601`, `epoch-s` and `epoch-ms`, converted in your profile zone. An epoch time must fall before the year 10000, so milliseconds read as seconds are refused.
- **Scale** is exact decimal arithmetic on the text. So `"0.4213"` dollars becomes 421300 micro-dollars with no float in between. The scale is 10, 100 and so on, up to 10^12. Leave it out for exact values. Digits finer than one unit are rounded half away from zero. Number fields without a scale must be whole numbers. A negative number is refused before it is rounded, so `-0.0000004` is never stored as zero.
- **Blank values.** A value that is missing, null, empty or only spaces counts as missing, so the field's `default` applies. A boolean may be written with spaces around `true` or `false`.
- **Checked on load.** Every `const` and `default` goes through the conversion of its field when the map loads. An `attrs.<key>` key must be 1 to 64 characters with no control characters. So a mistake fails once, with its field name, and not on every record. A map file is at most 256 KB.
- **source_ref** is the template filled in one pass. Each `{field}` becomes that field's converted value, and a value is never read as a template again. In a substituted value, `%`, `:`, `{` and `}` are written as `%25`, `%3A`, `%7B` and `%7D`. So `{a}:{b}` gives different refs for `a=x:y, b=z` and `a=x, b=y:z`. Text in the template itself is used as written.
- **Limits.** The input is at most 10 MB and 20,000 records, counted before any record is mapped. A CSV has at most 256 columns.
- **Bad records.** A record that cannot be mapped is left out and counted as skipped in `ingest.run`, with its reason. The mapped envelope in `inbox/` no longer holds the rows that were left out, so the command's own output is kept beside it as `inbox/<collector>-<run>.raw`, readable only by you. The note next to it names that file. A document that cannot be mapped at all writes a failed `ingest.run` and keeps its output the same way. Writing these files is best effort, like the rest of `inbox/`.
- **CSV** with `"input": "csv"` turns each row into an object keyed by its header, so `$.output_tokens` reads that column. Quoting follows RFC 4180. A quote opens a field only at its start, and only a comma or a line break may follow a closing quote. Anything else refuses the file, with its line number. A lone carriage return counts as a line break.

## Importing your data (docs/SPEC.md section 10.6)

1. Export from your existing app to a file (CSV or JSON).
2. Ask Claude Code on the Mac to write `maps/acme-app.json` from the first rows. The real format never leaves your machine or reaches the repository.
3. Dry run, then import. Cadence records the rows with source `import:acme-app`. That source is what marks them as imported, since usage rows carry no backfilled flag. Cadence does not keep the file, except that rows it could not read are kept in `inbox/`, as in section 10.1.

```sh
cadence import genai ~/Downloads/acme-usage.csv --map maps/acme-app.json --dry-run
map acme-app (map/1, csv) · 31 rows → 21 days · tool claude-code
day         requests   tokens out   cost       other sources
2026-10-01       118       51,302   $14.21     none
2026-10-02         0            0   $0.00      none        holiday
2026-10-05       164       77,940   $19.87     none
…
2026-10-28       212       96,115   $26.40     transcripts 95,880 (0.2% apart)
total          3,410    1,602,551   $431.06
dry run: nothing written. Run again without --dry-run to import.
```

**One source per day, never summed.** For each day and tool, the projection uses the first available of endpoint, transcripts, then import (`genai.priority` in config). The others stay visible in the day's detail. If they disagree on output tokens by more than 15%, the day carries a small mismatch mark.

## Writing your own (docs/SPEC.md section 10.7)

This example reads on-call shifts from a local file, one `date,role` line per shift.

```sh
#!/bin/sh
# prints a Cadence envelope/1 for shifts listed as "2026-10-12,primary" lines
set -eu
printf '{"cadence":"envelope/1","collector":"oncall","generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while IFS=, read -r day role; do
  printf '{"type":"item","source_ref":"oncall:%s","kind":"oncall.shift","day":"%s","title":"On call (%s)"}\n' "$day" "$day" "$role"
done < "$HOME/.config/cadence/oncall.csv"
```

Register it with `"command": ["/bin/sh", "/Users/you/.config/cadence/collectors/oncall.sh"]`, approve it once, and run `cadence collect run --name oncall`. The repository ships this script and a Python twin under `examples/collectors/`.
