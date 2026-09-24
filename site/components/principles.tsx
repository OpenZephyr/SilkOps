import { Section } from './section'

const features = [
  ['LSP-free glue', 'Named, repeatable, tested ops over glab — no re-derived GitLab API code.'],
  ['One result per run', 'Each script returns a single JSON object and a fixed exit code.'],
  ['Bounded waits', 'Pipelines are polled in bounded waits, not hand-watched.'],
  ['Recorded facts', 'CI failures are triaged against facts instead of re-learned each time.'],
  ['Short by contract', 'Verdict-first issue bodies and triage notes. No generated files in your repo.'],
  ['Human-terminated', 'The loop always ends at a human. The harness reports ready and stops.'],
]

const principles = [
  'A human merges. Never a merge call, never a protected-branch write.',
  'One JSON object on stdout, human text on stderr, fixed exit codes.',
  'Tokens only from the environment; never in argv, URLs, or output.',
  'Facts live with the project that owns the signature: repo, then overlay, then core.',
  'Verdict first. Short issue bodies. Short triage notes. No generated files in your repo.',
  'Disclosure is the operator\u2019s call: markers and attribution trailers can be switched off for public repos.',
]

export function Why() {
  return (
    <Section id="why" title="What is SilkOps?">
      <p className="max-w-2xl text-pretty leading-relaxed text-muted-foreground">
        Agents re-derive the same GitLab API glue, poll pipelines by hand, re-learn the same CI failures, and write
        verbose issues and notes. The harness makes each of those a named, repeatable, tested capability with one JSON
        result per script and a fixed exit-code contract.
      </p>
      <ul className="mt-7 grid gap-x-8 gap-y-3 sm:grid-cols-2">
        {features.map(([name, desc]) => (
          <li key={name} className="flex gap-3 text-muted-foreground">
            <span aria-hidden className="shrink-0 text-brand">
              [*]
            </span>
            <span className="text-pretty">
              <span className="font-bold text-foreground">{name}</span>
              {'  '}
              {desc}
            </span>
          </li>
        ))}
      </ul>
      <a
        href="https://github.com/OpenZephyr/SilkOps#readme"
        className="mt-8 inline-flex items-center rounded-md border border-border px-3 py-2 text-xs text-foreground transition-colors hover:border-brand hover:text-brand"
      >
        Read docs →
      </a>
    </Section>
  )
}

export function Principles() {
  return (
    <Section id="principles" title="Constraints the harness holds to">
      <ul className="grid gap-x-8 gap-y-3 sm:grid-cols-2">
        {principles.map((p) => (
          <li key={p} className="flex gap-3 leading-relaxed text-muted-foreground">
            <span aria-hidden className="shrink-0 text-accent">
              [*]
            </span>
            <span className="text-pretty">{p}</span>
          </li>
        ))}
      </ul>
    </Section>
  )
}
