## Shipping and tracking

- One branch per change; the default branch is never pushed to directly, and a human merges.
- Commit by naming files, never the whole tree; the message follows the repo's existing style.
- One merge request per branch, described from the plan or issue it implements.
- Watch CI with a bounded wait and at most one retry of a transient failure; report the first failing line, not the whole log.
