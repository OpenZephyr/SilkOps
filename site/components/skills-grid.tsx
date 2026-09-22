import { Section } from './section'

const skills = [
  ['commit', 'Commit named files in the repo\u2019s own style.'],
  ['ship-mr', 'Push a branch, open or re-sync its MR from a plan.'],
  ['watch-pipeline', 'Watch the pipeline in bounded waits.'],
  ['after-merge', 'Do the housekeeping once a human has merged.'],
  ['milestone-from-plan', 'Turn a plan into a milestone and its issues.'],
  ['file-residuals', 'File the leftover work as short issues.'],
  ['trace-timing', 'Trace where pipeline and job time goes.'],
  ['registry-ops', 'Operate on packages and container images.'],
  ['consumer-onboarding', 'Wire a new consumer project onto the harness.'],
]

export function SkillsGrid() {
  return (
    <Section id="skills" title="Nine composable skills">
      <ul className="grid gap-x-8 gap-y-4 sm:grid-cols-2">
        {skills.map(([name, desc]) => (
          <li key={name} className="flex gap-3 text-muted-foreground">
            <span aria-hidden className="shrink-0 text-brand">
              [*]
            </span>
            <span className="text-pretty">
              <span className="font-bold text-foreground">{name}</span>
              <br />
              <span className="text-muted-foreground">{desc}</span>
            </span>
          </li>
        ))}
      </ul>
    </Section>
  )
}
