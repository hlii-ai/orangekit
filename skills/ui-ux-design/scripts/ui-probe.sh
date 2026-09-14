#!/bin/bash
# skills/ui-ux-design/scripts/ui-probe.sh — render proof
#
# Opens an already-running screen once and collects **recon and evidence in the same pass**.
# It does not start the server — the built-in /run does that. This script takes that URL.
#
#   ui-probe.sh --url <URL> [options]
#
#   --url <URL>         http(s):// or file://  (required)
#   --ready <selector>  wait until this element is visible — **the most reliable wait there is**
#   --viewport <list>   default mobile,desktop  (mobile 390x844 · tablet 768x1024 · desktop 1440x900)
#   --out <dir>         where evidence is stored. Default .claude/.orangekit/ui-probe/ (keeps only the last 5 runs)
#   --ignore <regex>    exclude from failed requests and console (favicon.ico is excluded by default)
#   --recon             emit up to 40 recon inventory entries per kind (default 8)
#   --timeout <sec>     default 15
#   --quality off       turn off the quality measurements (the WARN axis)
#   --json              one unformatted blob of JSON
#   --self-test         self-test with fixtures
#   -h, --help
#
# Verdict: only console errors, uncaught exceptions, and failed requests are defects.
#       The quality measurements (contrast · touch target · body size · cursor · motion) are **WARN and do not raise the exit code** —
#       if a false positive such as text over an image spreads into a block, the user turns the guard off.
#
# Exit codes: 0 = no defects · 1 = defects found · 2 = undecidable (node·playwright·connection failure)·usage error
set -uo pipefail   # no -e: run every check to the end and emit the whole report

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_D=""; C_0=""; }

# Copies doctor.sh's conventions (not a source — lib/common.sh's set -Eeuo pipefail and its
# ERR trap conflict with the "run every check to the end" policy). return 0 is explicit:
# the original bad/warn return 1 when $2 is empty, so `... && warn ... || ok ...` runs both sides.
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
# The detail ($2) may span several lines — indent the continuation lines too.
detail() { [ -n "${1:-}" ] || return 0; printf '%s\n' "$1" | sed "s/^/      ${C_D}/;s/\$/${C_0}/"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
skip() { printf "  ${C_D}–${C_0} %s\n" "$1"; detail "${2:-}"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }
num()  { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$HERE/ui-probe.browser.mjs"

URL=""; READY=""; VIEWPORTS="mobile,desktop"; OUT=""; IGNORE=""; RECON=0
TIMEOUT=15; QUALITY=1; JSON_ONLY=0; MODE="run"

while [ $# -gt 0 ]; do
  case "$1" in
    --url)      URL="${2:-}"; shift 2 || exit 2 ;;
    --ready)    READY="${2:-}"; shift 2 || exit 2 ;;
    --viewport) VIEWPORTS="${2:-}"; shift 2 || exit 2 ;;
    --out)      OUT="${2:-}"; shift 2 || exit 2 ;;
    --ignore)   IGNORE="${2:-}"; shift 2 || exit 2 ;;
    --recon)    RECON=1; shift ;;
    --timeout)  TIMEOUT=$(num "${2:-15}"); shift 2 || exit 2 ;;
    --quality)  [ "${2:-}" = "off" ] && QUALITY=0; shift 2 || exit 2 ;;
    --json)     JSON_ONLY=1; shift ;;
    --self-test) MODE="selftest"; shift ;;
    -h|--help)  sed -n '2,25p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
    *) printf "unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || {
  printf "undecidable — node not found. Node.js 18+ is required.\n" >&2; exit 2; }
[ -f "$RUNNER" ] || {
  printf "undecidable — the runner is missing: %s\n" "$RUNNER" >&2; exit 2; }

