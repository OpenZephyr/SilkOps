'use client'

import { useState } from 'react'
import { Plus, Minus } from 'lucide-react'

const items = [
  {
    q: 'Does the harness ever merge?',
    a: 'No. It reports ready and stops. A human always merges — never a merge call, never a protected-branch write.',
  },
  {
    q: 'Which agents can use it?',
    a: 'Any agent that reads AGENTS.md. It ships as a Claude Code plugin, but the skills are plain bash/Python ops over the GitLab CLI (glab).',
  },
  {
    q: 'Where do recorded facts live?',
    a: 'Facts resolve most-specific-first: the repo .silkops/facts.json, then an overlay, then core. A repo can override or extend what core knows.',
  },
  {
    q: 'What does a script return?',
    a: 'One JSON object on stdout, human-readable text on stderr, and a fixed exit code. Tokens come only from the environment, never from argv, URLs, or output.',
  },
  {
    q: 'Can I turn off attribution on public repos?',
    a: "Yes. Disclosure is the operator's call — markers and attribution trailers can be switched off.",
  },
  {
    q: 'Is it open source?',
    a: 'Yes, MIT. Source of truth is GitLab; GitHub is a mirror where issues and PRs are welcome.',
  },
]

export function Faq() {
  const [open, setOpen] = useState<number | null>(0)

  return (
    <section id="faq" className="border-t border-border">
      <div className="mx-auto max-w-3xl px-6 py-16">
        <h2 className="text-sm font-bold tracking-tight text-foreground">
          <span className="text-brand">{'// '}</span>FAQ
        </h2>
        <ul className="mt-6">
          {items.map((item, i) => {
            const isOpen = open === i
            return (
              <li key={item.q} className="border-t border-border first:border-t-0">
                <button
                  type="button"
                  onClick={() => setOpen(isOpen ? null : i)}
                  aria-expanded={isOpen}
                  className="flex w-full items-center gap-3 py-3 text-left text-sm transition-colors hover:text-brand"
                >
                  <span aria-hidden className="text-brand">
                    {isOpen ? <Minus className="size-4" /> : <Plus className="size-4" />}
                  </span>
                  <span className="font-medium">{item.q}</span>
                </button>
                {isOpen && (
                  <p className="pb-4 pl-7 pr-4 text-sm leading-relaxed text-muted-foreground text-pretty">
                    {item.a}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      </div>
    </section>
  )
}
