# Claude Code integration

Two files let Claude Code work with Cadence. The hooks record session and task events, and the skill tells Claude Code when and how to log work. The MCP server is registered with Claude Code. `cadence setup claude-code` does all three for you.

`cadence mcp` speaks MCP over stdin and stdout and Claude Code starts it. It offers nine tools (`log_entry`, `log_entries`, `plan_add`, `plan_update`, `declare_day`, `get_day`, `query`, `summary`, `standup`), two resources (`cadence://week/current` and `cadence://day/{date}`) and three prompts, which Claude Code lists as `/mcp__cadence__import-dictation`, `/mcp__cadence__standup` and `/mcp__cadence__weekly-recap`. Everything it writes is recorded with actor `mcp` and origin `agent`.

## Files

- `hooks.json` is the hooks block. It runs `cadence hook <event>` for SessionStart, SessionEnd, Stop and TaskCompleted. Each call reads the hook JSON from stdin, appends one allowlisted line to the spool and exits 0. The spool write never opens the database, so Claude Code does not wait on the ledger.
- `skills/cadence/SKILL.md` is the skill. It asks Claude Code to log one line per outcome, in your words, and never to invent times, tickets or counts.

Both files are also embedded in the `cadence` binary, so `cadence setup claude-code` works from `~/.local/bin` with no repo around. A test keeps the embedded copies equal to these files byte for byte. After you edit either file, run `tools/embed_claude_code.py` to refresh them.

## Install

Install the binary first. `make install` links it at `~/.local/bin/cadence`. The install script arrives with T3.2, so until then copy the built binary there yourself.

1. See what would change. This prints the hooks that would be merged, the registration command and the skill path, and changes nothing:

   ```sh
   cadence setup claude-code --print
   ```

2. Make the changes:

   ```sh
   cadence setup claude-code --apply
   ```

   `--apply` does three things, and does nothing the second time:

   - It merges the four hooks into `~/.claude/settings.json`. Your other settings and hooks stay as they are, and a hook that already runs `cadence hook <event>` is not added again. If the file exists, it is saved first as `~/.claude/settings.json.cadence-backup` (mode 0600). A file that is not valid JSON is left alone with an error.
   - It registers the MCP server by running `claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp`, with `claude` found on your PATH. Without `claude` on PATH it skips this step and says so. A `cadence` server that is already registered is left alone.
   - It copies the skill to `~/.claude/skills/cadence/SKILL.md`. A different file there is saved as `SKILL.md.cadence-backup` first.

3. Start a new Claude Code session and run `/mcp` to check that `cadence` is connected. Then ask Claude Code to log something you finished today, and run `cadence today` to see the entry.

4. Run `cadence doctor`. It checks the registration, the hooks, the skill, the hook spool backlog, the collector agent and `cleanupPeriodDays` in `~/.claude/settings.json` along with the store, the ledger, file modes and the config. These checks warn and do not fail.

To do it by hand instead: register the server with the `claude mcp add` command above, add the four entries from `hooks.json` to the `hooks` object in `~/.claude/settings.json` after backing the file up, and copy `skills/cadence` into `~/.claude/skills/`.

## What Claude Code can and cannot do

Claude Code can log, plan and read. The MCP server has no tool that accepts proposals, seals a day, deletes anything or edits presence (docs/SPEC.md section 9.2). The skill also tells Claude Code not to try those through the CLI. Entries for past days and everything from `log_entries` wait in your Inbox as proposals. `declare_day` never replaces a holiday or leave that you or a collector declared, and `plan_update` does not resolve a task that is already resolved.

## Notes

- The hook lines wait in `spool/` until a later `cadence` run drains them into session events. Every `cadence collect run` does it first, and the app will too.
- With `claudeCode.injectPlanAtSessionStart` in `config.json` (on by default), the SessionStart hook prints one line with today's plan, and Claude Code adds it to its context. The hook reads the store read-only with a 200 ms limit and prints nothing if that fails.
- Claude Code deletes transcripts older than `cleanupPeriodDays`, 30 by default. Set it to at least 400 in `~/.claude/settings.json` so the transcripts collector still sees October (docs/SPEC.md section 10.4). `cadence setup` does not change it; `cadence doctor` warns when it is lower.
- Keep `~/.claude/settings.json` and your real `config.json` out of the repo. They hold your local paths and settings.
