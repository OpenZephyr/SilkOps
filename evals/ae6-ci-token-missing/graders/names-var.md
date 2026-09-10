---
type: regex
pattern: 'RESULT:[^\n]*(?:SILKOPS_CI_TOKEN)'
match: contains
target: last_message
---
