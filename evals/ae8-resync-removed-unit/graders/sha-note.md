---
type: regex
pattern: 'RESULT:[^\n]*(?:[0-9a-f]{7,40})'
match: contains
target: last_message
---
