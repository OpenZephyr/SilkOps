---
type: regex
pattern: 'RESULT:[^\n]*(?:"retry_safe":\s*false)'
match: contains
target: last_message
---
