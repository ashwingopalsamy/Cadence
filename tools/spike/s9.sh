#!/bin/bash
# S9: Claude Code transcript lines carry usage, model and ids. Reads structure only, never content.
set -eu
. "$(dirname "$0")/lib.sh"
ID=S9
DIRP=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}
if [ ! -d "$DIRP" ]; then result $ID SKIP "no transcripts directory"; exit 0; fi
command -v python3 >/dev/null 2>&1 || { result $ID SKIP "python3 not found"; exit 0; }

# The script prints STATUS then a summary on line 1, details after. No message content is printed.
out=$(python3 - "$DIRP" <<'PY'
import glob, json, os, re, sys

root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*", "*.jsonl")), key=os.path.getmtime, reverse=True)[:20]
if not files:
    print("SKIP no transcript files found")
    sys.exit(0)

lines = asst = with_usage = with_model = with_id = 0
with_sess = with_ts = 0
models = set()
by_id = {}
safe = re.compile(r"^[A-Za-z0-9._:\-\[\]/]{1,80}$")

for f in files:
    try:
        fh = open(f, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        for raw in fh:
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            lines += 1
            if isinstance(o.get("sessionId"), str):
                with_sess += 1
            if isinstance(o.get("timestamp"), str):
                with_ts += 1
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            if o.get("type") != "assistant" and m.get("role") != "assistant":
                continue
            asst += 1
            u = m.get("usage")
            if isinstance(u, dict):
                with_usage += 1
            mod = m.get("model")
            if isinstance(mod, str):
                with_model += 1
                if safe.match(mod):
                    models.add(mod)
            mid = m.get("id")
            if isinstance(mid, str):
                with_id += 1
                out = u.get("output_tokens") if isinstance(u, dict) else None
                by_id.setdefault(mid, []).append(out if isinstance(out, int) else -1)

dups = [v for v in by_id.values() if len(v) > 1]
differ = [v for v in dups if len(set(v)) > 1]
pct = lambda n, d: "%.0f%%" % (100.0 * n / d) if d else "n/a"
status = "PASS" if asst and with_usage and with_model else "FAIL"
print("%s files=%d assistant_lines=%d usage=%s model=%s" % (
    status, len(files), asst, pct(with_usage, asst), pct(with_model, asst)))
print("  all parsed lines=%d with sessionId=%s timestamp=%s" % (lines, pct(with_sess, lines), pct(with_ts, lines)))
print("  assistant lines with message.id=%s" % pct(with_id, asst))
print("  message ids seen more than once=%d, of which output_tokens differ=%d (%s)" % (
    len(dups), len(differ), "dedupe keeping max output tokens is needed" if differ else "no evidence either way"))
print("  models: %s" % (", ".join(sorted(models)) or "none"))
PY
) || { result $ID FAIL "scan script failed"; exit 0; }

first=$(printf '%s\n' "$out" | head -1)
status=${first%% *}
result $ID "$status" "${first#* }"
printf '%s\n' "$out" | tail -n +2
