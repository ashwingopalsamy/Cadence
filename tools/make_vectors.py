#!/usr/bin/env python3
"""Generate the shared test vectors in Tests/Vectors/: canonical JSON, hash chains and proofs.

Python 3.8+, standard library only. Deterministic: running it twice gives the same bytes.

    python3 tools/make_vectors.py           write the vectors
    python3 tools/make_vectors.py --check   fail if the files on disk differ from a fresh run

The hashing rules are the ones in docs/SPEC.md section 7.3, taken from tools/verify_proof.py
so the vectors and the verifier can never disagree about canonical JSON. All data is ACME.
"""
import copy
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECTORS = os.path.join(ROOT, "Tests", "Vectors")
OUT = os.path.join(VECTORS, "proofs")

_spec = importlib.util.spec_from_file_location("verify_proof", os.path.join(ROOT, "tools", "verify_proof.py"))
verify_proof = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(verify_proof)
canon, sha, HEAD = verify_proof.canon, verify_proof.sha, verify_proof.HEAD

ZERO = "0" * 64
TZ = "Asia/Kolkata"


def ulid(n):
    # Fixed, readable ULID-shaped ids: 26 Crockford base32 characters.
    return "01JB0000000000000000%06d" % n


def build_chain(drafts):
    events, prev = [], ZERO
    for seq, (at, actor, etype, subject, data) in enumerate(drafts, start=1):
        e = {"v": 1, "seq": seq, "id": ulid(seq), "at": at, "actor": actor, "type": etype,
             "subject": subject, "data_digest": sha(data), "prev": prev}
        e["hash"] = sha({k: e[k] for k in HEAD})
        e["data"] = data
        events.append(e)
        prev = e["hash"]
    return events


def entry(eid, day, kind, family, title, occurred_at, origin, source=None, source_ref=None,
          ticket=None, links=None, export="include"):
    return {"id": eid, "day": day, "kind": kind, "family": family, "title": title,
            "occurred_at": occurred_at, "ticket": ticket, "links": links or [], "tags": [],
            "attrs": {}, "origin": origin, "source": source, "source_ref": source_ref,
            "status": "accepted", "backfilled": False, "after_seal": False, "export": export}


