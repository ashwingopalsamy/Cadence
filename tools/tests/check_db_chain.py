#!/usr/bin/env python3
"""Check the hash chain inside a cadence.db with the proof verifier's own rules.

Independent of the Swift code: reads the events table with Python's sqlite3 and recomputes every
data digest and event hash with tools/verify_proof.py's canon(). Prints a summary; exit 1 on any problem.
Usage: python3 tools/tests/check_db_chain.py PATH/TO/cadence.db [EXPECTED_EVENT_COUNT]"""
import importlib.util, json, os, sqlite3, sys

sys.dont_write_bytecode = True
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("verify_proof", os.path.join(ROOT, "tools", "verify_proof.py"))
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)


def main(path, expected=None):
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    rows = db.execute("SELECT seq, id, v, at, actor, type, subject, data, data_digest, prev, hash FROM events ORDER BY seq").fetchall()
    problems, prev, ids = [], "0" * 64, set()
    for i, (seq, eid, v, at, actor, etype, subject, data, digest, eprev, ehash) in enumerate(rows, start=1):
        if seq != i:
            problems.append("event %d: sequence gap" % seq)
        if eprev != prev:
            problems.append("event %d: bad link" % seq)
        payload = json.loads(data)
        if vp.canon(payload).decode("utf-8") != data:
            problems.append("event %d: stored payload is not canonical" % seq)
        if vp.sha(payload) != digest:
            problems.append("event %d: data digest mismatch" % seq)
        head = {"v": v, "seq": seq, "id": eid, "at": at, "actor": actor, "type": etype, "subject": subject,
                "data_digest": digest, "prev": eprev}
        if vp.sha(head) != ehash:
            problems.append("event %d: hash mismatch" % seq)
        if eid in ids:
            problems.append("event %d: duplicate id" % seq)
        ids.add(eid)
        prev = ehash
    if expected is not None and len(rows) != expected:
        problems.append("expected %d events, found %d" % (expected, len(rows)))
    for p in problems[:20]:
        print("FAIL " + p)
    print("chain %d events, %s" % (len(rows), "ok" if not problems else "%d problems" % len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else None))
