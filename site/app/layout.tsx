import type { Metadata, Viewport } from 'next'
import { IBM_Plex_Mono } from 'next/font/google'
import './globals.css'

const ibmMono = IBM_Plex_Mono({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700'],
  variable: '--font-ibm-mono',
})

export const metadata: Metadata = {
  title: 'silkops-harness — a GitLab dev-loop harness for coding agents',
  description:
    'An open-source (MIT) Claude Code plugin of small skills that compose bash/Python ops over the GitLab CLI: commit, ship an MR, watch the pipeline, triage failures against recorded facts. A human always merges.',
}

export const viewport: Viewport = {
  colorScheme: 'dark light',
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f7f8f8' },
    { media: '(prefers-color-scheme: dark)', color: '#080d15' },
  ],
}

const themeInit = `
try {
  var t = localStorage.getItem('silkops-theme');
  if (t === 'light') document.documentElement.classList.add('light');
} catch (e) {}
`

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" className={`${ibmMono.variable} bg-background`}>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeInit }} />
      </head>
      <body className="font-mono antialiased">
        {children}
      </body>
    </html>
  )
}
