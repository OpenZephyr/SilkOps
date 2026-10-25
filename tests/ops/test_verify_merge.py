import json, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "ops", "verify-merge.py")
SHA = "3f2c9a1e7b0d4c5a8e6f1b2d3c4e5f6a7b8c9d0e"


def dump(obj, path):
    with open(path, "w") as fh:
        json.dump(obj, fh)


def finding(i, **kw):
    f = {"id": i, "title": "t-" + i, "claim": "c-" + i, "location": "src/%s.c:1" % i}
    f.update(kw)
    return f


def report(i, verdict, **kw):
    r = {"id": i, "verdict": verdict, "confidence": 0.8, "summary": "s-" + i,
         "evidence": [{"kind": "file", "ref": "src/%s.c:1@%s" % (i, SHA[:8]), "note": "n"}], "corrections": []}
    if verdict == "corrected":
        r["corrections"] = [{"field": "claim", "from": "five", "to": "three"}]
    r.update(kw)
    return r


class VerifyMerge(unittest.TestCase):
    def run_merge(self, findings, verifiers, sha=SHA, out=True, extra=()):
        with tempfile.TemporaryDirectory() as d:
            fp = os.path.join(d, "findings.json")
            dump(findings, fp)
            vps = []
            for n, v in enumerate(verifiers):
                p = os.path.join(d, "group-%d.out.json" % n)
                dump(v, p)
                vps.append(p)
            cmd = [sys.executable, SCRIPT, "--findings", fp, "--sha", sha] + list(extra)
            op = os.path.join(d, "findings.verified.json")
            if out:
                cmd += ["--out", op]
            r = subprocess.run(cmd + vps, capture_output=True, text=True)
            written = None
            if out and os.path.exists(op):
                with open(op) as fh:
                    written = json.load(fh)
            return r, written

    def findings(self, *ids):
        return {"source": "reviews/r.md", "sha": SHA, "findings": [finding(i) for i in ids]}

    def test_merge_two_groups_pass_through_and_table(self):
        fd = self.findings("F-01", "F-02", "F-03", "F-04")
        v1 = {"group": "firmware", "sha": SHA, "findings": [report("F-01", "confirmed"), report("F-02", "corrected")]}
        v2 = {"group": "docs", "sha": SHA, "findings": [report("F-03", "refuted")]}
        r, written = self.run_merge(fd, [v1, v2])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        doc = json.loads(r.stdout)
        self.assertTrue(doc["ok"])
        self.assertEqual(doc["sha"], SHA)
        self.assertEqual(doc["source"], "reviews/r.md")
        self.assertEqual(doc["verifiers"], 2)
        self.assertEqual(doc["counts"], {"confirmed": 1, "corrected": 1, "refuted": 1, "unverifiable": 1})
        self.assertEqual(doc["pass_through"], ["F-01", "F-02"])
        self.assertEqual(doc["contradictions"], [])
        by = {f["id"]: f for f in doc["findings"]}
        self.assertEqual([f["id"] for f in doc["findings"]], ["F-01", "F-02", "F-03", "F-04"], "input order kept")
        # the unreported finding is unverifiable, never silently passed
        self.assertEqual(by["F-04"]["verdict"], "unverifiable")
        self.assertEqual(by["F-04"]["summary"], "no verifier reported this finding")
        # the refuted finding stays, with its evidence, for the record
        self.assertEqual(by["F-03"]["verdict"], "refuted")
        self.assertEqual(len(by["F-03"]["evidence"]), 1)
        self.assertEqual(by["F-03"]["verifiers"], ["docs"])
        # the original claim and title travel with the corrections
        self.assertEqual(by["F-02"]["claim"], "c-F-02")
        self.assertEqual(by["F-02"]["corrections"][0]["to"], "three")
        # --out holds the same document, stdout is one line
        self.assertEqual(written["pass_through"], doc["pass_through"])
        self.assertEqual(len(r.stdout.strip().splitlines()), 1)
        # the table on stderr: one line per finding plus header and counts
        lines = r.stderr.strip().splitlines()
        self.assertEqual(len(lines), 1 + 4 + 1)
        self.assertIn("F-03", lines[3])
        self.assertIn("refuted", lines[3])
        self.assertIn("4 findings: 1 confirmed, 1 corrected, 1 refuted, 1 unverifiable; 0 contradiction(s); 2 pass to file-residuals", lines[-1])

    def test_contradiction_becomes_unverifiable_and_is_listed(self):
        fd = self.findings("F-01")
        v1 = {"group": "a", "sha": SHA, "findings": [report("F-01", "confirmed", confidence=0.9)]}
        v2 = {"group": "b", "sha": SHA, "findings": [report("F-01", "refuted", confidence=0.6)]}
        r, _ = self.run_merge(fd, [v1, v2], out=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        doc = json.loads(r.stdout)
        f = doc["findings"][0]
        self.assertEqual(f["verdict"], "unverifiable")
        self.assertEqual(f["confidence"], 0.6)
        self.assertEqual(len(f["evidence"]), 2, "evidence from both verifiers is kept")
        self.assertEqual(f["verifiers"], ["a", "b"])
        self.assertIn("a says confirmed", f["summary"])
        self.assertEqual(doc["contradictions"], [{"id": "F-01", "verdicts": [
            {"verifier": "a", "verdict": "confirmed"}, {"verifier": "b", "verdict": "refuted"}]}])
        self.assertEqual(doc["pass_through"], [])
        self.assertNotIn("out", doc)

    def test_agreeing_verifiers_merge_evidence_with_the_lower_confidence(self):
        fd = self.findings("F-01")
        v1 = {"group": "a", "sha": SHA, "findings": [report("F-01", "corrected", confidence=0.9)]}
        v2 = {"group": "b", "sha": SHA, "findings": [report("F-01", "corrected", confidence=0.7)]}
        r, _ = self.run_merge(fd, [v1, v2], out=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        f = json.loads(r.stdout)["findings"][0]
        self.assertEqual(f["verdict"], "corrected")
        self.assertEqual(f["confidence"], 0.7)
        self.assertEqual(len(f["evidence"]), 2)
        self.assertEqual(len(f["corrections"]), 2)
        self.assertEqual(f["summary"], "s-F-01 / s-F-01")

    def assert_usage(self, r, needle):
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        doc = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(doc, {"ok": False, "error": "usage", "message": doc["message"]})
        self.assertIn(needle, doc["message"])

    def test_bad_input_exits_2_with_a_json_object(self):
        fd = self.findings("F-01")
        good = {"group": "a", "sha": SHA, "findings": [report("F-01", "confirmed")]}
        # verifier at another sha: its evidence points at a different tree
        r, _ = self.run_merge(fd, [dict(good, sha="0" * 40)], out=False)
        self.assert_usage(r, "reports sha")
        # findings pinned at another sha than --sha
        r, _ = self.run_merge(dict(fd, sha="0" * 40), [good], out=False)
        self.assert_usage(r, "differs from --sha")
        # a verdict outside the four
        r, _ = self.run_merge(fd, [{"group": "a", "sha": SHA, "findings": [report("F-01", "maybe")]}], out=False)
        self.assert_usage(r, "verdict 'maybe'")
        # an id the review never drafted
        r, _ = self.run_merge(fd, [{"group": "a", "sha": SHA, "findings": [report("F-09", "confirmed")]}], out=False)
        self.assert_usage(r, "unknown finding id")
        # corrected without a correction
        r, _ = self.run_merge(fd, [{"group": "a", "sha": SHA, "findings": [report("F-01", "corrected", corrections=[])]}], out=False)
        self.assert_usage(r, "without corrections")
        # a finding without a claim
        r, _ = self.run_merge({"sha": SHA, "findings": [{"id": "F-01", "title": "t"}]}, [good], out=False)
        self.assert_usage(r, "without id, title or claim")
        # not JSON at all
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "bad.json")
            with open(p, "w") as fh:
                fh.write("{not json")
            fp = os.path.join(d, "f.json")
            dump(fd, fp)
            r = subprocess.run([sys.executable, SCRIPT, "--findings", fp, "--sha", SHA, p], capture_output=True, text=True)
            self.assert_usage(r, "verifier")
            # a missing required argument is a usage failure in the same shape
            r = subprocess.run([sys.executable, SCRIPT, "--findings", fp, p], capture_output=True, text=True)
            self.assert_usage(r, "--sha")

    def test_silkops_verb_runs_the_script(self):
        fd = self.findings("F-01")
        with tempfile.TemporaryDirectory() as d:
            fp = os.path.join(d, "f.json")
            dump(fd, fp)
            vp = os.path.join(d, "v.json")
            dump({"group": "a", "sha": SHA, "findings": [report("F-01", "confirmed")]}, vp)
            r = subprocess.run(["bash", os.path.join(ROOT, "bin", "silkops"), "verify-merge", "--findings", fp, "--sha", SHA, vp],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(json.loads(r.stdout)["pass_through"], ["F-01"])


if __name__ == "__main__":
    unittest.main()
