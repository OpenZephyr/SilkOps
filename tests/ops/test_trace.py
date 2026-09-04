#!/usr/bin/env python3
"""Tests for ops/trace.py (U4): section parsing, per-command timing, root cause."""

import os
import re
import sys
import tempfile
import unittest

import json as _json
import subprocess as _subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OPS = os.path.join(REPO_ROOT, "ops")
TRACES = os.path.join(REPO_ROOT, "tests", "fixtures", "traces")
FACTS = os.path.join(REPO_ROOT, "facts", "environment.json")
CICD_PLANS = "/Users/poelyte/Documents/a-Dev/ci-cd/docs/plans"


def trace(name):
    return os.path.join(TRACES, name)


def run(script, *args, stdin=None):
    """Run ops/<script> as a subprocess; return (rc, parsed-json-or-None, stderr)."""
    p = _subprocess.run(["python3", os.path.join(OPS, script)] + list(args),
                        input=stdin, capture_output=True, text=True)
    out = None
    if p.stdout.strip():
        lines = [l for l in p.stdout.splitlines() if l.strip()]
        assert len(lines) == 1, "expected exactly one JSON line on stdout, got: %r" % p.stdout
        out = _json.loads(lines[0])
    return p.returncode, out, p.stderr

TS_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z (\d{2}[OE])(\+| )?")


class TraceContract(unittest.TestCase):
    def test_bad_args_exit_2(self):
        rc, out, _ = run("trace.py")
        self.assertEqual(rc, 2)
        self.assertEqual(out["ok"], False)
        self.assertEqual(out["error"], "usage")
        rc, out, _ = run("trace.py", "bogus-subcommand", trace("publish-green.log"))
        self.assertEqual(rc, 2)
        self.assertEqual(out["ok"], False)

    def test_missing_file_exit_5(self):
        rc, out, _ = run("trace.py", "parse", trace("does-not-exist.log"))
        self.assertEqual(rc, 5)
        self.assertEqual(out["ok"], False)
        self.assertEqual(out["error"], "not_found")

    def test_reads_stdin(self):
        with open(trace("publish-green.log")) as f:
            rc, out, _ = run("trace.py", "parse", "-", stdin=f.read())
        self.assertEqual(rc, 0)
        self.assertTrue(out["ok"])
        self.assertEqual(len(out["sections"]), 6)


