#!/usr/bin/env python3
"""expand-links.py — expand {{link:...}} placeholders in an issue body to pinned permalinks (#90).

Usage: expand-links.py --project-url <url> --provider gitlab|github|gitea --sha <sha> < body > body

Placeholders: {{link:<path>}}, {{link:<path>:<a>}}, {{link:<path>:<a>-<b>}} become the host's blob
URL at <sha> (the formats of ops/link.sh). Anything else between double braces is left verbatim,
as is a link placeholder whose line part is not <a> or <a>-<b>. stdin to stdout, no network.
Python 3.9 stdlib only.
"""
import argparse
import re
import sys
from urllib.parse import quote

PLACEHOLDER = re.compile(r"\{\{link:(?P<path>[^:{}\s]+)(?::(?P<a>\d+)(?:-(?P<b>\d+))?)?\}\}")


def permalink(project_url, provider, sha, path, a=None, b=None):
    """The permalink for <path> at <sha>, with a line fragment when a (and b) are given."""
    base = project_url.rstrip("/")
    enc = "/".join(quote(seg, safe="") for seg in path.strip("/").split("/"))
    if provider == "gitlab":
        url = "%s/-/blob/%s/%s" % (base, sha, enc)
        frag = "" if a is None else ("#L%d" % a if b is None else "#L%d-%d" % (a, b))
    elif provider == "github":
        url = "%s/blob/%s/%s" % (base, sha, enc)
        frag = "" if a is None else ("#L%d" % a if b is None else "#L%d-L%d" % (a, b))
    elif provider == "gitea":
        url = "%s/src/commit/%s/%s" % (base, sha, enc)
        frag = "" if a is None else ("#L%d" % a if b is None else "#L%d-L%d" % (a, b))
    else:
        raise ValueError("no permalink format for provider %r" % provider)
    return url + frag


def expand(text, project_url, provider, sha):
    """Replace every well-formed {{link:...}}; return (new_text, count)."""
    count = 0

    def sub(m):
        nonlocal count
        a = int(m.group("a")) if m.group("a") else None
        b = int(m.group("b")) if m.group("b") else None
        if a is not None and a < 1:
            return m.group(0)
        if b is not None and b < a:
            return m.group(0)
        if b is not None and b == a:
            b = None
        count += 1
        return permalink(project_url, provider, sha, m.group("path"), a, b)

    return PLACEHOLDER.sub(sub, text), count


def main(argv=None):
    ap = argparse.ArgumentParser(description="expand {{link:path[:a[-b]]}} to pinned permalinks")
    ap.add_argument("--project-url", required=True)
    ap.add_argument("--provider", required=True, choices=("gitlab", "github", "gitea"))
    ap.add_argument("--sha", required=True)
    args = ap.parse_args(argv)
    if not re.fullmatch(r"[0-9a-fA-F]{7,64}", args.sha):
        sys.stderr.write("expand-links: --sha must be a commit sha, not a ref (got %r)\n" % args.sha)
        return 2
    text = sys.stdin.read()
    out, n = expand(text, args.project_url, args.provider, args.sha)
    sys.stdout.write(out)
    if n:
        sys.stderr.write("expand-links: %d link(s) pinned at %s\n" % (n, args.sha[:12]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
