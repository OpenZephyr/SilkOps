# facts

`environment.json` — core environment facts: generic GitLab, Docker and runner behaviour. Feeds the classifier and the CI-rendered runbook.

Three layers, most specific first: the consumer repo's `.silkops/facts.json`, the plugin overlay (`overlay/facts.d/*.json`, or `$SILKOPS_FACTS_OVERLAY`), then this file. A fact belongs with the project that owns its signature; core never names a consumer.
