#!/usr/bin/env python3
"""Tests for facts/environment.json (KTD7): shape, regex validity, unique ids,
and that each fixture-backed fact actually matches its fixture."""

import json
import os
import re
import sys
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

REQUIRED = ("id", "pattern", "explanation", "class", "retry_safe", "step", "source")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def cleaned_lines(path):
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    return [ANSI.sub("", l).replace("\r", "") for l in text.split("\n")]


class FactsFile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(FACTS) as f:
            cls.doc = json.load(f)
        cls.facts = cls.doc["facts"]

    def test_schema_version(self):
        self.assertEqual(self.doc["schema_version"], "1")
        self.assertIsInstance(self.facts, list)
        self.assertGreaterEqual(len(self.facts), 10)

    def test_every_fact_has_required_fields(self):
        for fact in self.facts:
            for key in REQUIRED:
                self.assertIn(key, fact, "fact %r lacks %s" % (fact.get("id"), key))
                self.assertNotEqual(fact[key], "", "fact %r has empty %s" % (fact.get("id"), key))
            self.assertIn(fact["class"], ("transient", "permanent"), fact["id"])
            self.assertIsInstance(fact["retry_safe"], bool, fact["id"])
            self.assertRegex(fact["id"], r"^[a-z0-9][a-z0-9-]*$")
            self.assertRegex(fact["source"], r"^[\w./-]+(\.\w+)(:\d+(-\d+)?)?$", fact["id"])

    def test_patterns_compile(self):
        for fact in self.facts:
            re.compile(fact["pattern"])

    def test_ids_unique(self):
        ids = [f["id"] for f in self.facts]
        self.assertEqual(len(ids), len(set(ids)))

    def test_permanent_is_never_retry_safe(self):
        for fact in self.facts:
            if fact["class"] == "permanent":
                self.assertFalse(fact["retry_safe"], fact["id"])

    def _first_match(self, path):
        lines = cleaned_lines(path)
        for fact in self.facts:
            rx = re.compile(fact["pattern"])
            if any(rx.search(l) for l in lines):
                return fact
        return None

    def test_docker_hub_fixture(self):
        fact = self._first_match(trace("docker-hub-502.log"))
        self.assertEqual(fact["id"], "docker-hub-502")
        self.assertEqual(fact["class"], "transient")
        self.assertTrue(fact["retry_safe"])

    def test_dind_dns_fixture(self):
        fact = self._first_match(trace("dind-dns.log"))
        self.assertEqual(fact["id"], "dind-service-dns")
        self.assertEqual(fact["class"], "permanent")

    def test_pipefail_fixture(self):
        fact = self._first_match(trace("grep-q-pipefail.log"))
        self.assertEqual(fact["id"], "grep-q-sigpipe-under-pipefail")
        self.assertEqual(fact["class"], "permanent")

    def test_green_trace_matches_nothing(self):
        self.assertIsNone(self._first_match(trace("publish-green.log")))

    def test_expected_ids_present(self):
        ids = {f["id"] for f in self.facts}
        for want in ("pull-access-denied", "ipv6-service-alias", "registry-listing-lag",
                     "misfiring-cron-every-minute", "manifest-inspect-network-error",
                     "cross-project-variable-expansion", "git-identity-missing",
                     "bind-mount-outside-builds", "tag-already-exists"):
            self.assertIn(want, ids)


if __name__ == "__main__":
    unittest.main()
