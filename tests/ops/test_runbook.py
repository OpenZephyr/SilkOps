import json, os, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "ops", "render-runbook.py")


class Runbook(unittest.TestCase):
    def facts(self):
        return json.load(open(os.path.join(ROOT, "facts", "environment.json")))["facts"]

    def test_checked_in_runbook_is_fresh(self):
        r = subprocess.run([sys.executable, SCRIPT, "--check"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(json.loads(r.stdout)["ok"])

    def test_every_fact_rendered(self):
        text = open(os.path.join(ROOT, "references", "runbook.md")).read()
        for f in self.facts():
            self.assertIn("### `%s`" % f["id"], text)
            self.assertIn(f["explanation"].strip(), text)

    def test_stale_runbook_detected(self):
        with tempfile.TemporaryDirectory() as d:
            for sub in ("facts", "references"):
                os.makedirs(os.path.join(d, sub))
            json.dump({"schema_version": "1", "facts": self.facts()},
                      open(os.path.join(d, "facts", "environment.json"), "w"))
            open(os.path.join(d, "references", "runbook.template.md"), "w").write("# t\n{{FACTS}}\n")
            open(os.path.join(d, "references", "runbook.md"), "w").write("stale\n")
            r = subprocess.run([sys.executable, SCRIPT, "--root", d, "--check"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(json.loads(r.stdout)["error"], "runbook_stale")

    def test_snippet_matches_ci_cd_claude_md_block(self):
        snippet = open(os.path.join(ROOT, "references", "claude-md-snippet.md")).read()
        self.assertIn("`ship-mr`", snippet)
        self.assertIn("`file-residuals`", snippet)
        self.assertIn("never merges", snippet)


if __name__ == "__main__":
    unittest.main()
