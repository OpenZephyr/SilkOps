import { SiteHeader } from '@/components/site-header'
import { Hero } from '@/components/hero'
import { Why, Principles } from '@/components/principles'
import { SkillsGrid } from '@/components/skills-grid'
import { HowItWorks } from '@/components/how-it-works'
import { CodeExample, Testing } from '@/components/code-example'
import { Faq } from '@/components/faq'
import { SiteFooter } from '@/components/site-footer'

export default function Page() {
  return (
    <div className="min-h-dvh">
      <SiteHeader />
      <main>
        <Hero />
        <Why />
        <Principles />
        <SkillsGrid />
        <HowItWorks />
        <CodeExample />
        <Testing />
        <Faq />
      </main>
      <SiteFooter />
    </div>
  )
}