class ParsePublishGreen(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rc, cls.out, cls.err = run("trace.py", "parse", trace("publish-green.log"))

    def test_ok(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertTrue(self.out["ok"])
        self.assertTrue(self.out["has_timestamps"])
        self.assertFalse(self.out["failed"])

    def test_six_sections_in_order(self):
        names = [s["name"] for s in self.out["sections"]]
        self.assertEqual(names, ["prepare_executor", "prepare_script", "get_sources",
                                 "step_script", "upload_artifacts_on_success",
                                 "cleanup_file_variables"])
        step = [s for s in self.out["sections"] if s["name"] == "step_script"][0]
        self.assertEqual(step["start"], 1788483616)
        self.assertEqual(step["end"], 1788483878)
        self.assertEqual(step["duration_s"], 262)

    def test_steps_are_command_echoes_cleaned(self):
        cmds = [s["command"] for s in self.out["steps"]]
        self.assertEqual(len(cmds), 5)
        self.assertIn("FACTORY_DEFER_PUSH=true bash scripts/ci/build-image.sh", cmds)
        for c in cmds:
            self.assertNotIn("\x1b", c)
            self.assertNotIn("\r", c)
            self.assertFalse(c.startswith("$ "))

    def test_push_digest_line_lands_in_publish_step(self):
        publish = [s for s in self.out["steps"] if s["command"].startswith("if jq -e '.would_publish == true'")]
        self.assertEqual(len(publish), 1)
        notable = "\n".join(publish[0]["notable"])
        self.assertIn("4.7.2-stable-r2: digest: sha256:8e8cc127", notable)
        self.assertIn("commit-records: pushed records for godot 4.7.2-stable-r2 to main", notable)
        self.assertGreater(publish[0]["duration_s"], 180)

    def test_total(self):
        self.assertGreater(self.out["total_s"], 275)
        self.assertLess(self.out["total_s"], 290)


class TimingReleaseBuild(unittest.TestCase):
    """release-build-linux-3243s.log: the plan cites cp ≈ 1132s and export ≈ 38s.
    Measured from the fixture's own timestamps: 1131.50s and 38.05s."""

    @classmethod
    def setUpClass(cls):
        cls.rc, cls.out, cls.err = run("trace.py", "timing", trace("release-build-linux-3243s.log"), "--top", "3")

    def test_ok(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertTrue(self.out["ok"])
        self.assertNotIn("notice", self.out)

    def test_largest_step_is_template_cp(self):
        top = self.out["steps"][0]
        self.assertEqual(top["command"], 'mkdir -p "$TPL_DIR" && cp "${TPL_CACHE}"/* "$TPL_DIR/"')
        self.assertAlmostEqual(top["duration_s"], 1131.496, delta=0.01)
        self.assertEqual(self.out["largest_step"]["command"], top["command"])
        self.assertEqual(len(self.out["steps"]), 3)

    def test_export_step_38s(self):
        rc, full, _ = run("trace.py", "timing", trace("release-build-linux-3243s.log"), "--top", "0")
        export = [s for s in full["steps"] if s["command"].startswith("ospan godot-export")]
        self.assertEqual(len(export), 1)
        self.assertAlmostEqual(export[0]["duration_s"], 38.046, delta=0.01)

    def test_sections_ranked_desc(self):
        durs = [s["duration_s"] for s in self.out["sections"]]
        self.assertEqual(durs, sorted(durs, reverse=True))
        self.assertEqual(self.out["sections"][0]["name"], "step_script")
        self.assertEqual(self.out["sections"][0]["duration_s"], 1787947836 - 1787945493)

    def test_total(self):
        self.assertGreater(self.out["total_s"], 3180)
        self.assertLess(self.out["total_s"], 3190)


class TimingWithoutTimestamps(unittest.TestCase):
    def setUp(self):
        with open(trace("publish-green.log"), "rb") as f:
            raw = f.read().decode("utf-8", "replace")
        stripped = "\n".join(TS_PREFIX.sub("", l) for l in raw.split("\n"))
        self.assertNotRegex(stripped, r"^\d{4}-\d{2}-\d{2}T")
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        self.tmp.write(stripped)
        self.tmp.close()

    def tearDown(self):
        os.unlink(self.tmp.name)

    def test_sections_only_with_notice(self):
        rc, out, err = run("trace.py", "timing", self.tmp.name)
        self.assertEqual(rc, 0, err)
        self.assertTrue(out["ok"])
        self.assertFalse(out["has_timestamps"])
        self.assertEqual(out["notice"], "no per-line timestamps; sections only")
        self.assertEqual(len(out["sections"]), 6)
        self.assertEqual(out["steps"], [])
        self.assertEqual(out["total_s"], 1788483880 - 1788483600)

    def test_parse_still_lists_commands(self):
        rc, out, _ = run("trace.py", "parse", self.tmp.name)
        self.assertEqual(rc, 0)
        self.assertFalse(out["has_timestamps"])
        self.assertEqual(len(out["steps"]), 5)
        self.assertIsNone(out["steps"][0]["duration_s"])


class RootCause(unittest.TestCase):
    def test_docker_hub_502(self):
        rc, out, err = run("trace.py", "root-cause", trace("docker-hub-502.log"))
        self.assertEqual(rc, 0, err)
        self.assertTrue(out["failed"])
        self.assertEqual(out["exit_code"], 125)
        self.assertEqual(out["failure_line"], "ERROR: Job failed: exit code 125")
        joined = "\n".join(out["lines"])
        self.assertIn("received unexpected HTTP status: 502 Bad Gateway", joined)
        self.assertLessEqual(len(out["lines"]), 40)
        # the window ends where the script ended (section_end step_script): no
        # artifact-upload / cleanup chatter, no runner-stream lines
        self.assertEqual(out["lines"][-1], "See 'docker run --help'.")
        self.assertIn("502 Bad Gateway", out["lines"][-2])
        self.assertNotIn("no matching files", joined)
        self.assertNotIn("Cleaning up project directory", joined)
        self.assertNotIn("section_", joined)
        self.assertNotIn("\x1b", joined)
        pats = {h["pattern"] for h in out["hits"]}
        self.assertIn("502", pats)
        self.assertIn("Job failed: exit code", pats)
        self.assertIsNone(out["no_retry_after"])

    def test_dind_dns_hits(self):
        rc, out, _ = run("trace.py", "root-cause", trace("dind-dns.log"), "--lines", "10")
        self.assertEqual(rc, 0)
        self.assertEqual(len(out["lines"]), 10)
        self.assertTrue(any(h["pattern"] == "no such host" for h in out["hits"]))
        self.assertEqual(sum(1 for h in out["hits"] if h["pattern"] == "no such host"), 4)

    def test_green_trace_not_failed(self):
        rc, out, _ = run("trace.py", "root-cause", trace("publish-green.log"))
        self.assertEqual(rc, 0)
        self.assertFalse(out["failed"])
        self.assertIsNone(out["exit_code"])
        self.assertIsNone(out["failure_line"])

    def test_declaration_line_surfaced(self):
        rc, out, _ = run("trace.py", "root-cause", trace("publish-502-after-push.log"))
        self.assertEqual(rc, 0)
        self.assertEqual(out["no_retry_after"], "build-image: pushing")
        self.assertTrue(out["failed"])


if __name__ == "__main__":
    unittest.main()
