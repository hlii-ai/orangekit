#!/bin/bash
# skills/ui-ux-design/scripts/design-sync.sh — canvas ↔ MASTER.md token cross-check
#
# The two documents **do not overlap in jurisdiction**: MASTER.md holds the tokens and the direction, the canvas holds the per-screen composition.
# The overlapping set is only three things — color, font, signature — and that is exactly where drift is possible.
# This script looks at only the **two a machine can decide** (color, font) — the signature is prose,
# so set operations are impossible on it and Claude compares it by eye.
#
#   design-sync.sh [--master <MASTER.md>] [--canvas <canvas.html>]
#
#   --master <path>   default: the first of dev/docs/design/*/MASTER.md
#   --canvas <path>   local HTML downloaded from the Saved canvas
#   --self-test       self-test with fixtures
#   -h, --help
#
# Verdict: a color or font of MASTER.md that is **absent** from the canvas is a defect — a signal the write-back is unfinished.
#       The reverse direction (a color only in the canvas) is a WARN and does not raise the exit code:
#       a canvas legitimately carries derived shades, borders, and overlays. Folding those into a block
#       makes a false positive, and false positives make the user turn the guard off.
#
# Exit codes: 0 = match · 1 = mismatch · 2 = undecidable
#            Undecidable has two branches and they **mean opposite things**:
#              · MASTER.md has no `## Canvas` section  → canvas not in use (normal)
#              · the section exists but the canvas is unreachable → declaration and reality disagree (report it)
set -uo pipefail   # no -e: run every check to the end and emit the whole report

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_D=""; C_0=""; }

# Copies doctor.sh's conventions (not a source — lib/common.sh's set -Eeuo pipefail and its
# ERR trap conflict with the "run every check to the end" policy). return 0 is explicit:
# the original bad/warn return 1 when $2 is empty, so `... && warn ... || ok ...` runs both sides.
detail() { [ -n "${1:-}" ] || return 0; printf '%s\n' "$1" | sed "s/^/      ${C_D}/;s/\$/${C_0}/"; return 0; }
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
skip() { printf "  ${C_D}–${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }
num()  { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

MASTER=""; CANVAS=""; SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --master)   MASTER="${2:-}"; shift 2 ;;
    --canvas)   CANVAS="${2:-}"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h|--help)  sed -n '2,27p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
    *) printf "unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
  esac
done

# ── extraction ────────────────────────────────────────────────────────
# Colors are taken only from the `### Color Palette` (persist) or `### Colors` (one-shot output) table.
# Sweeping the whole file lets the example CSS in Component Specs pass itself off as palette.
master_hexes() {   # $1 master
  awk '/^### (Color Palette|Colors)/{on=1; next} on && /^### /{on=0} on' "$1" \
    | grep -oiE '#[0-9a-f]{6}|#[0-9a-f]{3}\b' | norm_hex
}
# Expand 3-digit to 6-digit and uppercase — #FFF and #ffffff must not be counted as different colors.
norm_hex() {
  tr '[:lower:]' '[:upper:]' \
    | awk '{ h=substr($0,2)
             if (length(h)==3) h=substr(h,1,1) substr(h,1,1) substr(h,2,1) substr(h,2,1) substr(h,3,1) substr(h,3,1)
             print "#" h }' \
    | sort -u
}
canvas_hexes() { grep -oiE '#[0-9a-f]{6}|#[0-9a-f]{3}\b' "$1" | norm_hex; }

master_fonts() {   # $1 master — the Heading/Body roles only
  grep -oE '^- \*\*(Heading|Body) Font:\*\*.*' "$1" \
    | sed -E 's/^- \*\*(Heading|Body) Font:\*\* *//' \
    | sed -E 's/[[:space:]]+$//' | grep -v '^$' | sort -u
}
# Is that name actually used in a font-family declaration of the canvas? An incidental string
# outside a declaration (a font name appearing in body copy) does not count as font usage.
canvas_font_decls() { grep -oiE 'font-family[^;}]*' "$1" | tr '[:upper:]' '[:lower:]'; }

# ── cross-check ───────────────────────────────────────────────────────
compare() {   # $1 master  $2 canvas
  local m="$1" c="$2" miss_c=0 miss_f=0 extra
  local mh ch
  mh=$(master_hexes "$m"); ch=$(canvas_hexes "$c")

  if [ -z "$mh" ]; then
    warn "no palette found in MASTER.md" "there is no \`### Color Palette\` table — skipping the color cross-check"
  else
    local h
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      printf '%s\n' "$ch" | grep -qxF "$h" || { bad "MASTER color missing from the canvas: $h" "the write-back is unfinished, or the canvas dropped this color"; miss_c=$((miss_c+1)); }
    done <<< "$mh"
    [ "$miss_c" -eq 0 ] && ok "all $(num "$(printf '%s\n' "$mh" | wc -l)") MASTER palette colors present in the canvas"
  fi

  # The reverse direction is a WARN — derived shades and borders are not folded into a block.
  extra=$(printf '%s\n' "$ch" | grep -vxF -f <(printf '%s\n' "$mh") 2>/dev/null | head -8)
  if [ -n "$extra" ] && [ -n "$mh" ]; then
    warn "$(num "$(printf '%s\n' "$ch" | grep -vxcF -f <(printf '%s\n' "$mh") 2>/dev/null)") colors present only in the canvas" \
         "$(printf '%s' "$extra" | tr '\n' ' ')
If they are derived shades this is normal. If they are a new role, put them into the MASTER.md palette"
  fi

  local mf f decls
  mf=$(master_fonts "$m"); decls=$(canvas_font_decls "$c")
  if [ -z "$mf" ]; then
    warn "no font role found in MASTER.md" "there is no \`- **Heading Font:**\` / \`- **Body Font:**\` line"
  else
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      printf '%s' "$decls" | grep -qiF "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" \
        || { bad "MASTER font missing from the canvas font-family: $f" "the write-back is unfinished, or the canvas uses a different font"; miss_f=$((miss_f+1)); }
    done <<< "$mf"
    [ "$miss_f" -eq 0 ] && ok "all MASTER font roles present in the canvas"
  fi

  skip "this script does not judge the signature" "it is prose, so set operations are impossible — Claude compares \`## Signature\` against the canvas by eye"
  return 0
}

