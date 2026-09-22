const GITHUB_URL = 'https://github.com/OpenZephyr/SilkOps'

const links = [
  ['GitHub', GITHUB_URL],
  ['Releases', `${GITHUB_URL}/releases`],
  ['MIT license', `${GITHUB_URL}/blob/main/LICENSE`],
]

export function SiteFooter() {
  return (
    <footer className="border-t border-border">
      <div aria-hidden className="hazard h-1.5 w-full" />
      <div className="mx-auto max-w-3xl px-6 py-10">
        <nav className="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
          {links.map(([label, href], i) => (
            <span key={label} className="flex items-center gap-4">
              {i > 0 && <span aria-hidden className="text-border">|</span>}
              <a href={href} className="text-muted-foreground transition-colors hover:text-brand">
                {label}
              </a>
            </span>
          ))}
        </nav>
        <p className="mt-5 text-xs leading-relaxed text-muted-foreground text-pretty">
          silkops<span className="text-brand">-harness</span> — source of truth is GitLab. GitHub is a mirror where
          issues and PRs are welcome. A human always merges.
        </p>
        <p className="mt-2 text-xs text-muted-foreground">
          {'>>'} END OF TRANSMISSION {'<<'} · MIT · open source
        </p>
      </div>
    </footer>
  )
}
