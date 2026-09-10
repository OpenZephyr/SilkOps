---
type: regex
pattern: 'RESULT:[^\n]*(?:"ready":\s*true)'
match: contains
target: last_message
---
