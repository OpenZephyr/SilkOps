---
type: regex
pattern: 'ship-mr[\s\S]*trace-timing[\s\S]*consumer-onboarding|consumer-onboarding[\s\S]*ship-mr'
match: contains
target: last_message
---