# ── one probe ─────────────────────────────────────────────────────────
# stdout is JSON, stderr is the human message. Exit code 2 = undecidable.
probe() {   # $1 url  $2 outdir("" means no screenshots)  → JSON into RESULT, returns 0/2
  local url="$1" outdir="$2" cfg
  cfg=$(node -e '
    const [url,ready,vps,out,ignore,recon,timeout,quality] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({
      url, ready: ready || null, viewports: vps.split(",").map(s=>s.trim()).filter(Boolean),
      out: out || null, ignore: ignore || null, recon: recon === "1",
      timeout: Number(timeout), quality: quality === "1",
    }));
  ' "$url" "$READY" "$VIEWPORTS" "$outdir" "$IGNORE" "$RECON" "$TIMEOUT" "$QUALITY")
  RESULT=$(node "$RUNNER" "$cfg" 2>/dev/null)
  return $?
}

# ── verdict + formatting ─────────────────────────────────────────────
report() {   # $1 JSON
  local j="$1"
  if ! command -v jq >/dev/null 2>&1; then
    printf "undecidable — jq is missing, so formatting and a verdict cannot be produced. Raw result:\n%s\n" "$j" >&2
    return 2
  fi

  local und; und=$(printf '%s' "$j" | jq -r '.undecidable // empty')
  if [ -n "$und" ]; then
    printf "undecidable — %s\n" "$und" >&2
    printf '%s' "$j" | jq -r '.hint // empty' >&2
    return 2
  fi

  local ce pe fr
  ce=$(num "$(printf '%s' "$j" | jq -r '.runtime.consoleErrors | length')")
  pe=$(num "$(printf '%s' "$j" | jq -r '.runtime.pageErrors    | length')")
  fr=$(num "$(printf '%s' "$j" | jq -r '.runtime.failedRequests| length')")

  sec "runtime"
  if [ "$((ce+pe+fr))" -eq 0 ]; then
    ok "console errors 0 · uncaught exceptions 0 · failed requests 0"
  else
    [ "$ce" -gt 0 ] && bad "${ce} console error(s)" \
      "$(printf '%s' "$j" | jq -r '.runtime.consoleErrors[:3][] | "[\(.viewport)] \(.text)"')"
    [ "$pe" -gt 0 ] && bad "${pe} uncaught exception(s)" \
      "$(printf '%s' "$j" | jq -r '.runtime.pageErrors[:3][] | "[\(.viewport)] \(.text)"')"
    [ "$fr" -gt 0 ] && bad "${fr} failed request(s)" \
      "$(printf '%s' "$j" | jq -r '.runtime.failedRequests[:3][] | "\(.status)  \(.url)"')"
  fi
  local wt; wt=$(printf '%s' "$j" | jq -r '.wait.warning // empty')
  [ -n "$wt" ] && skip "wait: $(printf '%s' "$j" | jq -r '.wait.strategy')" "$wt"

  if [ "$QUALITY" -eq 1 ] && [ "$(printf '%s' "$j" | jq -r '.quality // "null"')" != "null" ]; then
    sec "quality measurements (WARN — does not raise the exit code)"
    local tt ttv; tt=$(num "$(printf '%s' "$j" | jq -r '.quality.touchTargets.checked // 0')")
    ttv=$(num "$(printf '%s' "$j" | jq -r '.quality.touchTargets.total // 0')")
    if [ "$tt" -gt 0 ]; then
      if [ "$ttv" -eq 0 ]; then ok "touch target 44px — all ${tt} satisfy it"
      else warn "touch target under 44px ${ttv}/${tt}" \
        "$(printf '%s' "$j" | jq -r '.quality.touchTargets.violations[:3][] | "\(.name)  \(.w)x\(.h)  \(.hint)"')"; fi
    fi
    local bf bok; bf=$(printf '%s' "$j" | jq -r '.quality.bodyFontSize.median // empty')
    bok=$(printf '%s' "$j" | jq -r '.quality.bodyFontSize.ok // empty')
    if [ -n "$bf" ]; then
      if [ "$bok" = "true" ]; then ok "body size median ${bf}px"
      else warn "body size median ${bf}px — 16px or more is recommended on mobile"; fi
    fi
    local cu cuv; cu=$(num "$(printf '%s' "$j" | jq -r '.quality.cursor.checked // 0')")
    cuv=$(num "$(printf '%s' "$j" | jq -r '.quality.cursor.total // 0')")
    if [ "$cu" -gt 0 ]; then
      if [ "$cuv" -eq 0 ]; then ok "cursor:pointer — all ${cu} satisfy it"
      else warn "cursor:pointer missing ${cuv}/${cu}" \
        "$(printf '%s' "$j" | jq -r '.quality.cursor.violations[:3][] | "\(.name)  cursor: \(.cursor)  \(.hint)"')"; fi
    fi
    local cc ccv; cc=$(num "$(printf '%s' "$j" | jq -r '.quality.contrast.checked // 0')")
    ccv=$(num "$(printf '%s' "$j" | jq -r '.quality.contrast.total // 0')")
    if [ "$cc" -gt 0 ]; then
      if [ "$ccv" -eq 0 ]; then ok "contrast ratio — all ${cc} meet the threshold"
      else warn "contrast ratio below threshold ${ccv}/${cc}" \
        "$(printf '%s' "$j" | jq -r '.quality.contrast.violations[:3][] | "\(.name)  \(.ratio):1 (needs \(.need):1)  \(.hint)"')"; fi
    fi
    local rm; rm=$(num "$(printf '%s' "$j" | jq -r '.reducedMotion // 0')")
    if [ "$rm" -eq 0 ]; then ok "prefers-reduced-motion — no animation running under reduced motion"
    else warn "prefers-reduced-motion ignored — ${rm} animation(s) still run under the reduced-motion setting"; fi
  fi

  sec "recon"
  printf "  %s\n" "$(printf '%s' "$j" | jq -r \
    '"buttons \(.recon.buttons.total) · links \(.recon.links.total) · inputs \(.recon.inputs.total)"')"
  printf '%s' "$j" | jq -r '
    [(.recon.buttons.items[]|"[button] \(.name)  →  \(.hint)"),
     (.recon.inputs.items[] |"[input]  \(.name)  →  \(.hint)"),
     (.recon.links.items[]  |"[link]   \(.name)  →  \(.hint)")] | .[]' \
    | sed "s/^/      ${C_D}/;s/$/${C_0}/"
  [ "$RECON" -eq 0 ] && printf "      ${C_D}(--recon for up to 40 per kind)${C_0}\n"

  local shots; shots=$(printf '%s' "$j" | jq -r '.screenshots[]?.path')
  if [ -n "$shots" ]; then
    sec "evidence"
    printf '%s\n' "$shots" | sed "s/^/  /"
  fi
  return 0
}