def valid_proof():
    pr_link = "https://git.example.com/acme/ledger-core/pull/405"
    drafts = [
        ("2026-10-01T03:58:00.000Z", "app", "ledger.genesis", "ledger",
         {"created": "2026-10-01T03:58:00.000Z", "app_version": "0.0.0", "profile": {"name": "Sample Person", "timezone": TZ}}),
        ("2026-10-01T04:12:30.000Z", "app", "day.started", "day:2026-10-01",
         {"at": "2026-10-01T04:12:30.000Z", "source": "input"}),
        ("2026-10-01T04:15:02.000Z", "cli", "plan.added", "task:01JB00000000000000000T0001",
         {"day": "2026-10-01", "position": 1, "title": "Batch settlement writes", "ticket": {"key": "ACME-482901", "class": "assigned"}, "origin": "self"}),
        ("2026-10-01T09:42:40.000Z", "collector:github", "entry.created", "entry:01JB00000000000000000E0001",
         entry("01JB00000000000000000E0001", "2026-10-01", "pr.merged", "delivery", "ACME-482901 Batch settlement writes",
               "2026-10-01T15:12:40+05:30", "collected", "github", "github:PR_kwDOAcme405:merged",
               {"key": "ACME-482901", "class": "assigned"}, [{"kind": "pr", "url": pr_link}])),
        ("2026-10-01T10:05:11.000Z", "mcp", "entry.created", "entry:01JB00000000000000000E0002",
         entry("01JB00000000000000000E0002", "2026-10-01", "work.done", "delivery", "Fixed flaky ledger test with deterministic clock",
               "2026-10-01T15:35:11+05:30", "agent")),
        ("2026-10-01T10:20:00.000Z", "cli", "entry.created", "entry:01JB00000000000000000E0003",
         entry("01JB00000000000000000E0003", "2026-10-01", "note", "presence", "Private note about a 1:1",
               "2026-10-01T15:50:00+05:30", "self", export="digest")),
        ("2026-10-01T10:21:00.000Z", "cli", "entry.created", "entry:01JB00000000000000000E0004",
         entry("01JB00000000000000000E0004", "2026-10-01", "discussion.raised", "leadership", "Raised retry storms risk in arch sync",
               "2026-10-01T15:51:00+05:30", "self")),
        ("2026-10-01T11:54:10.000Z", "app", "plan.resolved", "task:01JB00000000000000000T0001",
         {"status": "done", "reason": None, "links": ["entry:01JB00000000000000000E0001"]}),
        ("2026-10-01T11:54:10.000Z", "app", "day.sealed", "day:2026-10-01",
         {"counts": {"entries": 4, "planned": 1, "done": 1}, "plan": {"done": 1, "slipped": 0, "dropped": 0}}),
        ("2026-10-01T11:54:11.000Z", "app", "witness.checkpoint", "day:2026-10-01", {"purpose": "standup"}),
    ]
    events = build_chain(drafts)
    by_seq = {e["seq"]: e for e in events}
    # The note's export policy is "digest": the payload is dropped, the chain still verifies.
    del by_seq[6]["data"]
    seal, witness = by_seq[9], by_seq[10]

    def item(seq, last=None, redacted=False):
        e = by_seq[seq]
        if redacted:
            return {"ev": e["hash"], "last_ev": e["hash"], "kind": "note", "origin": "self", "redacted": True,
                    "flags": {"edited": False, "after_seal": False, "backfilled": False}}
        d = e["data"]
        it = {"ev": e["hash"], "last_ev": (last or e)["hash"], "kind": d["kind"], "family": d["family"],
              "title": d["title"], "occurred_at": d["occurred_at"], "origin": d["origin"]}
        if d.get("source"):
            it["source"] = d["source"]
        if d.get("ticket"):
            it["ticket"] = d["ticket"]
        it["links"] = [l["url"] for l in d["links"]]
        it["flags"] = {"edited": False, "after_seal": False, "backfilled": False}
        return it

    proof = {
        "format": "cadence.proof/1",
        "generated_at": "2026-10-02T09:12:00+05:30",
        "generator": "Cadence 0.0.0",
        "subject": {"name": "Sample Person", "role": "Software Engineer"},
        "range": {"from": "2026-10-01", "to": "2026-10-01", "tz": TZ},
        "how_to_verify": "Synthetic test vector. Run: python3 tools/verify_proof.py THIS_FILE",
        "verifier_py": "omitted in test vectors",
        "summary": {
            "sealed_workdays": {"value": 1, "of": 1, "definition": "Workdays wrapped up by 23:59 the next day; leave and holidays excluded"},
            "plan_done": {"value": 1, "of": 1, "definition": "Planned tasks marked done on their day"},
            "merged_prs": {"value": 1, "assigned": 1, "self_initiated": 0, "definition": "Merged PRs authored, from the GitHub collector"},
        },
        "days": [{
            "date": "2026-10-01", "kind": "workday", "first_activity": "09:42", "last_activity": "-",
            "sealed_at": "2026-10-01T17:24:10+05:30", "seal_ev": seal["hash"],
            "items": [item(4), item(5), item(6, redacted=True), item(7)],
        }],
        "chain": {"algo": "sha256", "c14n": "cadence-c14n/1", "events": events},
        "witnesses": [{"date": "2026-10-01", "code": witness["hash"][:16], "where": "stand-up message"}],
        "checks": ["export_digest", "sequence", "links", "payload_digests", "event_hashes", "references", "witnesses"],
    }
    proof["export_digest"] = sha(proof)
    return proof


