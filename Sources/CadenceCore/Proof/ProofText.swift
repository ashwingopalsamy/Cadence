/// Text embedded in every proof file (docs/SPEC.md sections 12.2 and 12.3).
///
/// `verifierPython` must equal tools/verify_proof.py byte for byte; a test checks it, so the
/// script a manager runs is the one `make check` tests against the tampered vectors.
public enum ProofText {
    public static let howToVerify = #"""
This is a Cadence work log export. To check it:
1. Save verifier_py from this file as verify.py and run: python3 verify.py THIS_FILE
   (Python 3.8+, standard library only). PASS means the file is unaltered since export,
   the event chain is complete and in order, and every item and seal refers to an event
   in the chain.
2. Spot-check items with origin "collected": open a few links on the company network
   and compare title, date and state.
3. Match witness codes to the last line of the person's stand-up messages for those
   dates. A match shows the log up to that point existed at the message's time.
4. Treat origin "self" and "agent" items as self-reported: plausible, not proven.
   Items flagged after_seal or edited were added or changed after that day's wrap-up.
5. This file is tamper-evident, not tamper-proof: its owner could have rebuilt the
   whole chain before the first witness. Witnesses narrow that window.
"""#

    public static let verifierPython = #"""
#!/usr/bin/env python3
"""Verify a cadence.proof/1 file. Python 3.8+, standard library only.
Usage: python3 verify.py proof.json"""
import hashlib, json, sys

HEAD = ("v", "seq", "id", "at", "actor", "type", "subject", "data_digest", "prev")

def canon(x):
    return json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

def sha(x):
    return hashlib.sha256(canon(x)).hexdigest()

def verify(p):
    fails, warns = [], []
    if p.get("format") != "cadence.proof/1":
        return ["unknown format " + repr(p.get("format"))], warns
    body = {k: v for k, v in p.items() if k != "export_digest"}
    if sha(body) != p.get("export_digest"):
        fails.append("export_digest does not match the file: it was edited after export")
    prev, hashes, last_at = "0" * 64, set(), ""
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
        hashes.add(e["hash"])
    for d in p["days"]:
        for ref in [d.get("seal_ev")] + [it["ev"] for it in d["items"]]:
            if ref and ref not in hashes:
                fails.append("%s: references an event that is not in the chain" % d["date"])
    for w in p.get("witnesses", []):
        if not any(h.startswith(w["code"]) for h in hashes):
            fails.append("witness %s (%s) matches no event" % (w["code"], w["date"]))
    return fails, warns

def main(path):
    with open(path, encoding="utf-8") as f:
        p = json.load(f)
    fails, warns = verify(p)
    ev = p.get("chain", {}).get("events", [])
    items = [it for d in p.get("days", []) for it in d["items"]]
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
    print("RESULT  " + ("PASS: internally consistent and unaltered since export" if not fails else "FAIL"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))

"""#
}
