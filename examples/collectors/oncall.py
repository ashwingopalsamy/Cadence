#!/usr/bin/env python3
"""Cadence collector: on-call shifts from a local file, printed as an envelope/1 on stdout.

The Python twin of oncall.sh (docs/SPEC.md sections 10.1 and 10.7). Same arguments, input and output.

    python3 oncall.py --since DAY --until DAY [--name NAME]

DAY is YYYY-MM-DD or an RFC 3339 time with an offset. The window includes both days. The shifts file holds one
shift per line, day,role,service. Lines that start with # and blank lines are skipped. The file is $ONCALL_SHIFTS,
or ~/.config/cadence/oncall.csv when that is unset. Nothing here touches the network.

Try the synthetic sample from the repo root:

    ONCALL_SHIFTS=examples/collectors/oncall-shifts.csv python3 examples/collectors/oncall.py --since 2026-10-26 --until 2026-10-29

In config.json the command is ["/usr/bin/python3", "/absolute/path/to/oncall.py", "--since", "{since}", "--until", "{until}"],
with ONCALL_SHIFTS in the collector's env. Cadence runs the command with that environment and nothing else.
"""

import argparse
import datetime
import json
import os
import re
import sys

EDGE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2}))?")
DAY = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
ROLE = re.compile(r"[A-Za-z0-9_-]+")
SERVICE = re.compile(r"[A-Za-z0-9._ -]+")
NAME = re.compile(r"[a-z0-9-]{1,64}")


def die(message, status=2):
    print(f"oncall: {message}", file=sys.stderr)
    sys.exit(status)


def emit(obj):
    print(json.dumps(obj, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(description="Print on-call shifts as a Cadence envelope/1.")
    parser.add_argument("--since", required=True, help="first day, YYYY-MM-DD, or an RFC 3339 time")
    parser.add_argument("--until", required=True, help="last day, YYYY-MM-DD, or an RFC 3339 time")
    parser.add_argument("--name", default="oncall", help="collector name for the header")
    args = parser.parse_args()

    if not EDGE.fullmatch(args.since):
        die("--since must be YYYY-MM-DD or an RFC 3339 time", 1)
    if not EDGE.fullmatch(args.until):
        die("--until must be YYYY-MM-DD or an RFC 3339 time", 1)
    if not NAME.fullmatch(args.name):
        die("--name must be lowercase letters, digits or dashes", 1)

    shifts = os.environ.get("ONCALL_SHIFTS") or os.path.expanduser("~/.config/cadence/oncall.csv")
    try:
        with open(shifts, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
    except (OSError, UnicodeDecodeError):
        die(f"cannot read the shifts file {shifts}", 1)

    now = datetime.datetime.now(datetime.timezone.utc)
    emit({
        "cadence": "envelope/1",
        "collector": args.name,
        "run": f"oncall-{now.strftime('%Y%m%d%H%M%S')}-{os.getpid()}",
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window": {"since": args.since, "until": args.until},
    })

    since_n = args.since[:10].replace("-", "")
    until_n = args.until[:10].replace("-", "")
    for number, text in enumerate(lines, start=1):
        if text.startswith("#"):
            continue
        day, role, service = (text.split(",", 2) + ["", ""])[:3]
        if not (day or role or service):
            continue
        if not DAY.fullmatch(day):
            die(f"{shifts} line {number}: day must be YYYY-MM-DD")
        if not ROLE.fullmatch(role):
            die(f"{shifts} line {number}: role must be letters, digits, dashes or underscores")
        if not SERVICE.fullmatch(service):
            die(f"{shifts} line {number}: service must be letters, digits, spaces, dots, dashes or underscores")
        if since_n <= day.replace("-", "") <= until_n:
            emit({
                "type": "item",
                "source_ref": f"oncall:{day}:{role}",
                "kind": "oncall.shift",
                "day": day,
                "title": f"On call ({role}) for {service}",
            })


if __name__ == "__main__":
    main()
