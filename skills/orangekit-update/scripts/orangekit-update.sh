#!/bin/bash
# orangekit-update.sh — brings every plugin-installed asset in a consumer project up to the installed plugin version
#
# A plugin update replaces only the plugin. The copies an older version installed into the project — T1 rule cards,
# reference assets, stack rule cards, detailed guide skills — stay behind until something reinstalls them, and
# session-brief reports that drift one item at a time. This script settles all of it in one run, **through the same
# installers init uses** (install-rules.sh · install-guide.sh). It decides nothing those installers already decide.
#
#   orangekit-update.sh [--plugin-root <dir>] [--project <dir>]                check: report what is behind, change nothing
#   orangekit-update.sh [--plugin-root <dir>] [--project <dir>] --apply        update, then check again
#   orangekit-update.sh ... --apply --retire     also move cards the plugin no longer ships to .claude/deprecated/ (14-day shadow)
#   orangekit-update.sh [--project <dir>] --changes   audit input: diff of each installed file, before the last update → now
#   orangekit-update.sh --self-test              proves check → apply → check on a project an older version installed
#   orangekit-update.sh --help
#
# Ownership — never crossed:
#   updated    T1 cards · references (install-rules.sh) · stack-<axis>-<pack>.md · guide pack files (install-guide.sh).
#              An older copy the user edited is kept as .bak; a same-version edit is preserved
#   reported   a v2 harness (→ /orangekit-migrate) · orangekit.config.json in an old shape · guides whose stack premise
#              moved (→ /stack-guide-generator) · cards the plugin no longer ships (moved only with --retire)
#   baseline   before an apply that writes anything, the installed files as they were go to .orangekit/update-baseline/
#              (gitignored by init) — what --changes diffs against. An apply with nothing pending keeps the previous one
#   untouched  project cards (project-structure · code-conventions) · CLAUDE.md · generated seams · dev/ · .gitignore
#
# Undecidable (no jq) is reported, not guessed: the config and guide steps are skipped and the run says so.
#
# Exit code: 0 = up to date (or updated and verified) · 1 = something is behind or needs a person · 2 = cannot run
#   --changes: 0 = changes printed · 1 = no file changed since the baseline · 2 = no baseline (no update applied yet)

set -uo pipefail   # no -e: every step runs to the end so the full report is produced

# Windows shims (Python resolution, CRLF stripping) — canonical in <plugin>/scripts/lib/win-compat.sh
_okc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/scripts/lib/win-compat.sh"; [ -f "$_okc" ] && . "$_okc"; unset _okc

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_D=""; C_0=""; }

# Copied from doctor.sh — the original bad/warn return 1 when $2 is empty, so return 0 is explicit
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; }
num()  { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

PLUGIN_ROOT="" PROJECT="" APPLY=0 RETIRE=0 SELFTEST=0 CHANGES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root|--project)
      # `shift 2` with one argument left fails without shifting — the loop never ended
      [ $# -ge 2 ] || { printf '%s needs a directory (see --help)\n' "$1" >&2; exit 2; }
      if [ "$1" = --plugin-root ]; then PLUGIN_ROOT="$2"; else PROJECT="$2"; fi; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    --retire)      RETIRE=1; shift ;;
    --changes)     CHANGES=1; shift ;;
    --self-test)   SELFTEST=1; shift ;;
    -h|--help)     awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done

# This file lives at <plugin>/skills/orangekit-update/scripts/ — the fallback when neither the flag nor the variable is set
SELF_PLUGIN="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$SELF_PLUGIN}}"

# ── Steps ──────────────────────────────────────────────────────────────
# Each step adds to PENDING (files an installer would write) or HUMAN (items only a person or a skill can settle).

PENDING=0; HUMAN=0; HUMAN_LIST=""; UNDEC=0; UNDEC_LIST=""
# A step that could not be checked is neither "current" nor "behind" — it is reported and never folded into success
undecided() { UNDEC=$((UNDEC+1)); UNDEC_LIST="${UNDEC_LIST}  - $1"$'\n'; warn "$1" "${2:-}"; }
human() { HUMAN=$((HUMAN+1)); HUMAN_LIST="${HUMAN_LIST}  - $1"$'\n'; warn "$1" "${2:-}"; }

