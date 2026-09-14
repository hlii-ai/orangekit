# Next.js App Router SEO Guide

SEO optimization patterns for a Next.js 15 App Router project.

## Metadata API

### Static Metadata

```typescript
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Product Name - Tagline',
  description: 'A description within 150-160 characters. Including a CTA is recommended.',
  openGraph: { /* ... */ },
  twitter: { card: 'summary_large_image' },
  robots: { index: true, follow: true },
  alternates: { canonical: 'https://example.com' },
}
```

### Dynamic Metadata

```typescript
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params
  const product = await getProduct(slug)
  return {
    title: `${product.name} - Site Name`,
    description: product.description.slice(0, 160),
  }
}
```

## Sitemap (`app/sitemap.ts`)

## Robots (`app/robots.ts`)

## JSON-LD Structured Data

## OG Image Generation (`app/opengraph-image.tsx`)

## SEO Checklist for Next.js

- [ ] `generateMetadata()` implemented on every dynamic page
- [ ] `sitemap.ts` set up for automatic generation
- [ ] `robots.ts` defines the crawl rules
- [ ] JSON-LD applied to the main pages
- [ ] OG images generated dynamically or supplied as static files
- [ ] `next/image` used (automatic optimization)
- [ ] `next/font` used (prevents FOIT/FOUT)
- [ ] ISR/SSG used
