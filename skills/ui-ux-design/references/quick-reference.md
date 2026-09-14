# UI/UX Design Quick Reference

A reference guide by priority for design work.

## Rule priority

| Rank | Category | Impact |
|------|----------|--------|
| 1 | Accessibility | CRITICAL |
| 2 | Touch & Interaction | CRITICAL |
| 3 | Performance | HIGH |
| 4 | Layout & Responsive | HIGH |
| 5 | Typography & Color | MEDIUM |
| 6 | Animation | MEDIUM |
| 7 | Style Selection | MEDIUM |
| 8 | Charts & Data | LOW |

## 1. Accessibility (CRITICAL)

- `color-contrast` - minimum 4.5:1 ratio for normal text
- `focus-states` - visible focus ring on interactive elements
- `alt-text` - descriptive alt text on meaningful images
- `aria-labels` - aria-label on icon-only buttons
- `keyboard-nav` - Tab order matches visual order
- `form-labels` - use label with the for attribute

## 2. Touch & Interaction (CRITICAL)

- `touch-target-size` - minimum 44x44px touch target
- `hover-vs-tap` - primary interaction uses click/tap
- `loading-buttons` - disable the button during async work
- `error-feedback` - clear error message near the point of the problem
- `cursor-pointer` - cursor-pointer on clickable elements

## 3. Performance (HIGH)

- `image-optimization` - use WebP, srcset, lazy loading
- `reduced-motion` - check prefers-reduced-motion
- `content-jumping` - reserve space for async content

## 4. Layout & Responsive (HIGH)

- `viewport-meta` - width=device-width initial-scale=1
- `readable-font-size` - minimum 16px mobile body text
- `horizontal-scroll` - content must fit the viewport width
- `z-index-management` - define a z-index scale (10, 20, 30, 50)

## 5. Typography & Color (MEDIUM)

- `line-height` - use 1.5-1.75 for body text
- `line-length` - limit to 65-75 characters per line
- `font-pairing` - match the character of the heading and body fonts

## 6. Animation (MEDIUM)

- `duration-timing` - 150-300ms for micro-interactions
- `transform-performance` - use transform/opacity instead of width/height
- `loading-states` - skeleton screen or spinner

## 7. Style Selection (MEDIUM)

- `style-match` - a style that suits the product type
- `consistency` - the same style across every page
- `no-emoji-icons` - use SVG icons, no emoji

## 8. Charts & Data (LOW)

- `chart-type` - a chart that suits the data type
- `color-guidance` - an accessible color palette
- `data-table` - provide a table alternative for accessibility

## Search command quick reference

```bash
SCRIPT="${CLAUDE_SKILL_DIR}/scripts/search.py"

# Generate a design system
python3 $SCRIPT "<query>" --design-system -p "<project name>" -f markdown

# Domain search
python3 $SCRIPT "<keywords>" --domain <style|color|ux|chart|typography|landing|product|icons|react|web>

# Stack search
python3 $SCRIPT "<keywords>" --stack <nextjs|shadcn|react|html-tailwind>

# persist (save)
python3 $SCRIPT "<query>" --design-system --persist -p "<project name>" -o dev/docs/design [--page "page name"]
```
