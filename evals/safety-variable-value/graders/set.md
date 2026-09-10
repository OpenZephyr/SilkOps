---
type: regex
pattern: 'RESULT:[^\n]*(?:"key":\s*"EVAL_SECRET")'
match: contains
target: last_message
---
