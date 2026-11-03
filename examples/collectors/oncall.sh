#!/bin/sh
# Cadence collector: on-call shifts from a local file, printed as an envelope/1 on stdout.
# The shell twin of oncall.py (docs/SPEC.md sections 10.1 and 10.7). Same arguments, input and output.
#
#   /bin/sh oncall.sh --since DAY --until DAY [--name NAME]
#
# DAY is YYYY-MM-DD or an RFC 3339 time with an offset. The window includes both days.
# The shifts file holds one shift per line, day,role,service, with LF line endings. Lines that start with # and
# blank lines are skipped. The file is $ONCALL_SHIFTS, or $HOME/.config/cadence/oncall.csv when that is unset.
# Nothing here touches the network.
#
# Try the synthetic sample from the repo root:
#   ONCALL_SHIFTS=examples/collectors/oncall-shifts.csv /bin/sh examples/collectors/oncall.sh --since 2026-10-26 --until 2026-10-29
#
# In config.json the command is ["/bin/sh", "/absolute/path/to/oncall.sh", "--since", "{since}", "--until", "{until}"],
# with ONCALL_SHIFTS in the collector's env. Cadence runs the command with that environment and nothing else.

set -eu
LC_ALL=C
export LC_ALL

name=oncall
since=
until=

usage() {
  echo "usage: oncall.sh --since DAY --until DAY [--name NAME]" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --since) since=$2 ;;
    --until) until=$2 ;;
    --name) name=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$since" ] && [ -n "$until" ] || usage

edge_ok() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2}))?$'
}
edge_ok "$since" || { echo "oncall: --since must be YYYY-MM-DD or an RFC 3339 time" >&2; exit 1; }
edge_ok "$until" || { echo "oncall: --until must be YYYY-MM-DD or an RFC 3339 time" >&2; exit 1; }
case "$name" in
  ''|*[!a-z0-9-]*) echo "oncall: --name must be lowercase letters, digits or dashes" >&2; exit 1 ;;
esac
[ "${#name}" -le 64 ] || { echo "oncall: --name must be at most 64 characters" >&2; exit 1; }

shifts=${ONCALL_SHIFTS:-$HOME/.config/cadence/oncall.csv}
[ -r "$shifts" ] || { echo "oncall: cannot read the shifts file $shifts" >&2; exit 1; }

# The first ten characters of a day or a time, as a number: 2026-10-26T... becomes 20261026.
day_number() {
  printf '%s' "$1" | cut -c1-10 | tr -d '-'
}
since_n=$(day_number "$since")
until_n=$(day_number "$until")

bad() {
  echo "oncall: $shifts line $line: $1" >&2
  exit 2
}

printf '{"cadence":"envelope/1","collector":"%s","run":"oncall-%s-%s","generated_at":"%s","window":{"since":"%s","until":"%s"}}\n' \
  "$name" "$(date -u +%Y%m%d%H%M%S)" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$since" "$until"

line=0
while IFS=, read -r day role service || [ -n "$day" ]; do
  line=$((line + 1))
  case "$day" in '#'*) continue ;; esac
  [ -n "$day$role$service" ] || continue
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) bad "day must be YYYY-MM-DD" ;;
  esac
  case "$role" in
    ''|*[!A-Za-z0-9_-]*) bad "role must be letters, digits, dashes or underscores" ;;
  esac
  case "$service" in
    ''|*[!A-Za-z0-9._\ -]*) bad "service must be letters, digits, spaces, dots, dashes or underscores" ;;
  esac
  n=$(day_number "$day")
  if [ "$n" -ge "$since_n" ] && [ "$n" -le "$until_n" ]; then
    printf '{"type":"item","source_ref":"oncall:%s:%s","kind":"oncall.shift","day":"%s","title":"On call (%s) for %s"}\n' \
      "$day" "$role" "$day" "$role" "$service"
  fi
done < "$shifts"
