---
type: regex
pattern: 'RESULT:[^\n]*(?:merge_requests/\d+)'
match: contains
target: last_message
---
