# Consumer onboarding pre-flight checklist

Report every line before Phase A. A ✗ on a settings line stops the run until resolved.

| Check | How | Pass |
|---|---|---|
| Settings token present | `SILKOPS_SETTINGS_TOKEN` set in the environment | token-check exits 0 or 4 (not 3) |
| Role on the factory | `token-check.sh --project <factory> --for settings` | Maintainer (40+) |
| Role on the consumer | `token-check.sh --project <consumer> --for settings` | Maintainer (40+) |
| Token expiry | `expires_at` in the token-check result | more than 14 days out, or null with a note |
| Image tag exists | `registry.sh --project <factory> digest <image> <tag>` | digest returned |
| Consumer already allow-listed | `allowlist.sh --project <factory> get` | reported either way |
| Existing schedules | `schedule.sh --project <consumer> list` | owner and cron reported; any sub-daily cron flagged |
| Protected-branch principals on the consumer | informational from token-check `--for session` | reported; the harness never edits them |
| Conventions block in consumer `AGENTS.md` | `ops/conventions.sh --dir <checkout>` reports `unchanged` | present / to add in Phase B |

Rotation note: schedules created by the harness belong to the token's bot user. Rotate the
token with the rotate endpoint; revoking and recreating it deactivates those schedules.
