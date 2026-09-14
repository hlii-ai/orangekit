// skills/ui-ux-design/scripts/ui-probe.browser.mjs
//
// The execution half of ui-probe.sh. Opens the browser once and gathers **recon and evidence in the same pass**,
// then prints one JSON blob to stdout. Human-readable formatting, verdicts and exit codes are the caller's (bash) job.
//
// Never call this directly — the contract (--help, 0/1/2, three-state) is owned by ui-probe.sh.
//
// Argument: argv[2] = config JSON (built by ui-probe.sh)
// Exit codes: 0 = collection succeeded (regardless of defects) · 2 = undecidable (no browser, connection failed)

import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const CFG = JSON.parse(process.argv[2] || '{}');

const VIEWPORTS = {
  mobile: { width: 390, height: 844, isMobile: true },
  tablet: { width: 768, height: 1024, isMobile: true },
  desktop: { width: 1440, height: 900, isMobile: false },
};

function bail(reason, hint) {
  process.stdout.write(JSON.stringify({ undecidable: reason, hint: hint || null }) + '\n');
  process.exit(2);
}

// -- resolving playwright ------------------------------------------------
// An ESM import resolves **relative to this file**. This file lives inside the plugin cache and
// has no node_modules. It has to use the consumer project's install, so resolve relative to cwd.
async function loadChromium() {
  const req = createRequire(path.join(process.cwd(), 'ui-probe.resolve.cjs'));
  const errs = [];
  for (const name of ['playwright', 'playwright-core', '@playwright/test']) {
    try {
      const mod = await import(pathToFileURL(req.resolve(name)).href);
      const chromium = (mod.chromium || mod.default?.chromium);
      if (chromium) return { chromium, from: name };
    } catch (e) { errs.push(`${name}: ${e.code || e.message}`); }
  }
  bail(
    'playwright could not be found',
    `Install it in this project: npm i -D playwright && npx playwright install chromium\n(paths checked: ${errs.join(' / ')})`
  );
}

