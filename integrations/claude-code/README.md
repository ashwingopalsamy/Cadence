# Claude Code integration

Two files let Claude Code work with Cadence. The hooks record session and task events, and the skill tells Claude Code when and how to log work. The MCP server is registered separately.

## Files

- `hooks.json` is the hooks block. It runs `cadence hook <event>` for SessionStart, SessionEnd, Stop and TaskCompleted. Each call reads the hook JSON from stdin, appends one allowlisted line to the spool and exits 0. The spool write never opens the database, so Claude Code does not wait on the ledger.
- `skills/cadence/SKILL.md` is the skill. It asks Claude Code to log one line per outcome, in your words, and never to invent times, tickets or counts.

## Install

Install the binary first. `make install` links it at `~/.local/bin/cadence`. The install script arrives with T3.2, so until then copy the built binary there yourself. `cadence doctor` then checks the store, the ledger, file modes and the config.

1. Register the MCP server for your user account:

   ```sh
   claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp
   ```

   `cadence mcp` is not wired into the CLI yet, so this step fails until it is.

2. Merge the hooks into `~/.claude/settings.json`. If that file exists, back it up first, keep the hooks you already have, and add the four entries from `hooks.json` to the `hooks` object. You can also ask Claude Code to do the merge for you.

   ```sh
   cp ~/.claude/settings.json ~/.claude/settings.json.bak
   ```

3. Copy the skill into your personal skills folder:

   ```sh
   mkdir -p ~/.claude/skills
   cp -R integrations/claude-code/skills/cadence ~/.claude/skills/
   ```

   The skill calls `log_entry` and `log_entries`, which arrive with T2.2. Until then it has nothing to call.

4. Once `cadence mcp` exists, start a new Claude Code session and run `/mcp` to check that `cadence` is connected. Then ask Claude Code to log something you finished today, and run `cadence today` to see the entry.

## What Claude Code can and cannot do

Claude Code can log, plan and read. The MCP server has no tool that accepts proposals, seals a day, deletes anything or edits presence (docs/SPEC.md section 9.2). The skill also tells Claude Code not to try those through the CLI.

## Notes

- With `claudeCode.injectPlanAtSessionStart` in `config.json` (on by default), the SessionStart hook prints one line with today's plan, and Claude Code adds it to its context. The hook reads the store read-only with a 200 ms limit and prints nothing if that fails.
- Keep `~/.claude/settings.json` and your real `config.json` out of the repo. They hold your local paths and settings.
