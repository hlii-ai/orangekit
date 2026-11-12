#!/bin/bash
# skill-lint.sh — checks only the skill authoring best practices that a machine can rule on
#
# Basis: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
#        (checked 2026-11-03). Items that need model judgement belong to references/authoring-baseline.md.
#
#   skill-lint.sh <skill directory>...  check the SKILL.md and bundled .md files of each directory
#   skill-lint.sh --self-test      prove that fixtures with planted defects fail for the intended reason
#   skill-lint.sh --help
#
# Failure (✗) — platform constraint or official limit violated:
#   name format (lowercase, digits, hyphens, ≤64 chars, no anthropic/claude, matches directory name)
#   description empty · over 1024 characters · XML tag · SKILL.md body over 500 lines · backslash path
# Warning (!) — recommendation violated:
#   description has no "when to use" clause · first/second person · body over 300 lines (this repository's target) ·
#   reference file over 100 lines with no contents list · two-level reference not reachable directly from SKILL.md
#
# Exit code: 0 = no failures (warnings allowed), 1 = failures present, 2 = cannot run (bad argument)
# Works on any skill root (skills/, marketing/skills, harness/skills) — it takes the skill directory itself.

set -uo pipefail   # no -e: run every check to the end so the full report is produced

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_D=""; C_0=""; }

# Copied from doctor.sh — the original bad/warn return 1 when $2 is empty, so return 0 is explicit
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; }
num() { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

# Character count — 1024 is a character limit, not a byte limit. Counting with wc -c would over-penalize non-ASCII text.
# Locale-free: drop UTF-8 continuation bytes (0x80–0xBF) and count what is left — one byte per character. `wc -m` under a
# named locale (en_US.UTF-8) silently counted bytes where that locale is not generated (minimal Linux, WSL: only C.UTF-8)
chars() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }

lint_one() {
  local dir="${1%/}" sm fm name desc dlen body_lines base
  sm="$dir/SKILL.md"; base=$(basename "$(cd "$dir" 2>/dev/null && pwd || echo "$dir")")
  sec "$base"
  [ -f "$sm" ] || { bad "SKILL.md missing: $sm"; return 0; }

  fm=$(awk '/^---$/{n++; if(n==2) exit; next} n==1' "$sm")
  name=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')
  desc=$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//')

  # ── name ──
  if [ -z "$name" ]; then bad "name missing"
  elif ! printf '%s' "$name" | grep -qE '^[a-z0-9-]{1,64}$'; then bad "name format violation: $name" "lowercase letters, digits, hyphens only, 64 characters or fewer"
  elif printf '%s' "$name" | grep -qE 'anthropic|claude'; then bad "name contains a reserved word: $name" "anthropic and claude cannot be used"
  elif [ "$name" != "$base" ]; then bad "name ($name) differs from directory name ($base)"
  else ok "name $name"; fi

  # ── description ──
  case "$desc" in '|'*|'>'*) bad "description is a block scalar" "write it on one line — this check and doctor's resident-cost measurement read only the first line"; desc="" ;; esac
  if [ -z "$desc" ]; then bad "description missing"
  else
    dlen=$(num "$(chars "$desc")")
    if [ "$dlen" -gt 1024 ]; then bad "description ${dlen} characters — over the 1024 limit"; else ok "description ${dlen}/1024 characters"; fi
    printf '%s' "$desc" | grep -qE '<[A-Za-z/][^>]*>' && bad "description contains an XML tag" "it is injected into the system prompt, so tags are forbidden"
    printf '%s' "$desc" | grep -qE '[Uu]se (when|for|before|after|right|this|it|to|if)( |$)|[Ww]hen |[Tt]rigger' \
      || warn "description has no 'when to use' clause" "say what it does + when to use it (the trigger situation, the words the user types)"
    printf '%s' "$desc" | grep -qiE "(^| )(I can|I will|I'll|I'm|you can|you should|you will|your)( |$)" \
      && warn "description is in first/second person" "write it in third person — it is injected into the system prompt, so a mixed point of view disturbs discovery"
  fi

  # ── body length ──
  body_lines=$(num "$(awk '/^---$/{n++; next} n>=2' "$sm" | wc -l | tr -d ' ')")
  if [ "$body_lines" -gt 500 ]; then bad "body ${body_lines} lines — over the 500 limit" "split detail into reference files and link them directly from SKILL.md"
  elif [ "$body_lines" -gt 300 ]; then warn "body ${body_lines} lines — over this repository's 300-line target"
  else ok "body ${body_lines} lines"; fi

  # ── backslash paths ── (only paths with an extension, to avoid false positives on regexes and escapes in code blocks)
  local bs; bs=$(grep -nE '[A-Za-z0-9_]\\[A-Za-z0-9_.-]+\.(md|py|sh|js|ts|json|txt)\b' "$sm" | head -3)
  [ -n "$bs" ] && bad "backslash path" "$(printf '%s' "$bs" | head -1) — write paths with /"

  # ── bundled .md: contents list · reference depth ──
  local f n rel direct toc_miss="" nested=""
  direct=$(grep -oE '[A-Za-z0-9._/-]+\.md' "$sm" | sed 's|.*/||' | sort -u)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$dir/}"
    n=$(num "$(wc -l < "$f" | tr -d ' ')")
    if [ "$n" -gt 100 ] && ! head -40 "$f" | grep -qiE '^#+ *(contents|table of contents)'; then
      toc_miss="$toc_miss $rel(${n} lines)"
    fi
    # A file SKILL.md does not name directly but another bundled file does = a two-level reference
    if ! printf '%s\n' "$direct" | grep -qxF "$(basename "$f")"; then
      grep -rlF --include='*.md' "$(basename "$f")" "$dir" 2>/dev/null | grep -v "^$f$" | grep -qv '/SKILL.md$' \
        && nested="$nested $rel"
    fi
  done < <(find "$dir" -type f -name '*.md' ! -name SKILL.md ! -path '*/node_modules/*' 2>/dev/null | sort)
  [ -n "$toc_miss" ] && warn "reference file over 100 lines with no contents list:$toc_miss" "put a '## Contents' at the top — so the whole scope is visible even when only part is read"
  [ -n "$nested" ] && warn "two-level reference not reachable directly from SKILL.md:$nested" "link references one level deep from SKILL.md — nested references get read only in part"
  return 0
}