# ── --self-test ──────────────────────────────────────────────────────
run_self_test() {
  local fx="$HERE/../assets/probe-fixtures"
  printf "\n${C_D}ui-probe self-test${C_0}\n"

  sec "fixtures"
  [ -f "$fx/clean.html" ] && ok "clean.html" || bad "clean.html missing" "$fx"
  [ -f "$fx/broken.html" ] && ok "broken.html" || bad "broken.html missing" "$fx"
  [ "$FAIL" -gt 0 ] && return 1

  sec "undecidable path (missing dependency → exit 2)"
  # Point cwd at an empty directory with no node_modules so playwright resolution fails.
  local empty rc; empty=$(mktemp -d)
  rc=0; (cd "$empty" && node "$RUNNER" '{"url":"about:blank","viewports":["desktop"],"timeout":5}' >/dev/null 2>&1) || rc=$?
  rm -rf "$empty"
  if [ "$rc" -eq 2 ]; then ok "playwright missing → exit 2 (undecidable, not a block)"
  else bad "playwright is missing yet exit ${rc}" "folding undecidable into a defect makes a false positive"; fi

  # From here on playwright must actually be present.
  # The verdict is on **whether it is null** — a successful result also always carries the
  # "undecidable":null key, so grepping the key name alone always matches and skips the whole check.
  QUALITY=0; VIEWPORTS="desktop"; RECON=0; TIMEOUT=5
  probe "about:blank" "" || true
  if ! printf '%s' "$RESULT" | grep -q '"undecidable":null'; then
    sec "block proof"
    skip "clean/broken fixtures unverified — playwright cannot be resolved in this directory" \
      "run npm i -D playwright && npx playwright install chromium, then run again. This is unverified, not a silent pass."
    printf "\n────────────────────────────────────────────\n"
    printf "  pass %s · warn %s · fail %s\n\n" "$PASS" "$WARN" "$FAIL"
    [ "$FAIL" -gt 0 ] && return 1
    return 0
  fi

  # ① The baseline false-positive check comes first — a clean fixture must produce no defect.
  sec "baseline (no false positives)"
  probe "file://$fx/clean.html" ""
  local ce; ce=$(printf '%s' "$RESULT" | jq -r '[.runtime.consoleErrors,.runtime.pageErrors,.runtime.failedRequests]|map(length)|add')
  if [ "$(num "$ce")" -eq 0 ]; then ok "clean.html → 0 defects (no false positives)"
  else bad "${ce} defect(s) in clean.html" "a check that blocks only misses and not false positives is soon ignored"; fi

  # ② Does the fixture with a planted defect get caught **for the intended reason**?
  sec "block proof (defect fixture)"
  probe "file://$fx/broken.html" ""
  local c p f
  c=$(num "$(printf '%s' "$RESULT" | jq -r '.runtime.consoleErrors|length')")
  p=$(num "$(printf '%s' "$RESULT" | jq -r '.runtime.pageErrors|length')")
  f=$(num "$(printf '%s' "$RESULT" | jq -r '.runtime.failedRequests|length')")
  [ "$c" -gt 0 ] && ok "console error detected (${c})" || bad "console error not detected"
  [ "$p" -gt 0 ] && ok "uncaught exception detected (${p})" || bad "uncaught exception not detected"
  [ "$f" -gt 0 ] && ok "failed request detected (${f})" || bad "failed request not detected"
  [ "${ORANGEKIT_FX_WHY:-}" = "1" ] && printf '%s' "$RESULT" | jq -r '.runtime | to_entries[] | "      \(.key): \(.value|map(.text // .url)|join(" | "))"'

  printf "\n────────────────────────────────────────────\n"
  printf "  pass %s · warn %s · fail %s\n\n" "$PASS" "$WARN" "$FAIL"
  [ "$FAIL" -gt 0 ] && return 1
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────
if [ "$MODE" = "selftest" ]; then
  run_self_test; exit $?
fi

[ -n "$URL" ] || { printf '%s\n' "--url is required (see --help)" >&2; exit 2; }

# Evidence directory — keeps only the last 5 runs. Wherever something appends, put a cap with it.
if [ -z "$OUT" ]; then
  BASE="${ORANGEKIT_STATE_DIR:-$PWD/.claude/.orangekit}/ui-probe"
  OUT="$BASE/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$OUT" 2>/dev/null || OUT=""
  if [ -n "$OUT" ] && [ -d "$BASE" ]; then
    ls -1d "$BASE"/*/ 2>/dev/null | sort -r | tail -n +6 | while IFS= read -r old; do rm -rf "$old"; done
  fi
else
  mkdir -p "$OUT" 2>/dev/null || OUT=""
fi

probe "$URL" "$OUT"
PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] && [ -z "$RESULT" ]; then
  printf "undecidable — the runner produced no result (node %s)\n" "$(node --version 2>/dev/null)" >&2
  exit 2
fi

if [ "$JSON_ONLY" -eq 1 ]; then
  printf '%s\n' "$RESULT"
  printf '%s' "$RESULT" | grep -q '"undecidable":null' || exit 2
  # The exit code must be the same whether or not there is formatting — a script that uses --json
  # and takes a defect as a pass is not a gate.
  command -v jq >/dev/null 2>&1 || exit 0
  DEFECTS=$(num "$(printf '%s' "$RESULT" | jq -r \
    '[.runtime.consoleErrors,.runtime.pageErrors,.runtime.failedRequests]|map(length)|add')")
  [ "$DEFECTS" -gt 0 ] && exit 1
  exit 0
fi

report "$RESULT"; REPORT_RC=$?
[ "$REPORT_RC" -eq 2 ] && exit 2

printf "\n────────────────────────────────────────────\n"
printf "  defects %s · warnings %s · confirmed %s\n\n" "$FAIL" "$WARN" "$PASS"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
