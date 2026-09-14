# Web Asset Specifications

## Favicon Specifications

### Standard Sizes
| File | Size | Usage |
|------|------|-------|
| `favicon-16x16.png` | 16x16 | Browser tab icon |
| `favicon-32x32.png` | 32x32 | Standard browser favicon, taskbar |
| `favicon-96x96.png` | 96x96 | Google TV favicon |
| `favicon.ico` | 16+32 | Multi-resolution ICO (legacy browsers) |

### App Icon Sizes
| File | Size | Usage |
|------|------|-------|
| `apple-touch-icon.png` | 180x180 | iOS Safari |
| `android-chrome-192x192.png` | 192x192 | Android Chrome |
| `android-chrome-512x512.png` | 512x512 | Android high-res, PWA splash |

## Open Graph (Social Media) Specifications

### Primary Sizes
| File | Size | Ratio | Platforms |
|------|------|-------|-----------|
| `og-facebook.png` | 1200x630 | 1.91:1 | Facebook, LinkedIn, WhatsApp |
| `og-twitter.png` | 1200x675 | 16:9 | Twitter summary_large_image |
| `og-square.png` | 1200x1200 | 1:1 | Some contexts |

## Next.js 15 Metadata API Integration

### Favicon Integration (src/app/layout.tsx)
```typescript
import type { Metadata } from 'next';

export const metadata: Metadata = {
  icons: {
    icon: [
      { url: '/favicon-16x16.png', sizes: '16x16', type: 'image/png' },
      { url: '/favicon-32x32.png', sizes: '32x32', type: 'image/png' },
      { url: '/favicon-96x96.png', sizes: '96x96', type: 'image/png' },
    ],
    apple: [
      { url: '/apple-touch-icon.png', sizes: '180x180' },
    ],
  },
};
```

### Vercel Deployment Note
```typescript
const BASE_URL = process.env.VERCEL_URL
  ? `https://${process.env.VERCEL_URL}`
  : 'http://localhost:3000';

export const metadata: Metadata = {
  metadataBase: new URL(BASE_URL),
};
```

## WCAG Contrast Requirements

| Level | Normal Text | Large Text |
|-------|-------------|------------|
| AA | 4.5:1 | 3.0:1 |
| AAA | 7.0:1 | 4.5:1 |