def redigest(p):
    p = {k: v for k, v in p.items() if k != "export_digest"}
    p["export_digest"] = sha(p)
    return p


def tampered_variants(valid):
    out = {}
    # One edited title, as in docs/SPEC.md 12.3: export digest and payload digest both fail.
    t = copy.deepcopy(valid)
    t["chain"]["events"][3]["data"]["title"] = "ACME-482901 Batch settlement writes and more"
    t["days"][0]["items"][0]["title"] = "ACME-482901 Batch settlement writes and more"
    out["tampered.json"] = t
    # Payload edited and the export digest recomputed: the payload digest still fails.
    t = copy.deepcopy(valid)
    t["chain"]["events"][4]["data"]["title"] = "Fixed every flaky test"
    out["tampered-payload-redigested.json"] = redigest(t)
    # An event dropped from the middle of the chain.
    t = copy.deepcopy(valid)
    del t["chain"]["events"][6]
    out["tampered-drop.json"] = redigest(t)
    # Two events swapped.
    t = copy.deepcopy(valid)
    ev = t["chain"]["events"]
    ev[4], ev[5] = ev[5], ev[4]
    out["tampered-reorder.json"] = redigest(t)
    # A witness code that matches no event.
    t = copy.deepcopy(valid)
    t["witnesses"][0]["code"] = "0123456789abcdef"
    out["tampered-witness.json"] = redigest(t)
    # The cases below recompute export_digest, which anyone can do. Each must still fail because the
    # days, the summary and the witnesses are checked against the chain itself.
    def variant(name, change):
        t = copy.deepcopy(valid)
        change(t)
        out["tampered-%s.json" % name] = redigest(t)
    item0 = lambda t: t["days"][0]["items"][0]
    variant("item-title", lambda t: item0(t).update(title="ACME-482901 Rewrote the whole ledger"))
    variant("item-origin", lambda t: t["days"][0]["items"][1].update(origin="collected"))
    variant("item-link", lambda t: item0(t)["links"].append("https://git.example.com/acme/other/pull/9"))
    variant("item-last-ev", lambda t: item0(t).update(last_ev="f" * 64))
    variant("item-fake", lambda t: t["days"][0]["items"].append(dict(item0(t), ev=t["chain"]["events"][2]["hash"])))
    variant("item-redacted-unhidden", lambda t: t["days"][0]["items"].__setitem__(0, {
        "ev": item0(t)["ev"], "last_ev": item0(t)["last_ev"], "kind": "pr.merged", "origin": "collected", "redacted": True}))
    variant("summary", lambda t: t["summary"]["merged_prs"].update(value=40))
    variant("summary-unknown", lambda t: t["summary"]["merged_prs"].update(value=None))
    variant("witness-empty", lambda t: t["witnesses"].append({"date": "2026-10-01", "code": "", "where": "x"}))
    variant("witness-short", lambda t: t["witnesses"].append({"date": "2026-10-01", "code": "a", "where": "x"}))
    variant("witness-not-checkpoint", lambda t: t["witnesses"].__setitem__(0, dict(t["witnesses"][0], code=t["chain"]["events"][3]["hash"][:16])))
    variant("seal-genesis", lambda t: t["days"][0].update(seal_ev=t["chain"]["events"][0]["hash"]))
    variant("sealed-at", lambda t: t["days"][0].update(sealed_at="2026-10-01T23:00:00+05:30"))
    variant("range", lambda t: t["range"].update(to="2026-09-30", **{"from": "2026-09-30"}))
    def strip(t):
        for e in t["chain"]["events"]:
            e.pop("data", None)
    variant("no-payloads", strip)
    return out


