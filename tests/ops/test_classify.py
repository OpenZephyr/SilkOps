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
                        input=stdin, capture_output=True, text=True, timeout=30)
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

    def test_early_nonfatal_hit_does_not_shrink_the_window(self):
        # review #8: a non-fatal line matching the docker-hub-502 pattern BEFORE the push,
        # then the fatal one after it — the window must end at the runner's failure line, so
        # the marker between the two hits still vetoes the retry
        p = self._write(
            '$ echo "silkops: no-retry-after=build-image: pushing"\n'
            "silkops: no-retry-after=build-image: pushing\n"
            "$ scripts/publish.sh\n"
            'warning: registry-1.docker.io returned "received unexpected HTTP status: 502 Bad Gateway" on attempt 1, retrying\n'
            "build-image: pushing registry/x:1\n"
            'docker: Error response from daemon: Get "https://registry-1.docker.io/v2/x/manifests/y": received unexpected HTTP status: 502 Bad Gateway.\n'
            "ERROR: Job failed: exit code 125\n")
        rc, out, err = run("classify-failure.py", p)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["fact"], "docker-hub-502")
        self.assertTrue(out["transient"])
        self.assertTrue(out["marker_hit_before_failure"])
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["marker_line_no"], 5)
        self.assertEqual(out["failure_line_no"], 7)

    def test_no_runner_failure_line_uses_last_hit(self):
        # truncated trace (no `ERROR: Job failed`): the window ends at the fact's LAST hit
        p = self._write(
            "silkops: no-retry-after=build-image: pushing\n"
            'warning: 502 Bad Gateway from registry-1.docker.io, retrying\n'
            "build-image: pushing registry/x:1\n"
            'docker: Error response from daemon: Get "https://registry-1.docker.io/v2/x/manifests/y": received unexpected HTTP status: 502 Bad Gateway.\n')
        rc, out, _ = run("classify-failure.py", p)
        self.assertEqual(rc, 0)
        self.assertTrue(out["marker_hit_before_failure"])
        self.assertFalse(out["retry_safe"])
        self.assertEqual(out["failure_line_no"], 4)

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


class UntrustedDeclaration(unittest.TestCase):
    """review #21: the declared pattern is job output; a backtracking bomb must not hang."""

    def _write(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        f.write(text)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    FATAL = ('docker: Error response from daemon: Get "https://registry-1.docker.io/v2/x/manifests/y": '
             "received unexpected HTTP status: 502 Bad Gateway.\n"
             "ERROR: Job failed: exit code 125\n")

    def test_pathological_declaration_completes(self):
        import time
        p = self._write("silkops: no-retry-after=(a+)+$\n" + "a" * 5000 + "!\n" + self.FATAL)
        t0 = time.monotonic()
        rc, out, err = run("classify-failure.py", p)
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["no_retry_after"], "(a+)+$")
        # matched literally: no line contains the text `(a+)+$`, so retry follows the fact
        self.assertFalse(out["marker_hit_before_failure"])
        self.assertTrue(out["retry_safe"])

    def test_pathological_declaration_literal_match_still_vetoes(self):
        p = self._write("silkops: no-retry-after=(a+)+$\n" + "a" * 5000 + "!\n"
                        "step (a+)+$ reached\n" + self.FATAL)
        rc, out, err = run("classify-failure.py", p)
        self.assertEqual(rc, 0, err)
        self.assertTrue(out["marker_hit_before_failure"])
        self.assertEqual(out["marker_line_no"], 3)
        self.assertFalse(out["retry_safe"])

    def test_overlong_line_and_declaration_are_capped(self):
        long_decl = "x" * 300
        p = self._write("silkops: no-retry-after=" + long_decl + "\n" + "y" * 10000 + " " + "x" * 300 + "\n" + self.FATAL)
        rc, out, err = run("classify-failure.py", p)
        self.assertEqual(rc, 0, err)
        # the marker sits past the 4096-char cut, so it is not seen; the run completes
        self.assertFalse(out["marker_hit_before_failure"])
        self.assertEqual(out["no_retry_after"], long_decl)

    def test_plain_regex_declaration_still_a_regex(self):
        p = self._write("silkops: no-retry-after=build-image: push(ing|ed) .*:[0-9]\n"
                        "build-image: pushed registry/x:1\n" + self.FATAL)
        rc, out, err = run("classify-failure.py", p)
        self.assertEqual(rc, 0, err)
        self.assertTrue(out["marker_hit_before_failure"])
        self.assertFalse(out["retry_safe"])


if __name__ == "__main__":
    unittest.main()
