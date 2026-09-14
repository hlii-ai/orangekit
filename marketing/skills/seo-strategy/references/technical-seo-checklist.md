# Technical SEO Checklist

Technical SEO items to check during a site audit (Mode 2).

## Crawlability & Indexability

- [ ] `robots.txt` exists and is valid
- [ ] `sitemap.xml` exists and is valid
- [ ] Canonical URL consistency
- [ ] Crawl budget optimized

## URL Structure

- [ ] Clean URL structure (parameters minimized)
- [ ] Slugs contain keywords
- [ ] Depth of 3 levels or less
- [ ] Hyphens used, lowercase consistently

## Redirects

- [ ] No 301 redirect chains (1 hop maximum)
- [ ] No redirect loops

## HTTP/Security

- [ ] HTTPS everywhere
- [ ] No mixed content
- [ ] HSTS header set

## Performance (Core Web Vitals)

- [ ] **LCP** < 2.5s
- [ ] **FID/INP** < 200ms
- [ ] **CLS** < 0.1

## Image Optimization

- [ ] Next-generation formats (WebP, AVIF) used
- [ ] lazy loading
- [ ] Descriptive alt text on every image
- [ ] srcset/sizes responsive images

## Structured Data

- [ ] JSON-LD format used
- [ ] The applicable schema types applied (Organization, Product, Article, FAQ, and so on)
- [ ] Passes the Google Rich Results Test

## Server Configuration

- [ ] Server response time < 200ms
- [ ] Gzip/Brotli compression enabled
- [ ] Appropriate Cache-Control headers
- [ ] A CDN used (for static assets)
