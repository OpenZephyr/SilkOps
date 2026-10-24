---
name: verify-findings
description: Adversarial gate between a code review and file-residuals. Sub-agents try to refute each drafted finding against the repo at a pinned sha, its history, dependency sources and vendor docs; a merged verdict table decides what may become an issue. Use when the user says "verify the findings", "adversarial pass on the review", "check the findings before filing", or before file-residuals.
argument-hint: "<findings.json | draft-issues.md> [--sha <sha>] [--groups <n>] [--budget <minutes>]"
---

# verify-findings

Result: `findings.verified.json` from `silkops verify-merge`: per finding `verdict`
(`confirmed | corrected | refuted | unverifiable`), `evidence[]`, `corrections[]`, `confidence`,
`summary`; plus `counts`, `contradictions[]`, `pass_through[]` (what file-residuals may take).
A verdict table, one line per finding, on stderr. Nothing is filed, nothing is fixed.

## Steps

1. Read the findings (JSON per `references/schema.md`, or the review's draft issues, id from
   the heading). Pin `--sha` (default `git rev-parse HEAD`). Ask for the wall-clock budget
   (default 10 min).
2. Group by subsystem (path prefix, then the review's sections) into at most `--groups` groups
   (default 4); write `group-<n>.json` per group: its findings in full, the sha, the budget share.
3. Dispatch one sub-agent per group, in parallel, with `references/verifier-brief.md` verbatim
   plus its group file; each returns one verifier JSON as `group-<n>.out.json`. Past the
   budget: its findings stay `unverifiable`; say so.
4. `silkops verify-merge --findings <f> --sha <sha> --out findings.verified.json group-*.out.json`
   merges verdicts, keeps all evidence, marks a finding two verifiers disagree on `unverifiable`
   and lists it in `contradictions[]`. Show the table.
5. Hand off: `file-residuals` takes only `pass_through[]`; the issue body carries the corrected
   claim and the evidence (`silkops link` permalinks if that verb exists, else `path:line@sha`),
   never the original text.
6. Stop. `refuted` stays in the file for the record; `unverifiable` and contradictions are
   the human's call.

## Guardrails

- Files no issue, edits nothing in the repo under review; a verifier never fixes.
- Never trust the review's numbers: counts, line totals, "merged", "stray" are recounted.
- Bounded: one dispatch round inside the budget; no second pass unasked.
- A finding missing from every verifier output is `unverifiable`, never silently passed.
