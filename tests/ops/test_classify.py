#!/usr/bin/env python3
"""Tests for ops/classify-failure.py (U4, KTD6/KTD7): fact matching against
cleaned trace lines and the `silkops: no-retry-after=` immutability guard."""

import os
import tempfile
import unittest

import json as _json
import subprocess as _subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OPS = os.path.join(REPO_ROOT, "ops")
TRACES = os.path.join(REPO_ROOT, "tests", "fixtures", "traces")
FACTS = os.path.join(REPO_ROOT, "facts", "environment.json")


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


class Contract(unittest.TestCase):
    def test_bad_args_exit_2(self):
        rc, out, _ = run("classify-failure.py")
        self.assertEqual(rc, 2)
        self.assertEqual(out["ok"], False)
        self.assertEqual(out["error"], "usage")
        rc, out, _ = run("classify-failure.py", trace("dind-dns.log"), "--nope")
        self.assertEqual(rc, 2)

    def test_missing_trace_exit_5(self):
        rc, out, _ = run("classify-failure.py", trace("nope.log"))
        self.assertEqual(rc, 5)
        self.assertEqual(out["error"], "not_found")

    def test_missing_facts_exit_5(self):
        rc, out, _ = run("classify-failure.py", trace("dind-dns.log"), "--facts", "/nonexistent/facts.json")
        self.assertEqual(rc, 5)
        self.assertEqual(out["ok"], False)
        self.assertIn("facts", out["message"])


class DockerHub502(unittest.TestCase):
    def test_transient_retry_safe(self):
        rc, out, err = run("classify-failure.py", trace("docker-hub-502.log"), "--facts", FACTS)
        self.assertEqual(rc, 0, err)
        self.assertTrue(out["ok"])
        self.assertEqual(out["class"], "transient")
        self.assertTrue(out["transient"])
        self.assertTrue(out["retry_safe"])
        self.assertEqual(out["fact"], "docker-hub-502")
        self.assertIsNone(out["no_retry_after"])
        self.assertFalse(out["marker_hit_before_failure"])
        self.assertIn("no declaration", out["reason"])
        self.assertTrue(any(h["fact"] == "docker-hub-502" for h in out["hits"]))

    def test_default_facts_path(self):
        rc, out, _ = run("classify-failure.py", trace("docker-hub-502.log"))
        self.assertEqual(rc, 0)
        self.assertEqual(out["fact"], "docker-hub-502")

    def test_strict_exit_0_when_safe(self):
        rc, out, _ = run("classify-failure.py", trace("docker-hub-502.log"), "--strict")
        self.assertEqual(rc, 0)


class Publish502AfterPush(unittest.TestCase):
    """AE7: the same 502 after `build-image: pushing` is transient but NOT retry-safe."""

    def test_guard_blocks_retry(self):
        rc, out, err = run("classify-failure.py", trace("publish-502-after-push.log"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["class"], "transient")
        self.assertTrue(out["transient"])
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["fact"], "docker-hub-502")
        self.assertEqual(out["no_retry_after"], "build-image: pushing")
        self.assertTrue(out["marker_hit_before_failure"])
        self.assertIn("immutab", out["reason"].lower())
        # the guard hit is the factory's own echo, not the declaration's `$ echo` command line
        self.assertEqual(out["marker_line_no"], 1222)
        self.assertIn("build-image: pushing godot:4.7.2-stable-r2", out["reason"])

    def test_strict_exit_6(self):
        rc, out, _ = run("classify-failure.py", trace("publish-502-after-push.log"), "--strict")
        self.assertEqual(rc, 6)
        self.assertTrue(out["ok"])
        self.assertFalse(out["retry_safe"])


class Permanent(unittest.TestCase):
    def test_dind_dns(self):
        rc, out, err = run("classify-failure.py", trace("dind-dns.log"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["class"], "permanent")
        self.assertFalse(out["transient"])
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["fact"], "dind-service-dns")

    def test_grep_q_pipefail(self):
        rc, out, err = run("classify-failure.py", trace("grep-q-pipefail.log"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["class"], "permanent")
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["fact"], "grep-q-sigpipe-under-pipefail")
        # a `build-image: pushing` line occurs in this trace, but nothing declares it
        self.assertIsNone(out["no_retry_after"])
        self.assertFalse(out["marker_hit_before_failure"])


class NoDeclarationAndUnknown(unittest.TestCase):
    def _write(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        f.write(text)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_no_declaration_follows_fact(self):
        # transient fact, no declaration -> retry_safe follows the fact (true)
        p = self._write(
            "$ build-image: pushing registry/x:1\n"
            'docker: Error response from daemon: Get "https://registry-1.docker.io/v2/x/manifests/y": received unexpected HTTP status: 502 Bad Gateway.\n'
            "ERROR: Job failed: exit code 125\n")
        rc, out, _ = run("classify-failure.py", p)
        self.assertEqual(rc, 0)
        self.assertEqual(out["fact"], "docker-hub-502")
        self.assertTrue(out["retry_safe"])
        self.assertIsNone(out["no_retry_after"])

    def test_declaration_line_itself_is_not_a_hit(self):
        # the declaration (its `$ echo` command line AND its output) contains the pattern
        # text; neither may count as the guard tripping
        p = self._write(
            '$ echo "silkops: no-retry-after=build-image: pushing"\n'
            "silkops: no-retry-after=build-image: pushing\n"
            'docker: Error response from daemon: Get "https://registry-1.docker.io/v2/x/manifests/y": received unexpected HTTP status: 502 Bad Gateway.\n'
            "ERROR: Job failed: exit code 125\n")
        rc, out, _ = run("classify-failure.py", p)
        self.assertEqual(out["no_retry_after"], "build-image: pushing")
        self.assertFalse(out["marker_hit_before_failure"])
        self.assertTrue(out["retry_safe"])

    def test_unknown_failure(self):
        p = self._write("$ make\nsomething odd happened\nERROR: Job failed: exit code 1\n")
        rc, out, _ = run("classify-failure.py", p)
        self.assertEqual(rc, 0)
        self.assertEqual(out["class"], "unknown")
        self.assertIsNone(out["fact"])
        self.assertFalse(out["transient"])
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["hits"], [])

    def test_unknown_with_strict_exit_6(self):
        p = self._write("ERROR: Job failed: exit code 1\n")
        rc, out, _ = run("classify-failure.py", p, "--strict")
        self.assertEqual(rc, 6)

    def test_reads_stdin(self):
        with open(trace("dind-dns.log")) as f:
            rc, out, _ = run("classify-failure.py", "-", stdin=f.read())
        self.assertEqual(rc, 0)
        self.assertEqual(out["fact"], "dind-service-dns")


if __name__ == "__main__":
    unittest.main()