# Canonical JSON vectors (docs/SPEC.md 12.1). Inputs are JSON text, so each side parses them
# with its own parser; "canonical" is what Python's canon() produces and Swift must match.
C14N_INPUTS = [
    ("scalars", '[null,true,false,0,-0,1,-1,42]'),
    ("max safe integers", '[9007199254740991,-9007199254740991]'),
    ("empty containers", '{"a":[],"b":{},"c":""}'),
    ("key order is by code point", '{"b":1,"a":2,"B":3,"aa":4,"_":5,"":6,"a b":7,"0":8,"~":9}'),
    ("nested key order", '{"z":{"y":{"x":1,"w":2},"v":[{"u":1,"t":2}]},"s":0}'),
    ("whitespace is dropped", ' { "a" : [ 1 , 2 ] ,\n\t"b" : null } '),
    ("quote and backslash", '"say \\"hi\\" and \\\\ back"'),
    ("short escapes", '"\\b\\f\\n\\r\\t"'),
    ("other control characters", '"\\u0000\\u0001\\u001f\\u000b\\u001B"'),
    ("slash stays raw", '"https:\\/\\/git.example.com/acme/pull/1"'),
    ("delete stays raw", '"a\\u007fb"'),
    ("latin escapes become raw UTF-8", '"caf\\u00e9 r\\u00e9sum\\u00e9"'),
    ("raw UTF-8 stays raw", '"S\u00e3o Paulo \u00b7 \u20b9 \u4e2d\u6587"'),
    ("combining marks are not normalised", '["e\\u0301","\\u00e9"]'),
    ("line separators stay raw", '"a\\u2028b\\u2029c"'),
    ("astral plane from surrogate pair", '"\\ud83d\\ude80 launch"'),
    ("astral plane raw", '"\U0001F680"'),
    ("ACME entry", '{"kind":"pr.merged","title":"ACME-482913 Ship retry budget","attrs":{"number":412,"ai_assisted":true,"additions":184},"links":[{"kind":"pr","url":"https://git.example.com/acme/ledger-core/pull/412"}],"occurred_at":"2026-10-29T16:02:11+05:30","ticket":{"class":"assigned","key":"ACME-482913"}}'),
    ("deep nesting", '[[[[[[[[[[{"a":[[[[1]]]]}]]]]]]]]]]'),
    ("64 levels of nesting", "[" * 63 + "{}" + "]" * 63),
    ("escaped keys sort after unescaping", '{"\\u0062":1,"a":2}'),
    ("keys that need escaping", '{"a\\"b":1,"a\\\\b":2,"\\n":3,"\\u007f":4}'),
    ("C1 controls stay raw", '"\\u0080\\u009f"'),
    ("BOM and noncharacter stay raw", '"\\ufeff\\uffff"'),
    ("uppercase hex escape", '"\\u00E9"'),
    ("highest code point", '"\\udbff\\udfff"'),
    ("top-level string", '"x"'),
    ("top-level integer", '7'),
]

# Each reject names the stage that must refuse it: "parse" (JSONParser) or "write" (CanonicalJSON).
C14N_REJECTS = [
    ("float", '1.0'),
    ("float in object", '{"cost":0.42}'),
    ("exponent", '1e3'),
    ("negative exponent", '{"a":5E-1}'),
    ("integer above 2^53 - 1", '9007199254740992'),
    ("integer below -(2^53 - 1)", '-9007199254740992'),
    ("huge integer", '123456789012345678901234567890'),
    ("non-ASCII key", '{"caf\u00e9":1}'),
    ("duplicate key", '{"a":1,"a":2}'),
    ("unpaired high surrogate", '"\\ud800"'),
    ("unpaired low surrogate", '"\\udc00x"'),
    ("raw control character", '"a\tb"'),
    ("leading zero", '012'),
    ("trailing content", '{} {}'),
    ("NaN", 'NaN'),
    ("invalid escape", '"\\x41"'),
    ("non-ASCII key through an escape", '{"caf\\u00e9":1}'),
    ("high surrogate then a letter", '"\\ud800A"'),
    ("two high surrogates", '"\\ud800\\ud800"'),
    ("lone minus", '-'),
    ("negative leading zero", '-01'),
    ("plus sign", '+1'),
    ("negative zero float", '-0.0'),
    ("zero exponent", '0e0'),
    ("trailing comma in array", '[1,]'),
    ("trailing comma in object", '{"a":1,}'),
    ("missing colon", '{"a" 1}'),
    ("Infinity", 'Infinity'),
    ("short unicode escape", '"\\u12"'),
    ("uppercase U escape", '"\\U0041"'),
    ("leading byte order mark", '\ufeff[]'),
    ("65 levels of nesting", "[" * 65 + "]" * 65),
]

