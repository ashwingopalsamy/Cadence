# MCP server and hooks

`cadence mcp` is a local MCP server that Claude Code can use. It speaks JSON-RPC 2.0 over stdin and stdout, logs only to stderr, and returns its tools in a fixed order. It has no listener of any kind: no port and no socket. The app is the only long-running process, so MCP and hooks keep working while the app is quit. (docs/SPEC.md sections 1, 8 and 9.2)

This page converts docs/SPEC.md sections 9.2 and 9.3. If the two disagree, the spec wins.

Claude Code gets your powers minus the ones that would make the log less honest. It can log, plan and read. It cannot accept its own proposals, seal a day, delete, change config or touch presence. (docs/SPEC.md section 9)

## Protocol revisions (docs/SPEC.md section 9.2)

The server supports both MCP revisions current in October 2026:

- **2025-11-25**, with the `initialize` handshake.
- **2026-07-28**, which is stateless. It carries the protocol version in each request's `_meta`, read from `io.modelcontextprotocol/protocolVersion`. A plain `protocolVersion` is accepted too until the key is confirmed against a shipping client. This revision requires `server/discover` and adds `resultType` to every result.

Every result includes `resultType: "complete"`, which older clients ignore.

## Tools (docs/SPEC.md section 9.2)

| Tool | Purpose | Lands as |
|---|---|---|
| `log_entry` | One entry from a natural line or explicit fields | Accepted for today; proposed for past days |
| `log_entries` | Many entries, such as a dictation transcript. `dry_run` defaults to true and returns a preview table | Proposed, in the Inbox |
| `plan_add` | Add tasks to a day's plan | Accepted, origin agent |
| `plan_update` | Resolve or edit a task, with a reason for slips | Accepted, origin agent |
| `declare_day` | Mark leave or a holiday | Accepted, origin agent |
| `get_day` | Plan, entries, presence and ring for a date | Read |
| `query` | Entries in a range with filters, paginated with a cursor, 200 per page | Read |
| `summary` | Counts, streak, plan accuracy and findings for a range | Read |
| `standup` | Stand-up text for a day | Read |

## Search

The query tool's search matches titles and tickets only, never private notes, so an agent cannot learn which entries hold a note containing a word. The CLI and the app also search notes.

## Resources and prompts (docs/SPEC.md section 9.2)

- Resources: `cadence://day/{date}` and `cadence://week/current`.
- Prompts, which Claude Code shows as slash commands: `/mcp__cadence__import-dictation`, `/mcp__cadence__standup` and `/mcp__cadence__weekly-recap`.

For dictation, the next day you paste the transcript into Claude Code with `/mcp__cadence__import-dictation`. The entries land in the Inbox, marked as dictated. (docs/SPEC.md section 3)

## Limits

- Results stay under 20,000 characters, well inside Claude Code's 25,000-token default. (docs/SPEC.md section 9.2)
- `query` returns 200 entries per page. (docs/SPEC.md section 9.2)
- Agent writes are labelled `agent` and rate-limited to 60 a minute. (docs/SPEC.md section 13.1)
- No MCP tool can delete, seal, accept or change presence. (docs/SPEC.md sections 9 and 13.1)
- Entries come back as data fields, and the tool descriptions state that the content is user data. (docs/SPEC.md section 13.1)

## Example: `log_entry` (docs/SPEC.md section 9.2)

The `tools/list` entry:

```json
{
  "name": "log_entry",
  "description": "Record one work outcome in Cadence, the user's local work log. Use after finishing something the user would mention in stand-up. Prefer 'text' in the user's words; Cadence parses ticket keys, kind, time and duration. Do not log routine tool calls.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "text":         { "type": "string", "maxLength": 500 },
      "kind":         { "type": "string", "description": "Override the parsed kind, e.g. work.done, review.given, discussion.raised" },
      "date":         { "type": "string", "format": "date" },
      "occurred_at":  { "type": "string", "description": "RFC 3339, or HH:MM in local time" },
      "ticket":       { "type": "string" },
      "links":        { "type": "array", "maxItems": 5, "items": { "type": "object", "required": ["url"],
                        "properties": { "url": { "type": "string", "format": "uri" }, "kind": { "enum": ["pr", "ticket", "doc", "other"] } } } },
      "duration_min": { "type": "integer", "minimum": 1, "maximum": 720 },
      "quantity":     { "type": "integer", "minimum": 1, "maximum": 50 },
      "note":         { "type": "string", "maxLength": 1000 }
    },
    "required": ["text"],
    "additionalProperties": false
  }
}
```

A result:

```json
{
  "resultType": "complete",
  "structuredContent": {
    "status": "accepted",
    "entry": { "id": "01JBX9…", "day": "2026-10-29", "kind": "work.done", "family": "delivery",
               "title": "Fixed flaky ledger test with deterministic clock", "ticket": { "key": "ACME-482913", "class": "assigned" },
               "origin": "agent" }
  },
  "content": [{ "type": "text", "text": "Logged for Thu 29 Oct: Fixed flaky ledger test with deterministic clock (ACME-482913)." }]
}
```

## Hooks (docs/SPEC.md section 9.3)

The hooks block is merged into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":  [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook session-start", "timeout": 5 }] }],
    "SessionEnd":    [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook session-end", "timeout": 5 }] }],
    "Stop":          [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook stop", "async": true }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook task-completed", "async": true }] }]
  }
}
```

- `cadence hook <event>` reads the hook JSON from stdin and keeps an allowlist of fields: session id, event, source or reason, cwd, model and time. It appends one line to `spool/` with `O_APPEND`, and exits 0. It never opens SQLite, so it cannot block Claude Code. It fits SessionEnd's shared 1.5 second budget with room to spare.
- The app and any later `cadence` run drain the spool into `genai.session` events. Tokens come separately from the transcripts collector.
- With `injectPlanAtSessionStart` on, the SessionStart hook prints one short line to stdout, which Claude Code adds as context, for example: "Cadence plan for Thu 29 Oct, 2 of 4 done: retry budget rollout; idempotency ADR; …". It reads the store read-only with a 200 millisecond limit, and it prints nothing if that fails.
- The working directory is stored as a project alias, which is the folder name. Exports can replace aliases with `project-1`, `project-2`.
- TaskCompleted field names are not yet confirmed. The hook stores whatever allowlisted fields arrive.