self_test() {
  local T; T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  local fails=0 cases=0 out rc
  mk() { mkdir -p "$T/$1"; printf -- '---\nname: %s\ndescription: %s\n---\n\n# X\n\nBody.\n' "$2" "$3" > "$T/$1/SKILL.md"; }
  expect() {  # $1=case $2=expected exit code $3=expected reason (regex)
    cases=$((cases+1))
    out=$(bash "$0" "$T/$1" 2>&1); rc=$?
    if [ "$rc" -ne "$2" ]; then echo "FAIL $1: exit $rc (expected $2)"; fails=$((fails+1)); return 0; fi
    if [ -n "$3" ] && ! printf '%s\n' "$out" | grep -qE "$3"; then echo "FAIL $1: reason mismatch — expected /$3/"; fails=$((fails+1)); fi
    return 0
  }
  mk clean clean "Extracts tables from PDFs. Use when the user asks about PDF files or table extraction."
  expect clean 0 'name clean'
  mk Bad-Name Bad-Name "Does x. Use when y."
  expect Bad-Name 1 'name format violation'
  mk claude-tool claude-tool "Does x. Use when y."
  expect claude-tool 1 'reserved word'
  mk mismatch other "Does x. Use when y."
  expect mismatch 1 'directory name'
  mk longdesc longdesc "$(printf 'a%.0s' $(seq 1 1030)) Use when y."
  expect longdesc 1 'over the 1024 limit'
  # Non-ASCII text under 1024 characters is double the bytes but must pass (proves the character-based ruling)
  mk widedesc widedesc "$(printf 'é%.0s' $(seq 1 900)) Use when y."
  expect widedesc 0 'description 9[0-9][0-9]/1024 characters'
  mk xmldesc xmldesc "Does <b>x</b>. Use when y."
  expect xmldesc 1 'XML tag'
  mk nowhen nowhen "Processes Excel files."
  expect nowhen 0 "no 'when to use' clause"
  mk person person "I can help you process files. Use when files appear."
  expect person 0 'first/second person'
  mk longbody longbody "Does x. Use when y."
  seq 1 520 >> "$T/longbody/SKILL.md"
  expect longbody 1 'over the 500 limit'
  mk winpath winpath "Does x. Use when y."
  printf 'run scripts\\helper.py now\n' >> "$T/winpath/SKILL.md"
  expect winpath 1 'backslash path'
  mk refs refs "Does x. Use when y."
  mkdir -p "$T/refs/references"
  printf 'See references/a.md\n' >> "$T/refs/SKILL.md"
  { echo "# A"; echo "See details.md"; seq 1 120; } > "$T/refs/references/a.md"
  echo "# D" > "$T/refs/references/details.md"
  expect refs 0 'no contents list:.*a\.md'
  expect refs 0 'two-level reference.*details\.md'
  [ "$fails" -eq 0 ] && echo "PASS skill-lint self-test ($cases cases: 7 failure kinds · 4 warning kinds · 2 pass — failure reasons checked)"
  return "$fails"
}

case "${1:-}" in
  ''|-h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] && exit 0 || exit 2 ;;
  --self-test) self_test; exit $? ;;
esac

for d in "$@"; do
  [ -d "$d" ] || { printf 'not a directory: %s\n' "$d" >&2; exit 2; }
  lint_one "$d"
done
printf "\n  pass %d · warn %d · fail %d\n" "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