# "new N · updated M" is the summary line both installers print; summing them is the pending count
# An installer whose dry run failed, or printed no "new N · updated M" summary, decided nothing — never read that as "current"
_dry_ok() {  # $1 exit code · $2 output · $3 label → 0 usable · 1 reported undecided
  if [ "$1" -ne 0 ] || ! printf '%s\n' "$2" | grep -q 'new [0-9]* · updated [0-9]*'; then
    undecided "$3 could not be checked — the installer failed (exit $1)" "$(printf '%s\n' "$2" | grep -E 'FATAL|ERROR|✗' | head -2 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

_count_changes() {  # stdin: installer output → number of files it would write
  awk '
    /new [0-9]+ · updated [0-9]+/ { for (i = 1; i <= NF; i++) { if ($i == "new") n += $(i+1); if ($i == "updated") n += $(i+1) } }
    /\+ [0-9]+ reference assets/   { for (i = 1; i <= NF; i++) if ($i == "+") n += $(i+1) }
    END { print n + 0 }'
}

# The per-file lines of an installer (+ new · ↑ updated), indented under this report
_show_changes() { grep -E '^[[:space:]]+(\+|↑) ' | sed 's/^[[:space:]]*/      /' || true; }

# Copies newer than the plugin's own are kept by the installers (no downgrade) — said out loud, never counted as pending
_report_kept() {  # $1 installer output
  local k; k=$(num "$(printf '%s\n' "$1" | grep -c 'newer than the plugin' || true)")
  [ "$k" -eq 0 ] && return 0
  warn "$k file(s) are newer than this plugin — kept, not downgraded" \
       "a newer or forked plugin set them up; update the plugin to match, or reinstall with --force to take this plugin's copy"
  printf '%s\n' "$1" | grep 'newer than the plugin' | sed 's/^[[:space:]]*/      /'
}

step_v2() {
  sec "v2 harness"
  local hits="" f
  for f in .claude/hooks/session-start-validator.sh .claude/hooks/stop-guard.sh .claude/hooks/pre-compact-saver.sh \
           .claude/hooks/pre-tool-use-guard.sh .claude/rules/task-workflow.md; do
    [ -e "$PROJECT/$f" ] && hits="$hits $f"
  done
  if [ -n "$hits" ]; then
    human "a v2 harness is still installed:$hits" "run /orangekit-migrate first — it converts v2 to v3; this update covers v3 projects"
    return 1
  fi
  ok "no v2 harness files"
  return 0
}

FE="none" BE="none" APP="none" HAVE_JQ=0
step_config() {
  sec "orangekit.config.json"
  local cfg="$PROJECT/orangekit.config.json"
  if ! command -v jq >/dev/null 2>&1; then
    undecided "jq not installed — orangekit.config.json, stack cards and guides were not checked" "install jq (docs/windows-setup.md on Windows) and run again"
    return 0
  fi
  HAVE_JQ=1
  if ! jq -e . "$cfg" >/dev/null 2>&1; then
    human "orangekit.config.json is not valid JSON" "fix it by hand or re-run /orangekit-init — nothing below reads it"
    HAVE_JQ=0; return 0
  fi
  FE=$(jq -r '.techStack.presets.frontend // "none"' "$cfg"); BE=$(jq -r '.techStack.presets.backend // "none"' "$cfg")
  APP=$(jq -r '.techStack.presets.app // "none"' "$cfg")
  local shapes=0
  if jq -e '(.techStack.presets | not) and (.techStack.preset != null)' "$cfg" >/dev/null 2>&1; then
    human "config uses the old single-axis preset ($(jq -r '.techStack.preset' "$cfg"))" \
          "the /orangekit-update skill converts it with the two-axis preset table in /orangekit-migrate"
    shapes=1
  fi
  if jq -e '(.techStack.deliveryModel == "native") and (.techStack.presets.app == null)' "$cfg" >/dev/null 2>&1; then
    human "config predates the app axis (deliveryModel native, no presets.app)" \
          "the /orangekit-update skill converts it with the app-axis table in /orangekit-migrate"
    shapes=1
  fi
  local axis val allowed
  for axis in frontend backend app; do
    val=$(jq -r --arg a "$axis" '.techStack.presets[$a] // empty' "$cfg")
    [ -n "$val" ] || continue
    allowed=$(jq -r --arg a "$axis" '.properties.techStack.properties.presets.properties[$a].enum // [] | join(" ")' \
              "$PLUGIN_ROOT/schema/orangekit.config.schema.json" 2>/dev/null)
    [ -z "$allowed" ] && continue
    case " $allowed " in
      *" $val "*) ;;
      *) human "presets.$axis = \"$val\" is not a name this plugin knows" "change it to custom and move the real name into that axis's framework field"; shapes=1 ;;
    esac
  done
  [ "$shapes" -eq 0 ] && ok "config shape is current (frontend=$FE · backend=$BE · app=$APP)"
  return 0
}

