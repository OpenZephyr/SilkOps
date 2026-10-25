import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "ops", "expand-links.py")
SHA = "0123456789abcdef0123456789abcdef01234567"


def run(body, provider="gitlab", url="https://host.example/g/p", sha=SHA):
    return subprocess.run([sys.executable, SCRIPT, "--project-url", url, "--provider", provider, "--sha", sha],
                          input=body, capture_output=True, text=True)


class ExpandLinks(unittest.TestCase):
    # #90: {{link:path[:a[-b]]}} becomes the host's permalink pinned at the sha; nothing else changes.

    def test_gitlab_range_single_and_whole_file(self):
        r = run("See {{link:ops/link.sh:3-4}}, {{link:ops/link.sh:3}} and {{link:ops/link.sh}}.\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "See https://host.example/g/p/-/blob/%s/ops/link.sh#L3-4, "
                                   "https://host.example/g/p/-/blob/%s/ops/link.sh#L3 and "
                                   "https://host.example/g/p/-/blob/%s/ops/link.sh.\n" % (SHA, SHA, SHA))
        self.assertIn("3 link(s) pinned", r.stderr)

    def test_github_format(self):
        r = run("{{link:README.md:1-2}} {{link:README.md:7}}", provider="github", url="https://github.com/o/r/")
        self.assertEqual(r.stdout, "https://github.com/o/r/blob/%s/README.md#L1-L2 "
                                   "https://github.com/o/r/blob/%s/README.md#L7" % (SHA, SHA))

    def test_gitea_format(self):
        # path segments are percent-encoded (a '+' is not a space in a path); '/' stays
        r = run("{{link:docs/a+b.md:10-12}}", provider="gitea", url="https://gitea.example/o/r")
        self.assertEqual(r.stdout, "https://gitea.example/o/r/src/commit/%s/docs/a%%2Bb.md#L10-L12" % SHA)

    def test_unknown_placeholders_stay_verbatim(self):
        body = "{{foo}} {{link}} {{link:}} {{link:a.md:x}} {{link:a.md:2-1}} {{link:a.md:0}} {{ link:a.md }} {{link:a.md:1-2-3}}\n"
        r = run(body)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, body)
        self.assertEqual(r.stderr, "")

    def test_same_start_and_end_collapses_to_one_line(self):
        r = run("{{link:a.md:5-5}}")
        self.assertEqual(r.stdout, "https://host.example/g/p/-/blob/%s/a.md#L5" % SHA)

    def test_body_without_placeholders_is_byte_identical(self):
        body = "**Goal.** keep {{braces}} and `{{link:x}}`-looking code? no: only exact placeholders change.\n\n- line\n"
        r = run(body.replace("{{link:x}}", "{{nolink:x}}"))
        self.assertEqual(r.stdout, body.replace("{{link:x}}", "{{nolink:x}}"))

    def test_sha_must_be_a_sha(self):
        r = run("{{link:a.md}}", sha="HEAD")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--sha", r.stderr)

    def test_bad_provider_is_a_usage_error(self):
        r = run("{{link:a.md}}", provider="bitbucket")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
