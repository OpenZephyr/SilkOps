import { Section } from './section'

const flow = ['plan', 'commit', 'ship-mr', 'watch-pipeline', 'human merges', 'after-merge']
const factsLayers = ['repo .silkops/facts.json', 'overlay', 'core']

function Node({ label, muted }: { label: string; muted?: boolean }) {
  return (
    <span
      className={
        'inline-flex items-center rounded border px-2.5 py-1 text-xs ' +
        (muted ? 'border-accent/50 bg-accent/10 text-accent' : 'border-border bg-card text-foreground')
      }
    >
      {label}
    </span>
  )
}

function Arrow() {
  return (
    <span aria-hidden className="text-sm text-muted-foreground">
      →
    </span>
  )
}

export function HowItWorks() {
  return (
    <Section id="how" title="One loop, ending at a human">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-3">
        {flow.map((step, i) => (
          <div key={step} className="flex items-center gap-2">
            <Node label={step} muted={step === 'human merges'} />
            {i < flow.length - 1 && <Arrow />}
          </div>
        ))}
      </div>

      <div className="mt-10">
        <p className="text-sm text-muted-foreground">
          Facts resolve most-specific-first, so a repo can override or extend what core knows.
        </p>
        <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-3">
          {factsLayers.map((layer, i) => (
            <div key={layer} className="flex items-center gap-2">
              <Node label={layer} />
              {i < factsLayers.length - 1 && <Arrow />}
            </div>
          ))}
          <span className="ml-1 text-xs text-muted-foreground">most specific wins</span>
        </div>
      </div>
    </Section>
  )
}