# ── self-test ─────────────────────────────────────────────────────────
# Confirms that a fixture with a planted defect gets its verdict **for the intended reason**. Alive ≠ working.
self_test() {
  sec "design-sync self-test"
  local T; T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  local sfail=0

  cat > "$T/MASTER.md" <<'MD'
# Design System: Fixture

## Signature
One large visual anchor.

## Direction review
Changed the accent to get out of the default cluster.

## Canvas
- URL: https://example.invalid/artifact/fixture
- Confirmed: 2026-09-10

## Global Rules

### Color Palette

| Role | Hex | CSS Variable |
|------|-----|--------------|
| Primary | `#2563EB` | `--color-primary` |
| CTA/Accent | `#F97316` | `--color-cta` |

### Typography

- **Heading Font:** Playfair Display
- **Body Font:** Inter
MD

  # Matching fixture — a derived shade (#1E40AF) is planted on purpose: it is a WARN, not a defect.
  cat > "$T/match.html" <<'HT'
<style>
  :root { --p: #2563eb; --c: #F97316; --shade: #1E40AF; }
  h1 { font-family: "Playfair Display", serif; }
  body { font-family: 'Inter', sans-serif; }
</style>
HT
  sed 's/#2563eb/#7C3AED/' "$T/match.html" > "$T/hex-drift.html"
  sed "s/'Inter'/'Roboto'/" "$T/match.html" > "$T/font-drift.html"
  grep -v '^## Canvas$' "$T/MASTER.md" | grep -v 'example.invalid' | grep -v '^- Confirmed' > "$T/MASTER-nocanvas.md"

  _case() {   # $1 label  $2 expected code  $3 expected phrase  $4.. args
    local label="$1" want="$2" needle="$3"; shift 3
    local out rc
    out=$(bash "$0" "$@" 2>&1); rc=$?
    if [ "$rc" -ne "$want" ]; then
      bad "$label — exit $rc (expected $want)" "$(printf '%s' "$out" | head -4)"; sfail=$((sfail+1)); return 0
    fi
    if ! printf '%s' "$out" | grep -qF "$needle"; then
      bad "$label — exit is right but the reason differs" "expected phrase: $needle"; sfail=$((sfail+1)); return 0
    fi
    ok "$label — exit $rc · reason cross-check passed"
    return 0
  }

  _case "matching canvas"             0 "present in the canvas"  --master "$T/MASTER.md" --canvas "$T/match.html"
  _case "canvas with one hex changed" 1 "#2563EB"                --master "$T/MASTER.md" --canvas "$T/hex-drift.html"
  _case "canvas with body font changed" 1 "Inter"                --master "$T/MASTER.md" --canvas "$T/font-drift.html"
  _case "MASTER with no canvas"       2 "canvas not in use"      --master "$T/MASTER-nocanvas.md"
  _case "declared but nothing there"  2 "could not be reached"   --master "$T/MASTER.md"

  printf "\n"
  if [ "$sfail" -gt 0 ]; then
    printf "${C_R}self-test failures: %d${C_0}\n" "$sfail"; return 1
  fi
  printf "${C_G}self-test passed — 5 fixtures${C_0}\n"; return 0
}

if [ "$SELFTEST" -eq 1 ]; then
  self_test; exit $?
fi

# ── run ───────────────────────────────────────────────────────────────
if [ -z "$MASTER" ]; then
  MASTER=$(ls -1 dev/docs/design/*/MASTER.md 2>/dev/null | head -1)
fi
[ -n "$MASTER" ] && [ -f "$MASTER" ] || {
  printf "undecidable — MASTER.md not found%s\n" "${MASTER:+: $MASTER}" >&2
  printf "  point --master at dev/docs/design/<project>/MASTER.md\n" >&2
  exit 2; }

sec "design token cross-check"
printf "  ${C_D}MASTER: %s${C_0}\n" "$MASTER"

CANVAS_DECLARED=0
grep -qE '^## Canvas' "$MASTER" && CANVAS_DECLARED=1

if [ -z "$CANVAS" ]; then
  if [ "$CANVAS_DECLARED" -eq 0 ]; then
    ok "canvas not in use — MASTER.md is canonical down to the composition" \
       "there is no \`## Canvas\` section. The layout is carried by the direction-review one-pass items (rules/ui-design.md §3)"
    exit 2
  fi
  warn "canvas is declared but could not be reached" \
       "$(grep -A3 -E '^## Canvas' "$MASTER" | grep -oE 'https?://[^ )]+' | head -1)
Download the published version and pass it with --canvas"
  exit 2
fi

[ -f "$CANVAS" ] || {
  warn "could not reach the canvas file" "$CANVAS"; exit 2; }

printf "  ${C_D}canvas: %s${C_0}\n" "$CANVAS"
compare "$MASTER" "$CANVAS"

printf "\n"
if [ "$FAIL" -gt 0 ]; then
  printf "${C_R}%d mismatch(es)${C_0} · %d warning(s) — the write-back is unfinished (Step 2.7)\n" "$FAIL" "$WARN"
  exit 1
fi
printf "${C_G}tokens match${C_0} · %d warning(s) — only the signature eye-check remains\n" "$WARN"
exit 0
