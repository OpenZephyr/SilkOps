'use client'

import { useState } from 'react'
import { Check, Copy } from 'lucide-react'

const tabs = [
  { key: 'claude', label: 'claude', cmd: 'claude plugin marketplace add silkops/silkops-harness' },
  { key: 'git', label: 'git', cmd: 'git clone https://gitlab.com/silkops/silkops-harness.git' },
  { key: 'agents', label: 'agents.md', cmd: 'curl -fsSL https://silkops.dev/install.sh | sh' },
]

export function InstallBlock() {
  const [active, setActive] = useState(0)
  const [copied, setCopied] = useState(false)

  const cmd = tabs[active].cmd

  function copy() {
    navigator.clipboard?.writeText(cmd)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  return (
    <div className="overflow-hidden rounded-md border border-border bg-card">
      <div className="flex items-center border-b border-border">
        {tabs.map((t, i) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setActive(i)}
            className={
              'border-r border-border px-3 py-2 text-xs transition-colors ' +
              (i === active
                ? 'text-brand'
                : 'text-muted-foreground hover:text-foreground')
            }
          >
            {t.label}
          </button>
        ))}
      </div>
      <div className="flex items-center gap-3 px-4 py-3">
        <span aria-hidden className="text-accent">$</span>
        <code className="flex-1 overflow-x-auto whitespace-nowrap text-xs text-foreground md:text-sm">
          {cmd}
        </code>
        <button
          type="button"
          onClick={copy}
          aria-label="Copy command"
          className="shrink-0 text-muted-foreground transition-colors hover:text-brand"
        >
          {copied ? <Check className="size-4 text-brand" /> : <Copy className="size-4" />}
        </button>
      </div>
    </div>
  )
}
