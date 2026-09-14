# Sections Guide — Detailed Implementation Reference

This document contains the exact implementation patterns for every section of the scroll-stop
website. Read the relevant section when building that part of the site.

## Table of Contents

1. [Starscape Background](#1-starscape-background)
2. [Loader](#2-loader)
3. [Scroll Progress Bar](#3-scroll-progress-bar)
4. [Navbar (Scroll-to-Pill)](#4-navbar)
5. [Hero Section](#5-hero-section)
6. [Scroll Animation (Frame Sequence)](#6-scroll-animation)
7. [Annotation Cards (Snap-Stop)](#7-annotation-cards)
8. [Specs Section (Count-Up)](#8-specs-section)
9. [Features Grid](#9-features-grid)
10. [CTA Section](#10-cta-section)
11. [Testimonials (Optional)](#11-testimonials)
12. [Card Scanner (Optional)](#12-card-scanner)
13. [Footer](#13-footer)

---

## 1. Starscape Background

A fixed canvas that sits behind all content, creating a subtle, living background of twinkling
stars that slowly drift.

### Structure

```html
<canvas id="starscape"></canvas>
```

### Styling

```css
#starscape {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
  z-index: 0;
  pointer-events: none;
  opacity: 0.6;
}
```

### JavaScript

Generate ~180 stars, each with:
- Random x, y position
- Random radius (0.3-1.5px)
- Random base opacity (0.2-0.8)
- Random drift speed (x: -0.02 to 0.02, y: -0.01 to 0.01)
- Random twinkle speed and phase

Animation loop:
```javascript
function animateStars() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  stars.forEach(star => {
    star.x += star.driftX;
    star.y += star.driftY;
    if (star.x < 0) star.x = canvas.width;
    if (star.x > canvas.width) star.x = 0;
    if (star.y < 0) star.y = canvas.height;
    if (star.y > canvas.height) star.y = 0;
    const twinkle = Math.sin(Date.now() * star.twinkleSpeed + star.twinklePhase);
    const opacity = star.baseOpacity + twinkle * 0.3;
    ctx.beginPath();
    ctx.arc(star.x, star.y, star.radius, 0, Math.PI * 2);
    ctx.fillStyle = `rgba(255, 255, 255, ${Math.max(0, opacity)})`;
    ctx.fill();
  });
  requestAnimationFrame(animateStars);
}
```

Scale canvas for devicePixelRatio on resize.

---

## 2. Loader

Full-screen overlay that shows while frames are preloading. Disappears with a fade-out once all frames are loaded.

- Full viewport, `position: fixed`, `z-index: 9999`
- Progress bar: accent color, `transition: width 0.3s ease`
- When all frames loaded: fade opacity to 0, then `display: none`

---

## 3. Scroll Progress Bar

Thin bar at the very top of the viewport showing overall page scroll progress.

```css
#scrollProgress {
  position: fixed;
  top: 0;
  left: 0;
  height: 3px;
  width: 0%;
  background: linear-gradient(90deg, var(--accent), var(--accent-light, var(--accent)));
  z-index: 10000;
  transition: width 0.1s linear;
}
```

---

## 4. Navbar

Starts as a full-width bar, then on scroll transforms into a centered floating pill with glass-morphism styling.

Scrolled (pill) state via `.nav-scrolled` class:
```css
#navbar.nav-scrolled .nav-inner {
  max-width: 820px;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  backdrop-filter: blur(20px);
  border-radius: 100px;
  padding: 10px 24px;
}
```

Toggle class at `scrollY > 80`.

---

## 5. Hero Section

Opening section with headline, subtitle, CTA buttons, and decorative elements (orbs, grid overlay, scroll hint).

**Orbs**: Large blurred circles using accent color at low opacity, `filter: blur(80px)`.

**Grid overlay**: Subtle CSS grid lines with `rgba(255,255,255,0.02)`.

**Buttons**: Primary = accent bg + glow shadow; Secondary = transparent + border.

---

## 6. Scroll Animation

The core: a sticky canvas that plays video forward/backward based on scroll.

```css
.scroll-animation {
  height: 350vh;
  position: relative;
}
.scroll-sticky {
  position: sticky;
  top: 0;
  height: 100vh;
  width: 100%;
  overflow: hidden;
}
```

Responsive heights: 300vh (tablet), 250vh (mobile).

Frame preloading: load all extracted JPEG frames into Image objects.

Scroll-to-frame mapping: calculate progress from section bounding rect, map to frame index, draw only when frame changes.

Cover-fit drawing: desktop = cover-fit (fills canvas, crops overflow); mobile = zoomed contain-fit (1.2x zoom).

Canvas resize: `canvas.width = innerWidth * devicePixelRatio`.

---

## 7. Annotation Cards

Cards that appear over the scroll animation at specific progress points with snap-stop behavior.

- `data-show` and `data-hide` attributes control visibility based on scroll progress (0.0-1.0)
- Glass-morphism styling: `backdrop-filter: blur(20px)`, `border-radius: 20px`
- Snap-stop: `overflow: hidden` for 600ms when entering a snap zone
- Mobile: compact single-line (number + title only, `bottom: 1.5vh`)

---

## 8. Specs Section

Four stat numbers that count up from 0 when scrolled into view.

- `easeOutExpo` easing function
- 200ms stagger between items
- IntersectionObserver trigger at 0.3 threshold
- Glow text-shadow during counting animation
- Mobile: 2x2 grid

---

## 9. Features Grid

Glass-morphism cards in a responsive grid (3 columns desktop, 1 column mobile).

```css
.feature-card {
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.06);
  backdrop-filter: blur(20px);
  border-radius: 20px;
  padding: 32px;
}
.feature-card:hover {
  transform: translateY(-4px);
  border-color: rgba(var(--accent-rgb), 0.2);
}
```

---

## 10. CTA Section

Focused call-to-action section. Centered text + large primary button. Add an orb behind for visual emphasis.

---

## 11. Testimonials (Optional)

Horizontal drag-to-scroll cards with `scroll-snap-type: x mandatory`. Include drag-to-scroll mouse handlers.

---

## 12. Card Scanner (Optional)

Three.js-based particle effect. Only build if user specifically requests it.
- Particle count: 2000-5000
- Trigger: IntersectionObserver at 30% visible
- Include Three.js from CDN

---

## 13. Footer

Simple footer with brand name and optional links.

```css
footer {
  border-top: 1px solid rgba(255, 255, 255, 0.06);
  padding: 60px 32px 40px;
  text-align: center;
}
```
