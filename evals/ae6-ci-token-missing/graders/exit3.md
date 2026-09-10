---
type: regex
pattern: 'RESULT:[^\n]*(?:exit(ed| code)?\s*[:=]?\s*3|"error":\s*"no_token")'
match: contains
target: last_message
---
