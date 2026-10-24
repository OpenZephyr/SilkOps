---
name: verify-handoff
description: Hand off the surfaces a change could not be exercised on (OS, distro, host, device) as a verify milestone with one operator-assigned issue per surface, a docs/testing.md status table, and a line on the MR. Use when the user says "I could only test this on macOS", "hand off verification", "file the untested surfaces", or an MR ships with unverified platforms.
argument-hint: "<branch or MR iid> --surfaces <a,b,...> [--project <group/project>]"
---

# verify-handoff

Result: one line per step, verdict first: the milestone `verify: <branch or MR title>`
(`silkops milestone-upsert`), `issues[] {surface, iid, action}` from `silkops issue-upsert`
(identity `plan=verify-<branch> unit=surface-<slug>`, so a rerun is `unchanged`), the
operator assigned by `silkops issue-edit --assign-operator`, the `docs/testing.md` commit,
and the MR line. Never merges; a closed issue is never edited (exit 7).

## Steps

1. Surfaces: from the MR description (`silkops mr-upsert … --dry-run` reports `current`) or
   the user. Verified = what ran; unverified = the rest, one slug each (`linux-arm64`).
2. `silkops milestone-upsert --project P --title "verify: <t>" --plan verify-<branch> --run
   <id> --marker-unit milestone --description-file <f>`: one paragraph, the MR link.
3. Per surface: `silkops issue-upsert --project P --marker-unit surface-<slug> --plan
   verify-<branch> --run <id> --title "verify: <surface>" --body-file <f> --labels verify
   --milestone "verify: <t>"`; body = what to run, expected result, the MR link. Then
   `silkops issue-edit --project P --iid <iid> --assign-operator`. Report `dead_mentions` if any.
4. `docs/testing.md`: a table `surface | status | how to verify` (verified / unverified, issue
   link), created or rows updated in place. `silkops commit --message-file <f> --path
   docs/testing.md` (`docs(testing): …`).
5. MR: `silkops mr-upsert` with the current description plus one line, `Verify: <milestone url>`,
   under the managed region when the MR carries one; the rest stays byte-identical.
6. Report: milestone URL, surface → iid → action, the commit SHA.

## Guardrails

- A surface the operator already verified is a table row, never an issue.
- No operator (`operator_username` fact or `SILKOPS_OPERATOR`): stop and ask; never guess a handle.
- Markers and `verify` labels follow `SILKOPS_MARKER`; with it off, identity is the label alone.
