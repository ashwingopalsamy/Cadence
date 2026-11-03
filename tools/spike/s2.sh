#!/bin/bash
# S2: SMAppService.mainApp and .agent register from ~/Applications. Unregisters afterwards.
set -eu
. "$(dirname "$0")/lib.sh"
spike_begin S2
make_store
mkdir -p "$HOME/Applications"
AGENT_PLIST="$PREFIX.s2.agent.plist"
REGISTERED=0

# Agent plist lives inside the bundle (spec 14.3), so it must exist before signing.
s2_presign() {
  mkdir -p "$1/Contents/Library/LaunchAgents"
  cat >"$1/Contents/Library/LaunchAgents/$AGENT_PLIST" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${AGENT_PLIST%.plist}</string>
<key>BundleProgram</key><string>Contents/MacOS/CadenceSpikeS2</string>
<key>ProgramArguments</key><array><string>CadenceSpikeS2</string><string>--agent</string></array>
<key>RunAtLoad</key><false/>
</dict></plist>
EOT
}

# Always unregister before the app is deleted, even after a failure.
spike_extra_cleanup() {
  if [ "$REGISTERED" = 1 ] && [ -d "$HOME/Applications/CadenceSpikeS2.app" ]; then
    run_app "$HOME/Applications/CadenceSpikeS2.app" --cmd unregister --plist "$AGENT_PLIST" \
      --log "$STORE/s2-unreg.log" >/dev/null 2>&1 || true
  fi
}

APP_PRESIGN=s2_presign build_app CadenceSpikeS2 s2_app.swift 1 "$HOME/Applications" \
  || { result S2 FAIL "could not build the spike app"; exit 0; }

REGISTERED=1
run_app "$APP" --cmd register --plist "$AGENT_PLIST" --log "$STORE/s2.log" || true
LOG="$STORE/s2.log"
if [ ! -f "$LOG" ]; then result S2 FAIL "app wrote no result file"; exit 0; fi

m=$(getv "$LOG" main); a=$(getv "$LOG" agent)
me=$(getv "$LOG" mainerr); ae=$(getv "$LOG" agenterr)
summary="mainApp=$m agent=$a"
[ -z "$me" ] || summary="$summary mainerr=[$me]"
[ -z "$ae" ] || summary="$summary agenterr=[$ae]"

ok() { [ "$1" = enabled ] || [ "$1" = requiresApproval ]; }
if ok "$m" && ok "$a"; then
  if [ "$m" = enabled ] && [ "$a" = enabled ]; then
    result S2 PASS "$summary"
  else
    result S2 MANUAL "$summary (approval needed)"
    note "1. Open System Settings > General > Login Items & Extensions."
    note "2. Under 'Open at Login' and 'Allow in the Background' look for CadenceSpikeS2; switch it on."
    note "3. Note whether macOS accepted it, or whether a managed Mac blocks the toggle."
    note "4. Paste into docs/SPIKES.md: S2 | PASS or FAIL | what you saw in step 2-3"
    note "The spike app is unregistered and deleted when this script ends; the toggles disappear with it."
  fi
else
  result S2 FAIL "$summary"
fi
