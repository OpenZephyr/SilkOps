---
type: regex
pattern: 'RESULT:[^\n]*(?:exit(ed)?\s*7|refused|already exists)'
match: contains
target: last_message
---
