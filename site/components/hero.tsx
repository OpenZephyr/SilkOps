import { InstallBlock } from './install-block'

const GITHUB_URL = 'https://github.com/OpenZephyr/SilkOps'

export function Hero() {
  return (
    <section id="top" className="mx-auto max-w-3xl px-6 pt-16 pb-14 md:pt-20">
      <p className="text-xs text-muted-foreground">
        <span className="text-accent">[*]</span> GitLab dev-loop harness for coding agents
      </p>
      <h1 className="mt-5 text-balance text-2xl font-bold leading-tight tracking-tight md:text-3xl">
        The GitLab loop, driven by small skills{' '}
        <span className="text-brand">— that stop at a human.</span>
      </h1>
      <p className="mt-5 max-w-2xl text-pretty text-sm leading-relaxed text-muted-foreground">
        A Claude Code plugin of small skills that compose bash/Python ops over the GitLab CLI
        (<span className="text-foreground">glab</span>). A session commits in the repo&apos;s own style, ships a merge
        request from a plan, watches the pipeline in bounded waits, triages failures against recorded facts, retries
        once when it is safe, reports <span className="text-brand">ready</span>, and stops. It never merges. A human
        always merges.
      </p>

      <div className="mt-8">
        <InstallBlock />
      </div>

      <div className="mt-6 flex flex-wrap items-center gap-x-5 gap-y-2 text-xs">
        <a href={GITHUB_URL} className="text-brand underline-offset-4 hover:underline">
          View on GitHub →
        </a>
        <a href={`${GITHUB_URL}#readme`} className="text-muted-foreground transition-colors hover:text-foreground">
          Read the docs
        </a>
        <span className="text-muted-foreground">MIT · open source · usable by any AGENTS.md agent</span>
      </div>
    </section>
  )
}
