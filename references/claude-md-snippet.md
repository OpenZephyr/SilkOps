# CLAUDE.md snippet for GitLab repos using the harness

Add this block to the repo's `CLAUDE.md` (create the file if absent). `consumer-onboarding`
adds it in the pin MR and skips lines already present.

```markdown
## Shipping and tracking (silkops-harness)

- The shipping process for this repo is the `ship-mr` skill from the `silkops-harness`
  plugin: it opens or updates the GitLab merge request for the current branch and hands
  off to `watch-pipeline`. It never merges; a human merges. Use it in place of
  `ce-commit-push-pr`.
- Accepted code-review residuals are filed with `file-residuals`; plan units become
  milestone issues with `milestone-from-plan`.
- Environment facts and the operating loop live in the plugin: `facts/environment.json`
  and `references/runbook.md`. Add a fact there, not as a comment here.
```
