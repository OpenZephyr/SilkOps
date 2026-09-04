---
type: regex
pattern: 'RESULT:[^\n]*(?:(source_digest|target_digest)[\s\S]*sha256:)'
match: contains
target: last_message
---
