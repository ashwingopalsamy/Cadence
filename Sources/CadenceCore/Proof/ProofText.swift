/// Text embedded in every proof file (docs/SPEC.md sections 12.2 and 12.3).
///
/// `verifierPython` must equal tools/verify_proof.py byte for byte; a test checks it, so the
/// script a manager runs is the one `make check` tests against the tampered vectors.
public enum ProofText {
    public static let howToVerify = #"""
This is a Cadence work log export. To check it:
1. Save verifier_py from this file as verify.py and run: python3 verify.py THIS_FILE
   (Python 3.8+, standard library only). PASS means the event chain is complete and in
   order, and every item, seal, witness and the merged PR and review counts match the
   events in the chain. The other summary numbers are computed by Cadence from the same
   days; their definitions are next to them.
2. Spot-check items with origin "collected": open a few links on the company network
   and compare title, date and state.
3. Match witness codes to the last line of the person's stand-up messages for those
   dates. A match shows the log up to that point existed at the message's time.
4. Treat origin "self" and "agent" items as self-reported: plausible, not proven.
   Items flagged after_seal were added after that day's wrap-up, and items flagged
   edited were changed after it.
5. This file is tamper-evident, not tamper-proof: its owner could have rebuilt the
   whole chain before the first witness. Witnesses narrow that window. export_digest
   catches accidental edits only, since anyone can recompute it.
6. Private notes and items marked private are in the chain as hashes only; the
   summary counts them as private_events. Hash-only events still show their type,
   subject and recorded time.
"""#

    public static let verifierPython = #"""
#!/usr/bin/env python3
"""Verify a cadence.proof/1 file. Python 3.8+, standard library only.
Usage: python3 verify.py proof.json"""
import hashlib, json, re, sys
from datetime import datetime

HEAD = ("v", "seq", "id", "at", "actor", "type", "subject", "data_digest", "prev")
CODE = re.compile(r"[0-9a-f]{16}\Z")

def canon(x):
    return json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

def sha(x):
    return hashlib.sha256(canon(x)).hexdigest()

def instant(text):
    t = datetime.fromisoformat(text.replace("Z", "+00:00").replace("z", "+00:00"))
    return int(t.timestamp())

def replay(created, updates):
    """The entry as its events leave it: entry.created data with each entry.updated change applied."""
    entry = dict(created)
    for u in updates:
        for field, change in sorted(u["changes"].items()):
            entry[field] = change[1]
    return entry

def check_item(it, date, by_hash, by_subject, fails):
    e = by_hash.get(it["ev"])
    if e is None:
        return fails.append("%s: references an event that is not in the chain" % date)
    if e["type"] != "entry.created" or not str(e["subject"]).startswith("entry:"):
        return fails.append("%s: item %s does not cite an entry.created event" % (date, it["ev"][:16]))
    history = by_subject[e["subject"]]
    if it.get("last_ev") != history[-1]["hash"]:
        fails.append("%s: item %s last_ev is not the entry's last event" % (date, it["ev"][:16]))
    if it.get("redacted"):
        if "data" in e:
            fails.append("%s: item %s is marked redacted but its payload is in the chain" % (date, it["ev"][:16]))
        return
    updates = [x for x in history if x["type"] == "entry.updated"]
    if "data" not in e or any("data" not in x for x in updates):
        return fails.append("%s: item %s has no payload in the chain to check it against" % (date, it["ev"][:16]))
    entry = replay(e["data"], [x["data"] for x in updates])
    shown = {"kind": entry["kind"], "family": entry["family"], "title": entry["title"], "origin": entry["origin"],
             "ticket": entry["ticket"], "links": [l["url"] for l in entry["links"]], "day": entry["day"]}
    for field, value in sorted(shown.items()):
        got = date if field == "day" else it.get(field)
        if got != value:
            fails.append("%s: item %s %s does not match its events" % (date, it["ev"][:16], field))

def verify(p):
    fails, warns = [], []
    if not isinstance(p, dict) or p.get("format") != "cadence.proof/1":
        return ["unknown format " + repr(p.get("format") if isinstance(p, dict) else p)], warns
    body = {k: v for k, v in p.items() if k != "export_digest"}
    if sha(body) != p.get("export_digest"):
        fails.append("export_digest does not match the file: it was edited after export")
    prev, last_at, by_hash, by_subject, by_code = "0" * 64, "", {}, {}, {}
    for i, e in enumerate(p["chain"]["events"], start=1):
        tag = "event %s" % e.get("seq")
        if e["seq"] != i:
            fails.append(tag + ": sequence gap or reorder")
        if e["prev"] != prev:
            fails.append(tag + ": does not link to the event before it")
        if "data" in e and sha(e["data"]) != e["data_digest"]:
            fails.append(tag + ": payload changed after it was recorded")
        if sha({k: e[k] for k in HEAD}) != e["hash"]:
            fails.append(tag + ": event hash mismatch")
        if e["at"] < last_at:
            warns.append(tag + ": recorded time goes backwards (clock change?)")
        last_at, prev = max(last_at, e["at"]), e["hash"]
        by_hash[e["hash"]] = e
        by_subject.setdefault(e["subject"], []).append(e)
        by_code.setdefault(e["hash"][:16], []).append(e)
    lo, hi = p["range"]["from"], p["range"]["to"]
    counts = {"merged_prs": 0, "reviews": 0}
    for d in p["days"]:
        date = d["date"]
        if not lo <= date <= hi:
            fails.append("%s: day is outside the range" % date)
        if d.get("seal_ev") or d.get("sealed_at"):
            s = by_hash.get(d.get("seal_ev"))
            if s is None:
                fails.append("%s: references an event that is not in the chain" % date)
            elif s["type"] != "day.sealed" or s["subject"] != "day:" + date:
                fails.append("%s: seal_ev is not this day's seal" % date)
            elif not d.get("sealed_at") or instant(d["sealed_at"]) != instant(s["at"]):
                fails.append("%s: sealed_at does not match the seal event" % date)
        for it in d["items"]:
            check_item(it, date, by_hash, by_subject, fails)
            if it["kind"] == "pr.merged" and it["origin"] == "collected":
                counts["merged_prs"] += 1
            if it["kind"] == "review.given":
                counts["reviews"] += 1
    for key, n in sorted(counts.items()):
        if key in p.get("summary", {}) and p["summary"][key]["value"] != n:
            fails.append("summary %s says %s, the items show %d" % (key, p["summary"][key]["value"], n))
    for w in p.get("witnesses", []):
        hit = by_code.get(w["code"], []) if CODE.match(str(w["code"])) else []
        if not any(e["type"] == "witness.checkpoint" and e["subject"] == "day:" + w["date"] for e in hit):
            fails.append("witness %s (%s) matches no checkpoint for that day" % (w["code"], w["date"]))
    return fails, warns

def main(path):
    try:
        with open(path, encoding="utf-8") as f:
            p = json.load(f)
        fails, warns = verify(p)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        print("FAIL    the file is not a readable proof: %s %s" % (type(error).__name__, error))
        print("RESULT  FAIL")
        return 1
    if fails and fails[0].startswith("unknown format"):
        print("FAIL    " + fails[0])
        print("RESULT  FAIL")
        return 1
    ev = p["chain"]["events"]
    items = [it for d in p["days"] for it in d["items"]]
    by_origin = {}
    for it in items:
        by_origin[it["origin"]] = by_origin.get(it["origin"], 0) + 1
    print("cadence.proof/1  %s .. %s  (%s)" % (p["range"]["from"], p["range"]["to"], p["range"]["tz"]))
    print("chain   %d events, head %s" % (len(ev), ev[-1]["hash"][:16] if ev else "-"))
    print("items   %d: %s" % (len(items), ", ".join("%s %d" % kv for kv in sorted(by_origin.items()))))
    print("links   %d items carry a source link to check" % sum(1 for it in items if it.get("links")))
    print("witness %d codes, all found in chain" % len(p.get("witnesses", [])) if not any("witness" in f for f in fails) else "witness MISMATCH")
    for w in warns:
        print("warn    " + w)
    for f in fails:
        print("FAIL    " + f)
    print("RESULT  " + ("PASS: the chain is complete and in order, and every item, seal and witness matches it" if not fails else "FAIL"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

"""#
}