step_rules() {  # $1 = check|apply
  sec "T1 rule cards · references"
  local out n
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --dry-run 2>&1)
  _dry_ok $? "$out" "T1 rule cards" || return 0
  n=$(num "$(printf '%s\n' "$out" | _count_changes)")
  [ "$1" = check ] && _report_kept "$out"
  if [ "$n" -eq 0 ]; then ok "every T1 card and reference is current"; return 0; fi
  if [ "$1" = check ]; then
    PENDING=$((PENDING+n)); warn "$n card/reference files behind"; printf '%s\n' "$out" | _show_changes; return 0
  fi
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN_ROOT/scripts/install-rules.sh" 2>&1)
  if [ $? -ne 0 ]; then bad "install-rules.sh failed" "$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"; return 0; fi
  ok "updated $n card/reference files (an edited older copy is kept as .bak)"; printf '%s\n' "$out" | _show_changes
}

_is_pack() { case "$1" in ""|none|custom|undecided) return 1 ;; *) return 0 ;; esac; }

step_guides() {  # $1 = check|apply
  sec "stack rule cards · guide skills"
  [ "$HAVE_JQ" -eq 1 ] || { printf '  – not checked (needs jq, see above)\n'; return 0; }
  if ! _is_pack "$FE" && ! _is_pack "$BE" && ! _is_pack "$APP"; then ok "no stack pack selected — nothing to install"; return 0; fi
  # Guide skills already installed → refresh them too (same-premise fixes only; install-guide.sh pins the rest).
  # None installed → stack rule cards only, init's default — the update does not opt the project into guides
  local args=(--frontend "$FE" --backend "$BE" --app "$APP" --no-freshness) mode="stack rule cards"
  if ls "$PROJECT"/.claude/skills/*-guide/assembly.json >/dev/null 2>&1; then mode="stack rule cards + guide skills"; else args+=(--rules-only); fi
  [ -f "$PROJECT/.orangekit/preset-notes.json" ] && args+=(--notes "$PROJECT/.orangekit/preset-notes.json")
  local out n pinned
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN_ROOT/scripts/install-guide.sh" "${args[@]}" --dry-run 2>&1)
  _dry_ok $? "$out" "$mode" || return 0
  pinned=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*state:' | grep -oE '[a-z]+=pinned' | cut -d= -f1 | tr '\n' ' ')
  [ -n "$pinned" ] && human "guide premise moved for: ${pinned}— not updated" "move it across with /stack-guide-generator when the project raises that dependency"
  n=$(num "$(printf '%s\n' "$out" | _count_changes)")
  [ "$1" = check ] && _report_kept "$out"
  if [ "$n" -eq 0 ]; then ok "$mode current"; return 0; fi
  if [ "$1" = check ]; then
    PENDING=$((PENDING+n)); warn "$n $mode files behind"; printf '%s\n' "$out" | _show_changes; return 0
  fi
  out=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN_ROOT/scripts/install-guide.sh" "${args[@]}" 2>&1)
  if [ $? -ne 0 ]; then bad "install-guide.sh failed" "$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"; return 0; fi
  ok "updated $n $mode files"; printf '%s\n' "$out" | _show_changes
}

# Is version $1 newer than $2 (x.y.z, numeric per part)? Same rule as the installers' ver_gt
ver_gt() { awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 } exit 1 }'; }

step_retired() {  # $1 = check|apply
  sec "cards the plugin no longer ships"
  local c base stack axis pack list="" n=0 exp dst newest="" v newer=""
  # An empty plugin rules/ would make every stamped card look retired — decide nothing then
  if ! ls "$PLUGIN_ROOT"/rules/*.md >/dev/null 2>&1; then undecided "the plugin ships no rules/*.md — retired cards not checked"; return 0; fi
  # A card stamped newer than every card this plugin ships came from a newer plugin (the no-downgrade case) — not retired
  for c in "$PLUGIN_ROOT"/rules/*.md; do
    v=$({ grep -m1 -oE 'orangekit-rule-version: [0-9]+\.[0-9]+\.[0-9]+' "$c" 2>/dev/null || true; } | awk '{print $2}')
    [ -n "$v" ] && { [ -z "$newest" ] || ver_gt "$v" "$newest"; } && newest=$v
  done
  for c in "$PROJECT"/.claude/rules/*.md; do
    [ -f "$c" ] || continue
    grep -q 'orangekit-rule-version:' "$c" 2>/dev/null || continue     # no stamp = project-owned, never ours to retire
    base=$(basename "$c")
    [ -f "$PLUGIN_ROOT/rules/$base" ] && continue
    v=$({ grep -m1 -oE 'orangekit-rule-version: [0-9]+\.[0-9]+\.[0-9]+' "$c" 2>/dev/null || true; } | awk '{print $2}')
    if [ -n "$newest" ] && [ -n "$v" ] && ver_gt "$v" "$newest"; then newer="$newer $base"; continue; fi
    case "$base" in
      stack-*-*.md) stack=${base#stack-}; stack=${stack%.md}; axis=${stack%%-*}; pack=${stack#*-}
                    [ -f "$PLUGIN_ROOT/guides/$axis/$pack/RULES.md" ] && continue ;;
    esac
    list="$list $base"; n=$((n+1))
  done
  [ -n "$newer" ] && [ "$1" = check ] && warn "kept (newer than any card this plugin ships — set up by a newer plugin):$newer"
  if [ "$n" -eq 0 ]; then ok "none"; return 0; fi
  if [ "$1" = apply ] && [ "$RETIRE" -eq 1 ]; then
    # Retirement protocol (rules/harness-change.md): a shadow with an expiry date, not a deletion
    exp=$(date -v+14d +%Y-%m-%d 2>/dev/null || date -d '+14 days' +%Y-%m-%d 2>/dev/null || printf 'unknown')
    mkdir -p "$PROJECT/.claude/deprecated"
    for base in $list; do
      dst="$PROJECT/.claude/deprecated/rules_${base}.shadow-expires-${exp}"
      mv "$PROJECT/.claude/rules/$base" "$dst" && printf '      → %s\n' "${dst#$PROJECT/}"
    done
    ok "moved $n retired card(s) to .claude/deprecated/ (restore by moving back; delete after $exp)"
    return 0
  fi
  human "$n card(s) the plugin no longer ships:$list" "they still load every matching session — re-run with --apply --retire to move them to .claude/deprecated/ (14-day shadow)"
}

# ── Audit baseline ─────────────────────────────────────────────────────
# The plugin-installed files (T1 cards · stack cards · references · guide skills). Project cards are skipped by name;
# .bak copies the installers leave are not rules
_installed() {  # $1 root → relative paths, one per line
  (cd "$1" 2>/dev/null && find .claude/rules .claude/references .claude/skills/*-guide -type f ! -name '*.bak' 2>/dev/null) \
    | grep -vE '^\.claude/rules/(project-structure|code-conventions)\.md$' | LC_ALL=C sort || true
}
BASE_DIR() { printf '%s/.orangekit/update-baseline' "$PROJECT"; }
snapshot() {  # $1 version being installed
  local b f; b=$(BASE_DIR); rm -rf "$b"; mkdir -p "$b/files"
  _installed "$PROJECT" | while IFS= read -r f; do mkdir -p "$b/files/$(dirname "$f")" && cp -p "$PROJECT/$f" "$b/files/$f"; done
  printf 'to=%s\ndate=%s\n' "$1" "$(date +%Y-%m-%d)" > "$b/info"
}
changes() {
  local b f n=0; b=$(BASE_DIR)
  [ -f "$b/info" ] || { printf 'no update baseline in %s — run the update (--apply) first; the audit compares against it\n' "${b#$PROJECT/}"; exit 2; }
  printf 'orangekit update — changes since the baseline (%s)\n' "$(tr '\n' ' ' < "$b/info")"
  printf 'note: a file a person edited after the update shows here too\n'
  while IFS= read -r f; do
    if [ ! -f "$b/files/$f" ]; then n=$((n+1)); printf '\n=== new: %s\n' "$f"; cat "$PROJECT/$f"
    elif [ ! -f "$PROJECT/$f" ]; then n=$((n+1)); printf '\n=== removed: %s\n' "$f"
    elif ! cmp -s "$b/files/$f" "$PROJECT/$f"; then n=$((n+1)); printf '\n=== changed: %s\n' "$f"; diff -u "$b/files/$f" "$PROJECT/$f" | tail -n +3; fi
  done < <({ _installed "$PROJECT"; _installed "$b/files"; } | LC_ALL=C sort -u)
  printf '\n%s file(s) changed\n' "$n"
  [ "$n" -gt 0 ] && exit 0 || exit 1
}

run() {  # $1 = check|apply
  step_v2 || return 0      # a v2 project goes to /orangekit-migrate first — nothing else is touched
  step_config
  step_rules "$1"
  step_guides "$1"
  step_retired "$1"
}

main() {
  if [ ! -f "$PLUGIN_ROOT/scripts/install-rules.sh" ] || [ ! -f "$PLUGIN_ROOT/scripts/install-guide.sh" ]; then
    printf 'FATAL: not an orangekit plugin root: %s (pass --plugin-root "${CLAUDE_PLUGIN_ROOT}")\n' "$PLUGIN_ROOT" >&2; exit 2
  fi
  PROJECT="${PROJECT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || { printf 'FATAL: project directory not found\n' >&2; exit 2; }
  local ver; ver=$({ grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  printf 'orangekit update — %s\n  plugin:  %s (v%s)\n  project: %s\n' "$([ "$APPLY" -eq 1 ] && echo apply || echo check)" "$PLUGIN_ROOT" "${ver:-?}" "$PROJECT"
  if [ ! -f "$PROJECT/orangekit.config.json" ]; then
    printf '\n  ✗ orangekit.config.json not found — this project was never initialized. Run /orangekit-init\n'; exit 2
  fi

  if [ "$APPLY" -eq 0 ]; then
    [ "$CHANGES" -eq 1 ] && changes
    run check
    sec "summary"
    if [ "$PENDING" -eq 0 ] && [ "$HUMAN" -eq 0 ] && [ "$UNDEC" -eq 0 ]; then ok "up to date with v${ver:-?}"; exit 0; fi
    [ "$PENDING" -gt 0 ] && printf '  %s file(s) behind v%s — run again with --apply\n' "$PENDING" "${ver:-?}"
    [ "$HUMAN" -gt 0 ] && printf '  %s item(s) need a person:\n%s' "$HUMAN" "$HUMAN_LIST"
    [ "$UNDEC" -gt 0 ] && printf '  %s step(s) could not be checked:\n%s' "$UNDEC" "$UNDEC_LIST"
    exit 1
  fi

  # Baseline for the audit — only when this apply writes something, so a no-op apply keeps the last real one
  run check >/dev/null 2>&1
  [ "$PENDING" -gt 0 ] && snapshot "${ver:-?}"
  PENDING=0; HUMAN=0; HUMAN_LIST=""; UNDEC=0; UNDEC_LIST=""; PASS=0; WARN=0; FAIL=0
  run apply
  # Verify — "the installer ran" is not "the project is current". Check again from scratch
  local applied_fail=$FAIL
  PENDING=0; HUMAN=0; HUMAN_LIST=""; UNDEC=0; UNDEC_LIST=""
  sec "verification (check again)"
  run check >/dev/null 2>&1
  sec "summary"
  if [ "$applied_fail" -gt 0 ]; then bad "an installer failed — see above"; exit 1; fi
  if [ "$PENDING" -gt 0 ]; then bad "$PENDING file(s) still behind after the update" "an installer skipped them — run without --apply to see which"; exit 1; fi
  if [ "$UNDEC" -gt 0 ]; then
    ok "every file that could be checked matches v${ver:-?}"
    printf '  %s step(s) could not be checked — not verified:\n%s' "$UNDEC" "$UNDEC_LIST"
  else
    ok "every plugin-installed file matches v${ver:-?}"
  fi
  if [ "$HUMAN" -gt 0 ]; then printf '  %s item(s) still need a person:\n%s' "$HUMAN" "$HUMAN_LIST"; exit 1; fi
  [ "$UNDEC" -gt 0 ] && exit 1
  exit 0
}

# ── Self-test ──────────────────────────────────────────────────────────
# A project laid out the way an older version left it, built from this plugin's own rules (no fixture copies to drift):
# an aged card, a missing card, a same-version user edit, a retired card, a project card, no stack rule cards.
self_test() {
  printf 'orangekit-update self-test\n'
  local T P out rc
  T=$(mktemp -d 2>/dev/null) || { printf 'cannot create a temporary directory\n' >&2; exit 2; }
  P="$T/proj"; mkdir -p "$P"
  printf '{"techStack":{"presets":{"frontend":"nextjs","backend":"supabase","app":"none"},"deliveryModel":"web"}}\n' > "$P/orangekit.config.json"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$P" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --quiet >/dev/null 2>&1
  sed 's/orangekit-rule-version: [0-9.]*/orangekit-rule-version: 0.0.1/' "$P/.claude/rules/workflow-routing.md" > "$T/x" && mv "$T/x" "$P/.claude/rules/workflow-routing.md"
  rm -f "$P/.claude/rules/security.md"
  printf '\n<!-- team note: keep -->\n' >> "$P/.claude/rules/code-change.md"
  printf '<!-- orangekit-rule-version: 1.0.0 -->\n# a card the plugin stopped shipping\n' > "$P/.claude/rules/old-card.md"
  printf '# project structure — written by the team\n' > "$P/.claude/rules/project-structure.md"
  local sum_ps; sum_ps=$(cksum < "$P/.claude/rules/project-structure.md")
  _tree() { (cd "$1" && find .claude -type f -exec cksum {} \; 2>/dev/null | LC_ALL=C sort); }
  local tree0; tree0=$(_tree "$P")

  sec "check on an older layout"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && ok "check → exit 1 (behind)" || bad "check → exit $rc (expected 1)"
  printf '%s' "$out" | grep -q 'workflow-routing.md' && printf '%s' "$out" | grep -q 'security.md' \
    && ok "the aged and the missing card are both listed" || bad "aged/missing card not listed" "$(printf '%s' "$out" | tail -5 | tr '\n' ' ')"
  printf '%s' "$out" | grep -q 'stack-frontend-nextjs.md' && ok "the stack rule card an older version never installed is listed" \
    || bad "stack rule card not listed"
  printf '%s' "$out" | grep -q 'no longer ships:.*old-card.md' && ok "the retired card is reported" || bad "retired card not reported"
  [ "$(_tree "$P")" = "$tree0" ] && ok "check changed nothing (whole .claude tree compared)" || bad "check modified a file under .claude"
  bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --changes >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "--changes before any update → exit 2 (no baseline to audit against)" || bad "--changes without a baseline → exit $rc (expected 2)"

  sec "apply"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --apply 2>&1); rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'still need a person' \
    && ok "apply → exit 1 while the retired card waits for --retire" || bad "apply → exit $rc" "$(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  printf '%s' "$out" | grep -q 'every plugin-installed file matches' && ok "apply verified by a fresh check" || bad "apply not verified"
  grep -q 'version: 0.0.1' "$P/.claude/rules/workflow-routing.md" && bad "aged card not updated" || ok "aged card updated"
  [ -f "$P/.claude/rules/security.md" ] && ok "missing card installed" || bad "missing card not installed"
  [ -f "$P/.claude/rules/stack-frontend-nextjs.md" ] && [ -f "$P/.claude/rules/stack-backend-supabase.md" ] \
    && ok "stack rule cards installed" || bad "stack rule cards missing"
  [ ! -d "$P/.claude/skills/frontend-guide" ] && ok "guide skills not opted into (init's default kept)" || bad "update installed guide skills nobody asked for"
  grep -q 'team note: keep' "$P/.claude/rules/code-change.md" && ok "same-version user edit preserved" || bad "user edit overwritten"
  [ "$(cksum < "$P/.claude/rules/project-structure.md")" = "$sum_ps" ] && ok "project card untouched" || bad "project card modified"
  [ -f "$P/.claude/rules/old-card.md" ] && ok "retired card left in place without --retire" || bad "retired card moved without --retire"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --changes 2>&1); rc=$?
  [ "$rc" -eq 0 ] && grep -q '=== changed: .claude/rules/workflow-routing.md' <<<"$out" \
    && grep -q '=== new: .claude/rules/security.md' <<<"$out" && grep -q '^-<!-- orangekit-rule-version: 0.0.1' <<<"$out" \
    && ! grep -q 'project-structure.md' <<<"$out" \
    && ok "--changes → the aged card as a diff from its old text, the new card in full, project cards left out" \
    || bad "--changes did not report the update (exit $rc)" "$(printf '%s' "$out" | grep '^===' | head -4 | tr '\n' ' ')"

  sec "apply --retire"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --apply --retire 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "apply --retire → exit 0" || bad "apply --retire → exit $rc" "$(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  ls "$P/.claude/deprecated/"rules_old-card.md.shadow-expires-* >/dev/null 2>&1 && [ ! -f "$P/.claude/rules/old-card.md" ] \
    && ok "retired card moved to a dated shadow" || bad "retired card not shadowed"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "check afterwards → exit 0 (up to date)" || bad "check afterwards → exit $rc" "$(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --apply >/dev/null 2>&1
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$P" --changes 2>&1)   # here-strings, not `| grep -q`: under pipefail a large diff is 141 (B1)
  grep -q '=== changed: .claude/rules/workflow-routing.md' <<<"$out" \
    && ok "an apply with nothing pending keeps the last baseline (the audit still sees that update)" || bad "a no-op apply overwrote the audit baseline"

  sec "no downgrade (a newer or forked plugin set the project up)"
  local N="$T/newer"; mkdir -p "$N"
  printf '{"techStack":{"presets":{"frontend":"nextjs","backend":"none","app":"none"}}}\n' > "$N/orangekit.config.json"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$N" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --quiet >/dev/null 2>&1
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$N" bash "$PLUGIN_ROOT/scripts/install-guide.sh" --frontend nextjs --backend none --rules-only --no-freshness >/dev/null 2>&1
  sed 's/orangekit-rule-version: [0-9.]*/orangekit-rule-version: 99.0.0/' "$N/.claude/rules/security.md" > "$T/x" && mv "$T/x" "$N/.claude/rules/security.md"
  sed 's#\(orangekit-pack: frontend/nextjs\) v[0-9.]*#\1 v99.0.0#' "$N/.claude/rules/stack-frontend-nextjs.md" > "$T/x" && mv "$T/x" "$N/.claude/rules/stack-frontend-nextjs.md"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$N" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'newer than this plugin' && printf '%s' "$out" | grep -q 'security.md' \
    && printf '%s' "$out" | grep -q 'stack-frontend-nextjs.md' \
    && ok "a newer card and a newer stack card → reported as kept, nothing pending (exit 0)" \
    || bad "newer copies not reported as kept (exit $rc)" "$(printf '%s' "$out" | tail -4 | tr '\n' ' ')"
  bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$N" --apply >/dev/null 2>&1
  grep -q 'orangekit-rule-version: 99.0.0' "$N/.claude/rules/security.md" && grep -q 'frontend/nextjs v99.0.0' "$N/.claude/rules/stack-frontend-nextjs.md" \
    && ok "apply does not downgrade them" || bad "apply downgraded a newer copy"

  sec "no jq: unchecked steps are not reported as success"
  local NJ="$T/nojq-bin" d f; mkdir -p "$NJ"
  for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do [ "$(basename "$f")" = jq ] && continue; [ -e "$NJ/$(basename "$f")" ] || ln -s "$f" "$NJ/$(basename "$f")" 2>/dev/null; done
  done
  if PATH="$NJ" command -v jq >/dev/null 2>&1; then
    warn "could not build a PATH without jq on this host — case unverified"
  else
    local J="$T/nojq"; mkdir -p "$J"
    printf '{"techStack":{"presets":{"frontend":"nextjs","backend":"none","app":"none"}}}\n' > "$J/orangekit.config.json"
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$J" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --quiet >/dev/null 2>&1
    out=$(PATH="$NJ" bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$J" --apply 2>&1); rc=$?
    [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'could not be checked' && ! printf '%s' "$out" | grep -q 'every plugin-installed file matches' \
      && ok "no jq → apply exits 1 and names the unchecked steps instead of claiming success" \
      || bad "no jq → success claimed for steps that never ran (exit $rc)" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi

  sec "failures are not read as success"
  ( perl -e 'alarm 5; exec @ARGV' bash "$0" --plugin-root ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "--plugin-root with no value → exit 2 (no endless loop)" || bad "--plugin-root with no value → exit $rc (142 = it looped until killed)"
  local FP="$T/brokenplugin"; mkdir -p "$FP/scripts" "$FP/rules"
  printf '#!/bin/bash\necho "FATAL: broken installer" >&2; exit 2\n' > "$FP/scripts/install-rules.sh"; cp "$FP/scripts/install-rules.sh" "$FP/scripts/install-guide.sh"
  printf '<!-- orangekit-rule-version: 1.0.0 -->\n' > "$FP/rules/a.md"
  out=$(bash "$0" --plugin-root "$FP" --project "$P" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'installer failed' && ! printf '%s' "$out" | grep -q 'up to date' \
    && ok "an installer that fails → exit 1 'could not be checked', never 'up to date'" || bad "a failing installer read as success (exit $rc)" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  local F6="$T/future"; mkdir -p "$F6"; printf '{}\n' > "$F6/orangekit.config.json"
  CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_PROJECT_DIR="$F6" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --quiet >/dev/null 2>&1
  printf '<!-- orangekit-rule-version: 99.0.0 -->\n# a card from a newer plugin\n' > "$F6/.claude/rules/future-card.md"
  bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$F6" --apply --retire >/dev/null 2>&1
  [ -f "$F6/.claude/rules/future-card.md" ] && ok "--retire keeps a card stamped newer than anything this plugin ships" || bad "--retire moved a newer plugin's card away"

  sec "what it refuses to guess"
  mkdir -p "$T/v2/.claude/hooks"; : > "$T/v2/.claude/hooks/stop-guard.sh"; printf '{}\n' > "$T/v2/orangekit.config.json"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$T/v2" --apply 2>&1); rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '/orangekit-migrate' && [ ! -d "$T/v2/.claude/rules" ] \
    && ok "v2 harness → exit 1, sent to /orangekit-migrate, nothing installed" || bad "v2 harness not stopped (exit $rc)"
  mkdir -p "$T/old"; printf '{"techStack":{"preset":"nextjs-supabase"}}\n' > "$T/old/orangekit.config.json"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$T/old" 2>&1); rc=$?
  if command -v jq >/dev/null 2>&1; then
    [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'old single-axis preset' && ok "single-axis config → reported for conversion" \
      || bad "single-axis config not reported (exit $rc)"
  else
    warn "jq not installed — config-shape case unverified"
  fi
  mkdir -p "$T/none"
  out=$(bash "$0" --plugin-root "$PLUGIN_ROOT" --project "$T/none" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '/orangekit-init' && ok "uninitialized project → exit 2, sent to /orangekit-init" \
    || bad "uninitialized project → exit $rc (expected 2)"

  rm -rf "$T"
  printf '\n  pass %s · warn %s · fail %s\n' "$PASS" "$WARN" "$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}

if [ "$SELFTEST" -eq 1 ]; then self_test; fi
main
