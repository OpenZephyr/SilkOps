#!/usr/bin/env python3
"""Tests for ops/plan-units.py (U4): unit extraction from unified plans."""

import os
import tempfile
import unittest

import json as _json
import subprocess as _subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OPS = os.path.join(REPO_ROOT, "ops")
TRACES = os.path.join(REPO_ROOT, "tests", "fixtures", "traces")
FACTS = os.path.join(REPO_ROOT, "facts", "environment.json")
CICD_PLANS = os.path.join(REPO_ROOT, "tests", "fixtures", "plans")  # unit sections of the two real plans (#57)


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

FACTORY = os.path.join(CICD_PLANS, "2026-08-30-1440-feat-ci-image-factory-plan.md")
HARNESS = os.path.join(CICD_PLANS, "2026-09-02-2334-feat-silkops-harness-plan.md")


def by_id(out):
    return {u["id"]: u for u in out["units"]}


class FactoryPlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rc, cls.out, cls.err = run("plan-units.py", FACTORY)

    def test_eight_units(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertTrue(self.out["ok"])
        self.assertEqual(self.out["count"], 8)
        self.assertEqual([u["id"] for u in self.out["units"]], ["U%d" % i for i in range(1, 9)])
        self.assertEqual(self.out["plan"], "2026-08-30-1440-feat-ci-image-factory-plan.md")

    def test_dependencies_as_written(self):
        u = by_id(self.out)
        self.assertEqual(u["U1"]["depends_on"], [])
        self.assertEqual(u["U2"]["depends_on"], ["U1"])
        self.assertEqual(u["U3"]["depends_on"], ["U2"])
        self.assertEqual(u["U4"]["depends_on"], ["U3"])
        self.assertEqual(u["U5"]["depends_on"], ["U4"])
        self.assertEqual(u["U8"]["depends_on"], ["U5"])

    def test_fields(self):
        u = by_id(self.out)["U1"]
        self.assertEqual(u["title"], "Catalog contract and scaffolding")
        self.assertEqual(u["goal"], "Establish the `images/` layout and the `image.yml` schema every later unit reads.")
        self.assertEqual(u["requirements"], ["R1", "R5"])
        self.assertEqual(u["files"], ["images/README.md", "docs/image-catalog.md"])
        self.assertEqual(u["verification"], "`docs/image-catalog.md` describes every field U2's build script reads.")
        self.assertEqual(self.out["index_present"], False)


class HarnessPlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rc, cls.out, cls.err = run("plan-units.py", HARNESS)

    def test_ten_units(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertEqual(self.out["count"], 10)

    def test_dependencies(self):
        u = by_id(self.out)
        self.assertEqual(u["U1"]["depends_on"], [])
        self.assertEqual(u["U3"]["depends_on"], ["U2"])
        self.assertEqual(u["U4"]["depends_on"], ["U1", "U3"])
        self.assertEqual(u["U9"]["depends_on"], ["U4"])  # "U4; by-hand: ..." -> only the U-ID
        self.assertEqual(u["U10"]["depends_on"], ["U5", "U6", "U7", "U8", "U9"])

    def test_files_are_backticked_paths_only(self):
        u = by_id(self.out)["U4"]
        self.assertIn("ops/trace.py", u["files"])
        self.assertIn("ops/classify-failure.py", u["files"])
        self.assertIn("tests/ops/test_trace.py", u["files"])
        self.assertNotIn("/jwt/auth", u["files"])  # inside the parenthetical description
        for f in u["files"]:
            self.assertNotIn("`", f)

    def test_index_reconciled(self):
        self.assertTrue(self.out["index_present"])
        self.assertEqual(self.out["index"]["U10"]["depends_on"], ["U5", "U6", "U7", "U8", "U9"])
        self.assertEqual(self.out["warnings"], [])
        self.assertEqual(by_id(self.out)["U8"]["requirements"], ["R10", "R11", "R15", "KTD7", "KTD12"])


class Contract(unittest.TestCase):
    def test_bad_args_exit_2(self):
        rc, out, _ = run("plan-units.py")
        self.assertEqual(rc, 2)
        self.assertEqual(out["ok"], False)
        self.assertEqual(out["error"], "usage")

    def test_missing_file_exit_5(self):
        rc, out, _ = run("plan-units.py", "/nonexistent/plan.md")
        self.assertEqual(rc, 5)
        self.assertEqual(out["error"], "not_found")

    def test_heading_wins_over_index(self):
        md = (
            "## Units\n\n### Unit Index\n\n| U-ID | Title | Files touched | Depends on |\n|---|---|---|---|\n"
            "| U1 | Alpha | `a` | — |\n| U2 | Beta | `b` | U1 |\n| U3 | Gamma | `c` | U1 |\n\n"
            "### U1. Alpha\n\n- **Goal:** first.\n- **Requirements:** none\n- **Dependencies:** none\n"
            "- **Files:**\n  - `a/one.sh` (create — thing)\n- **Verification:** ok.\n\n"
            "### U2. Beta\n\n- **Goal:** second.\n- **Dependencies:** U1\n- **Files:**\n  - `b/two.sh`\n"
            "- **Verification:**\n  - v1\n  - v2\n\n"
            "### U3. Gamma\n\n- **Goal:** third.\n- **Dependencies:** U1, U2\n\n## After\n"
        )
        f = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
        f.write(md)
        f.close()
        self.addCleanup(os.unlink, f.name)
        rc, out, _ = run("plan-units.py", f.name)
        self.assertEqual(rc, 0)
        self.assertEqual(out["count"], 3)
        u = by_id(out)
        self.assertEqual(u["U1"]["requirements"], [])
        self.assertEqual(u["U1"]["files"], ["a/one.sh"])
        self.assertEqual(u["U2"]["verification"], "v1\nv2")
        self.assertEqual(u["U3"]["depends_on"], ["U1", "U2"])  # heading wins over index's U1
        self.assertEqual(out["index"]["U3"]["depends_on"], ["U1"])
        self.assertEqual(len(out["warnings"]), 1)
        self.assertIn("U3", out["warnings"][0])


class ProseAndBraces(unittest.TestCase):
    """#25 (v0.2 U7): prose in Dependencies, sentence breaks in Requirements, brace expansion in Files."""
    PLAN = """---
title: t
---
### U1. First
- **Goal:** g
- **Requirements:** R1, R2, R16. KTD1, KTD2.
- **Dependencies:** none
- **Files:**
  - `apps/gitlab-runner/steam/{helmrelease.yaml,values.yaml}` (modify)
  - `ops/one.sh` (create)
- **Verification:** v
### U2. Second
- **Goal:** g
- **Requirements:** R3
- **Dependencies:** none for the repo change; U8 bootstraps it live.
- **Files:**
  - `x.md`
- **Verification:** v
### U3. Third
- **Goal:** g
- **Requirements:** —
- **Dependencies:** U1, U2
- **Files:**
  - `y.md`
- **Verification:** v
"""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.path = os.path.join(self.d, "plan.md")
        with open(self.path, "w") as f:
            f.write(self.PLAN)
        self.rc, self.out, self.err = run("plan-units.py", self.path)
        self.assertEqual(self.rc, 0, self.err)

    def test_dependencies_prose_after_none_is_not_a_dependency(self):
        u = by_id(self.out)
        self.assertEqual(u["U2"]["depends_on"], [])
        self.assertEqual(u["U3"]["depends_on"], ["U1", "U2"])

    def test_requirements_split_on_sentence_breaks(self):
        self.assertEqual(by_id(self.out)["U1"]["requirements"], ["R1", "R2", "R16", "KTD1", "KTD2"])

    def test_files_brace_expansion(self):
        self.assertEqual(by_id(self.out)["U1"]["files"],
                         ["apps/gitlab-runner/steam/helmrelease.yaml", "apps/gitlab-runner/steam/values.yaml", "ops/one.sh"])


MILESTONES = os.path.join(CICD_PLANS, "milestones-two.md")


class MilestonesProfile(unittest.TestCase):
    """#78: `## M<n> · <title>` milestones with `### M<n>-<nn>` units, auto-detected."""

    @classmethod
    def setUpClass(cls):
        cls.rc, cls.out, cls.err = run("plan-units.py", MILESTONES)

    def test_detected_and_grouped(self):
        self.assertEqual(self.rc, 0, self.err)
        self.assertEqual(self.out["profile"], "milestones")
        self.assertEqual(self.out["count"], 5)
        self.assertEqual([(m["id"], m["title"], m["units"]) for m in self.out["milestones"]],
                         [("M1", "Foundations", ["M1-01", "M1-02", "M1-03"]), ("M2", "Delivery", ["M2-01", "M2-02"])])
        u = by_id(self.out)
        self.assertEqual(u["M1-03"]["milestone"], "Foundations")   # `### M1-03: Logging` (colon) and `## M2: Delivery`
        self.assertEqual(u["M2-02"]["milestone"], "Delivery")
        self.assertEqual(u["M2-02"]["milestone_id"], "M2")
        self.assertEqual(self.out["warnings"], [])

    def test_scope_acceptance_labels_and_shared_line(self):
        u = by_id(self.out)
        self.assertEqual(u["M1-01"]["goal"], "lay out the directories and the build entry point.")
        self.assertEqual(u["M1-01"]["acceptance"], "`make build` runs on a clean clone.")
        self.assertEqual(u["M1-01"]["labels"], ["build", "infra"])     # same line as Depends on, after ·
        self.assertEqual(u["M1-01"]["depends_on"], [])
        self.assertEqual(u["M1-02"]["labels"], ["core"])               # same line, no separator
        self.assertEqual(u["M1-02"]["depends_on"], ["M1-01"])
        self.assertEqual(u["M1-02"]["acceptance"], "missing file → defaults\nmalformed file → exit 2")
        self.assertEqual(u["M1-03"]["labels"], [])
        self.assertEqual(u["M2-02"]["labels"], ["docs"])               # its own bullet

    def test_cross_milestone_dependency(self):
        self.assertEqual(by_id(self.out)["M2-01"]["depends_on"], ["M1-02", "M1-03"])

    def test_profile_override_and_unified_shape_unchanged(self):
        rc, out, _ = run("plan-units.py", MILESTONES, "--profile", "unified")
        self.assertEqual(rc, 0)
        self.assertEqual(out["count"], 0)   # no `### U<N>.` headings in a milestones plan
        rc, out, _ = run("plan-units.py", os.path.join(CICD_PLANS, "sync-two.md"))
        self.assertEqual(out["profile"], "unified")
        self.assertEqual(out["milestones"], [])
        self.assertEqual(sorted(out["units"][0].keys()),
                         ["depends_on", "files", "goal", "id", "requirements", "title", "verification"])

    def test_facts_custom_regexes(self):
        d = tempfile.mkdtemp()
        plan = os.path.join(d, "plan.md")
        with open(plan, "w") as f:
            f.write("## Phase A — Start\n\n### T1 One\n- **Does:** first\n- **After:** none\n\n"
                    "## Phase B — Finish\n\n### T2 Two\n- **Does:** second\n- **After:** T1 · **Tags:** `x`\n")
        facts = os.path.join(d, "facts.json")
        with open(facts, "w") as f:
            _json.dump({"plan": {"profile": "milestones", "milestone_heading": r"^## (Phase [A-Z]) — (.+?)\s*$",
                                 "unit_heading": r"^### (T\d+)\s+(.+?)\s*$", "goal_bullet": "^does$",
                                 "depends_bullet": "^after$", "labels_bullet": "^tags$", "unit_id": r"T\d+"}}, f)
        core = os.path.join(d, "core.json")
        with open(core, "w") as f:
            _json.dump({"facts": []}, f)
        rc, out, err = run("plan-units.py", plan, "--facts", facts, "--facts", core)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out["profile"], "milestones")
        self.assertEqual([m["title"] for m in out["milestones"]], ["Start", "Finish"])
        u = by_id(out)
        self.assertEqual(u["T1"]["goal"], "first")
        self.assertEqual(u["T2"]["depends_on"], ["T1"])
        self.assertEqual(u["T2"]["labels"], ["x"])
        self.assertEqual(u["T2"]["milestone"], "Finish")
        # a bad regex in the facts is a usage error, not a crash
        with open(facts, "w") as f:
            _json.dump({"plan": {"unit_heading": "^### ("}}, f)
        rc, out, _ = run("plan-units.py", plan, "--facts", facts)
        self.assertEqual(rc, 2)
        self.assertEqual(out["error"], "usage")


if __name__ == "__main__":
    unittest.main()
