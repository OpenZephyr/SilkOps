import type { ReactNode } from 'react'

export function Section({
  id,
  title,
  children,
}: {
  id: string
  title: string
  children: ReactNode
}) {
  return (
    <section id={id} className="border-t border-border">
      <div className="mx-auto max-w-3xl px-6 py-16">
        <h2 className="text-sm font-bold tracking-tight text-foreground">
          <span className="text-brand">{'// '}</span>
          {title}
        </h2>
        <div className="mt-6 text-sm leading-relaxed">{children}</div>
      </div>
    </section>
  )
}
