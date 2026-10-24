#!/usr/bin/env python3
"""Merge N verifier outputs into one findings.verified.json (verify-findings skill, #89).

  verify-merge.py --findings FILE --sha SHA [--out FILE] VERIFIER.json [VERIFIER.json ...]

Each verifier file holds the verdicts one sub-agent reached for one group of findings
(skills/verify-findings/references/schema.md). The merge keeps every evidence pointer, turns a
disagreement between verifiers into `unverifiable` listed under contradictions[], marks a finding
no verifier reported `unverifiable`, and lists the confirmed and corrected ids in pass_through[],
the only ids file-residuals may take. One JSON object on stdout, the verdict table on stderr,
exit 2 on bad input. Stdlib only, Python 3.9.
"""
import argparse, json, sys

VERDICTS = ("confirmed", "corrected", "refuted", "unverifiable")
PASS = ("confirmed", "corrected")


def usage(msg):
    print(json.dumps({"ok": False, "error": "usage", "message": msg}))
    sys.exit(2)


def load(path, what):
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        usage("%s %s: %s" % (what, path, e))
    if not isinstance(doc, dict) or not isinstance(doc.get("findings"), list):
        usage("%s %s: expected an object with a findings[] list" % (what, path))
    return doc


def merge(findings_doc, verifier_docs, sha):
    """Pure merge: returns the verified document. Raises ValueError on bad input."""
    if findings_doc.get("sha") and findings_doc["sha"] != sha:
        raise ValueError("findings sha %s differs from --sha %s" % (findings_doc["sha"], sha))
    order, base = [], {}
    for f in findings_doc["findings"]:
        fid = f.get("id")
        if not fid or not f.get("claim") or not f.get("title"):
            raise ValueError("finding without id, title or claim: %r" % (f,))
        if fid in base:
            raise ValueError("duplicate finding id %s" % fid)
        order.append(fid)
        base[fid] = f
    reports = {fid: [] for fid in order}
    for n, v in enumerate(verifier_docs):
        name = v.get("group") or "verifier-%d" % (n + 1)
        if v.get("sha") and v["sha"] != sha:
            raise ValueError("verifier %s reports sha %s, not %s" % (name, v["sha"], sha))
        for r in v["findings"]:
            fid = r.get("id")
            if fid not in base:
                raise ValueError("verifier %s reports unknown finding id %r" % (name, fid))
            if r.get("verdict") not in VERDICTS:
                raise ValueError("verifier %s, finding %s: verdict %r not in %s" % (name, fid, r.get("verdict"), "|".join(VERDICTS)))
            if r.get("verdict") == "corrected" and not r.get("corrections"):
                raise ValueError("verifier %s, finding %s: corrected without corrections[]" % (name, fid))
            reports[fid].append((name, r))
    out, contradictions, counts = [], [], {v: 0 for v in VERDICTS}
    for fid in order:
        f = base[fid]
        row = {k: f[k] for k in ("id", "title", "claim", "location", "subsystem", "severity", "suggested_fix") if k in f}
        rs = reports[fid]
        if not rs:
            row.update(verdict="unverifiable", confidence=0.0, summary="no verifier reported this finding",
                       evidence=[], corrections=[], verifiers=[])
        else:
            verdicts = sorted({r["verdict"] for _, r in rs})
            evidence = [e for _, r in rs for e in r.get("evidence") or []]
            corrections = [c for _, r in rs for c in r.get("corrections") or []]
            confidence = min(float(r.get("confidence", 0.0)) for _, r in rs)
            if len(verdicts) == 1:
                verdict = verdicts[0]
                summary = " / ".join(s for s in (r.get("summary") for _, r in rs) if s) or ""
            else:
                verdict = "unverifiable"
                summary = "verifiers disagree: " + ", ".join("%s says %s" % (n, r["verdict"]) for n, r in rs)
                contradictions.append({"id": fid, "verdicts": [{"verifier": n, "verdict": r["verdict"]} for n, r in rs]})
            row.update(verdict=verdict, confidence=confidence, summary=summary, evidence=evidence,
                       corrections=corrections, verifiers=[n for n, _ in rs])
        counts[row["verdict"]] += 1
        out.append(row)
    return {"ok": True, "sha": sha, "source": findings_doc.get("source"), "verifiers": len(verifier_docs),
            "counts": counts, "pass_through": [r["id"] for r in out if r["verdict"] in PASS],
            "contradictions": contradictions, "findings": out}


def table(doc):
    w = max([len(r["id"]) for r in doc["findings"]] + [2])
    lines = ["%-*s  %-12s  %-4s  %s" % (w, "id", "verdict", "conf", "summary")]
    for r in doc["findings"]:
        lines.append("%-*s  %-12s  %.2f  %s" % (w, r["id"], r["verdict"], r["confidence"], r["summary"]))
    c = doc["counts"]
    lines.append("%d findings: %d confirmed, %d corrected, %d refuted, %d unverifiable; %d contradiction(s); %d pass to file-residuals" % (
        len(doc["findings"]), c["confirmed"], c["corrected"], c["refuted"], c["unverifiable"],
        len(doc["contradictions"]), len(doc["pass_through"])))
    return "\n".join(lines)


class Parser(argparse.ArgumentParser):
    def error(self, message):  # the ops contract: a usage failure is one JSON object and exit 2
        print(self.format_usage().strip(), file=sys.stderr)
        usage(message)


def main():
    ap = Parser(add_help=True, usage="verify-merge.py --findings FILE --sha SHA [--out FILE] VERIFIER [VERIFIER ...]")
    ap.add_argument("--findings", required=True, metavar="FILE", help="the review's findings (schema.md)")
    ap.add_argument("--sha", required=True, help="the commit every verifier checked against")
    ap.add_argument("--out", metavar="FILE", help="write the verified document here as well")
    ap.add_argument("verifiers", nargs="+", metavar="VERIFIER", help="one verifier output per group")
    a = ap.parse_args()
    if not a.sha.strip():
        usage("--sha must not be empty")
    findings = load(a.findings, "findings")
    verifiers = [load(p, "verifier") for p in a.verifiers]
    try:
        doc = merge(findings, verifiers, a.sha.strip())
    except ValueError as e:
        usage(str(e))
    if a.out:
        try:
            with open(a.out, "w") as fh:
                json.dump(doc, fh, indent=2)
                fh.write("\n")
        except OSError as e:
            usage("cannot write %s: %s" % (a.out, e))
        doc["out"] = a.out
    print(table(doc), file=sys.stderr)
    print(json.dumps(doc, separators=(",", ":")))


if __name__ == "__main__":
    main()