// -- the collector that runs inside the page ------------------------------
// Passed as a string and executed with page.evaluate. Everything it references is a browser global.
function inPageCollect(opts) {
  // Inventory ceiling. Keeping the default small is the point — this output goes into the model's context.
  // Widen it with --recon only when you actually need to find a selector.
  const CAP = opts.recon ? 40 : 8;
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
  };
  const name = (el) =>
    (el.getAttribute('aria-label') ||
      el.getAttribute('placeholder') ||
      (el.innerText || '').trim().split('\n')[0] ||
      el.getAttribute('name') ||
      el.getAttribute('title') ||
      el.value ||
      '').slice(0, 60);
  const hint = (el) => {
    if (el.getAttribute('data-testid')) return `[data-testid="${el.getAttribute('data-testid')}"]`;
    if (el.id) return `#${el.id}`;
    if (el.getAttribute('aria-label')) return `[aria-label="${el.getAttribute('aria-label')}"]`;
    const t = name(el);
    return t ? `text=${t}` : el.tagName.toLowerCase();
  };

  // -- recon: inventory of interactive elements --
  const grab = (sel) => Array.from(document.querySelectorAll(sel)).filter(vis);
  const buttons = grab('button, [role="button"], input[type="submit"], input[type="button"]');
  const links = grab('a[href]');
  const inputs = grab('input:not([type="hidden"]):not([type="submit"]):not([type="button"]), textarea, select');
  const pack = (els) => ({
    total: els.length,
    items: els.slice(0, CAP).map((el) => ({ name: name(el), hint: hint(el) })),
  });
  const recon = { buttons: pack(buttons), links: pack(links), inputs: pack(inputs) };

  if (!opts.quality) return { recon, quality: null };

  // -- measured quality (all of it is a WARN axis — a false positive must not escalate into a block) --
  const q = {};

  // 1) 44px touch targets — only meaningful in a mobile viewport.
  //    An inline link inside a paragraph structurally cannot be 44px -> exclude anchors with display:inline.
  if (opts.isMobile) {
    const targets = [...buttons, ...links, ...inputs].filter((el) => {
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') return false;
      if (el.tagName === 'A' && getComputedStyle(el).display === 'inline') return false;
      return true;
    });
    const bad = targets
      .map((el) => ({ el, r: el.getBoundingClientRect() }))
      .filter(({ r }) => r.width < 44 || r.height < 44)
      .map(({ el, r }) => ({ name: name(el), hint: hint(el), w: Math.round(r.width), h: Math.round(r.height) }));
    q.touchTargets = { checked: targets.length, violations: bad.slice(0, 5), total: bad.length };
  }

  // 2) 16px body text — look at the **median**, not at individual elements. One caption or footnote must not raise a warning.
  const paras = grab('p, li').filter((el) => (el.innerText || '').trim().length > 20);
  if (paras.length) {
    const sizes = paras.map((el) => parseFloat(getComputedStyle(el).fontSize)).sort((a, b) => a - b);
    const median = sizes[Math.floor(sizes.length / 2)];
    q.bodyFontSize = { median: Math.round(median * 10) / 10, sampled: sizes.length, ok: median >= 16 };
  }

  // 3) cursor:pointer on interactive elements — exclude disabled ones (not-allowed is correct there).
  const clickable = [...buttons, ...links].filter(
    (el) => !el.disabled && el.getAttribute('aria-disabled') !== 'true'
  );
  const noPointer = clickable
    .filter((el) => getComputedStyle(el).cursor !== 'pointer')
    .map((el) => ({ name: name(el), hint: hint(el), cursor: getComputedStyle(el).cursor }));
  q.cursor = { checked: clickable.length, violations: noPointer.slice(0, 5), total: noPointer.length };

  // 4) 4.5:1 contrast ratio — remove the sources of false positives first.
  //    If an ancestor carries a background image or gradient the computed value is not the real background, so **skip it.**
  const lum = (rgb) => {
    const c = rgb.map((v) => {
      const s = v / 255;
      return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const parse = (s) => {
    const m = (s || '').match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(',').map((x) => parseFloat(x));
    return { rgb: [p[0], p[1], p[2]], a: p.length > 3 ? p[3] : 1 };
  };
  const bgOf = (el) => {
    let cur = el;
    while (cur && cur !== document.documentElement.parentNode) {
      const s = getComputedStyle(cur);
      if (s.backgroundImage && s.backgroundImage !== 'none') return null; // undecidable
      const b = parse(s.backgroundColor);
      if (b && b.a > 0.95) return b.rgb;
      cur = cur.parentElement;
    }
    return [255, 255, 255];
  };
  const texts = Array.from(document.querySelectorAll('p, li, span, a, h1, h2, h3, h4, h5, h6, button, label, td'))
    .filter(vis)
    .filter((el) => Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim().length > 1));
  const cbad = [];
  let cchecked = 0;
  for (const el of texts.slice(0, 400)) {
    const s = getComputedStyle(el);
    const fg = parse(s.color);
    const bg = bgOf(el);
    if (!fg || !bg || fg.a < 0.95) continue;
    cchecked++;
    const size = parseFloat(s.fontSize);
    const bold = parseInt(s.fontWeight, 10) >= 700;
    const need = size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5;
    const l1 = lum(fg.rgb), l2 = lum(bg);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    if (ratio < need) {
      cbad.push({ name: name(el), hint: hint(el), ratio: Math.round(ratio * 100) / 100, need });
    }
  }
  q.contrast = { checked: cchecked, violations: cbad.slice(0, 5), total: cbad.length };

  return { recon, quality: q };
}

// -- run -----------------------------------------------------------------
const { chromium, from } = await loadChromium();

let browser;
try {
  browser = await chromium.launch({ headless: true });
} catch (e) {
  bail(
    'chromium could not be launched',
    `Install the browser binary: npx playwright install chromium\n(${e.message.split('\n')[0]})`
  );
}

const timeout = (CFG.timeout || 15) * 1000;
const ignore = CFG.ignore ? new RegExp(CFG.ignore) : null;
const result = {
  undecidable: null,
  url: CFG.url,
  playwrightFrom: from,
  wait: { strategy: null, warning: null },
  runtime: { consoleErrors: [], pageErrors: [], failedRequests: [] },
  quality: null,
  recon: null,
  screenshots: [],
  reducedMotion: null,
};

// Fold by text so the same defect is not reported once per viewport.
const seen = new Set();
const push = (bucket, key, obj) => {
  if (seen.has(key)) return;
  seen.add(key);
  result.runtime[bucket].push(obj);
};

async function visit(vpName, opts = {}) {
  const vp = VIEWPORTS[vpName];
  const ctx = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    isMobile: false, // deviceScaleFactor/touch emulation distorts the font measurements
    ...(opts.reducedMotion ? { reducedMotion: 'reduce' } : {}),
  });
  const page = await ctx.newPage();

  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const t = m.text();
    if (ignore && ignore.test(t)) return;
    // A failed resource load is also printed to the console by the browser. failedRequests reports the same
    // fact more precisely, with URL and status, so it is not counted twice here.
    if (/^Failed to load resource/.test(t)) return;
    push('consoleErrors', 'c:' + t, { text: t.slice(0, 300), viewport: vpName });
  });
  page.on('pageerror', (e) => {
    const t = e.message || String(e);
    push('pageErrors', 'p:' + t, { text: t.slice(0, 300), viewport: vpName });
  });
  page.on('response', (r) => {
    const s = r.status();
    if (s < 400) return;
    if (ignore && ignore.test(r.url())) return;
    if (/favicon\.ico(\?|$)/.test(r.url())) return;
    push('failedRequests', 'r:' + r.url(), { url: r.url().slice(0, 200), status: s, viewport: vpName });
  });
  page.on('requestfailed', (r) => {
    const u = r.url();
    if (ignore && ignore.test(u)) return;
    if (/favicon\.ico(\?|$)/.test(u)) return;
    push('failedRequests', 'r:' + u, {
      url: u.slice(0, 200),
      status: r.failure()?.errorText || 'failed',
      viewport: vpName,
    });
  });

  try {
    await page.goto(CFG.url, { waitUntil: 'load', timeout });
  } catch (e) {
    await ctx.close();
    throw new Error(`connection failed — ${e.message.split("\n")[0]}`);
  }

  // -- waiting discipline --
  // Visibility-based waiting comes first. networkidle is an API Playwright discourages, and it
  // never settles in polling, SSE or websocket apps. Fixed waits are not used.
  if (CFG.ready) {
    await page.locator(CFG.ready).first().waitFor({ state: 'visible', timeout });
    result.wait.strategy = `visible: ${CFG.ready}`;
  } else {
    // The stand-in when --ready is absent: wait until the body has content. Gets past an empty #root in an SPA.
    try {
      await page.waitForFunction(
        () => document.body && ((document.body.innerText || '').trim().length > 0 ||
          document.body.querySelector('img, svg, canvas, video')),
        { timeout }
      );
    } catch { /* if content never appears, it is observed as-is below */ }
    result.wait.strategy = 'load + body content appeared';
    result.wait.warning = 'passing --ready <selector> is far more reliable — this is a stand-in wait';
  }

  const collected = await page.evaluate(
    `(${inPageCollect.toString()})(${JSON.stringify({ quality: CFG.quality, recon: CFG.recon, isMobile: vp.isMobile })})`
  );

  if (opts.reducedMotion) {
    result.reducedMotion = await page.evaluate(() =>
      document.getAnimations()
        .filter((a) => a.playState === 'running' && (a.effect?.getTiming?.().duration || 0) > 0).length
    );
  } else {
    if (!result.recon) result.recon = collected.recon;
    if (collected.quality) result.quality = { ...(result.quality || {}), ...collected.quality };

    if (CFG.out) {
      const p = path.join(CFG.out, `${vpName}.png`);
      await page.screenshot({ path: p, fullPage: true });
      result.screenshots.push({ viewport: vpName, path: p });
    }
  }

  await ctx.close();
}

try {
  for (const v of CFG.viewports) {
    if (!VIEWPORTS[v]) continue;
    await visit(v);
  }
  // prefers-reduced-motion needs its own context — look at it once, on desktop.
  if (CFG.quality) await visit('desktop', { reducedMotion: true });
} catch (e) {
  await browser.close();
  bail(e.message, null);
}

await browser.close();
process.stdout.write(JSON.stringify(result) + '\n');
