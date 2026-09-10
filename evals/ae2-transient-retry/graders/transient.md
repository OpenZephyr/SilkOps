---
type: regex
pattern: 'RESULT:[^\n]*(?:"transient":\s*true)'
match: contains
target: last_message
---
