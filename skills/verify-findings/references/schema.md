# verify-findings: JSON shapes

Three files move through the skill: the findings a review drafted, one verifier output per
group, and the merged `findings.verified.json` that `silkops verify-merge` writes. All are
plain JSON (no YAML parser exists in the harness).

## Findings (input)

```json
{
  "source": "reviews/2026-10-20-edu-wind-tunnel.md",
  "sha": "3f2c9a1e7b0d4c5a8e6f1b2d3c4e5f6a7b8c9d0e",
  "findings": [
    {
      "id": "F-03",
      "title": "fan_ctl: PWM ramp retries five times",
      "claim": "ramp_pwm() retries five times before raising FAN_FAULT; the datasheet allows one.",
      "location": "firmware/fan_ctl.c:118",
      "subsystem": "firmware",
      "severity": "medium",
      "suggested_fix": "retry once, then fault"
    }
  ]
}
```

| field | required | meaning |
|---|---|---|
| `source` | yes | path or URL of the review result the findings came from |
| `sha` | yes | the commit every claim is checked against; `verify-merge --sha` must match |
| `findings[].id` | yes | stable identity, reused as the file-residuals key suffix |
| `findings[].title` | yes | one line, becomes the issue title after corrections |
| `findings[].claim` | yes | the exact assertion to refute, numbers included |
| `findings[].location` | no | `path:line` (or `path`) where the claim points |
| `findings[].subsystem` | no | grouping hint; absent, the skill groups by path prefix |
| `findings[].severity` | no | the review's own scale, passed through untouched |
| `findings[].suggested_fix` | no | passed through; never applied by a verifier |

From markdown draft issues: one finding per `## ` heading, `id` from the heading's leading
token (`## F-03 …`) or its ordinal, `claim` the first paragraph, `location` the first
`path:line` in the body.

## Verifier output (one file per group)

```json
{
  "group": "firmware",
  "sha": "3f2c9a1e7b0d4c5a8e6f1b2d3c4e5f6a7b8c9d0e",
  "elapsed_s": 212,
  "findings": [
    {
      "id": "F-03",
      "verdict": "corrected",
      "confidence": 0.9,
      "summary": "retries three times, not five; the datasheet limit is as stated",
      "evidence": [
        {"kind": "file", "ref": "firmware/fan_ctl.c:118-131@3f2c9a1e", "note": "for (i = 0; i < 3; i++)"},
        {"kind": "doc", "ref": "vendor/DS-4411 rev C §7.2", "note": "one retry permitted"}
      ],
      "corrections": [
        {"field": "claim", "from": "retries five times", "to": "retries three times"}
      ]
    }
  ]
}
```

`verdict` is one of `confirmed` (claim holds as written), `corrected` (holds with the listed
corrections), `refuted` (does not hold; evidence says why), `unverifiable` (no evidence either
way inside the budget; `summary` says what was missing). `confidence` is 0 to 1.
`evidence[].kind` is `file`, `commit`, `doc`, `dependency` or `history`; `ref` is a
`path:line@sha`, a commit sha, a tag plus path, or a URL. Evidence for both directions is
kept, including evidence that supports a `refuted` finding's original claim.

## Verified (output of `silkops verify-merge`)

```json
{
  "ok": true,
  "sha": "3f2c9a1e7b0d4c5a8e6f1b2d3c4e5f6a7b8c9d0e",
  "source": "reviews/2026-10-20-edu-wind-tunnel.md",
  "verifiers": 4,
  "counts": {"confirmed": 1, "corrected": 7, "refuted": 2, "unverifiable": 0},
  "pass_through": ["F-01", "F-03"],
  "contradictions": [],
  "findings": [
    {
      "id": "F-03",
      "title": "fan_ctl: PWM ramp retries five times",
      "claim": "ramp_pwm() retries five times before raising FAN_FAULT; the datasheet allows one.",
      "location": "firmware/fan_ctl.c:118",
      "verdict": "corrected",
      "confidence": 0.9,
      "summary": "retries three times, not five; the datasheet limit is as stated",
      "evidence": [{"kind": "file", "ref": "firmware/fan_ctl.c:118-131@3f2c9a1e", "note": "for (i = 0; i < 3; i++)"}],
      "corrections": [{"field": "claim", "from": "retries five times", "to": "retries three times"}],
      "verifiers": ["firmware"]
    }
  ]
}
```

Rules the merge applies:

- Every input finding appears once; one no verifier reported is `unverifiable` with
  `summary: "no verifier reported this finding"`.
- Two verifiers, same verdict: evidence and corrections are concatenated, `confidence` is the
  lower one.
- Two verifiers, different verdicts: `verdict` becomes `unverifiable`, both verdicts are kept
  in `contradictions[] {id, verdicts: [{verifier, verdict}]}`, all evidence stays.
- `pass_through[]` lists `confirmed` and `corrected` ids, in input order. file-residuals takes
  this list and nothing else.
- A verifier `sha` that differs from `--sha` is a usage error (exit 2): the evidence would
  point at a different tree.

The stderr table has one line per finding: `id  verdict  confidence  summary`, then the counts.
