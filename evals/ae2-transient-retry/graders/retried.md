---
type: regex
pattern: 'RESULT:[^\n]*(?:"retried":\s*\[\s*\d)'
match: contains
target: last_message
---
