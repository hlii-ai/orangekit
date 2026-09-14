#!/usr/bin/env python3
"""Derive the artifact and download builds of the manual from the Pages build in docs/manual/.

The same page is published on three surfaces, and **the shape of a cross-page link differs on
each one**:

  Pages       relative path     user.html · ops.html
  artifact    absolute URL      each artifact is its own URL, so a relative path dies
  download    local filename    the files sit side by side, so a filename joins them

Matching them by hand always misses one — in practice a download build shipped with a link that
went nowhere, and an artifact's link pointed at nothing at all. So all three derive from one source.

Usage:
  python3 scripts/gen/manual-variants.py [--artifact-dir DIR] [--download-dir DIR]
"""
import pathlib, sys

SRC = pathlib.Path("docs/manual")
args = sys.argv[1:]
def opt(name, default):
    return args[args.index(name) + 1] if name in args else default
ART_DIR = pathlib.Path(opt("--artifact-dir", "/tmp/orangekit-manual-artifact"))
DL_DIR  = pathlib.Path(opt("--download-dir", str(pathlib.Path.home() / "Downloads")))

# Artifact URL per page — publish a new one and this is the only line to edit
ARTIFACT = {
    "user.html": "https://claude.ai/code/artifact/6adc852e-f3ea-4e36-ba2e-57db69915cf8",
    "ops.html":  "https://claude.ai/code/artifact/d7ec6155-0e08-4b37-ad68-d2209bb7495c",
}
DOWNLOAD = {
    "user.html": "OrangeKit-HarnessMap.html",
    "ops.html":  "OrangeKit-AdminMap.html",
}
# Per page: "this relative link points at which page"
LINKS = {
    "user.html": {"ops.html": "ops.html"},
    "ops.html":  {"user.html": "user.html"},
}

def rewrite(text, page, table):
    """Point relative links at the address the target surface uses. Report any that were not found."""
    missed = []
    for href, target in LINKS[page].items():
        pat = 'href="%s"' % href
        if pat not in text:
            missed.append(href); continue
        text = text.replace(pat, 'href="%s"' % table[target])
    return text, missed

def check(text, page, label, table):
    """Did the cross-page link survive onto this surface — say it is missing when it is."""
    for target in LINKS[page].values():
        if table[target] not in text:
            print("  x %-14s %s: cross-page link missing (%s)" % (page, label, table[target]))
            return 1
    return 0

bad = 0
ART_DIR.mkdir(parents=True, exist_ok=True)
for page in LINKS:
    src = SRC / page
    if not src.exists():
        print("  x source missing: %s" % src); bad += 1; continue
    raw = src.read_text()

    art, m1 = rewrite(raw, page, ARTIFACT)
    dl,  m2 = rewrite(raw, page, DOWNLOAD)
    for href in set(m1 + m2):
        print("  ! %-14s no link found to rewrite: %s" % (page, href)); bad += 1

    ap = ART_DIR / page
    ap.write_text(art)
    dp = DL_DIR / DOWNLOAD[page]
    dp.write_text(dl)
    bad += check(art, page, "artifact", ARTIFACT)
    bad += check(dl, page, "download", DOWNLOAD)
    print("  %-14s -> %-34s . %s" % (page, ap.name, DOWNLOAD[page]))

print("\nartifact build %s . download build %s" % (ART_DIR, DL_DIR))
if bad:
    sys.exit("%d problem(s) — see above" % bad)
print("cross-page links verified on every surface")
