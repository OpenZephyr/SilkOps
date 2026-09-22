import { Section } from './section'

export function CodeExample() {
  return (
    <Section id="example" title="One command, one JSON result">
      <div className="overflow-hidden rounded-md border border-border bg-card">
        <div className="flex items-center gap-2 border-b border-border px-4 py-2">
          <span className="size-2.5 rounded-full bg-accent/60" />
          <span className="text-xs text-muted-foreground">ops/watch.sh</span>
        </div>
        <pre className="overflow-x-auto p-4 text-xs leading-relaxed md:text-sm">
          <code>
            <span className="text-accent">$ </span>
            <span className="text-foreground">ops/watch.sh --project group/project --mr 42 --wait 300</span>
            {'\n'}
            <span className="text-brand">
              {'{"ok":true,"status":"success","ready":true,"detailed_merge_status":"mergeable"}'}
            </span>
          </code>
        </pre>
      </div>
      <p className="mt-3 text-xs text-muted-foreground">
        Fig 1. JSON on stdout, human text on stderr, a fixed exit code.
      </p>
    </Section>
  )
}

export function Testing() {
  return (
    <Section id="testing" title="Two tiers gate every change">
      <dl className="grid gap-x-8 gap-y-6 sm:grid-cols-2">
        <div className="flex gap-3">
          <span aria-hidden className="shrink-0 text-brand">
            [*]
          </span>
          <div>
            <dt className="font-bold text-foreground">Tier 1</dt>
            <dd className="mt-1.5 leading-relaxed text-muted-foreground text-pretty">
              Offline, fixture-driven tests gate every change.
            </dd>
          </div>
        </div>
        <div className="flex gap-3">
          <span aria-hidden className="shrink-0 text-brand">
            [*]
          </span>
          <div>
            <dt className="font-bold text-foreground">Tier 2</dt>
            <dd className="mt-1.5 leading-relaxed text-muted-foreground text-pretty">
              Plugin evals run against a throwaway project.
            </dd>
          </div>
        </div>
      </dl>
    </Section>
  )
}
