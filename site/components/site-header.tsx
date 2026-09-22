import { ThemeToggle } from './theme-toggle'

const GITHUB_URL = 'https://github.com/OpenZephyr/SilkOps'

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-10 border-b border-border bg-background/85 backdrop-blur-sm">
      <div className="mx-auto flex h-14 max-w-3xl items-center justify-between px-6">
        <a href="#top" className="text-sm text-foreground">
          silkops<span className="text-brand">-harness</span>
        </a>
        <nav className="flex items-center gap-1 text-xs">
          <a
            href="#skills"
            className="hidden rounded px-2 py-1 text-muted-foreground transition-colors hover:text-foreground sm:inline"
          >
            Skills
          </a>
          <a
            href="#faq"
            className="hidden rounded px-2 py-1 text-muted-foreground transition-colors hover:text-foreground sm:inline"
          >
            FAQ
          </a>
          <a
            href={GITHUB_URL}
            className="rounded px-2 py-1 text-muted-foreground transition-colors hover:text-foreground"
          >
            GitHub
          </a>
          <ThemeToggle />
        </nav>
      </div>
    </header>
  )
}
