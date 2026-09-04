---
type: regex
pattern: 'RESULT:[^\n]*(?:"retried":\s*\[\s*\])'
match: contains
target: last_message
---