WRITE_STAGE_REJECTS = {"non-ASCII key", "non-ASCII key through an escape"}


def c14n_vectors():
    vectors = []
    for name, text in C14N_INPUTS:
        value = json.loads(text)
        out = canon(value)
        vectors.append({"name": name, "input": text, "canonical": out.decode("utf-8"),
                        "sha256": verify_proof.hashlib.sha256(out).hexdigest()})
    return {"c14n": "cadence-c14n/1", "vectors": vectors,
            "reject": [{"name": n, "input": t, "stage": "write" if n in WRITE_STAGE_REJECTS else "parse"}
                       for n, t in C14N_REJECTS]}


def chain_vectors():
    drafts = [
        ("2026-10-01T03:58:00.000Z", "app", "ledger.genesis", "ledger",
         {"created": "2026-10-01T03:58:00.000Z", "app_version": "0.0.0", "profile": {"name": "Sample Person", "timezone": TZ}}),
        ("2026-10-01T04:12:30.123Z", "app", "day.started", "day:2026-10-01", {"at": "2026-10-01T04:12:30.123Z", "source": "input"}),
        ("2026-10-01T05:00:00.000Z", "cli", "config.classifier", None, {"patterns": ["sha256:" + "ab" * 32]}),
        ("2026-10-01T06:30:00.000Z", "collector:github", "entry.created", "entry:01JB00000000000000000E0001",
         entry("01JB00000000000000000E0001", "2026-10-01", "review.given", "review", "ACME-000000 Idempotency keys \u00b7 refunds",
               "2026-10-01T12:00:00+05:30", "collected", "github", "github:PRR_kwDOAcme777", None,
               [{"kind": "pr", "url": "https://git.example.com/acme/refunds/pull/88"}])),
        ("2026-10-01T06:31:00.000Z", "import:october-app", "genai.usage", "usage:2026-10-01:claude-code:*:import",
         {"day": "2026-10-01", "tool": "claude-code", "model": "*", "source": "import:october-app", "requests": 118,
          "tokens": {"in": 48210, "out": 51302, "cache_read": 8120400, "cache_write": 402118}, "cost_micros": 14210000}),
        ("2026-10-01T06:32:00.000Z", "mcp", "entry.status", "entry:01JB00000000000000000E0001",
         {"from": "accepted", "to": "dismissed", "note": "line\nbreak \"quoted\" tab\t"}),
    ]
    events = build_chain(drafts)
    return {"c14n": "cadence-c14n/1", "algo": "sha256", "genesis_prev": ZERO, "events": events}


def render(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def main(argv):
    check = "--check" in argv
    valid = valid_proof()
    files = {"proofs/valid.json": valid}
    files.update({"proofs/" + k: v for k, v in tampered_variants(valid).items()})
    files["c14n.json"] = c14n_vectors()
    files["chains/basic.json"] = chain_vectors()
    stale = []
    for name, obj in sorted(files.items()):
        path = os.path.join(VECTORS, name)
        text = render(obj)
        if check:
            try:
                with open(path, encoding="utf-8") as f:
                    if f.read() != text:
                        stale.append(name)
            except FileNotFoundError:
                stale.append(name)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
    if stale:
        print("make_vectors: out of date: " + ", ".join(stale) + " (run python3 tools/make_vectors.py)")
        return 1
    print("make_vectors: %s %d vector files" % ("checked" if check else "wrote", len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
