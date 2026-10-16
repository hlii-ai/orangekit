#!/bin/bash
# skills/stack-guide-generator/scripts/guide-gate.sh — machine gate for generated guides
#
# The checklist that used to be scattered through the prompt, moved into a script. The verdict has three tiers.
#   FAIL   installation blocked — if even one remains, it is not installed (exit 1)
#   WARN   must be reported — install, but carry it into the user report
#   REVIEW a human justifies it one item at a time — made an automatic failure, it gets buried in false positives
#
#   guide-gate.sh --guide <guide-directory> [options]
#       --ledger <file>    symbol ledger (markdown table) ↔ actual definitions and consumers
#       --forbid <kw,kw>   cross-leak forbidden keywords (stack names not in the fixed combination)
#       --pm <name>        the preset's packageManager — catches commands of a different manager
#       --generated        treat as generated (generation stamp required)
#       --claims-out <file> export the version-claim inventory as TSV (the entire input of audit B).
#                          Above 40 entries, halve it with `split -n l/2` and run audit B in parallel —
#                          it is the only audit whose items are independent, so splitting loses nothing
#   guide-gate.sh --pack <pack-directory>
#       Checks an axis pack before assembly. Runs only the checks that close inside the axis, and explicitly
#       reports what it skipped for being a function of the combination (requires satisfaction·--pair).
#   guide-gate.sh --pair --contract <contract-file> --frontend <dir> --backend <dir>
#   guide-gate.sh --self-test   synthetic fixtures only (fast — run it on every harness change)
#   guide-gate.sh --regress     + actually checks every shipped pack and every pre-built seam.
#       Synthetic fixtures catch **misses**, real assets catch **false positives**. It is slow, so run it before shipping.
#   guide-gate.sh --help
#
# The code verdict looks only inside code fences. Comment lines and the span after a ❌/Bad marker are excluded —
# guides carry anti-pattern examples on purpose, so a blind scan would be riddled with false positives.
#
# Exit codes: 0 = FAIL 0, 1 = FAIL present, 2 = usage error

set -uo pipefail   # no -e: run every check to the end and emit the whole report

FAIL=0; WARN=0; PASS=0; REVIEW=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_0=""; }

# Copies doctor.sh's conventions (not a source — lib/common.sh's set -Eeuo pipefail and its
# ERR trap conflict with the "run every check to the end" policy).
# The original doctor.sh returns 1 when $2 is empty. Here return 0 is explicit.
ok()   { PASS=$((PASS+1));     printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1));     printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1));     printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
rev()  { REVIEW=$((REVIEW+1)); printf "  ${C_C}?${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }

num() { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

TMP=$(mktemp -d 2>/dev/null) || { printf "failed to create a temp directory\n" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── code-line extraction ────────────────────────────────────────────
# Keeps only lines inside a code fence that are not comments and are not in an anti-pattern (❌/Bad) span.
# Both idioms count as markers: `// ❌` / `// ✅`, `// Bad` / `// Good`.
# If the prose line right before a fence is ❌/Bad, the whole fence starts as an anti-pattern.
# Output: <file>\t<line number>\t<text>\t<fence ID>
# The 4th column exists for fence-level checks (security shape·duplicate fence). The first 3 columns are unchanged, so
# existing `cut -f3` consumers are unaffected.
codelines() {
  awk '
    # ❌/✅ outrank the English words as markers. The word test has to exclude _ and digits at its
    # boundary so contract identifiers (BAD_SHAPE·BAD_REQUEST) are not mistaken for anti-pattern markers —
    # if they are, code extraction switches off from there and every later check is silently skipped (a miss).
    function isbad(s)  { return (index(s,"❌")>0 || (index(s,"✅")==0 && s ~ /(^|[^A-Za-z0-9_])(Bad|BAD)([^A-Za-z0-9_]|$)/)) }
    function isgood(s) { return (index(s,"✅")>0 || (index(s,"❌")==0 && s ~ /(^|[^A-Za-z0-9_])(Good|GOOD)([^A-Za-z0-9_]|$)/)) }
    function iscomment(s) { return (s ~ /^[[:space:]]*(\/\/|#|\*|\/\*|--)/) }
    FNR==1 { inf=0; pol=1; lastprose=""; fn=0 }
    /^[[:space:]]*```/ { if (!inf) { inf=1; fn++; pol = isbad(lastprose) ? 0 : 1 } else { inf=0 }; next }
    !inf { if ($0 ~ /[^[:space:]]/) lastprose=$0; next }
    iscomment($0) { if (isbad($0)) pol=0; else if (isgood($0)) pol=1; next }
    pol { print FILENAME "\t" FNR "\t" $0 "\t" FILENAME "#" fn }
  ' "$@"
}

# Takes both a guide (SKILL.md) and an axis pack (PACK.md) — the --pack mode reuses the same checks.
guide_files() { ls "$1/SKILL.md" "$1/PACK.md" "$1"/resources/*.md 2>/dev/null; }

# Exports whose names the framework fixes — signatures legitimately differ between routes
FRAMEWORK_EXPORTS='^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|default|middleware|config|metadata|generateMetadata|generateStaticParams|loader|action|handler|Component|ErrorBoundary)$'

# ════════════════════════════════════════════════════════════════════
# --guide : check one guide
# ════════════════════════════════════════════════════════════════════
run_guide() {
  local G="$1"
  printf "\n${C_D}guide-gate${C_0}  %s\n" "$G"

  [ -d "$G" ] || { printf "guide directory missing: %s\n" "$G" >&2; exit 2; }
  [ -f "$G/SKILL.md" ] || { bad "SKILL.md missing"; return; }

  local FILES; FILES=$(guide_files "$G")
  [ -n "$FILES" ] || { bad "resources/*.md missing"; return; }
  # shellcheck disable=SC2086
  codelines $FILES > "$TMP/code.tsv"
  cut -f3 "$TMP/code.tsv" > "$TMP/code.txt"

  check_structure "$G"
  check_refs "$G"
  check_budget "$G"
  check_fences "$G"
  check_section_budget "$G"
  check_symbols "$G"
  check_env "$G"
  check_leak "$G"
  check_pm "$G"
  check_stamp "$G"
  check_ledger "$G"
  check_pack_iface "$G"
  check_policies "$G"
  check_security_shapes "$G"
  check_claims "$G"
  check_duplicate_fences "$G"
  check_blocking_proof "$G"
}

# ── 1. structure: frontmatter + the 8 required sections in order ──
check_structure() {
  local G="$1" f="$1/SKILL.md"
  sec "structure (8 required sections)"

  head -1 "$f" | grep -q '^---$' && ok "frontmatter delimiter" || bad "line 1 is not '---' — no frontmatter"

  local nm dn
  nm=$(awk '/^name:/{sub(/^name:[[:space:]]*/,"");gsub(/^"|"$/,"");print;exit}' "$f")
  dn=$(basename "$G")
  [ "$nm" = "$dn" ] && ok "name = directory name ($nm)" || bad "name mismatch: '$nm' ≠ directory '$dn'" "the skill does not load, or is exposed under another name"

  local dl
  dl=$(num "$(awk '/^description:/{sub(/^description:[[:space:]]*/,"");gsub(/^"|"$/,"");print length($0);exit}' "$f")")
  if [ "$dl" -eq 0 ]; then bad "description missing (or a block scalar)"
  elif [ "$dl" -le 450 ]; then ok "description ${dl}/450 chars"
  else bad "description ${dl} chars — over the 450-char spec limit"; fi

  local heads n h
  heads=$(grep '^## ' "$f" | sed 's/^## //')
  n=$(num "$(printf '%s\n' "$heads" | grep -c . | tr -d ' ')")
  if [ "$n" -ne 7 ]; then
    bad "'## ' sections: ${n} — the spec is 7 (8 counting frontmatter)" "$(printf '%s' "$heads" | tr '\n' '/')"
  else
    local i=1 okorder=1
    for want in "Quick Start" "Architecture Overview" "Directory Structure" "Core Principles" "Common Imports" "*" "Navigation Guide"; do
      h=$(printf '%s\n' "$heads" | sed -n "${i}p")
      if [ "$want" != "*" ]; then
        case "$h" in "$want"*) ;; *) bad "section ${i} mismatch: '$h' — the spec is '$want'"; okorder=0;; esac
      fi
      i=$((i+1))
    done
    [ "$okorder" -eq 1 ] && ok "the 7 required sections are in the right order"
  fi
}

# ── 2. references: dangling + Navigation coverage set difference ──
check_refs() {
  local G="$1"
  sec "references (dangling · Navigation coverage)"

  local d=0 c=0 r
  for r in $(grep -rhoE 'resources/[A-Za-z0-9._-]+\.md' "$G"/SKILL.md "$G"/resources/*.md 2>/dev/null | sort -u); do
    c=$((c+1))
    [ -f "$G/$r" ] || { bad "dangling reference: $r"; d=$((d+1)); }
  done
  [ "$d" -eq 0 ] && ok "all ${c} resource references exist"

  awk '/^## Navigation Guide/{s=1;next} /^## /{s=0} s' "$G/SKILL.md" \
    | grep -oE 'resources/[A-Za-z0-9._-]+\.md' | sort -u > "$TMP/nav.txt"
  ls "$G"/resources/*.md 2>/dev/null | while read -r p; do printf 'resources/%s\n' "$(basename "$p")"; done | sort -u > "$TMP/real.txt"

  local uncovered ghostref
  uncovered=$(comm -13 "$TMP/nav.txt" "$TMP/real.txt" | tr '\n' ' ')
  ghostref=$(comm -23 "$TMP/nav.txt" "$TMP/real.txt" | tr '\n' ' ')
  [ -n "$(printf '%s' "$uncovered" | tr -d ' ')" ] \
    && bad "resources not covered by the Navigation Guide: $uncovered" "spec: every file under resources/ appears at least once" \
    || ok "Navigation coverage complete ($(num "$(wc -l < "$TMP/real.txt")") files)"
  [ -n "$(printf '%s' "$ghostref" | tr -d ' ')" ] \
    && bad "the Navigation Guide points at a file that does not exist: $ghostref"

  local rc; rc=$(num "$(wc -l < "$TMP/real.txt")")
  if [ "$rc" -ge 6 ] && [ "$rc" -le 10 ]; then ok "${rc} resource files (spec 6~10)"
  else warn "${rc} resource files — outside the 6~10 spec" "the range derives from 7 required slots + 0~3 optional"; fi
}

# ── 3. budget ──
check_budget() {
  local G="$1" over=0 near=0 f n
  sec "budget (300 lines per file)"
  for f in $(guide_files "$G"); do
    # The shipping stamp (orangekit-pack/orangekit-seam) is machine metadata, not content — take it out of the budget.
    # Without that, an original at exactly 300 lines goes over just by being moved into a pack.
    n=$(num "$(grep -vcE '^<!-- orangekit-(pack|seam):' "$f" | tr -d ' ')")
    if   [ "$n" -gt 300 ]; then bad "$(basename "$f") ${n} lines — over 300"; over=$((over+1))
    elif [ "$n" -gt 290 ]; then warn "$(basename "$f") ${n} lines — over 290 (must be reported)" "in a file pinned to the limit, the next change lets the budget rather than the author pick what gets deleted"; near=$((near+1)); fi
  done
  [ "$over" -eq 0 ] && [ "$near" -eq 0 ] && ok "every file is 290 lines or fewer"
}

# ── 4. code-fence pairing ──
check_fences() {
  local G="$1" odd=0 f n
  sec "code-fence pairing"
  for f in $(guide_files "$G"); do
    n=$(num "$(grep -c '^[[:space:]]*```' "$f" | tr -d ' ')")
    [ $((n % 2)) -ne 0 ] && { bad "$(basename "$f"): ${n} fences — odd" "an unclosed code block. Everything after it renders as code"; odd=$((odd+1)); }
  done
  [ "$odd" -eq 0 ] && ok "code fences pair up in every file"
}

# ── 5. per-section budget (the budget column of the spec) ──
check_section_budget() {
  local G="$1" f="$1/SKILL.md"
  sec "per-section budget"

  local hit=0 name lim n
  while IFS=$'\t' read -r name lim; do
    [ -z "$name" ] && continue
    n=$(num "$(awk -v s="## $name" '$0==s||index($0,s)==1{f=1;next} /^## /{f=0} f' "$f" | grep -c . | tr -d ' ')")
    [ "$n" -eq 0 ] && continue
    [ "$n" -gt "$lim" ] && { warn "## $name ${n} lines — spec ${lim} lines"; hit=$((hit+1)); }
  done <<'LIMITS'
Architecture Overview	30
Directory Structure	30
Common Imports	30
LIMITS

  # The auxiliary section (the 6th) is ≤40 lines
  local aux
  aux=$(grep '^## ' "$f" | sed 's/^## //' | sed -n '6p')
  if [ -n "$aux" ]; then
    n=$(num "$(awk -v s="## $aux" 'index($0,s)==1{f=1;next} /^## /{f=0} f' "$f" | grep -c . | tr -d ' ')")
    [ "$n" -gt 40 ] && { warn "auxiliary section '## $aux' ${n} lines — spec 40 lines"; hit=$((hit+1)); }
  fi

  # Quick Start: 2 checklists, 6~9 items each
  local qs cl
  # A checklist title counts as either '### Title' or '**Title:**' (both idioms exist in the wild)
  qs=$(awk '/^## Quick Start/{f=1;next} /^## /{f=0} f' "$f")
  cl=$(num "$(printf '%s\n' "$qs" | grep -cE '^(### |\*\*.*\*\*[[:space:]]*$)' | tr -d ' ')")
  if [ "$cl" -ne 2 ]; then warn "Quick Start checklists: ${cl} — spec 2"; hit=$((hit+1)); fi
  printf '%s\n' "$qs" | awk '
    /^### /                      { if (h!="") print h "\t" c; h=substr($0,5); c=0; next }
    /^\*\*.*\*\*[[:space:]]*$/  { if (h!="") print h "\t" c; h=$0; gsub(/\*/,"",h); c=0; next }
    /^[[:space:]]*(-|[0-9]+\.)[[:space:]]/{ if (h!="") c++ }
    END{ if (h!="") print h "\t" c }' > "$TMP/qs.tsv"
  while IFS=$'\t' read -r name n; do
    [ -z "$name" ] && continue
    n=$(num "$n")
    { [ "$n" -lt 6 ] || [ "$n" -gt 9 ]; } && { warn "Quick Start '$name' ${n} items — spec 6~9"; hit=$((hit+1)); }
  done < "$TMP/qs.tsv"

  # Core Principles: 5~8 rules, each ≤20 lines
  local cp rules
  cp=$(awk '/^## Core Principles/{f=1;next} /^## /{f=0} f' "$f")
  rules=$(num "$(printf '%s\n' "$cp" | grep -c '^### ' | tr -d ' ')")
  { [ "$rules" -lt 5 ] || [ "$rules" -gt 8 ]; } && { warn "Core Principles rules: ${rules} — spec 5~8"; hit=$((hit+1)); }
  printf '%s\n' "$cp" | awk '
    /^### /{ if (h!="") print h "\t" c; h=substr($0,5); c=0; next }
    { if (h!="") c++ }
    END{ if (h!="") print h "\t" c }' > "$TMP/cp.tsv"
  while IFS=$'\t' read -r name n; do
    [ -z "$name" ] && continue
    [ "$(num "$n")" -gt 20 ] && { warn "rule '$(printf '%.44s' "$name")' $(num "$n") lines — spec 20 lines"; hit=$((hit+1)); }
  done < "$TMP/cp.tsv"

  [ "$hit" -eq 0 ] && ok "every per-section budget is within spec"
}

# ── 6. symbols: duplicate export with differing definitions (FAIL) · ghost definition/undefined call/mixed signature (REVIEW) ──
# ── symbol definition patterns (language-agnostic) ─────────────────
# A pattern that only knew TypeScript **missed the definitions of a Python pack wholesale** (measured in the fastapi pilot:
# `def to_app_error(...)`·`settings = Settings()` all FAILed as "no definition").
# Functions are `def`/`async def`, and module-level assignment is **pinned to column 0** — counting indented
# reassignment and attribute assignment (`obj.x = 1`) as a definition produces false positives.
# If a policy file **has rows that look like a table but parses to zero**, that is silent zero enforcement.
# In the firebase pack the `## Machine checks` heading was missing, 8 policies were ignored wholesale, and the gate
# emitted only a WARN — an enforcement device was green while doing nothing. That is the very failure mode this
# repository exists to eliminate, so it is raised to FAIL.
_policy_rows_look_present() { # $1=policy file
  [ -f "$1" ] || return 1
  grep -qE '^\|[[:space:]]*`[A-Za-z0-9_-]+`[[:space:]]*\|[[:space:]]*(forbid|require)[[:space:]]*\|' "$1"
}

# Is the symbol defined in this file? codelines() is the first pass, the JSDoc `@typedef` the second.
# **Type symbols in a JS pack are declared only in JSDoc comments** — `iscomment()` drops lines starting with `*`,
# so such a declaration **cannot exist** in codelines(). Measured on vanilla (the first JavaScript axis):
# `Task` FAILed as "no definition" even though it was defined. That is where the checker knew only one language.
_has_def() { # $1=file $2=symbol
  codelines "$1" | cut -f3 | grep -qE "$(_defpat "$2")" && return 0
  grep -qE "@typedef[[:space:]]*\{.*\}[[:space:]]*$2\b|@typedef[[:space:]]+$2\b" "$1" && return 0
  return 1
}

_defpat() { # $1=symbol name → grep -E pattern
  printf '(export[[:space:]]+)?(async[[:space:]]+)?(function|const|let|class|type|interface|enum)[[:space:]]+%s\\b|(async[[:space:]]+)?def[[:space:]]+%s\\b|^%s[[:space:]]*(:[^=]*)?=[^=]' "$1" "$1" "$1"
}

check_symbols() {
  local G="$1"
  sec "symbols (duplicate definition · ghost definition · undefined call)"

  # Definition site → "name<TAB>argument count".
  # The argument count tracks bracket depth and counts only top-level commas — counting the commas of
  # destructuring (`{ a, b }`) and generics (`Record<string, string>`) as arguments flags correct code as a mismatch.
  # If the parenthesis does not close on the same line (a multi-line signature), the verdict is abandoned.
  awk '
    function arity(s,   i,d,c,ch,pv,seen) {
      d=0; c=0; seen=0; pv=""
      for (i=1; i<=length(s); i++) {
        ch=substr(s,i,1)
        if (ch=="(" || ch=="{" || ch=="[") d++
        else if (ch=="<") { if (pv ~ /[A-Za-z0-9_]/) d++ }
        else if (ch==">") { if (pv != "=" && d>0) d-- }
        else if (ch=="}" || ch=="]") { if (d>0) d-- }
        else if (ch==")") { if (d==0) return seen ? c+1 : 0; d-- }
        else if (ch=="," && d==0) c++
        if (d==0 && ch ~ /[A-Za-z0-9_$]/) seen=1
        pv=ch
      }
      return -1
    }
    {
      line=$0
      while (match(line, /export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) \
          || match(line, /export[[:space:]]+const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?\(/)) {
        hit=substr(line, RSTART, RLENGTH)
        rest=substr(line, RSTART+RLENGTH)
        nm=hit; sub(/[[:space:]]*(=[[:space:]]*(async[[:space:]]+)?)?\($/, "", nm); sub(/.*[[:space:]]/, "", nm)
        a=arity(rest)
        if (a >= 0) print nm "\t" a
        line=rest
      }
    }' "$TMP/code.txt" | sort -u > "$TMP/defs.tsv"

  local dup
  dup=$(awk -F'\t' -v skip="$FRAMEWORK_EXPORTS" '$1 !~ skip {c[$1]++} END{for(k in c) if (c[k]>1) print k}' "$TMP/defs.tsv" | sort | tr '\n' ' ')
  if [ -n "$(printf '%s' "$dup" | tr -d ' ')" ]; then
    bad "duplicate export — the same name defined with different signatures: $dup" \
        "a consumer cannot tell which definition to trust. Unify them or split the name"
  else
    ok "no duplicate export with differing definitions"
  fi

  # Every export name (framework-reserved names excluded)
  grep -oE 'export (async )?(function|const|class|type|interface) [A-Za-z_][A-Za-z0-9_]*' "$TMP/code.txt" \
    | awk '{print $NF}' | sort -u | grep -vE "$FRAMEWORK_EXPORTS" > "$TMP/exports.txt"

  # Ghost definition — defined exactly once in the whole guide
  : > "$TMP/ghost_fn.txt"; : > "$TMP/ghost_comp.txt"
  local s cnt
  while read -r s; do
    [ -z "$s" ] && continue
    cnt=$(num "$(grep -rhow "$s" $(guide_files "$G") 2>/dev/null | grep -c . | tr -d ' ')")
    [ "$cnt" -gt 1 ] && continue
    case "$s" in [A-Z]*) printf '%s\n' "$s" >> "$TMP/ghost_comp.txt";; *) printf '%s\n' "$s" >> "$TMP/ghost_fn.txt";; esac
  done < "$TMP/exports.txt"

  local gf gc
  gf=$(num "$(grep -c . "$TMP/ghost_fn.txt" | tr -d ' ')")
  gc=$(num "$(grep -c . "$TMP/ghost_comp.txt" | tr -d ' ')")
  [ "$gf" -gt 0 ] && rev "ghost definitions (function·schema): ${gf}" "$(tr '\n' ' ' < "$TMP/ghost_fn.txt")— defined but never used again anywhere in the guide. Create a consumer or delete it"
  [ "$gc" -gt 0 ] && rev "components appearing once: ${gc}" "$(tr '\n' ' ' < "$TMP/ghost_comp.txt")— normal if it is a standalone example component"
  [ "$gf" -eq 0 ] && [ "$gc" -eq 0 ] && ok "no ghost definitions"

  # Undefined project-local calls — names imported from '@/' with no definition in the guide
  grep -oE "import (type )?\{[^}]*\} from '@/[^']*'" "$TMP/code.txt" \
    | sed -E "s/import (type )?\{//; s/\} from '.*//" | tr ',' '\n' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^type[[:space:]]+//; s/[[:space:]]+as[[:space:]]+.*//' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u > "$TMP/localimports.txt"
  : > "$TMP/undef.txt"
  while read -r s; do
    [ -z "$s" ] && continue
    grep -qE "$(_defpat "$s")" "$TMP/code.txt" \
      || printf '%s\n' "$s" >> "$TMP/undef.txt"
  done < "$TMP/localimports.txt"
  local ud; ud=$(num "$(grep -c . "$TMP/undef.txt" | tr -d ' ')")
  [ "$ud" -gt 0 ] \
    && rev "local symbols imported without a definition: ${ud}" "$(tr '\n' ' ' < "$TMP/undef.txt")— normal for scaffolding (a UI kit); a cut edge if the guide introduced the name" \
    || ok "every locally imported symbol is defined"

  # Mixed signature — one definition, but calls split between with-arguments and without
  local mixed=""
  while read -r s; do
    [ -z "$s" ] && continue
    local forms
    forms=$(grep -ohE "\b$s\([^)]*" "$TMP/code.txt" | sed -E "s/^$s\(//" | sed -E 's/^([A-Za-z0-9_{[]).*/◆/; s/^$/◇/' | sort -u | tr -d '\n')
    case "$forms" in *◆*◇*|*◇*◆*) mixed="$mixed $s";; esac
  done < "$TMP/exports.txt"
  [ -n "$mixed" ] \
    && rev "mixed call shapes:$mixed" "normal for a variadic utility (cn and friends) or an optional argument; otherwise self-contradictory" \
    || ok "no mixed call shapes"
}

# ── 7. env key coverage ──
check_env() {
  local G="$1"
  sec "env key coverage"

  # A value can be a **helper call** such as `ms(60_000)...`, not only the `z.string()...` shape.
  # Accepting only a dot flags a key declared through a helper as undeclared and FAILs correct code (measured on node-api).
  { grep -oE '^[[:space:]]*[A-Z][A-Z0-9_]{2,}:[[:space:]]*[A-Za-z_$][A-Za-z0-9_$]*[.(]' "$TMP/code.txt"
    # **A schema declared as class fields is also a declaration.** On the class-validator axis (node-nest)
    # the schema is a class rather than an object and what sits in the value position is a **type** — the regex above
    # knew only the form where the value is a call or property access (the z.string() family), so it saw 0 declarations in that pack
    # and the use of env.LOG_LEVEL FAILed as "a key not in the schema" (measured on node-nest — a false positive).
    # Only the two forms that do not mix with an object literal are accepted: `KEY!: T` / `KEY?: T` and `KEY: T = default`.
    grep -oE '^[[:space:]]*[A-Z][A-Z0-9_]{2,}[!?]:' "$TMP/code.txt"
    grep -oE "^[[:space:]]*[A-Z][A-Z0-9_]{2,}:[[:space:]]*[A-Za-z_$'\"][^=;]*=" "$TMP/code.txt"
  } | sed -E 's/^[[:space:]]*//; s/[!?]?:.*//' | sort -u > "$TMP/envdecl.txt"
  local nd; nd=$(num "$(grep -c . "$TMP/envdecl.txt" | tr -d ' ')")
  if [ "$nd" -eq 0 ]; then
    warn "no validated env schema — coverage check skipped" "spec: environment variables are input too. Fail at boot time from a single validated module"
    return
  fi

  grep -oE '(^|[^A-Za-z0-9_.])env\.[A-Z][A-Z0-9_]+' "$TMP/code.txt" | sed -E 's/.*env\.//' | sort -u > "$TMP/envuse.txt"
  local miss; miss=$(comm -23 "$TMP/envuse.txt" "$TMP/envdecl.txt" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$miss" | tr -d ' ')" ]; then
    bad "keys used that are not in the env schema: $miss" "they pass boot validation and then become undefined at the use site — add them to the schema"
  else
    ok "all $(num "$(wc -l < "$TMP/envuse.txt")") env keys used are declared in the schema (${nd} declared)"
  fi
}

# ── 8. cross-leak ──
check_leak() {
  local G="$1"
  [ -n "$FORBID" ] || return 0
  sec "cross-leak"
  # Matched on word boundaries (-w). Matching substrings catches the field names the contract specifies
  # (`--forbid next` ↔ `nextCursor`) — and the --pair mode of this same gate requires that field, so
  # the two checks would demand opposites. A library leak shows up as an import path or a dotted call,
  # and -w catches both of those (`@prisma/client`·`prisma.user`).
  #
  # When a product name is **also an ordinary English word** (`express`·`next`·`nest`), a word in prose is
  # mistaken for a leak (measured: "cannot express"). For those names only, code lines are matched
  # case-insensitively and prose only by the product spelling (capitalized — `Express`). Every other name
  # is still matched as is, because a lowercase command in prose (`prisma migrate`) is a leak too.
  local kw hits n=0 cap
  for kw in $(printf '%s' "$FORBID" | tr ',' '\n'); do
    kw=$(printf '%s' "$kw" | tr -d ' ')   # accept "a, b" too — a leftover leading space means that keyword never matches
    [ -z "$kw" ] && continue
    case "$(printf '%s' "$kw" | tr 'A-Z' 'a-z')" in
      express|next|nest|remix|solid|astro)
        # The product spelling in prose. next·nest collide with a sentence's first word ("Next, …"), so only the official spelling counts
        case "$(printf '%s' "$kw" | tr 'A-Z' 'a-z')" in
          next) cap="Next.js" ;; nest) cap="NestJS" ;;
          *)    cap="$(printf '%s' "${kw:0:1}" | tr 'a-z' 'A-Z')${kw:1}" ;;
        esac
        hits=$({ codelines $(guide_files "$G") 2>/dev/null | awk -F'\t' '{print $1":"$2":"$3}' | grep -iwF -- "$kw"
                 grep -rnwF -- "$cap" $(guide_files "$G") 2>/dev/null; } | head -3 | cut -c1-110 | tr '\n' ';')
        ;;
      *) hits=$(grep -rniwF "$kw" $(guide_files "$G") 2>/dev/null | head -3 | cut -c1-110 | tr '\n' ';') ;;
    esac
    if [ -n "$hits" ]; then bad "stack keyword '$kw' appears although it is not in the fixed combination" "$hits"; n=$((n+1)); fi
  done
  [ "$n" -eq 0 ] && ok "no forbidden keyword leaks"
}

# ── 9. package manager consistency ──
check_pm() {
  local G="$1"
  [ -n "$PM" ] || return 0
  sec "package manager"
  local other n=0 hits
  for other in npm pnpm yarn bun uv poetry pip; do
    [ "$other" = "$PM" ] && continue
    hits=$(grep -rhoE "\b$other (run|install|add|exec|dlx|create|i|sync|ci)\b" $(guide_files "$G") 2>/dev/null | sort -u | tr '\n' ' ')
    if [ -n "$(printf '%s' "$hits" | tr -d ' ')" ]; then
      bad "package manager mismatch: the fixed one is '$PM' but a '$other' command is used" "$hits"; n=$((n+1))
    fi
  done
  [ "$n" -eq 0 ] && ok "package manager '$PM' is consistent"
}

# ── 10. stamp and package coverage ──
check_stamp() {
  local G="$1" f="$1/SKILL.md"
  sec "stamp"

  local stamp base
  stamp=$(grep -m1 -oE '<!-- orangekit-guide:[^>]*-->' "$f" 2>/dev/null)
  base=$(grep -m1 -oE '<!-- orangekit-guide-baseline:[^>]*-->' "$f" 2>/dev/null)

  if [ "$GENERATED" -eq 1 ]; then
    [ -n "$stamp" ] && ok "generation stamp present" || bad "generation stamp missing" "on regeneration there is no basis left for detecting a hand edit"
    [ -n "$stamp" ] && { case "$stamp" in *pkgs=*) ok "the stamp carries pkgs=";; *) warn "the stamp has no pkgs=" "the version-drift check gets nothing to compare against";; esac; }
  else
    [ -n "$base" ] && ok "verification baseline present" || warn "verification baseline (orangekit-guide-baseline) missing" "for a pre-built guide the baseline is the only basis for judging staleness"
  fi

  local decl; decl="$stamp$base"
  [ -n "$decl" ] || return 0

  grep -oE "from '[^'.][^']*'" "$TMP/code.txt" | sed -E "s/from '//; s/'$//" \
    | grep -v '^@/' | grep -vE '^(node:|bun:)' \
    | sed -E 's#^(@[^/]+/[^/]+).*#\1#; s#^([^@][^/]*)/.*#\1#' \
    | grep -vE '^(fs|path|crypto|http|https|url|util|os|events|stream|buffer|child_process|assert|zlib|net|tls|worker_threads|perf_hooks|timers|process)$' \
    | sort -u > "$TMP/pkgs.txt"

  local p missing=""
  while read -r p; do
    [ -z "$p" ] && continue
    printf '%s' "$decl" | grep -qF "$p@" || missing="$missing $p"
  done < "$TMP/pkgs.txt"
  [ -n "$missing" ] \
    && warn "imported packages missing from the stamp:$missing" "the version-drift check cannot see these packages — add <pkg>@<major> to the stamp" \
    || ok "all $(num "$(wc -l < "$TMP/pkgs.txt")") imported packages are declared in the stamp"
}

# ── 11. symbol ledger cross-check ──
check_ledger() {
  local G="$1"
  [ -n "$LEDGER" ] || return 0
  sec "symbol ledger cross-check"
  [ -f "$LEDGER" ] || { bad "ledger file missing: $LEDGER"; return; }

  # | `symbol` | definition file | consumer1, consumer2 |
  sed -E 's/^[[:space:]]*\|//; s/\|[[:space:]]*$//' "$LEDGER" \
    | grep '|' | grep -v '^[[:space:]]*[-: ]*|[-: |]*$' \
    | awk -F'|' 'NF>=3 { gsub(/`|[[:space:]]/,"",$1); if ($1=="" || $1=="symbol") next; print $1"\t"$2"\t"$3 }' \
    > "$TMP/ledger.tsv"

  local rows; rows=$(num "$(grep -c . "$TMP/ledger.tsv" | tr -d ' ')")
  [ "$rows" -eq 0 ] && { bad "could not read entries from the ledger: $LEDGER" "format: | \`symbol\` | definition file | consumer, consumer |"; return; }

  local sym deff cons n_def=0 n_con=0 rf cf c
  while IFS=$'\t' read -r sym deff cons; do
    [ -z "$sym" ] && continue
    rf=$(_resolve "$G" "$deff")
    if [ -z "$rf" ]; then bad "the definition file of ledger entry '$sym' does not exist: $(printf '%s' "$deff" | tr -d ' `')"; n_def=$((n_def+1)); continue; fi
    if ! _has_def "$rf" "$sym"; then
      bad "the definition of ledger entry '$sym' is not in $(basename "$rf")" "the ledger is a contract — add the definition or delete the row"; n_def=$((n_def+1))
    fi
    for c in $(printf '%s' "$cons" | tr ',' '\n'); do
      c=$(printf '%s' "$c" | tr -d ' `')
      [ -z "$c" ] || [ "$c" = "—" ] || [ "$c" = "-" ] && continue
      cf=$(_resolve "$G" "$c")
      if [ -z "$cf" ]; then bad "the consumer file of ledger entry '$sym' does not exist: $c"; n_con=$((n_con+1)); continue; fi
      grep -qw "$sym" "$cf" || { bad "ledger entry '$sym' does not appear in the consumer $(basename "$cf")" "ghost definition — consume it or delete it from the ledger"; n_con=$((n_con+1)); }
    done
  done < "$TMP/ledger.tsv"

  cut -f1 "$TMP/ledger.tsv" | sort -u > "$TMP/ledgersym.txt"
  local unreg; unreg=$(comm -23 "$TMP/exports.txt" "$TMP/ledgersym.txt" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$unreg" | tr -d ' ')" ]; then
    bad "export symbols missing from the ledger:$unreg" "layer 2 discipline: a new project-local symbol is entered in the ledger the moment it is introduced"
  else
    ok "every export symbol is entered in the ledger"
  fi
  [ "$n_def" -eq 0 ] && [ "$n_con" -eq 0 ] && ok "${rows} ledger rows pass the definition·consumption cross-check"
}


# ── 12. pack interface: does the assembly satisfy the pack's requires? ──
# Shipping the axis pack and the seam separately makes "a symbol the pack uses but the seam does not give"
# a new class of defect. The requires table of the ledger is that contract, and this check is its enforcement.
# Kinds are distinguished: project=must be exported · library=the name appears in an import · cross-axis=owned by the other guide (skipped)
check_pack_iface() {
  local G="$1"
  [ -n "$ASSEMBLY" ] || return 0
  sec "pack interface (requires satisfaction)"
  [ -f "$ASSEMBLY" ] || { bad "assembly.json missing: $ASSEMBLY"; return; }

  local pack; pack=$(grep -oE '"pack"[[:space:]]*:[[:space:]]*"[^"]+"' "$ASSEMBLY" | sed -E 's/.*"([^"]+)"$/\1/')
  [ -n "$pack" ] || { warn "assembly.json has no pack entry"; return; }
  local pdir="$PLUGIN_GUIDES/$pack"
  [ -d "$pdir" ] || { bad "pack directory missing: $pdir" "pass the path with --plugin-guides, or set CLAUDE_PLUGIN_ROOT"; return; }
  local led="$pdir/$PACK_LEDGER_NAME"
  [ -f "$led" ] || { warn "pack ledger missing: $led"; return; }

  # Only the table of the requires section is read (mixing it with provides inverts the verdict)
  awk '/^## requires/{f=1;next} /^## /{f=0} f' "$led" \
    | grep -E '^\|[[:space:]]*`' \
    | awk -F'|' 'NF>=4 { gsub(/`|[[:space:]]/,"",$2); gsub(/[[:space:]]/,"",$3); if ($2!="") print $2"\t"$3 }' \
    > "$TMP/req.tsv"

  local n; n=$(num "$(grep -c . "$TMP/req.tsv" | tr -d ' ')")
  [ "$n" -eq 0 ] && { warn "could not read requires entries from the pack ledger" "format: | \`symbol\` | kind | shape | reason |"; return; }

  local sym kind miss=0 skipped=0
  while IFS=$'\t' read -r sym kind; do
    [ -z "$sym" ] && continue
    case "$kind" in
      cross-axis|generated)
        skipped=$((skipped+1)); continue ;;
      library)
        if grep -qhE "import[^\n]*\b$sym\b|from '[^']+'" $(guide_files "$G") 2>/dev/null \
           && grep -qhw "$sym" $(guide_files "$G") 2>/dev/null; then :; else
          bad "the binding for pack requires '$sym' (library) is not in the assembly"; miss=$((miss+1)); fi ;;
      *)
        if ! grep -hqE "^export[[:space:]]+(async[[:space:]]+)?(function|const|let|class|type|interface|enum)[[:space:]]+$sym\b" $(guide_files "$G") 2>/dev/null; then
          bad "the seam does not define pack requires '$sym'" "the pack example becomes unrunnable — have the seam export it, or fix the kind in the ledger"
          miss=$((miss+1)); fi ;;
    esac
  done < "$TMP/req.tsv"

  [ "$miss" -eq 0 ] && ok "${n} pack requires satisfied (${skipped} cross-axis entries excluded)"
}

# ── 13. policy ledger: does the assembly keep the cross-file invariants the pack declared? ──
# Measured (2026-08-22): 26 of 57 audit findings were "the place that declares a policy and the place that
# enforces it differ, and nothing obliges anyone to reconcile the two". Symbols had a ledger; policies did not.
# The check runs only on codelines() output — counting prose, comments, and anti-pattern examples is all false positives.
check_policies() {
  local G="$1"
  [ -n "$ASSEMBLY" ] || return 0
  sec "policy ledger (pack invariants)"

  local pack; pack=$(grep -oE '"pack"[[:space:]]*:[[:space:]]*"[^"]+"' "$ASSEMBLY" | sed -E 's/.*"([^"]+)"$/\1/')
  local pol="$PLUGIN_GUIDES/$pack/$PACK_POLICIES_NAME"
  [ -f "$pol" ] || { warn "pack policy file missing: $pol"; return; }

  # _parse_policies solely owns the parsing (if two parsers diverge, the check and the proof disagree).
  _parse_policies "$pol" "$TMP/pol.tsv"

  local n; n=$(num "$(grep -c . "$TMP/pol.tsv" | tr -d ' ')")
  if [ "$n" -eq 0 ]; then
    if _policy_rows_look_present "$pol"; then
      bad "pack policies silently enforce 0 entries: $pol" "the policy rows are there but parsing yields 0 — the parser reads the table only if a \`## Machine checks\` heading sits above it. As it stands, not one declared invariant is enforced"
    else
      warn "could not read entries from the pack policies: $pol"
    fi
    return
  fi

  # List of pack-owned files (used for the scope=seam verdict)
  local packfiles; packfiles=$(grep -oE '"packFiles"[^]]*\]' "$ASSEMBLY" | grep -oE '"[a-z0-9.-]+\.md"' | tr -d '"' | tr '\n' ' ')

  local id verdict scope rx except ex has viol=0 pass=0 targets f base hits
  while IFS=$'\t' read -r id verdict scope rx except ex has cx; do
    [ -z "$id" ] && continue
    # Reduce the target scope to a list of files
    targets=""
    for f in $(guide_files "$G"); do
      base=$(basename "$f")
      case "$scope" in
        seam)  case " $packfiles " in *" $base "*) continue;; esac ;;
        pack)  case " $packfiles " in *" $base "*) ;; *) continue;; esac ;;
        file:*) [ "$base" = "${scope#file:}" ] || continue ;;
      esac
      case "$except" in ""|"—"|"-") ;; *)
        case ",$(printf '%s' "$except" | tr -d ' '),"  in *",$base,"*) continue;; esac ;;
      esac
      targets="$targets
$f"
    done
    [ -z "$targets" ] && { rev "policy '$id' has 0 target files" "scope=$scope except=$except — check the scope"; continue; }

    # shellcheck disable=SC2086
    hits=$(codelines $targets | cut -f3 | grep -cE "$rx" 2>/dev/null || true)
    hits=$(num "$hits")
    if [ "$verdict" = "forbid" ]; then
      if [ "$hits" -gt 0 ]; then
        # shellcheck disable=SC2086
        bad "policy violation '$id' — ${hits} forbidden pattern hits" "$(codelines $targets | grep -E "$rx" | head -2 | awk -F'\t' '{printf "%s:%s ", substr($1,match($1,/[^\/]*$/)), $2}')"
        viol=$((viol+1))
      else pass=$((pass+1)); fi
    else
      if [ "$hits" -eq 0 ]; then
        bad "policy violation '$id' — the required pattern is not in the assembly" "regex: $rx"
        viol=$((viol+1))
      else pass=$((pass+1)); fi
    fi
  done < "$TMP/pol.tsv"

  [ "$viol" -eq 0 ] && ok "${pass} pack policies passed"

  check_policy_proof "$G" "$pol" "$packfiles"
}

# ── shared: parsing the policy table ─────────────────────────────────
# | id | verdict | scope | regex | exception file | proof example | counterexample | description |
# Output: id \t verdict \t scope \t regex \t exception \t proof example \t proof-example column present (0/1) \t counterexample
# A \| inside a regex is a markdown table escape — protect it before splitting columns.
_parse_policies() {
  awk '/^## Machine checks/{f=1;next} /^## /{f=0} f' "$1" \
    | grep -E '^\|[[:space:]]*`' \
    | sed 's/\\|/\x01/g' \
    | awk -F'|' 'NF>=7 {
        for(i=2;i<=8;i++){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); gsub(/`/,"",$i); gsub(/\x01/,"|",$i) }
        # Only the scope column is stripped of markdown emphasis. The * in a regex or a proof example is meaningful, so leave those alone.
        # Measured: the vue pack wrote the scope as **seam**, the gate failed to recognize the scope,
        # and the repair the audit ordered — "aim it at the seam" — was silently void.
        gsub(/[*_]/,"",$4)
        ex = (NF>=9) ? $7 : ""; has = (NF>=9) ? 1 : 0
        # An 8-column table (with the new counterexample column) has NF>=10. A 7-column table yields an empty counterexample.
        cx = (NF>=10) ? $8 : ""
        if ($2!="") print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"ex"\t"has"\t"cx }' > "$2"
}

# The target file list of one policy. If packfiles is empty, scope=seam ends up with 0 targets.
_policy_targets() {
  local G="$1" scope="$2" except="$3" packfiles="$4" f base out=""
  for f in $(guide_files "$G"); do
    base=$(basename "$f")
    case "$scope" in
      seam)  case " $packfiles " in *" $base "*) continue;; esac ;;
      pack)  case " $packfiles " in *" $base "*) ;; *) continue;; esac ;;
      file:*) [ "$base" = "${scope#file:}" ] || continue ;;
    esac
    case "$except" in ""|"—"|"-") ;; *)
      case ",$(printf '%s' "$except" | tr -d ' ')," in *",$base,"*) continue;; esac ;;
    esac
    out="$out
$f"
  done
  printf '%s' "$out"
}

# ── 14. policy block proof (the proof-example column) ───────────────
# Measured (2026-08-23): what dominated the wall clock of authoring the vue pack was "build a defect fixture for
# every policy and run it to see whether it is actually caught". That round trip becomes one table column plus the assertions here.
#   ① does the proof example match its own regex (if not, the regex is dead)
#   ② for forbid, is that example absent from the target files (if present, the policy violates itself)
# The verdict is promoted from the author's memory to a standing assertion of the gate.
check_policy_proof() {
  local G="$1" pol="$2" packfiles="${3:-}"
  sec "policy block proof (proof example)"
  [ -f "$pol" ] || { warn "policy file missing: $pol"; return 0; }
  _parse_policies "$pol" "$TMP/polproof.tsv"
  local n; n=$(num "$(grep -c . "$TMP/polproof.tsv" | tr -d ' ')")
  if [ "$n" -eq 0 ]; then
    if _policy_rows_look_present "$pol"; then
      bad "policies silently enforce 0 entries: $pol" "the policy rows are there but parsing yields 0 — the parser reads the table only if a \`## Machine checks\` heading sits above it"
    else
      warn "could not read entries from the policies: $pol" "format: | id | verdict | scope | regex | exception file | proof example | counterexample | description |"
    fi
    return 0
  fi

  local id verdict scope rx except ex has viol=0 pass=0 skip=0 targets
  while IFS=$'\t' read -r id verdict scope rx except ex has cx; do
    [ -z "$id" ] && continue
    if [ "$has" != "1" ] || [ -z "$ex" ] || [ "$ex" = "—" ] || [ "$ex" = "-" ]; then
      bad "policy '$id' — no proof example" "the block proof stays in the author's memory. Fill in the 'proof example' column of the table"
      viol=$((viol+1)); continue
    fi
    if ! printf '%s\n' "$ex" | grep -qE "$rx" 2>/dev/null; then
      bad "policy '$id' — the proof example is not caught by its own regex" "example: $ex  ·  regex: $rx — either the regex is dead or the example is wrong"
      viol=$((viol+1)); continue
    fi
    # ③ **Counterexample — the representative shape that makes the regex get the verdict wrong.** Its direction is opposite per verdict:
    #   the failure mode of forbid is **missing something**. The counterexample says "this must also be blocked" and it **must** match
    #     (measured: `rules-deny-all` caught only its own proof example and let `allow read: if request.auth != null;` through)
    #   the failure mode of require is **being satisfied by the wrong thing**. The counterexample says "this is not satisfaction" and it
    #     must **not** match (measured: `safeReturnTo` appears 13 times in the owning file while the enforcing call is a single line,
    #     so deleting that line still let the definition and tests satisfy the regex and FAIL came out 0)
    if [ -z "$cx" ] || [ "$cx" = "—" ] || [ "$cx" = "-" ]; then
      bad "policy '$id' — no counterexample" "a proof example asserts only «it must match». Without the opposite direction, a dead regex and satisfaction-by-definition-line both pass — fill in the 'counterexample' column of the table"
      viol=$((viol+1)); continue
    fi
    if [ "$verdict" = "forbid" ]; then
      if ! printf '%s\n' "$cx" | grep -qE "$rx" 2>/dev/null; then
        bad "policy '$id' — it misses the counterexample (forbid)" "counterexample: $cx  ·  regex: $rx — this regex aims at one proof example rather than at the class"
        viol=$((viol+1)); continue
      fi
    else
      if printf '%s\n' "$cx" | grep -qE "$rx" 2>/dev/null; then
        bad "policy '$id' — the counterexample satisfies the regex (require)" "counterexample: $cx  ·  regex: $rx — it is satisfied by something that is not the enforcement point, so deleting the enforcement still passes"
        viol=$((viol+1)); continue
      fi
    fi
    if [ "$verdict" = "forbid" ]; then
      targets=$(_policy_targets "$G" "$scope" "$except" "$packfiles")
      if [ -z "$targets" ]; then skip=$((skip+1)); pass=$((pass+1)); continue; fi
      # shellcheck disable=SC2086
      if codelines $targets | cut -f3 | grep -qF -- "$ex" 2>/dev/null; then
        bad "policy '$id' — the proof example really exists in the body" "an example of the forbidden pattern is on a code line = it violates its own policy"
        viol=$((viol+1)); continue
      fi
    fi
    pass=$((pass+1))
  done < "$TMP/polproof.tsv"
  [ "$viol" -eq 0 ] && ok "${pass} policies pass the block proof (${skip} real checks skipped for having 0 targets)"
  return 0
}

# ── 15. security shapes: blocking recurring shapes ───────────────────
# Not a per-pack policy but an axis-independent shape — which is why the gate owns it rather than policies.md.
# Measured (2026-08-23): the origin check of safeReturnTo was pierced by `/..//evil.example`.
# new URL() lets the origin through and then normalizes the dot segments, so `/..` swallows the leading `/`.
# All four shipped copies let 4/4 vectors through. Nothing is invented — only the two shapes the measurement found.
check_security_shapes() {
  local G="$1"
  sec "security shapes (recurrence block)"
  local files; files=$(guide_files "$G")
  [ -n "$files" ] || return 0

  cat > "$TMP/sec.awk" <<'AWKSEC'
BEGIN { FS = "\t" }
{ t[$4] = t[$4] "\n" $3; if (!($4 in loc)) loc[$4] = $1 ":" $2 }
END {
  for (k in t) {
    s = t[k]
    hasURL   = (index(s, "new URL(") > 0)
    hasOrig  = (s ~ /\.origin[[:space:]]*[!=]==/ || s ~ /[!=]==[[:space:]]*[A-Za-z0-9_.]*\.origin/)
    hasPath  = (index(s, "pathname") > 0)
    hasSlash = (index(s, "'//'") > 0 || index(s, "\"//\"") > 0)
    hasRedir = (s ~ /returnTo|redirectTo|returnPath|callbackUrl|safeReturn|safeInternal/)
    # **Aims only at return-path validation fences.** An origin comparison by itself is not a dangerous shape — in
    # link interception (do not intercept external links) it is exactly the right verdict, and catching that too
    # makes a correct implementation FAIL (measured on vanilla: interceptLinks was caught by this rule).
    # The prefix-only rule below had this condition from the start — the two are being aligned.
    if (hasURL && hasOrig && hasRedir && !(hasPath && hasSlash))
      print "origin-only-redirect\t" loc[k]
    hasSW    = (s ~ /startsWith\('\/'\)/ || s ~ /startsWith\("\/"\)/)
    if (hasSW && hasRedir && !hasSlash)
      print "prefix-only-redirect\t" loc[k]
  }
}
AWKSEC

  # shellcheck disable=SC2086
  codelines $files | awk -f "$TMP/sec.awk" | sort -u > "$TMP/secshape.txt"

  # ③ An **instruction** to redirect with a value that came from the request. This shape rides in prose and tables,
  # so looking only at fences misses it (measured on node-api: the 'current shape' cell of the misuse table
  # told the reader to read `req.get('Referer')` without validation, and in execution javascript:·absolute URLs all passed).
  # This is the third open redirect in this repository — catch it narrowly, but catch it by machine.
  # The direction that **carries** a value, such as `searchParams.set('redirect', …)`, has no `redirect(` and is not caught.
  # shellcheck disable=SC2086
  grep -nE 'redirect\(' $files 2>/dev/null \
    | grep -E 'Referer|req\.get\(|req\.query|req\.body|req\.headers|searchParams\.get\(|location\.search' \
    | grep -vE 'safe[A-Za-z]*\(|allowlist|\.origin' \
    | sed -E 's/^([^:]*):([0-9]+):.*/request-derived-redirect\t\1:\2/' | sort -u >> "$TMP/secshape.txt"

  local shape where n=0
  while IFS=$'\t' read -r shape where; do
    [ -z "$shape" ] && continue
    n=$((n+1))
    case "$shape" in
      origin-only-redirect)
        bad "the return path is judged by an origin comparison alone ($(basename "$where"))" \
            "new URL() lets the origin through and then normalizes the dot segments — '/..//host' becomes '//host'. Validate the resulting pathname" ;;
      prefix-only-redirect)
        bad "the return path is judged by startsWith('/') alone ($(basename "$where"))" \
            "'//host'·'/\\host' parse as external URLs in a browser — a string prefix check does not stop them" ;;
      request-derived-redirect)
        bad "redirect with a value that came from the request ($(basename "$where"))" \
            "Referer·query·body are set by the attacker — absolute URLs·javascript:·protocol-relative values pass straight through. Run it through a validation function or use an allowlist" ;;
    esac
  done < "$TMP/secshape.txt"
  [ "$n" -eq 0 ] && ok "no known vulnerable shapes"
  return 0
}

# ── 16. version-claim inventory ─────────────────────────────────────
# The "list of version claims" handed to the auditor is built by hand today. The gate collects it exhaustively
# from the prose. In the measurement (2026-08-23) 5 of this class were false, and knowledge held with misplaced
# confidence cannot be stopped by authoring discipline — it is the auditor's own territory, so handing over an accurate list is the job.
# Why WARN and not FAIL: prose regexes produce false positives. The purpose is to automate the list.
check_claims() {
  local G="$1"
  sec "version-claim inventory"
  local files; files=$(guide_files "$G")
  [ -n "$files" ] || return 0

  cat > "$TMP/claims.awk" <<'AWKCLAIM'
BEGIN { FS = "\n" }
FNR == 1 { inf = 0; prev = "" }
/^[[:space:]]*```/ { inf = !inf; prev = ""; next }
inf { next }
{
  line = $0
  if (line !~ /[^[:space:]]/) { prev = ""; next }
  claim = 0
  if (line ~ /(from|since|as of|after|before|prior to|up to)[[:space:]]+[Vv][0-9]+(\.[0-9]+)*/) claim = 1
  if (line ~ /[Vv][0-9]+(\.[0-9]+)*[[:space:]]+(or later|or newer|or above|or higher|and later|and above)/) claim = 1
  if (line ~ /deprecated|Deprecated|no longer (exists|supported|available|works|valid|required|accepts|returns)|was added in|since v[0-9]|removed in/) claim = 1
  if (line ~ /now (requires|returns|uses|needs)|older version|legacy version|previous version|(from|in) (version|major)[[:space:]]*[0-9]/) claim = 1
  # Run-confirmation markers in prose. If the author writes "run confirmed" in prose instead of a tag, the tag scan
  # misses it — and **the false claims were concentrated in exactly that blind spot** (node-api audit B: 3 of the
  # 4 false claims were untagged "(run confirmed)" blocks). Only what the tag discipline did not reach survived.
  if (line ~ /run confirmed|confirmed by running|block confirmed|type confirmed|instrumented|reproduced (it|with|on|by|before)|was reproduced/) claim = 1
  # The tag the author attached is itself a claim declaration — this catches what the phrase scan missed.
  # Excluding tagged lines from the inventory would leave audit B empty-handed on a fully tagged pack.
  tagged = 0
  if (line ~ /<!--[[:space:]]*(un)?verified/) { tagged = 1; claim = 1 }
  # Attribution to the previous line is accepted **only when that line is a standalone comment carrying just the tag**. Allowing
  # attribution from a line that also carries content (an inline tag inside a table row, say) lets one tag cover every table row
  # that follows it as 'tagged', so an untagged claim passes the check while evading it (audit B finding).
  else if (prev ~ /^[[:space:]]*<!--[^>]*(un)?verified[^>]*-->[[:space:]]*$/) { tagged = 1; claim = 1 }
  if (!claim) { prev = line; next }
  print (tagged ? "T" : "U") "\t" FILENAME ":" FNR "\t" substr(line, 1, 120)
  prev = line
}
AWKCLAIM

  # shellcheck disable=SC2086
  # ── the detector proves itself before it is trusted ──────────────────────────
  # `tot == 0` is indistinguishable from "the regexes above stopped matching", and that is not
  # hypothetical: this detector was once written entirely in the corpus's own natural language, so
  # when the corpus changed language it reported "no version claims" over a pack full of them —
  # a green tick for a check that had gone blind. The opposite failure is just as quiet: a regex
  # widened by one word starts flagging ordinary prose, and a WARN nobody believes is a WARN
  # nobody reads.
  #
  # So the probe carries **one line per claim branch**, and asserts the exact set of line numbers
  # that matched. One line per branch is the point: a probe whose lines each trip several branches
  # still passes when one branch is deleted, which is how the first version of this probe missed a
  # blinded branch. Lines 6-7 are ordinary prose that sits close to the claim vocabulary and must
  # never match.
  {
    printf '%s\n' \
      'Everything in this file assumes the CLI from v4.2 onward.' \
      'The runtime must be v20 or later.' \
      'This helper is deprecated.' \
      'The client now requires an explicit region.' \
      'The 404 path was confirmed by running it.' \
      'This race cannot be reproduced locally, so it is judged after deployment.' \
      'Once the chain passes three, the call site no longer shows which runs first.'
  } > "$TMP/claims-probe.md"
  local phit pwant='1 2 3 4 5'
  phit=$(awk -f "$TMP/claims.awk" "$TMP/claims-probe.md" 2>/dev/null \
         | sed -E 's/^[^\t]*\t[^:]*:([0-9]+)\t.*/\1/' | sort -n | tr '\n' ' ' | sed 's/ $//')
  if [ "$phit" != "$pwant" ]; then
    bad "the version-claim detector failed its own probe: matched lines [$phit], expected [$pwant]" \
        "probe lines 1-5 are one claim per branch and 6-7 are ordinary prose. A missing number means that branch has gone blind and the inventory below is empty for the wrong reason; an extra number means the detector is flagging prose. Fix claims.awk before trusting this section"
    return 1
  fi
  ok "claim detector probe passed (5 branches · 2 near-misses)"

  awk -f "$TMP/claims.awk" $files > "$TMP/claims.tsv" 2>/dev/null

  local tot unt
  tot=$(num "$(grep -c . "$TMP/claims.tsv" | tr -d ' ')")
  unt=$(num "$(grep -c '^U' "$TMP/claims.tsv" | tr -d ' ')")
  if [ "$tot" -eq 0 ]; then ok "no version claims"; return 0; fi

  if [ "$unt" -gt 0 ]; then
    warn "untagged version claims: ${unt} (of ${tot} total)" "marking it with <!-- verified: evidence --> or <!-- unverified --> makes it pass"
  else
    ok "all ${tot} version claims are tagged"
  fi

  # The inventory is printed **exhaustively**, tagged or not — this is the input of audit B, and
  # the tagged entries are precisely what is under judgement (a tag declares "a claim was made", it does not prove "true").
  # Printing only the untagged ones leaves audit B empty-handed on a fully tagged pack (measured on node-api).
  printf "      ${C_D}── version-claim inventory: %s (input of audit B) ──${C_0}\n" "$tot"
  local st loc txt shown=0
  while IFS=$'\t' read -r st loc txt; do
    [ -z "$loc" ] && continue
    shown=$((shown+1))
    [ "$shown" -le 40 ] && printf "      ${C_D}[%s] %s${C_0}  %s\n" "$st" "$loc" "$txt"
  done < "$TMP/claims.tsv"
  [ "$shown" -gt 40 ] && printf "      ${C_D}… the other %s are read from %s (not omitted)${C_0}\n" "$((shown-40))" "$TMP/claims.tsv"

  # The EXIT trap deletes $TMP — to hand it to audit B it has to be copied out. The entries are
  # independent of each other, so **splitting by line parallelizes without loss**. That is the reason this
  # flag exists (in the node-api measurement audit B was 15 min 46 s of critical path).
  if [ -n "${CLAIMS_OUT:-}" ]; then
    if cp "$TMP/claims.tsv" "$CLAIMS_OUT" 2>/dev/null; then
      ok "version-claim inventory exported: $CLAIMS_OUT"
      # `split -n l/2` is a GNU extension and fails on macOS — emit the split-by-line-count form
      [ "$tot" -gt 40 ] && printf "      ${C_D}%s entries — halve audit B: split -l %s %s <prefix>${C_0}\n" "$tot" "$(( (tot + 1) / 2 ))" "$CLAIMS_OUT"
    else
      warn "could not write the inventory: $CLAIMS_OUT" "check that the path is writable — the input of audit B disappears"
    fi
  fi
  return 0
}

# ── 17. duplicate fences: duplicated description produced by parallel authoring ──
# The ledger tracks only symbols and does not look at description. Splitting clusters for authoring makes each
# write the same code example, and after eating into the 300-line budget the two diverge into self-contradiction.
# Why REVIEW and not FAIL: legitimate repetition exists (a common import block, an anti-pattern and its repair).
check_duplicate_fences() {
  local G="$1"
  sec "duplicate fences (the same code across files)"
  local files; files=$(guide_files "$G")
  [ -n "$files" ] || return 0

  # shellcheck disable=SC2086
  codelines $files | awk -F'\t' '
    { line=$3
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",line); gsub(/[[:space:]]+/," ",line)
      if (line=="") next
      t[$4]=t[$4] line "\002"; c[$4]++; f[$4]=$1; if (!($4 in l)) l[$4]=$2 }
    END { for (k in t) if (c[k]>=3) print f[k] ":" l[k] "\t" t[k] }' \
    | sort -t"$(printf '\t')" -k2 > "$TMP/fences.tsv"

  awk -F'\t' '$2==p && $1!=pf { print pf " ↔ " $1 } { p=$2; pf=$1 }' "$TMP/fences.tsv" \
    | sed -E 's#[^ ]*/([^/ ]+)#\1#g' | sort -u > "$TMP/dupfence.txt"

  local n; n=$(num "$(grep -c . "$TMP/dupfence.txt" | tr -d ' ')")
  if [ "$n" -gt 0 ]; then
    rev "identical code fences across files: ${n} pairs" "$(head -4 "$TMP/dupfence.txt" | tr '\n' ';') — pass if it is legitimate repetition (a common import·an anti-pattern pair), otherwise gather it in one place"
  else
    ok "no duplicate code fences across files"
  fi
  return 0
}

# ── 17-B. tests with no block proof ─────────────────────────────────
# Measured (2026-08-23): the ownership regression test a pack offered as "the most expensive test on this axis"
# asserted only the negative (404), so replacing the whole query function with `return null` stayed green.
# **A guard that cannot prove it blocks** — the pack's test broke the very norm this repository applies to its own
# gate. A machine cannot judge meaning here, so it is REVIEW.
check_blocking_proof() {
  local G="$1"
  sec "block proof of the tests"
  local files; files=$(guide_files "$G")
  [ -n "$files" ] || return 0

  # Only files that contain test code are looked at
  # shellcheck disable=SC2086
  codelines $files | awk -F'\t' '$3 ~ /(^|[^A-Za-z])(it|test)\(/ {print $1}' | sort -u > "$TMP/testfiles.txt"
  local n; n=$(num "$(grep -c . "$TMP/testfiles.txt" | tr -d ' ')")
  [ "$n" -eq 0 ] && { ok "no test code — not applicable"; return 0; }

  local f neg pos base hit=0
  while read -r f; do
    [ -z "$f" ] && continue
    base=$(basename "$f")
    neg=$(num "$(codelines "$f" | cut -f3 | grep -cE 'toBe\((40[0-9]|41[0-9]|42[0-9]|50[0-9])\)|status\).toBe\(4' 2>/dev/null || true)")
    pos=$(num "$(codelines "$f" | cut -f3 | grep -cE 'toBe\(20[0-9]\)' 2>/dev/null || true)")
    if [ "$neg" -gt 0 ] && [ "$pos" -eq 0 ]; then
      rev "$base — ${neg} failure assertions, 0 success assertions" \
          "a test that passes even when the implementation is failed wholesale. Pair it with a positive path to prove blocking"
      hit=$((hit+1))
    fi
  done < "$TMP/testfiles.txt"
  [ "$hit" -eq 0 ] && ok "${n} test files — positive·negative pairs confirmed"
  return 0
}

# ── 18. pack metadata: pack.json ↔ real files ↔ fixesVariants ───────
# An axis pack pins down variants such as the framework and the ORM, yet until now it did not declare them and
# nothing cross-checked them at assembly time. A project that picked NestJS receiving the Express pack does not
# receive something missing — it receives **something wrong**. fixesVariants is that declaration and this is its consistency check.
# ── package name list · product matching ────────────────────────────
# **Do not match on substrings.** `@nestjs/platform-express` is Nest's default HTTP adapter, not a choice of
# Express, yet running grep -F "express" over one flattened string makes
# fixesVariants.framework=nestjs FAIL as "the competing product express is present" (measured on node-nest).
# A defect of the same class already happened once in check_leak (nextCursor ↔ next).
_pkgs_names() { # $1=pack.json → lowercased package names (versions stripped), one per line
  tr -d '\n' < "$1" 2>/dev/null | grep -oE '"pkgs"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | grep -oE '"[^"]+"' | tr -d '"' | grep -vx 'pkgs' \
    | sed -E 's/@[0-9][^@]*$//' | tr 'A-Z' 'a-z' | sort -u
}

# Is the product token in the package list? Only a whole-name match or a scope equal to that name counts
# (`prisma` ↔ `@prisma/client` is the same product, `express` ↔ `@nestjs/platform-express` is not).
_pkg_has_product() { # $1=name list file $2=token
  local t="${2%/}" esc
  grep -qxF "$t" "$1" 2>/dev/null && return 0
  esc=$(printf '%s' "$t" | sed 's/[][\.*^$/]/\\&/g')
  grep -qE "^@?${esc}/" "$1" 2>/dev/null
}

# knownGaps declaration ↔ reality cross-check.
# knownGaps was declared and **no gate ever read it** — and yet react-vite/ledger.md said
# "the gate reports it as REVIEW". The only candidate, the undefined-symbol branch of check_symbols,
# gathers names only from @/ alias imports, and those blank symbols are used bare in JSX with no import,
# so they never enter that check at all. There were three declarations and zero enforcement.
#
# Two directions are taken here: ① does the declared gap still exist (unresolved) ②
# was it repaired and only the record remains (a stale record). Judging whether a definition exists is a heuristic,
# so it is reported as REVIEW/WARN rather than FAIL — a machine blocking where a human should judge is a false positive, and false positives get switched off.
# Finds which axis pack's gap a seam's knownGaps entry inherited.
# Empty string if it is not a seam manifest, or if no pack declares that symbol.
_kg_owner_pack() {   # $1 manifest  $2 symbol
  local j="$1" sym="$2" axis pk pj
  case "$j" in */seam.json) ;; *) return 0;; esac
  for axis in frontend backend app; do
    pk=$(grep -oE "\"${axis}Pack\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$j" | sed -E 's|.*/||; s|"$||')
    [ -n "$pk" ] || continue
    pj="$PLUGIN_GUIDES/$axis/$pk/pack.json"
    [ -f "$pj" ] || continue
    if tr -d '\n' < "$pj" | grep -oE '"knownGaps"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
         | grep -qF "\"$sym\""; then
      printf '%s/%s' "$axis" "$pk"; return 0
    fi
  done
  return 0
}

check_known_gaps() {   # $1 directory  $2 manifest (pack.json or seam.json)
  local D="$1" j="$2" ent sym whr tgt
  [ -f "$j" ] || return 0
  grep -q '"knownGaps"' "$j" 2>/dev/null || return 0
  while IFS= read -r ent; do
    sym=$(printf '%s' "$ent" | grep -oE '"symbol"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$sym" ] || continue
    # Only the first token of where is used — notations like "resources/x.md §1·§2" exist.
    whr=$(printf '%s' "$ent" | grep -oE '"where"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sed 's/ .*//')
    if [ -z "$whr" ]; then
      # Three states. If where it is consumed is not declared, **no verdict is issued** — searching anywhere
      # makes a common symbol such as Task hit the domain vocabulary and always read as "unresolved" (measured).
      #
      # That said, a seam's entries are mostly **an inherited record of an axis pack's gap**, so there is nowhere
      # to put where (the gap is inside the pack). In that case the pack-side check already judges it, so no warning —
      # a warning that never goes away teaches people to ignore it.
      if [ -n "$(_kg_owner_pack "$j" "$sym")" ]; then
        ok "known gap $sym — inherited from $(_kg_owner_pack "$j" "$sym") (judged in that pack)"
      else
        warn "known gap '$sym' — where undeclared" "without which file consumes it, a machine cannot see whether it is resolved. Write where into the knownGaps entry"
      fi
    elif [ ! -f "$D/$whr" ]; then
      warn "known gap '$sym' — the where file is missing: $whr" "the record and reality diverged. If the file is gone, delete the entry too"
    elif grep -qF -- "$sym" "$D/$whr" 2>/dev/null; then
      rev "known gap: $sym — present in $whr" "it is still consumed at the declared place. Check whether the pack defines it or the seam filled it through provides"
    else
      # **No conclusion is drawn.** where is used in two senses: some entries point at "the place the symbol is
      # consumed" (react-vite/routing.md), others at "the place the symbol is **absent** —
      # that absence being the gap" (the missing C of the CRUD in aws-container/data-access.md).
      # Presence alone cannot separate "repaired" from "still missing", so only the fact is reported.
      rev "known gap: $sym — absent from $whr" "whether it was repaired and only the record remains, or the absence itself is the gap, is a human call. If it was repaired, delete it from knownGaps"
    fi
  done < <(tr -d '\n' < "$j" | grep -oE '"knownGaps"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/},/}\n/g')
  return 0
}

check_pack_meta() {
  local P="$1" j="$1/pack.json"
  sec "pack metadata (pack.json)"
  [ -f "$j" ] || { bad "pack.json missing: $j"; return 0; }

  local nm ax
  nm=$(grep -m1 -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' "$j" | sed -E 's/.*"([^"]+)"$/\1/')
  ax=$(grep -m1 -oE '"axis"[[:space:]]*:[[:space:]]*"[^"]+"' "$j" | sed -E 's/.*"([^"]+)"$/\1/')
  [ "$nm" = "$(basename "$P")" ] && ok "name = directory name ($nm)" || bad "pack.json name '$nm' ≠ directory '$(basename "$P")'"
  # The app axis follows the same pack contract as the web screen axis — only the axis name differs, the checks are the same
  case "$ax" in frontend|backend|app) ok "axis = $ax";; *) bad "axis is not frontend/backend/app: '$ax'";; esac

  # resources[] ↔ real files, both set differences
  grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]+"' "$j" | sed -E 's/.*"([^"]+)"$/\1/' | sort -u > "$TMP/pjres.txt"
  ls "$P"/resources/*.md 2>/dev/null | while read -r f; do basename "$f"; done | sort -u > "$TMP/realres.txt"
  local miss ghost
  miss=$(comm -13 "$TMP/pjres.txt" "$TMP/realres.txt" | tr '\n' ' ')
  ghost=$(comm -23 "$TMP/pjres.txt" "$TMP/realres.txt" | tr '\n' ' ')
  [ -n "$(printf '%s' "$miss" | tr -d ' ')" ] && bad "real files missing from pack.json resources[]: $miss" "no Navigation Guide row is created, so they become unreachable in the assembly"
  [ -n "$(printf '%s' "$ghost" | tr -d ' ')" ] && bad "pack.json resources[] points at a file that does not exist: $ghost"
  [ -z "$(printf '%s%s' "$miss" "$ghost" | tr -d ' ')" ] && ok "resources[] $(num "$(wc -l < "$TMP/pjres.txt")") entries ↔ real files match"

  # exampleDomain — pins the domain vocabulary (the contract that stops vocabulary from forking under parallel authoring)
  grep -q '"exampleDomain"' "$j" && ok "exampleDomain declared" || bad "exampleDomain missing" "without a pinned domain vocabulary each file uses a different resource name (measured: /tasks ↔ /notes)"

  # fixesVariants — declaration of the pinned variants (if there are none, state {} explicitly)
  if ! grep -q '"fixesVariants"' "$j"; then
    bad "fixesVariants not declared" "if the pack does not declare the framework·ORM it pins, nothing can be cross-checked at assembly time. If it pins nothing, state {} explicitly"
    return 0
  fi
  local pkgs; pkgs=$(tr -d '\n' < "$j" | grep -oE '"pkgs"[[:space:]]*:[[:space:]]*\[[^]]*\]' | tr 'A-Z' 'a-z')
  _pkgs_names "$j" > "$TMP/pkgnames.txt"
  local fv; fv=$(tr -d '\n' < "$j" | grep -oE '"fixesVariants"[[:space:]]*:[[:space:]]*\{[^}]*\}')
  local pairs; pairs=$(printf '%s' "$fv" | grep -oE '"[A-Za-z]+"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/"([A-Za-z]+)"[[:space:]]*:[[:space:]]*"([^"]+)"/\1\t\2/')
  if [ -z "$pairs" ]; then ok "fixesVariants empty (explicitly states that nothing is pinned)"; return 0; fi

  # Mutually exclusive product families — if a competitor of the declared value is in pkgs, the declaration is false
  cat > "$TMP/variants.tsv" <<'VARTBL'
framework	express	express
framework	hono	hono
framework	fastify	fastify
framework	koa	koa
framework	nestjs	@nestjs/
orm	prisma	prisma
orm	drizzle	drizzle-orm,drizzle-kit
orm	sequelize	sequelize
orm	typeorm	typeorm
orm	knex	knex
store	pinia	pinia
store	vuex	vuex
store	zustand	zustand
store	redux	@reduxjs/
store	jotai	jotai
query	vue-query	@tanstack/vue-query
query	react-query	@tanstack/react-query
query	swr	swr
query	apollo	@apollo/
VARTBL

  local dim val grp prod toks t mine="" hit=0 n=0
  while IFS=$'\t' read -r dim val; do
    [ -z "$val" ] && continue
    n=$((n+1))
    local lval; lval=$(printf '%s' "$val" | tr 'A-Z' 'a-z')
    # Which product is the declared value
    mine=""; grp=""
    while IFS=$'\t' read -r g prod toks; do
      for t in $(printf '%s' "$toks" | tr ',' '\n'); do
        case "$lval" in *"$t"*) mine="$prod"; grp="$g";; esac
        [ "$lval" = "$prod" ] && { mine="$prod"; grp="$g"; }
      done
    done < "$TMP/variants.tsv"
    if [ -z "$mine" ]; then
      _pkg_has_product "$TMP/pkgnames.txt" "$lval" && ok "fixesVariants.$dim = $val (appears in pkgs)" \
        || warn "fixesVariants.$dim = '$val' — cannot be confirmed from pkgs" "it is not a known product family and it is not in the package list either. Either a typo or a stale declaration"
      continue
    fi
    # If another product of the same family is in pkgs, that is a contradiction
    while IFS=$'\t' read -r g prod toks; do
      [ "$g" = "$grp" ] || continue
      [ "$prod" = "$mine" ] && continue
      for t in $(printf '%s' "$toks" | tr ',' '\n'); do
        if _pkg_has_product "$TMP/pkgnames.txt" "$t"; then
          bad "fixesVariants.$dim = '$val' yet pkgs carries the competing product '$t'" "the declaration contradicts reality — the assembly-time cross-check passes falsely"
          hit=$((hit+1))
        fi
      done
    done < "$TMP/variants.tsv"
  done <<EOF
$pairs
EOF
  [ "$hit" -eq 0 ] && ok "fixesVariants ${n} entries ↔ pkgs, no contradiction"
  return 0
}

# ── 19. pack ledger: provides definition cross-check ─────────────────
# requires cannot be checked before assembly (there is no seam yet). provides closes inside the axis,
# so it can be checked now, and this is exactly the fan-in point of parallel authoring —
# it confirms that the definition really landed in the file L0 assigned.
check_pack_ledger() {
  local P="$1" led="$1/ledger.md"
  sec "pack ledger (provides assignment cross-check)"
  [ -f "$led" ] || { bad "pack ledger missing: $led"; return 0; }

  # The provides table has 4 columns: | symbol | definition file | shape | nature |
  # Without «shape», a sibling cluster **guesses** the signature — in the measurement (2026-08-23)
  # another cluster called getTask(ownerId, id) as getTask(id, ownerId) and, both arguments being
  # string, neither TypeScript nor this gate caught it. It is the single cause of 2 critical defects.
  # The shape cell often carries an escaped `\|` because of unions and generics. Without protecting it
  # before splitting columns, the shape is truncated and the arity cross-check looks at the wrong value (the same trap as the policy table).
  awk '/^## provides/{f=1;next} /^## /{f=0} f' "$led" \
    | grep -E '^\|[[:space:]]*`' \
    | sed 's/\\|/\x01/g' \
    | awk -F'|' 'NF>=4 { gsub(/[[:space:]]/,"",$3); shape=(NF>=6)?$4:""
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",shape); gsub(/\x01/,"|",shape)
        print $2"\t"$3"\t"shape }' > "$TMP/prov.raw"

  # The idiom of several symbols in one row (`a` · `b`) exists in the wild — split it
  : > "$TMP/prov.tsv"
  local syms deff shape s noshape=0
  while IFS=$'\t' read -r syms deff shape; do
    [ -z "$syms" ] && continue
    case "$shape" in ""|"—"|"-") noshape=$((noshape+1)); shape="";; esac
    for s in $(printf '%s' "$syms" | tr -d ' ' | tr '`' ' ' | tr '·' ' ' | tr ' ' '\n'); do
      [ -z "$s" ] && continue
      printf '%s\t%s\t%s\n' "$s" "$deff" "$shape" >> "$TMP/prov.tsv"
    done
  done < "$TMP/prov.raw"

  if [ "$noshape" -gt 0 ]; then
    bad "provides rows with an empty «shape» column: ${noshape}" \
        "assigning only the owning file and leaving the shape empty makes a sibling cluster guess the signature. Write the argument order, the return, what it throws on failure, and what the caller must wire"
  else
    ok "every provides row declares a shape"
  fi

  local rows; rows=$(num "$(grep -c . "$TMP/prov.tsv" | tr -d ' ')")
  if [ "$rows" -eq 0 ]; then
    warn "the pack ledger provides is empty" "normal for a pattern-knowledge pack (0 exports) — declare it with symbolSurface in pack.json"
    return 0
  fi

  local n_def=0 rf declared actual
  while IFS=$'\t' read -r s deff shape; do
    [ -z "$s" ] && continue
    rf=$(_resolve "$P" "$deff")
    if [ -z "$rf" ]; then bad "the definition file of pack ledger entry '$s' does not exist: $deff"; n_def=$((n_def+1)); continue; fi
    _has_def "$rf" "$s" \
      || { bad "the definition of pack ledger entry '$s' is not in $(basename "$rf")" "the definition did not land in the owning file L0 assigned — put it there or fix the ledger"; n_def=$((n_def+1)); continue; }

    # If the shape declared a call signature, cross-check it against the argument count of the real definition.
    # A machine cannot see the name order, but **it does catch a count mismatch** — writing a shape and then
    # writing the definition differently makes the consumer trust the ledger and write the wrong call.
    # **Do not look for the signature only at the head of the shape.** Once the norm changed to «write the source
    # path in the shape column», the real shape looks like `src/boot.ts`. `boot(raw) => Env`, with the path
    # first — a head-anchored regex then **skips the arity cross-check entirely**
    # (measured on node-nest: the fixture passed even with a wrong argument count — a miss).
    local bare; bare=$(printf '%s' "$shape" | tr -d '`')
    declared=$(printf '%s' "$bare" | sed -nE "s/.*(^|[^A-Za-z0-9_])$s\(([^)]*)\).*/\2/p" | head -1)
    if printf '%s' "$bare" | grep -qE "(^|[^A-Za-z0-9_])$s\("; then
      local dn=0
      [ -n "$(printf '%s' "$declared" | tr -d ' ')" ] && dn=$(printf '%s' "$declared" | awk -F',' '{print NF}')
      actual=$(awk -F'\t' -v n="$s" '$1==n {print $2; exit}' "$TMP/defs.tsv")
      if [ -n "$actual" ] && [ "$dn" -ne "$(num "$actual")" ]; then
        bad "the shape of ledger entry '$s' has ${dn} arguments but the definition has $(num "$actual")" \
            "$(basename "$rf") — the consumer trusts the ledger. One of the two is wrong"
        n_def=$((n_def+1))
      fi
    fi
  done < "$TMP/prov.tsv"

  cut -f1 "$TMP/prov.tsv" | sort -u > "$TMP/provsym.txt"

  # A pack exporting a symbol it declared in requires is self-contradictory — it said the seam owns it
  # and then defined it itself, so after assembly the same name is defined in two places.
  # (measured: the react-vite pack put useTasksQuery in requires and exported it from PACK.md)
  awk '/^## requires/{f=1;next} /^## /{f=0} f' "$led" \
    | grep -E '^\|[[:space:]]*`' \
    | awk -F'|' 'NF>=4 { gsub(/`|[[:space:]]/,"",$2); if ($2!="") print $2 }' | sort -u > "$TMP/reqsym.txt"
  # If the pack **calls** a requires symbol and the shape carries no signature, the seam guesses the
  # argument order. Measured (2026-08-23): react-vite called `ApiError(500, 'BAD_SHAPE', msg)`
  # while the shape held only a field list — both trailing arguments are string, so swapping them
  # is invisible to TypeScript. The same hole as the «shape» column of provides was still open in requires.
  awk '/^## requires/{f=1;next} /^## /{f=0} f' "$led" \
    | grep -E '^\|[[:space:]]*`' | sed 's/\\|/\x01/g' \
    | awk -F'|' 'NF>=4 { gsub(/`|[[:space:]]/,"",$2); sh=$4
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",sh); gsub(/\x01/,"|",sh)
        if ($2!="") print $2"\t"sh }' > "$TMP/reqshape.tsv"

  local rsym rshape nosig=0
  while IFS=$'\t' read -r rsym rshape; do
    [ -z "$rsym" ] && continue
    # Does the pack call this symbol? codelines() already excluded the prose, and the **trailing comment** is
    # stripped too — `// ✅ router → notFound → errorHandler(4 args)` used to be caught as a call (a false positive).
    sed 's/[[:space:]]\/\/.*$//' "$TMP/code.txt" > "$TMP/code.nocomment.txt"
    grep -qE "(^|[^A-Za-z0-9_.\$])(new[[:space:]]+)?$rsym\(" "$TMP/code.nocomment.txt" 2>/dev/null || continue
    printf '%s' "$rshape" | grep -qF "$rsym(" && continue
    bad "requires '$rsym' is called but the shape carries no signature" \
        "the seam guesses the argument order. With two or more arguments of the same type, swapping them still type-checks — write \`$rsym(...)\` into the shape"
    nosig=$((nosig+1))
  done < "$TMP/reqshape.tsv"
  [ "$nosig" -eq 0 ] && ok "every requires symbol that is called declares a signature"

  local both; both=$(comm -12 "$TMP/exports.txt" "$TMP/reqsym.txt" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$both" | tr -d ' ')" ]; then
    bad "the pack exports a symbol it declared in requires:$both" \
        "it said the seam owns it and then defined it itself — after assembly there are two definitions. If it is an example, take it out of requires or state in the ledger that it is an example"
  else
    ok "no requires ↔ export conflict"
  fi

  # Example-only symbols are declared in the 'examples' section of the ledger (the vue pack's idiom).
  # A machine cannot judge whether something is an example component or a real module, so it is REVIEW —
  # making it FAIL would push authors to shove examples into provides, and that is worse.
  awk '/^## .*[Ee]xample/{f=1;next} /^## /{f=0} f' "$led" \
    | grep -oE '`[A-Za-z_][A-Za-z0-9_]*`' | tr -d '`' | sort -u > "$TMP/exsym.txt"
  cat "$TMP/provsym.txt" "$TMP/exsym.txt" | sort -u > "$TMP/declared.txt"
  local unreg; unreg=$(comm -23 "$TMP/exports.txt" "$TMP/declared.txt" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$unreg" | tr -d ' ')" ]; then
    rev "export symbols missing from the ledger:$unreg" "a symbol outside the assignment — put it in provides, or, if it is an example, write it into the 'examples' section of the ledger"
  else
    ok "every export symbol is declared in the ledger"
  fi
  [ "$n_def" -eq 0 ] && ok "${rows} pack ledger rows pass the definition cross-check"
  return 0
}

# ── 19-B. import completeness of whole-file fences ─────────────────
# `<!-- file: path -->` is the author's mark claiming "this fence alone is that file".
# If that claim is true, **it cannot happen that a ledger symbol is used without being defined or imported.**
# Measured (2026-08-23): clearClientState in the vue pack used STORAGE_KEY without importing it, so copying it
# verbatim was a ReferenceError. The gate's existing local-import check looked only at paths starting with `@/`,
# so it missed relative-path (`./ui`) files, and it looked only in that direction (is what was imported defined?) —
# this check is the opposite direction (is what was used procured?).
# Label fences (`// path`) are excerpts by design and are not checked.
check_fence_imports() {
  local P="$1"
  [ -s "$TMP/provsym.txt" ] || return 0
  sec "import completeness of whole-file fences"
  local files; files=$(guide_files "$P")
  [ -n "$files" ] || return 0

  # Only the fences right after `<!-- file: -->` are taken: <file>\t<start line>\t<text>
  # shellcheck disable=SC2086
  awk '
    FNR==1 { inf=0; claim=0 }
    /^[[:space:]]*<!--[[:space:]]*file:/ {
      claim=1
      p=$0; sub(/.*file:[[:space:]]*/,"",p); sub(/[[:space:]]*-->.*/,"",p)
      # **A data file has no import machinery** — the procurement check does not apply.
      # In the firebase pilot the string "queryScope": "COLLECTION" in firestore.indexes.json
      # was caught as unprocured use of the ledger symbol COLLECTION (a false positive). If the author dodges it by
      # demoting that fence to a label, the syntax checks are lost along with it — fixing the checker is the right move.
      # **This list must be the twin of the classifier in profiles/node-ts.sh.** The same concept lived in two places
      # and had forked — the gate did not know graphql·prisma and the classifier handled json separately.
      if (p ~ /\.(json|ya?ml|toml|rules|env|sql|md|txt|ini|cfg|graphql|prisma|html?|css|scss|sass|less|svg)$/) claim=0
      next
    }
    /^[[:space:]]*```/ {
      if (!inf) { inf=1; use=claim; start=FNR; claim=0 } else { inf=0; use=0 }
      next
    }
    !inf { if ($0 ~ /[^[:space:]]/) claim=0; next }
    # Comment lines are excluded — counting a symbol that appears only in a description as "use" is a false positive
    # (measured during development: `// ① readyz returns 503` was caught as unprocured).
    # It uses the same comment test as codelines().
    use && $0 !~ /^[[:space:]]*(\/\/|#|\*|\/\*|--)/ {
      line=$0
      sub(/[[:space:]]\/\/.*$/, "", line)   # the trailing comment is stripped too — `beginDrain(); // readyz returns 503`
      # A name inside a string literal is not a module binding use. The positive control of a guard
      # commonly holds rules·SQL·regexes as strings and asserts on them — in firebase, isOwner placed in a string
      # to prove a widened regex was caught as unprocured use (a false positive).
      # Data files already had an exception; strings inside code did not.
      gsub(/\047[^\047]*\047/, "", line)
      gsub(/"[^"]*"/, "", line)
      # A backtick template is a string too. Erasing it wholesale would lose the **real expressions** inside `${…}`,
      # so only the text is discarded and the interpolations are kept. Measured: in vanilla,
      # `throw new Error(`not a Task shape: ${where}`)` had the word Task, sitting in the message text,
      # caught as symbol use — the hole in the place that stripped only the two quote kinds.
      while (1) {
        s0 = index(line, "`"); if (s0 == 0) break
        rest = substr(line, s0 + 1); e0 = index(rest, "`"); if (e0 == 0) break
        tpl = substr(rest, 1, e0 - 1); keep = ""
        while (match(tpl, /\$\{[^}]*\}/)) {
          keep = keep " " substr(tpl, RSTART + 2, RLENGTH - 3)
          tpl = substr(tpl, RSTART + RLENGTH)
        }
        line = substr(line, 1, s0 - 1) keep substr(rest, e0 + 1)
      }
      print FILENAME "\t" start "\t" line
    }
  ' $files > "$TMP/fileunits.tsv"

  local nu; nu=$(cut -f1,2 "$TMP/fileunits.tsv" 2>/dev/null | sort -u | grep -c . | tr -d ' ')
  nu=$(num "$nu")
  [ "$nu" -eq 0 ] && { warn "0 fences claiming a whole file — nothing to check" "put <!-- file: path --> in front of the security primitive·configuration·test harness fences"; return 0; }

  local key bad_n=0 sym body
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    body=$(awk -F'\t' -v k="$key" '$1"\t"$2==k {print $3}' "$TMP/fileunits.tsv")
    while read -r sym; do
      [ -z "$sym" ] && continue
      # A name after a dot is a property access, not a module binding use
      # (`process.env` used to be caught as the ledger symbol `env` — a false positive measured during development).
      # A name after a dot (property access) and before a colon (object key·type annotation) is not a module binding use.
      # `process.env` · `env: { ... }` used to be caught as the ledger symbol `env` (a false positive measured during development).
      printf '%s\n' "$body" | grep -qE "(^|[^.[:alnum:]_$])$sym([^A-Za-z0-9_:]|$)" || continue
      # Is it defined or imported inside this fence?
      printf '%s\n' "$body" | grep -qE "$(_defpat "$sym")" && continue
      # **`from X import Y` is procurement too.** A rule that looked only at `^import` judged all 12 legitimate
      # imports of a Python pack unprocured (measured on the fastapi fan-in — a false positive).
      printf '%s\n' "$body" | grep -qE "^[[:space:]]*(import|from)[^;]*\b$sym\b" && continue
      bad "a whole file uses '$sym' without procuring it (as of ${key%%$'\t'*})" \
          "$(basename "${key%%$'\t'*}"):${key##*$'\t'} — copying it verbatim is a ReferenceError. Add the import, or demote it to a label (// path)"
      bad_n=$((bad_n+1))
    done < "$TMP/provsym.txt"
  done < <(cut -f1,2 "$TMP/fileunits.tsv" | sort -u)

  [ "$bad_n" -eq 0 ] && ok "${nu} whole files — ledger symbol procurement is complete"
  return 0
}

# ── 20. pack policy enforcement (before assembly) ────────────────────
# check_policies presumes assembly.json (=the assembly). Right after authoring a pack there is no seam, so
# only what can be judged inside the axis is run: forbid is a definite verdict (FAIL), while require may be filled
# by the seam so its absence is left as REVIEW. A policy whose scope is seam cannot be judged at all — that is reported explicitly.
check_pack_policies() {
  local P="$1" pol="$1/$PACK_POLICIES_NAME"
  sec "pack policy enforcement (what can be judged before assembly)"
  [ -f "$pol" ] || { warn "pack policy file missing: $pol"; return 0; }
  _parse_policies "$pol" "$TMP/packpol.tsv"
  local n; n=$(num "$(grep -c . "$TMP/packpol.tsv" | tr -d ' ')")
  if [ "$n" -eq 0 ]; then
    if _policy_rows_look_present "$pol"; then
      bad "pack policies silently enforce 0 entries: $pol" "the policy rows are there but parsing yields 0 — the parser reads the table only if a \`## Machine checks\` heading sits above it. As it stands, not one declared invariant is enforced"
    else
      warn "could not read entries from the pack policies: $pol"
    fi
    return 0
  fi

  local packfiles; packfiles=$(_pack_basenames "$P")
  local id verdict scope rx except ex has targets hits viol=0 pass=0 defer=0
  while IFS=$'\t' read -r id verdict scope rx except ex has cx; do
    [ -z "$id" ] && continue
    targets=$(_policy_targets "$P" "$scope" "$except" "$packfiles")
    if [ -z "$targets" ]; then
      # **0 targets is not deferred as one lump.** With scope=seam, 0 is normal because there is no seam,
      # but scope=file: names an owning file, so 0 means **the filename is wrong or the file is gone**.
      # Lumping them together disguises a single typo as «deferred until after assembly» and
      # that policy enforces 0 entries forever — the same class as the 8 firebase policies ignored wholesale.
      case "$scope" in
        file:*) bad "the target file of policy '$id' is missing: ${scope#file:}" \
                    "scope=file: names an owning file — either the filename is a typo or the file is gone. This policy enforces 0 entries"
                viol=$((viol+1)) ;;
        *)      defer=$((defer+1)) ;;
      esac
      continue
    fi
    # shellcheck disable=SC2086
    hits=$(num "$(codelines $targets | cut -f3 | grep -cE "$rx" 2>/dev/null || true)")
    if [ "$verdict" = "forbid" ]; then
      if [ "$hits" -gt 0 ]; then
        # shellcheck disable=SC2086
        bad "the pack violates its own policy '$id' — ${hits} forbidden pattern hits" \
            "$(codelines $targets | grep -E "$rx" | head -2 | awk -F'\t' '{printf "%s:%s ", substr($1,match($1,/[^\/]*$/)), $2}')"
        viol=$((viol+1))
      else pass=$((pass+1)); fi
    else
      if [ "$hits" -eq 0 ]; then
        rev "the required pattern '$id' is not in the pack" "regex: $rx — normal if it is a place the seam fills. Decide whether to move the scope to seam"
      else pass=$((pass+1)); fi
    fi
  done < "$TMP/packpol.tsv"
  [ "$viol" -eq 0 ] && ok "${pass} pack policies passed (${defer} excluded as scope=seam, deferred until after assembly)"
  return 0
}

# The basename list of the pack's files — used by _policy_targets for the scope verdict.
# Given this list in pack mode, scope=seam gets 0 targets and is automatically deferred until after assembly.
_pack_basenames() {
  local f out=""
  for f in $(guide_files "$1"); do out="$out $(basename "$f")"; done
  printf '%s' "$out"
}

# ════════════════════════════════════════════════════════════════════
# --pack : check one axis pack (before assembly)
# ════════════════════════════════════════════════════════════════════
# Until now a pack could not be verified on its own — run_guide presumes SKILL.md and a pack
# has PACK.md. So a new pack with no seam had no way of being checked right after authoring,
# which is also why authoring the vue pack turned into improvisation.
# Only the checks that close inside the axis are run. What is a function of the combination (requires satisfaction·--pair) comes after assembly.
# ── does an artifact the declaration named really exist inside the pack? ──
# **This harness has many declarations and few places that cross-check a declaration against reality.** Half of the
# 2026-08-24 measurement's defects came from that gap. What `check_refs` did for resource references is widened to four declarations.
#
#   ⓐ the source path in the ledger provides ↔ the `<!-- file: -->` fence claiming that path
#      without it, pack-smoke **replaces that file with an any stub** and typecheck·execution look at that instead.
#      gcp's 6 ownership-check functions and vanilla's 6 modules were green **without ever having been checked**.
#   ⓑ 0 source-path declarations in provides → that itself is a defect. The check passes silently with 0 entries
#      (the «real check skipped for having 0 targets» trap — a class the gate already blocks elsewhere)
#   ⓒ the test/* file a verified tag cited as evidence ↔ a `<!-- file: -->` fence at the same path
#      a verified tag on a file that does not exist is worse than circular verification (measured: test/router.test.js)
#   ⓓ two resources claiming the same `<!-- file: -->` path → the extractor overwrites one and it vanishes
check_declared_artifacts() {
  local G="$1"
  sec "declaration ↔ reality (references exist)"

  # Every path the pack claimed as a whole file
  grep -rhoE '<!-- file: [^ ]+ -->' "$G"/resources/*.md "$G"/SKILL.md 2>/dev/null \
    | sed -E 's/<!-- file: (.*) -->/\1/' | sort > "$TMP/claimed.raw"
  sort -u "$TMP/claimed.raw" > "$TMP/claimed.txt"

  # ⓓ duplicate claims — the later one overwrites the earlier
  local dup; dup=$(uniq -d "$TMP/claimed.raw" | tr '\n' ' ')
  if [ -n "$(printf '%s' "$dup" | tr -d ' ')" ]; then
    bad "several fences claim the same path as a whole file: $dup" \
        "the extractor overwrites one and the other vanishes — a measured case where two clusters authored the same test file. Split the paths or merge them into one section"
  else
    ok "no duplicate whole-file paths"
  fi

  # ⓐⓑ provides source paths — reuses prov.tsv built by check_pack_ledger (no copies)
  if [ ! -s "$TMP/prov.tsv" ]; then
    # For a pattern-knowledge pack (0 exports) an empty provides is normal — symbolSurface in
    # pack.json declares that. **Say what was skipped** (no silent omission).
    warn "provides is empty, so the source-path check was skipped" "normal for a pattern-knowledge pack — check that it is declared with symbolSurface in pack.json"
  else
    cut -f3 "$TMP/prov.tsv" \
      | grep -oE '`[A-Za-z0-9_./-]+/[A-Za-z0-9_.-]+\.(ts|tsx|js|jsx|mts|cts|py)`' | tr -d '`' \
      | grep -v '\.d\.ts$' | sort -u > "$TMP/provpaths.txt"
    # **Only something with a directory is a source path.** A bare filename is either a framework idiom (`page.tsx`)
    # or a negative reference («it is not `logging.py`»), so it is not a real path — 4 of the measured false positives were that.
    local np; np=$(num "$(grep -c . "$TMP/provpaths.txt" | tr -d ' ')")
    if [ "$np" -eq 0 ]; then
      bad "0 source-path declarations in the provides shape column" \
          "the ledger preamble already writes this as the norm — «definition file» is ownership within the document, not the path of the code. Without a path the checks below pass silently with 0 entries"
    else
      local unclaimed; unclaimed=$(comm -23 "$TMP/provpaths.txt" "$TMP/claimed.txt" | tr '\n' ' ')
      if [ -n "$(printf '%s' "$unclaimed" | tr -d ' ')" ]; then
        bad "no whole-file claim for a path the pack declared it owns: $unclaimed" \
            "that code is replaced by an any stub in pack-smoke and **receives neither typecheck nor execution**. Put <!-- file: path --> in front of the definition fence"
      else
        ok "all ${np} provides source paths are claimed as whole files"
      fi
    fi
  fi

  # ⓒ the test files a verified tag cited as evidence
  local t miss=0 seen=0
  for t in $({ grep -rhoE '<!--[[:space:]]*(un)?verified[^>]*(test|tests)/[A-Za-z0-9_./-]+\.[a-z]+' "$G"/resources/*.md "$G"/PACK.md 2>/dev/null || true; } \
             | grep -oE '(test|tests)/[A-Za-z0-9_./-]+\.[a-z]+' | sort -u); do
    seen=$((seen+1))
    grep -qxF "$t" "$TMP/claimed.txt" || { bad "a test a verified tag cited as evidence is not in the pack: $t" \
        "a verification tag on a file that does not exist is worse than circular verification — the next person believes «this is already proven» and moves on. Carry that file in a <!-- file: --> fence, or drop that evidence from the tag"; miss=$((miss+1)); }
  done
  [ "$seen" -gt 0 ] && [ "$miss" -eq 0 ] && ok "${seen} test evidence references of verified tags exist"
  return 0
}

# ── hub ↔ resources·ledger cross-check ───────────────────────────────
# **L2 (the hub fragment) is written in parallel, independently of L1 (the resources).** So a hub diverging from the
# resources is the defect intrinsic to this structure, and the 2026-08-24 audit found five findings on that boundary alone.
# Cross-checking every value by machine is expensive because the shape differs per stack, but there are **exactly two
# places that can be judged precisely and that actually caused an incident**:
#
#   ⓐ are the symbols the hub's `## Common Imports` imports from a **project-local path** (`@/` · a relative path)
#      in the ledger (provides/requires)? Library symbols (`useState`·`cookies`) are not entered
#      in the ledger, so they are not targeted — targeting them would catch every pack as a false positive.
#      Measured: the copy-paste block left out `statusFor` and **handed over the `ERROR_STATUS` the policy forbids**.
#      `isInvalidArgument` was missing too, so using it verbatim did not compile.
#   ⓑ is the prescription string of the ledger requires caught by its own pack's forbid regex?
#      Measured: the ledger instructed the seam to «set the status with `ERROR_STATUS`» while the policy
#      blocked that shape as a FAIL on the seam — **a seam that followed the ledger is guaranteed to fall.**
check_hub_contract() {
  local G="$1" led="$2" pol="$3"
  sec "hub ↔ ledger·policy cross-check"
  [ -f "$led" ] || { warn "ledger missing — cross-check skipped" "$led"; return 0; }

  # Every symbol entered in the ledger (provides + requires)
  { awk '/^## provides/{f=1;next} f&&/^## /{f=0} f' "$led"
    awk '/^## requires/{f=1;next} f&&/^## /{f=0} f' "$led"
    awk '/^## Symbols appearing in examples/{f=1;next} f&&/^## /{f=0} f' "$led"
  # The idiom of several symbols in one row (`pool` · `db`) exists in the wild — **taking only the first symbol makes
  # the rest count as absent from the ledger, so a hub import is mistaken for a ghost** (measured: `db` in aws-container).
  # The prov.tsv parser was already splitting them — the defect was that two places read the same cell differently.
  # **Every** backtick token in the first cell is taken.
  } | awk -F'|' '/^\|[[:space:]]*`/{print $2}' | grep -oE '`[^`]+`' | tr -d '`' \
    | tr -d ' ' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u > "$TMP/ledgersyms.txt"

  # ⓐ the symbols of the hub's Common Imports
  local hub="$G/PACK.md"; [ -f "$G/SKILL.md" ] && hub="$G/SKILL.md"
  awk '/<!-- pack-slot: common-imports/{f=1;m=1;next} m&&/<!-- \/pack-slot/{f=0;m=0;next} !m&&/^## Common Imports/{f=1;next} !m&&/^## /{f=0} f' "$hub" 2>/dev/null \
    | grep -oE "^import[[:space:]]+(type[[:space:]]+)?\{[^}]*\}[[:space:]]+from[[:space:]]+['\"][^'\"]+['\"]" \
    | grep -E "from[[:space:]]+['\"](@/|~/|\\./|\\.\\./)" \
    | sed -E "s/[[:space:]]+from[[:space:]]+['\"].*//" \
    | sed -E 's/^import[[:space:]]+(type[[:space:]]+)?\{//; s/\}//' \
    | tr ',' '\n' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^type[[:space:]]+//; s/[[:space:]]+as[[:space:]]+.*//' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u > "$TMP/hubimports.txt"

  # **A Python pack does not use `import { }`.** Locality is judged by the top-level directory of the provides
  # source path — if `app/obs/logging.py` exists, then `from app.… import x` is local.
  local proot=""
  [ -s "$TMP/provpaths.txt" ] && proot=$(cut -d/ -f1 "$TMP/provpaths.txt" | sort -u | grep -E '^[a-z_]+$' | head -1)
  if [ -n "$proot" ]; then
    awk '/<!-- pack-slot: common-imports/{f=1;m=1;next} m&&/<!-- \/pack-slot/{f=0;m=0;next} !m&&/^## Common Imports/{f=1;next} !m&&/^## /{f=0} f' "$hub" 2>/dev/null \
      | grep -oE "^from[[:space:]]+$proot[A-Za-z0-9_.]*[[:space:]]+import[[:space:]]+.*" \
      | sed -E 's/^from[[:space:]]+[A-Za-z0-9_.]+[[:space:]]+import[[:space:]]+//' \
      | tr ',' '\n' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]+as[[:space:]]+.*//' \
      | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u >> "$TMP/hubimports.txt"
    sort -u -o "$TMP/hubimports.txt" "$TMP/hubimports.txt"
  fi

  # **«could not read the block» and «there are 0 local imports» are different.** A block that hands over only
  # libraries is normal (fastapi); the block being absent means no cross-check is possible. No silent omission.
  local nimp; nimp=$(num "$(awk '/<!-- pack-slot: common-imports/{f=1;m=1;next} m&&/<!-- \/pack-slot/{f=0;m=0;next} !m&&/^## Common Imports/{f=1;next} !m&&/^## /{f=0} f' "$hub" 2>/dev/null | grep -cE '^(import|from)[[:space:]]' | tr -d ' ')")
  local nh; nh=$(num "$(grep -c . "$TMP/hubimports.txt" | tr -d ' ')")
  if [ "$nh" -eq 0 ] && [ "$nimp" -gt 0 ]; then
    ok "${nimp} hub imports — all libraries (nothing to cross-check against the ledger)"
  elif [ "$nh" -eq 0 ]; then
    warn "could not read symbols from the hub's Common Imports" "the copy-paste block is missing or has a different shape — it is impossible to cross-check which imports the assembly gets in hand"
  else
    local ghost; ghost=$(comm -23 "$TMP/hubimports.txt" "$TMP/ledgersyms.txt" | tr '\n' ' ')
    if [ -n "$(printf '%s' "$ghost" | tr -d ' ')" ]; then
      bad "the hub imports a symbol that is not in the ledger: $ghost" \
          "this is the copy-paste block — a reader using it verbatim has nowhere to procure it from. Enter it in the ledger or take it out of the block"
    else
      ok "all ${nh} hub imports are entered in the ledger"
    fi
  fi

  # A slot holding nothing but a placeholder — if it ships, it goes straight into the assembly. Measured: the
  # `common-imports-axis` of aws-serverless shipped as `<!-- filled by L2 -->` and nobody knew.
  local ph
  ph=$(awk '/<!-- pack-slot:/{n=$0; c=0; body=""; next} /<!-- \/pack-slot/{ if (body ~ /filled by L2|TODO|to fill|<!-- *[Ff]ill/ && c<=3) { sub(/.*pack-slot:[[:space:]]*/,"",n); sub(/[[:space:]]*-->.*/,"",n); print n } ; next } { if ($0 ~ /[^[:space:]]/) { c++; body=body" "$0 } }' "$hub" 2>/dev/null | tr '\n' ' ')
  if [ -n "$(printf '%s' "$ph" | tr -d ' ')" ]; then
    bad "a hub slot shipped as a placeholder: $ph" "on assembly that text goes straight into SKILL.md — have L2 fill it, or delete the slot"
  fi

  # ⓑ is the prescription of the ledger requires caught by its own pack's forbid?
  [ -f "$pol" ] || return 0
  _parse_policies "$pol" "$TMP/hubpol.tsv"
  awk '/^## requires/{f=1;next} f&&/^## /{f=0} f' "$led" | grep -E '^\|[[:space:]]*`' > "$TMP/reqrows.txt" || true
  local id verdict scope rx except ex has cx hit=0
  while IFS=$'\t' read -r id verdict scope rx except ex has cx; do
    [ -z "$id" ] && continue
    [ "$verdict" = "forbid" ] || continue
    case "$scope" in seam|guide) ;; *) continue ;; esac
    if grep -qE "$rx" "$TMP/reqrows.txt" 2>/dev/null; then
      bad "the prescription of the ledger requires is caught by its own forbid '$id'" \
          "regex: $rx — a seam that followed the ledger is guaranteed to fall on --assembly after assembly. Change the prescription to a safe shape the pack provides"
      hit=$((hit+1))
    fi
  done < "$TMP/hubpol.tsv"
  [ "$hit" -eq 0 ] && ok "the ledger requires prescriptions do not clash with their own forbids"
  return 0
}

# ── the standard wire contract (guides/contracts/) ──────────────────
# Each pack defining its own contract is why every combination had to generate a seam — the mere difference of
# calling the same thing `UNAUTHORIZED` or `UNAUTHENTICATED` was enough to split the API client.
# So an HTTP pack names one canonical contract through pack.json `wireContract`, and the gate checks ① that the
# named contract exists and its edition matches ② that no rival code is written in a code fence (FAIL) ③ that the pack
# covers its own side's contract tokens. ③ is a WARN until the seam slots move into the pack — for now the seam owns
# the envelope and the code table, so their absence from the pack alone is normal.
CONTRACT_RIVALS='UNAUTHORIZED|BAD_REQUEST|THROTTLED|VALIDATION_ERROR|INTERNAL_ERROR'
check_pack_contract() {
  local P="$1" j="$1/pack.json"
  sec "standard wire contract (wireContract)"
  [ -f "$j" ] || return 0
  local wc; wc=$(grep -m1 -oE '"wireContract"[[:space:]]*:[[:space:]]*"[^"]*"' "$j" | sed -E 's/.*"([^"]*)"$/\1/')
  if [ -z "$wc" ]; then
    bad "no wireContract declaration" "an HTTP pack states \"http-standard@<edition>\"; a pack with no HTTP boundary (BaaS and the like) states \"none\""
    return 0
  fi
  [ "$wc" = "none" ] && { ok "wireContract = none (no HTTP boundary — follows the combination seam's contract)"; return 0; }

  local cname="${wc%@*}" cver="${wc##*@}" cf
  cf="$PLUGIN_GUIDES/contracts/$cname.md"
  case "$wc" in *@*) ;; *) bad "malformed wireContract: '$wc'" "the form is \"<name>@<edition>\" — e.g. http-standard@1"; return 0;; esac
  [ -f "$cf" ] || { bad "wireContract names a contract that does not exist: $wc" "$cf is missing"; return 0; }
  local hv; hv=$(grep -m1 -oE "orangekit-wire-contract: $cname v[0-9]+" "$cf" | grep -oE '[0-9]+$')
  [ "$hv" = "$cver" ] && ok "wireContract = $wc (matches the canonical edition)" \
    || { bad "wireContract edition mismatch: pack $cver ≠ canonical ${hv:-?}" "if the canonical contract moved up, bring the pack to the new edition and then raise the declaration"; return 0; }

  # ② rival codes — only those written as string literals count. A constant name such as `HTTP_401_UNAUTHORIZED`
  # or a "do not use this" explanation in prose is not a contract violation
  local rv; rv=$(grep -oE "[\"'\`]($CONTRACT_RIVALS)[\"'\`]" "$TMP/code.txt" 2>/dev/null | tr -d "\"'\`" | sort -u | tr '\n' ' ')
  [ -n "$(printf '%s' "$rv" | tr -d ' ')" ] \
    && bad "code uses a rival error code the canonical contract does not have: $rv" "switch to the codes in canonical §4 (e.g. UNAUTHORIZED → UNAUTHENTICATED, BAD_REQUEST → VALIDATION_FAILED, THROTTLED → RATE_LIMITED)" \
    || ok "no rival error codes"

  # ③ this side's contract tokens (the same extraction rule as pair)
  local ax side; ax=$(grep -m1 -oE '"axis"[[:space:]]*:[[:space:]]*"[^"]+"' "$j" | sed -E 's/.*"([^"]+)"$/\1/')
  [ "$ax" = "backend" ] && side='^(both|backend)$' || side='^(both|frontend)$'
  local NOISE='^([A-Z]|string|number|boolean|object|null|true|false|undefined|unknown|never|any|void|json|JSON|Date|Promise|Record|Array|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$'
  { contract_rows_tagged "$cf" | awk -F'\t' -v re="$side" '$1 ~ re {print $2}' \
      | grep -oE '`[^`]+`' | tr -d '`' | grep -oE '[A-Za-z_][A-Za-z0-9_]*'
  } | grep -vE "$NOISE" | sort -u > "$TMP/ctok.txt"
  local t miss="" n=0
  while read -r t; do
    [ -z "$t" ] && continue
    grep -rqw -- "$t" $(guide_files "$P") 2>/dev/null || { miss="$miss $t"; n=$((n+1)); }
  done < "$TMP/ctok.txt"
  [ "$n" -eq 0 ] && ok "all $(num "$(wc -l < "$TMP/ctok.txt")") contract tokens appear" \
    || warn "${n} contract tokens missing from the pack:$miss" "normal while the seam still owns the envelope and code table — raise it to FAIL once the slots move into the pack"
  return 0
}

run_pack() {
  local P="$1"
  printf "\n${C_D}guide-gate --pack${C_0}  %s\n" "$P"

  [ -d "$P" ] || { printf "pack directory missing: %s\n" "$P" >&2; exit 2; }
  [ -f "$P/PACK.md" ] || { bad "PACK.md missing"; return; }

  local FILES; FILES=$(guide_files "$P")
  [ -n "$FILES" ] || { bad "resources/*.md missing"; return; }
  # shellcheck disable=SC2086
  codelines $FILES > "$TMP/code.tsv"
  cut -f3 "$TMP/code.tsv" > "$TMP/code.txt"

  check_pack_meta "$P"
  check_pack_contract "$P"
  check_known_gaps "$P" "$P/pack.json"
  check_budget "$P"
  check_fences "$P"
  check_symbols "$P"
  check_pack_ledger "$P"
  check_declared_artifacts "$P"
  check_hub_contract "$P" "$P/$PACK_LEDGER_NAME" "$P/$PACK_POLICIES_NAME"
  check_env "$P"
  check_leak "$P"
  check_pm "$P"
  check_pack_policies "$P"
  check_policy_proof "$P" "$P/$PACK_POLICIES_NAME" "$(_pack_basenames "$P")"
  check_security_shapes "$P"
  check_claims "$P"
  check_duplicate_fences "$P"
  check_blocking_proof "$P"
  check_fence_imports "$P"

  sec "checks deferred until after assembly (explicit)"
  warn "the pack requires satisfaction check was skipped" "there is no seam yet — after install-guide.sh assembles, run it with --guide --assembly"
  warn "the wire-contract cross-check (--pair) was skipped" "the guide of the other axis is needed — after assembly, run it with --pair --contract"
  warn "scope=seam policies are undecidable" "these policies aim at the seam — after assembly, --guide --assembly judges them"
}

_resolve() {
  local G="$1" name; name=$(printf '%s' "$2" | tr -d ' `')
  [ -z "$name" ] && return 0
  if   [ -f "$G/$name" ];           then printf '%s' "$G/$name"
  elif [ -f "$G/resources/$name" ]; then printf '%s' "$G/resources/$name"
  fi
}

# ════════════════════════════════════════════════════════════════════
# --pair : wire contract ↔ set difference of the two guides
# ════════════════════════════════════════════════════════════════════
# Keeps only the rows of the contract that are cross-check material: list items and table rows. Backticks in prose
# and block quotes (>) are description, not contract values — counting them turns a sentence like "the measurement showed
# the backend used `/notes`" into a contract requirement (14 misreadings confirmed during development).
# The '> surface: frontend|backend' declaration at the head of a section is read and tags that section's rows.
# With no declaration it is both — existing contracts keep working.
contract_rows_tagged() {
  awk '
    /^## /            { sfc="both" }
    /^>[[:space:]]*surface:[[:space:]]*(frontend|backend|both)[[:space:]]*$/ {
                        sub(/^>[[:space:]]*surface:[[:space:]]*/,""); gsub(/[[:space:]]/,"");
                        sfc=$0; next }
    # A bullet must have **whitespace after it** — if `**bold**` prose is read as a list,
    # a value meant for one side turns into a requirement for both. It uses the same rule as contract_rows().
    /^[[:space:]]*([-*][[:space:]]|\|)/ {
                        if ($0 ~ /^[[:space:]]*\|[[:space:]]*-+[[:space:]]*\|/) next
                        print sfc "\t" $0 }
  ' "$1"
}

# A list item must have **whitespace after the bullet**. Prose that starts with `**bold**`
# read as a `*` bullet turns a value meant for one side into a requirement for both (measured during development:
# the prose "**server only**: … the name is `rt`" in §6 of the contract produced a frontend-unsatisfied FAIL).
contract_rows() { grep -E '^[[:space:]]*([-*][[:space:]]|\|)' "$1" | grep -vE '^[[:space:]]*\|[[:space:]]*-+[[:space:]]*\|'; }

run_pair() {
  printf "\n${C_D}guide-gate --pair${C_0}  contract: %s\n" "$CONTRACT"
  [ -f "$CONTRACT" ] || { printf "contract file missing: %s\n" "$CONTRACT" >&2; exit 2; }
  [ -d "$FE" ] && [ -d "$BE" ] || { printf "guide directory missing (--frontend/--backend)\n" >&2; exit 2; }

  # Domain vocabulary: if §0 of the contract is empty, the two guides end up describing different resources.
  # In the measurement both pre-built pairs had frontend /tasks ↔ backend /notes.
  sec "domain vocabulary"
  if grep -q '^## 0\. Domain vocabulary' "$CONTRACT"; then
    local vocab; vocab=$(awk '/^## 0\. Domain vocabulary/{f=1;next} /^## /{f=0} f' "$CONTRACT" \
      | grep -E '^[[:space:]]*[-*]' \
      | grep -oE '`[A-Za-z_/][A-Za-z0-9_/-]*`' | tr -d '`' | sort -u)
    if [ -z "$vocab" ]; then
      bad "§0 domain vocabulary of the contract is empty" "fill in entities·collections·paths, each in backticks"
    else
      local vmiss=""
      for v in $vocab; do
        grep -rqw -- "$v" "$FE" 2>/dev/null || vmiss="$vmiss FE:$v"
        grep -rqw -- "$v" "$BE" 2>/dev/null || vmiss="$vmiss BE:$v"
      done
      if [ -n "$vmiss" ]; then bad "domain vocabulary mismatch:$vmiss" "a resource name only one side knows — the complete examples become unrunnable against each other"
      else ok "domain vocabulary: $(printf '%s' "$vocab" | wc -w | tr -d ' ') terms match on both sides"; fi
    fi
  else
    warn "the contract has no §0 domain vocabulary section" "this is the old format — fill in §0 of wire-contract.template.md"
  fi

  sec "contract token set difference"
  # The cross-check tokens are identifiers inside backticks plus 3-digit status codes. They are taken from
  # 'inside' the backtick span, not the span 'as a whole' — in a contract that wraps the whole envelope
  # (`{ data, nextCursor }`) the token count would be 0 and this check would pass silently.
  local NOISE='^([A-Z]|string|number|boolean|object|null|true|false|undefined|unknown|never|any|void|json|JSON|Date|Promise|Record|Array|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$'
  # They are taken per surface. If a section carries a '> surface: backend' declaration, that section's
  # tokens are required of the backend only — that is what the HTTP section is in a combination that talks in action boundaries.
  _tok() { # $1 = the surfaces to include out of both|frontend|backend (a regex)
    { contract_rows_tagged "$CONTRACT" | awk -F'\t' -v re="$1" '$1 ~ re {print $2}' \
        | grep -oE '`[^`]+`' | tr -d '`' | grep -oE '[A-Za-z_][A-Za-z0-9_]*'
      contract_rows_tagged "$CONTRACT" | awk -F'\t' -v re="$1" '$1 ~ re {print $2}' \
        | grep -oE '(^|[^0-9A-Za-z_])[1-5][0-9][0-9]([^0-9A-Za-z_]|$)' | grep -oE '[0-9]{3}'
    } | grep -vE "$NOISE" | sort -u
  }
  _tok '^(both|frontend|backend)$' > "$TMP/tokens.txt"
  _tok '^(both|frontend)$' > "$TMP/tok_fe.txt"
  _tok '^(both|backend)$'  > "$TMP/tok_be.txt"

  local ntok; ntok=$(num "$(wc -l < "$TMP/tokens.txt")")
  if [ "$ntok" -lt 5 ]; then
    bad "only ${ntok} cross-check tokens extracted from the contract" "field and error-code names must each be wrapped in backticks to be cross-checked (template: assets/wire-contract.template.md)"
    return
  fi
  ok "${ntok} contract tokens extracted"

  local t nf=0 nb=0 mf="" mb=""
  while read -r t; do
    [ -z "$t" ] && continue
    grep -rqw "$t" $(guide_files "$FE") 2>/dev/null || { mf="$mf $t"; nf=$((nf+1)); }
  done < "$TMP/tok_fe.txt"
  while read -r t; do
    [ -z "$t" ] && continue
    grep -rqw "$t" $(guide_files "$BE") 2>/dev/null || { mb="$mb $t"; nb=$((nb+1)); }
  done < "$TMP/tok_be.txt"

  [ "$nf" -gt 0 ] && bad "${nf} contract tokens are absent from frontend:$mf" "the frontend does not handle this part of the contract" || ok "every frontend contract token appears"
  [ "$nb" -gt 0 ] && bad "${nb} contract tokens are absent from backend:$mb"  "the backend does not emit this part of the contract" || ok "every backend contract token appears"

  sec "pagination model exclusivity"
  local model
  model=$(grep -iE 'model' "$CONTRACT" | grep -oiE 'cursor|offset' | head -1 | tr 'A-Z' 'a-z')
  if [ -z "$model" ]; then
    warn "the contract declares no pagination model (cursor|offset)"
  else
    local rival hits
    # offset preceded by a hyphen is excluded so CSS classes such as 'ring-offset-2' are not caught
    [ "$model" = "cursor" ] && rival='page=|[^-]offset[^-]|\btotalPages\b' || rival='\bnextCursor\b'
    hits=$(grep -rhoE "$rival" $(guide_files "$FE") $(guide_files "$BE") 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$(printf '%s' "$hits" | tr -d ' ')" ] \
      && rev "the model is '$model' yet the vocabulary of the other model appears: $hits" "normal if it is for explanation, a contract violation if the example code uses it" \
      || ok "pagination model '$model' stays exclusive"
  fi

  sec "endpoint set difference"
  # A UI route and an API path are not distinguishable by the string alone — only what has HTTP call
  # vocabulary on the same line counts as an API path. Judgement is required, so it is REVIEW.
  codelines $(guide_files "$FE") 2>/dev/null | cut -f3 \
    | grep -iE 'api|fetch|http|request|axios|client|url' \
    | grep -oE "'/[a-zA-Z0-9][a-zA-Z0-9/:{}._$-]*'" | tr -d "'" | sort -u > "$TMP/fe_paths.txt"
  local p miss=0 tot=0 stem missing=""
  while read -r p; do
    [ -z "$p" ] && continue
    tot=$((tot+1))
    stem=$(printf '%s' "$p" | sed -E 's#^/api##; s#/:[A-Za-z0-9_]+##g; s#/\{[^}]*\}##g; s#/$##')
    [ -z "$stem" ] || [ "$stem" = "/" ] && continue
    grep -rqF -- "$stem" $(guide_files "$BE") 2>/dev/null || { missing="$missing $p"; miss=$((miss+1)); }
  done < "$TMP/fe_paths.txt"
  [ "$miss" -eq 0 ] \
    && ok "all ${tot} paths the frontend calls were found in the backend" \
    || rev "${miss} frontend call paths not found in the backend:$missing" "normal for an illustrative fictional path, but if it is the real contract one side is missing"
}

# ════════════════════════════════════════════════════════════════════
# --self-test : proof of blocking ability (the positive-fixture pattern of doctor.sh)
# ════════════════════════════════════════════════════════════════════
# "It is alive" is not "it blocks". If a single regex is off, every check passes silently,
# and that state is outwardly indistinguishable from correct. Only by confirming that a fixture with a
# planted defect really receives exit 1 can the gate be trusted.
run_self_test() {
  printf "\n${C_D}guide-gate --self-test${C_0}  (proof of blocking ability)\n"
  local fx="$TMP/fx"
  _fx_build "$fx" || { bad "failed to build fixtures"; return; }

  sec "harmless fixtures (must pass)"
  _fx_assert "$fx/clean/sample-backend-guide" 0 "a guide with no defects" --generated
  _fx_assert "$fx/clean/sample-backend-guide" 0 "a correct ledger" --generated --ledger "$fx/clean/ledger-ok.md"
  # Two negative checks — a miss is more dangerous than a false positive. Each is a defect that really made the gate look like a pass
  _fx_assert "$fx/clean/sample-backend-guide" 0 "a contract identifier (BAD_SHAPE) is not mistaken for a marker" --generated --ledger "$fx/clean/ledger-ok.md"
  _fx_assert "$fx/clean/sample-backend-guide" 0 "a contract field name (nextCursor) is not caught as a forbidden substring" --generated --forbid next

  sec "positive fixtures (must be blocked)"
  _fx_assert "$fx/dangling/sample-backend-guide"  1 "dangling resource reference"  --generated
  _fx_assert "$fx/envkey/sample-backend-guide"    1 "key undeclared in the env schema"  --generated
  _fx_assert "$fx/envhelper/sample-backend-guide" 0 "an env key declared through a helper is not a false positive" --generated
  _fx_assert "$fx/dupexport/sample-backend-guide" 1 "duplicate export, differing definitions" --generated
  _fx_assert "$fx/budget/sample-backend-guide"    1 "resource over 300 lines"     --generated
  _fx_assert "$fx/fence/sample-backend-guide"     1 "unclosed code fence"  --generated
  _fx_assert "$fx/section/sample-backend-guide"   1 "required section missing"        --generated
  _fx_assert "$fx/nostamp/sample-backend-guide"   1 "generation stamp missing"      --generated
  _fx_assert "$fx/leak/sample-backend-guide"      1 "cross-leak keyword"      --generated --forbid prisma
  _fx_assert "$fx/leakword/sample-backend-guide"  0 "an ordinary English word (cannot express) is not a leak" --generated --forbid express
  _fx_assert "$fx/leakcap/sample-backend-guide"   1 "the product spelling (Express) is still a leak" --generated --forbid express
  _fx_assert "$fx/clean/sample-backend-guide"     1 "package manager mismatch"  --generated --pm pnpm
  _fx_assert "$fx/clean/sample-backend-guide"     1 "ledger mismatch (consumer absent)" --generated --ledger "$fx/clean/ledger-bad.md"
  _fx_assert "$fx/clean/sample-backend-guide"     1 "symbol not entered in the ledger"      --generated --ledger "$fx/clean/ledger-short.md"

  # pack/seam boundary (v3.12.0) — pack assets are injected with --plugin-guides
  local PG="$fx/pg" A="$fx/clean/asm.json"
  cp "$fx/pg/backend/fxpack/policies.md" "$fx/pg/backend/fxpack/.keep-policies" 2>/dev/null || true
  _fx_assert "$fx/clean/sample-backend-guide" 0 "pack requires satisfied + generated excluded" --generated --assembly "$A" --plugin-guides "$PG" --pack-ledger-name ledger-ok.md
  _fx_assert "$fx/clean/sample-backend-guide" 1 "pack requires unsatisfied"        --generated --assembly "$A" --plugin-guides "$PG" --pack-ledger-name ledger.md
  _fx_assert "$fx/clean/sample-backend-guide" 1 "pack policy violation (forbid)"     --generated --assembly "$A" --plugin-guides "$PG" --pack-ledger-name ledger-ok.md --pack-policies-name policies-forbid.md
  _fx_assert "$fx/clean/sample-backend-guide" 1 "pack policy violation (require absent)" --generated --assembly "$A" --plugin-guides "$PG" --pack-ledger-name ledger-ok.md --pack-policies-name policies-require-missing.md
  _fx_assert "$fx/clean/sample-backend-guide" 0 "the policy exception column actually takes effect"  --generated --assembly "$A" --plugin-guides "$PG" --pack-ledger-name ledger-ok.md --pack-policies-name policies-excepted.md

  # ── standalone axis pack check (v3.13.0) ──
  # A pack could not be verified without a seam. --pack is that place, and it is the fan-in point of parallel authoring.
  _fx_build_pack "$fx" || { bad "failed to build the pack fixtures"; return; }

  _fx_build_pypack "$fx" || { bad "failed to build the Python pack fixtures"; return; }

  sec "harmless pack fixtures (must pass)"
  _fx_assert_pack "$fx/pk/clean/fxpack2"     0 "an axis pack with no defects"
  _fx_assert_pack "$fx/pk/pyok/fxpypack"     0 "recognizes Python definitions (def · module-level assignment)"
  _fx_assert_pack "$fx/pk/jsonfence/fxpack2" 0 "a string literal in a data file is not symbol use"
  _fx_assert_pack "$fx/pk/secok/fxpack2"     0 "a repaired return-path validation is not a false positive"
  _fx_assert_pack "$fx/pk/dupfence/fxpack2"  0 "an identical fence across files is REVIEW, not FAIL"
  _fx_assert_pack "$fx/pk/jstypedef/fxpack2" 0 "a type symbol declared only with a JSDoc @typedef also counts as defined"
  _fx_assert_pack "$fx/pk/secintercept/fxpack2" 0 "the origin comparison of a link intercept is not a dangerous shape"
  _fx_assert_pack "$fx/pk/fvscope/fxpack2"      0 "a scoped package is not mistaken for a competing product"
  _fx_assert_pack "$fx/pk/envclass/fxpack2"     0 "an env schema declared as class fields is accepted"
  _fx_assert_pack "$fx/pk/multisym/fxpack2"     0 "the second symbol of a row also counts as entered in the ledger (hub ghost false positive)"
  _fx_assert_pack "$fx/pk/tpllit/fxpack2"       0 "a word in template literal text is not symbol use"
  _fx_assert_pack "$fx/pk/appaxis/fxpack2"      0 "an app-axis (axis: app) pack is accepted"
  _fx_assert_pack "$fx/pk/wcok/fxpack2"         0 "naming the standard contract with tokens absent is a WARN, not a FAIL"

  sec "positive pack fixtures (must be blocked)"
  _fx_assert_pack "$fx/pk/polnoex/fxpack2"   1 "no policy proof-example column"
  _fx_assert_pack "$fx/pk/polnohdr/fxpack2"  1 "the policy table is there but the heading is missing, so 0 entries are enforced"
  _fx_assert_pack "$fx/pk/polbadfile/fxpack2" 1 "file: names a file that does not exist, so 0 entries are enforced"
  _fx_assert_pack "$fx/pk/polbadex/fxpack2"  1 "the proof example does not match its own regex"
  _fx_assert_pack "$fx/pk/polrealex/fxpack2" 1 "a forbid proof example really exists in the body"
  _fx_assert_pack "$fx/pk/secorigin/fxpack2" 1 "the return path is judged by an origin comparison alone"
  _fx_assert_pack "$fx/pk/secprefix/fxpack2" 1 "the return path is judged by startsWith('/') alone"
  _fx_assert_pack "$fx/pk/secrefer/fxpack2"  1 "redirect with a value from the request (a prose instruction)"
  _fx_assert_pack "$fx/pk/ledgerbad/fxpack2" 1 "no definition in the file the ledger assigned"
  _fx_assert_pack "$fx/pk/pymissing/fxpypack" 1 "when the Python definition really is missing it is still caught"
  _fx_assert_pack "$fx/pk/reqexport/fxpack2" 1 "the pack exports a requires symbol itself"
  _fx_assert_pack "$fx/pk/fvbad/fxpack2"     1 "fixesVariants ↔ pkgs contradiction"
  _fx_assert_pack "$fx/pk/vocab/fxpack2"     1 "vocabulary policy violation (an L0-issued forbid)"
  _fx_assert_pack "$fx/pk/noshape/fxpack2"   1 "the provides shape column is empty"
  _fx_assert_pack "$fx/pk/badarity/fxpack2"  1 "the shape's argument count ≠ the real definition"
  _fx_assert_pack "$fx/pk/noimport/fxpack2"  1 "a whole file uses a ledger symbol without procuring it"
  _fx_assert_pack "$fx/pk/reqnosig/fxpack2"  1 "a requires symbol is called but no signature is declared"
  _fx_assert_pack "$fx/pk/ghostres/fxpack2" 1 "a declared resource has no real file (an unfinished pack)"
  _fx_assert_pack "$fx/pk/jstypedefgone/fxpack2" 1 "when the @typedef really is missing it is still caught"
  _fx_assert_pack "$fx/pk/fvscopebad/fxpack2"   1 "a real competing product (express) is still caught as a contradiction"
  _fx_assert_pack "$fx/pk/envclassbad/fxpack2"  1 "an env key absent from the class is still caught"
  _fx_assert_pack "$fx/pk/badaxis/fxpack2"      1 "an unknown axis name is still caught"
  _fx_assert_pack "$fx/pk/wcmissing/fxpack2"    1 "no wireContract declaration"
  _fx_assert_pack "$fx/pk/wcbadver/fxpack2"     1 "the wireContract edition differs from the canonical one"
  _fx_assert_pack "$fx/pk/wcrival/fxpack2"      1 "a rival error code the canonical contract does not have (UNAUTHORIZED)"
  # A space in the path — common in a project folder name (`My Projects`) or a Windows user home. If the file list
  # is split at spaces, the gate **reads 0 files and passes everything** (it does not FAIL, it goes blind)
  mkdir -p "$fx/pk/sp ace" && cp -R "$fx/pk/noimport" "$fx/pk/sp ace/" \
    && _fx_assert_pack "$fx/pk/sp ace/noimport/fxpack2" 1 "a defect is caught even with a space in the path (the file list is not split)"

  [ "$REGRESS" -eq 0 ] && { sec "regression corpus"; skip_note; }

  sec "REVIEW fixtures (the verdict must pass to a human)"
  _fx_review_assert "$fx/pk/noproof/fxpack2" "a test with no block proof" "failure assertions"
  _fx_review_assert "$fx/pk/clean/fxpack2"   "" "failure assertions"

  [ "$REGRESS" -eq 1 ] && run_shipped_corpus
  return 0
}

# ── shipped-pack regression corpus ──────────────────────────────────
# Synthetic fixtures alone cannot catch **false positives**. All 4 defects of this gate surfaced only in
# real use (measured on node-api): check_env misjudged a helper declaration as undeclared, check_claims
# excluded tagged claims from the inventory, previous-line tag attribution was too broad, security shapes could not see prose.
# So **every pack currently shipping goes into the self-test** — if a new check false-positives on a real asset,
# --self-test turns red immediately. A false positive makes a gate unusable just as much as a miss does.
run_shipped_corpus() {
  sec "shipped-pack regression corpus (false-positive block)"
  if [ ! -d "$PLUGIN_GUIDES" ]; then
    warn "shipped-pack directory missing: $PLUGIN_GUIDES" "pass the path with --plugin-guides and the regression turns on — right now it is **unchecked**"
    return 0
  fi
  local d n=0 code
  for d in "$PLUGIN_GUIDES"/frontend/*/ "$PLUGIN_GUIDES"/backend/*/ "$PLUGIN_GUIDES"/app/*/; do
    [ -f "$d/PACK.md" ] || continue
    n=$((n+1))
    code=0; bash "$0" --pack "${d%/}" >/dev/null 2>&1 || code=$?
    if [ "$code" -eq 0 ]; then
      ok "shipped pack $(basename "$(dirname "${d%/}")")/$(basename "${d%/}") → FAIL 0"
    else
      bad "shipped pack $(basename "$(dirname "${d%/}")")/$(basename "${d%/}") → exit $code" \
          "$(bash "$0" --pack "${d%/}" 2>&1 | grep '✗' | head -2 | sed 's/^  *//' | tr '\n' ';')"
    fi
  done
  [ "$n" -eq 0 ] && warn "0 shipped packs — the regression corpus is empty"

  run_shipped_seams
  return 0
}

# ── pre-built seam regression ───────────────────────────────────────
# A pre-built seam is a shipping asset at the combination level, so **it has to be checked every time a pack changes** —
# if a pack's requires grows or a policy changes, the seam silently diverges. If that check depends on a person's
# diligence, it gets missed. It assembles, then runs the assembly gate and --pair.
# (3 checks per combination × the number of seams. --pack alone does not turn on requires satisfaction or scope=seam policies)
# seamSlots triple cross-check (axis pack declaration ↔ seam.json ↔ real files).
# The axis pack had this cross-check (resources[] ↔ real files in check_pack_meta) — **the seam did not.**
# SKILL.md defines seamSlots as "the names of the files to create", so a mismatch is a spec violation.
# The reason it does not break today is that the assembler (install-guide.sh) copies *.md **by glob** and never
# resolves slot names — the moment anything looks up a file by slot name it breaks, and
# a slot-based generator creates one more file named after the slot **next to** the existing one, producing a duplicate.
check_seam_slots() {   # $1 seam directory (guides/seams/<combination>)
  local S="$1" sj="$1/seam.json" combo; combo=$(basename "$S")
  [ -f "$sj" ] || { warn "seam $combo — seam.json missing"; return 0; }
  local axis

  # ① seam.json declaration ↔ real files (the same two-way set difference as check_pack_meta)
  grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]+"' "$sj" | sed -E 's/.*"([^"]+)"$/\1/' | sort -u > "$TMP/sjres.txt"
  for axis in frontend backend app; do
    ls "$S/$axis"/resources/*.md 2>/dev/null | while read -r f; do basename "$f"; done
  done | sort -u > "$TMP/sjreal.txt"
  local smiss sghost
  smiss=$(comm -13 "$TMP/sjres.txt" "$TMP/sjreal.txt" | tr '\n' ' ')
  sghost=$(comm -23 "$TMP/sjres.txt" "$TMP/sjreal.txt" | tr '\n' ' ')
  [ -n "$(printf '%s' "$smiss" | tr -d ' ')" ] && bad "seam $combo — real files missing from seam.json resources[]: $smiss" "no HUB Navigation row is created, so they become unreachable in the assembly"
  [ -n "$(printf '%s' "$sghost" | tr -d ' ')" ] && bad "seam $combo — seam.json points at a file that does not exist: $sghost"
  [ -z "$(printf '%s%s' "$smiss" "$sghost" | tr -d ' ')" ] && ok "seam $combo — seam.json resources[] ↔ real files match"

  check_known_gaps "$S" "$sj"

  # ② the axis pack's seamSlots ↔ the real files of that axis
  local pk pj sdiff
  for axis in frontend backend app; do
    [ -d "$S/$axis/resources" ] || continue
    pk=$(grep -oE "\"${axis}Pack\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$sj" | sed -E 's|.*/||; s|"$||')
    [ -n "$pk" ] || { warn "seam $combo/$axis — could not read the pack reference"; continue; }
    pj="$PLUGIN_GUIDES/$axis/$pk/pack.json"
    [ -f "$pj" ] || { warn "seam $combo/$axis — pack.json missing ($pk)"; continue; }
    tr -d '\n' < "$pj" | grep -oE '"seamSlots"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
      | grep -oE '"[^"]+"' | sed -E 's/"([^"]+)"/\1/' | grep -vx 'seamSlots' \
      | sed 's/$/.md/' | sort -u > "$TMP/slots.txt"
    if [ ! -s "$TMP/slots.txt" ]; then
      warn "seam $combo/$axis — pack $pk has no seamSlots" "the places the seam is to fill are not declared"
      continue
    fi
    ls "$S/$axis"/resources/*.md 2>/dev/null | while read -r f; do basename "$f"; done | sort -u > "$TMP/slotreal.txt"
    sdiff=$(comm -3 "$TMP/slots.txt" "$TMP/slotreal.txt" | tr -d '\t' | tr '\n' ' ')
    if [ -n "$(printf '%s' "$sdiff" | tr -d ' ')" ]; then
      bad "seam $combo/$axis — seamSlots ↔ real files mismatch: $sdiff" \
          "the seamSlots of $pk/pack.json are **the names of the files to create**. If the names fork, it breaks the moment a consumer looks up a file by slot"
    else
      ok "seam $combo/$axis — seamSlots $(num "$(wc -l < "$TMP/slots.txt")") ↔ real files match"
    fi
  done
  return 0
}

run_shipped_seams() {
  local root; root=$(cd "$PLUGIN_GUIDES/.." 2>/dev/null && pwd) || return 0
  local inst="$root/scripts/install-guide.sh"
  [ -f "$inst" ] || { warn "install-guide.sh missing — seam regression skipped" "$inst"; return 0; }
  sec "pre-built seam regression (per combination)"

  local sj combo fe be proj n=0 code
  for sj in "$PLUGIN_GUIDES"/seams/*/seam.json; do
    [ -f "$sj" ] || continue
    combo=$(basename "$(dirname "$sj")")
    check_seam_slots "$(dirname "$sj")"
    fe=$(grep -oE '"frontendPack"[^"]*"[^"]+"' "$sj" | sed -E 's|.*/||; s|"$||')
    be=$(grep -oE '"backendPack"[^"]*"[^"]+"'  "$sj" | sed -E 's|.*/||; s|"$||')
    [ -n "$fe" ] && [ -n "$be" ] || { warn "seam $combo — could not read the pack reference"; continue; }
    n=$((n+1))
    proj="$TMP/seam-$combo"; mkdir -p "$proj"
    if ! CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$proj" \
         bash "$inst" --frontend "$fe" --backend "$be" --seam "$combo" --no-cache >/dev/null 2>&1; then
      bad "seam $combo — assembly failed"; continue
    fi
    local g ok_all=1
    for g in frontend backend; do
      code=0
      bash "$0" --guide "$proj/.claude/skills/$g-guide" \
                --assembly "$proj/.claude/skills/$g-guide/assembly.json" \
                --plugin-guides "$PLUGIN_GUIDES" >/dev/null 2>&1 || code=$?
      [ "$code" -eq 0 ] || { bad "seam $combo/$g → exit $code" \
        "$(bash "$0" --guide "$proj/.claude/skills/$g-guide" --assembly "$proj/.claude/skills/$g-guide/assembly.json" --plugin-guides "$PLUGIN_GUIDES" 2>&1 | grep '✗' | head -2 | sed 's/^  *//' | tr '\n' ';')"; ok_all=0; }
    done
    code=0
    bash "$0" --pair --contract "$PLUGIN_GUIDES/seams/$combo/contract.md" \
              --frontend "$proj/.claude/skills/frontend-guide" \
              --backend "$proj/.claude/skills/backend-guide" >/dev/null 2>&1 || code=$?
    [ "$code" -eq 0 ] || { bad "seam $combo --pair → exit $code" "the wire contract forked between the two sides"; ok_all=0; }
    [ "$ok_all" -eq 1 ] && ok "seam $combo → 2 assemblies + --pair FAIL 0"
  done
  [ "$n" -eq 0 ] && warn "0 pre-built seams"
  return 0
}


# REVIEW does not change the exit code, so the verdict is read from the output.
# An empty want means "that REVIEW must **not** appear" (false-positive block).
# If the corpus was skipped, say so — "the fixtures passed" and "the real assets were checked" are different.
skip_note() {
  printf "  ${C_C}–${C_0} shipped-pack·seam regression skipped (turn it on with --regress)\n"
  printf "      ${C_D}synthetic fixtures catch misses and real assets catch false positives — run --regress before shipping${C_0}\n"
  return 0
}

_fx_review_assert() {
  local dir="$1" label="$2" needle="$3"
  local out; out=$(bash "$0" --pack "$dir" 2>&1)
  if [ -n "$label" ]; then
    if printf '%s' "$out" | grep -q "$needle"; then ok "$label → REVIEW raised"
    else bad "$label → no REVIEW came out" "it let a test with no block proof through"; fi
  else
    if printf '%s' "$out" | grep -q "$needle"; then bad "'$needle' REVIEW false positive on a harmless pack"
    else ok "no block-proof REVIEW on a harmless pack"; fi
  fi
  return 0
}

_fx_assert_pack() {
  local dir="$1" want="$2" label="$3"; shift 3
  local out code=0
  out=$(bash "$0" --pack "$dir" "$@" 2>&1) || code=$?
  if [ "$code" -eq "$want" ]; then
    ok "$label → exit $code"
    # A fixture that was blocked, but blocked **for a different reason**, is not a fixture.
    # ORANGEKIT_FX_WHY=1 shows the real FAIL reason so it can be compared against the intent.
    [ -n "${ORANGEKIT_FX_WHY:-}" ] && [ "$want" -eq 1 ] && \
      printf "      ${C_D}%s${C_0}\n" "$(printf '%s' "$out" | grep '✗' | head -2 | sed 's/^  *//' | tr '\n' ';')"
  else
    bad "$label → exit $code (expected $want)" "$(printf '%s' "$out" | grep -E '✗|pass ' | head -3 | tr '\n' ';')"
  fi
}

# Axis pack fixtures — they pin the surface that appeared in v3.13.0 (--pack · proof example · security shapes · variant declaration).

# ── Python pack fixtures ────────────────────────────────────────────
# The symbol definition pattern **knew only TypeScript and missed the definitions of a Python pack wholesale**
# (measured in the fastapi pilot: `def to_app_error(...)`·`settings = Settings()` all FAILed as
# "no definition"). Both are pinned: that a correct Python pack passes (false positive), and that
# when the definition really is missing it is still caught (miss).
_fx_build_pypack() {
  local fx="$1" b="$1/pk/pyok/fxpypack"
  mkdir -p "$b/resources" || return 1

  cat > "$b/PACK.md" <<'FXPYM'
<!-- orangekit-pack: backend/fxpypack v0.0.0 verified 2026-01-01 pydantic@2 -->

# fxpypack axis pack — hub fragment

<!-- pack-slot: directory-structure -->
## Directory Structure

```
app/
├── settings.py
└── errors.py
```
<!-- /pack-slot -->
FXPYM

  cat > "$b/resources/a.md" <<'FXPYA'
# Environment validation

<!-- file: app/config.py -->
```python
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    DATABASE_URL: str


settings = Settings()
```

`settings` is used by the normalization path in b.md.
FXPYA

  cat > "$b/resources/b.md" <<'FXPYB'
# Error normalization

```python
ERROR_STATUS: dict[str, int] = {"NOT_FOUND": 404}


def to_app_error(exc: BaseException) -> str:
    return "INTERNAL"
```

`to_app_error` is called first by the exception handler.
FXPYB

  cat > "$b/ledger.md" <<'FXPYL'
## provides — this pack defines these

| symbol | definition file | shape | nature |
| --- | --- | --- | --- |
| `Settings` | a.md | `app/config.py`. `class Settings(BaseSettings)` — DATABASE_URL | env schema |
| `settings` | a.md | `app/config.py`. a `Settings` instance — created at module top level | validated environment values |
| `ERROR_STATUS` | b.md | `app/errors.py`. `dict[str, int]` — domain code → HTTP status | status mapping |
| `to_app_error` | b.md | `app/errors.py`. `to_app_error(exc: BaseException) -> str` — anything unknown is INTERNAL | normalization |

## requires — the seam must provide these

| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `logger` | project | structured logger | owned by the seam |
FXPYL

  cat > "$b/policies.md" <<'FXPYP'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-print` | forbid | guide | `\bprint\(` | — | `print(user)` | `print(f"{x}")` | use the structured logger only |
FXPYP

  cat > "$b/pack.json" <<'FXPYJ'
{
  "axis": "backend",
  "name": "fxpypack",
  "registry": "pypi",
  "exampleDomain": { "entity": "Task", "collection": "tasks" },
  "wireContract": "none",
  "fixesVariants": {},
  "pkgs": ["pydantic@2"],
  "resources": [
    { "file": "a.md", "nav": "Environment" },
    { "file": "b.md", "nav": "Errors" }
  ]
}
FXPYJ

  # The whole-file fence procures via `from X import Y` — this must not be a false positive
  cat >> "$b/resources/b.md" <<'FXPYC'

<!-- file: app/errors.py -->
```python
from app.settings import settings


def describe() -> str:
    return settings.DATABASE_URL
```
FXPYC

  # A variant where the definition really is missing — guards against a miss
  mkdir -p "$fx/pk/pymissing" && cp -R "$b" "$fx/pk/pymissing/" || return 1
  sed -i.bak 's#^def to_app_error.*#def other_name(exc: BaseException) -> str:#' \
    "$fx/pk/pymissing/fxpypack/resources/b.md" && rm -f "$fx/pk/pymissing/fxpypack/resources/b.md.bak"
  return 0
}

_fx_build_pack() {
  local fx="$1" b="$1/pk/clean/fxpack2" m
  mkdir -p "$b/resources" || return 1

  cat > "$b/PACK.md" <<'FXPM'
<!-- orangekit-pack: backend/fxpack2 v0.0.0 verified 2026-01-01 zod@4 -->

# fxpack2 axis pack — hub fragment

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── env.ts
└── boot.ts
```
<!-- /pack-slot -->
FXPM

  cat > "$b/resources/a.md" <<'FXPA'
# Schema and environment variables

<!-- file: src/env.ts -->
```ts
import { z } from 'zod'

export const EnvSchema = z.object({
  PORT: z.string(),
})
```

`EnvSchema` is used by the boot path in b.md.
FXPA

  cat > "$b/resources/b.md" <<'FXPB'
# Boot

<!-- file: src/boot.ts -->
```ts
import { EnvSchema } from '@/env'

export function boot(raw) {
  return EnvSchema.parse(raw)
}
```

`boot` is called exactly once by the entry point.
FXPB

  cat > "$b/ledger.md" <<'FXPL'
## provides — this pack defines these

| symbol | definition file | shape | nature |
| --- | --- | --- | --- |
| `EnvSchema` | a.md | `src/env.ts`. `ZodObject` — applied with `safeParse(process.env)` | env schema |
| `boot` | b.md | `src/boot.ts`. `boot(raw: unknown) => Env` — throws on failure | boot |

## requires — the seam must provide these

| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `logger` | project | structured logger | owned by the seam |
FXPL

  cat > "$b/policies.md" <<'FXPP'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `zod-present` | require | guide | `from 'zod'` | — | `import { z } from 'zod'` | `import { v } from 'valibot'` | the schema library is pinned |
| `no-console` | forbid | guide | `console\.log\(` | — | `console.log(user)` | `console.log({ id })` | use the structured logger only |
FXPP

  cat > "$b/pack.json" <<'FXPJ'
{
  "axis": "backend",
  "name": "fxpack2",
  "exampleDomain": { "entity": "Task", "collection": "tasks" },
  "wireContract": "none",
  "fixesVariants": { "orm": "prisma" },
  "pkgs": ["zod@4", "prisma@6"],
  "resources": [
    { "file": "a.md", "nav": "Schema" },
    { "file": "b.md", "nav": "Boot" }
  ]
}
FXPJ

  for m in polnoex polbadex polrealex secorigin secprefix secok secrefer ledgerbad reqexport fvbad vocab dupfence noproof noshape badarity noimport reqnosig polnohdr jsonfence polbadfile ghostres jstypedef jstypedefgone secintercept fvscope fvscopebad envclass envclassbad multisym tpllit appaxis badaxis wcok wcmissing wcbadver wcrival; do
    mkdir -p "$fx/pk/$m" && cp -R "$b" "$fx/pk/$m/" || return 1
  done
  # A fixture that adds c.md must carry it in pack.json too, or it is not blocked by the intended check.
  # Without that it is caught first by 'resources[] mismatch' and the fixture ends up proving something else.
  local v
  for v in secorigin secprefix secok; do
    sed -i.bak 's#{ "file": "b.md", "nav": "Boot" }#{ "file": "b.md", "nav": "Boot" },\
    { "file": "c.md", "nav": "Return path" }#' "$fx/pk/$v/fxpack2/pack.json" && rm -f "$fx/pk/$v/fxpack2/pack.json.bak"
  done

  # App axis — the pack contract is the same as the web screen axis, only the axis name differs. Exactly three names must be accepted
  sed -i.bak 's#"axis": "backend"#"axis": "app"#' "$fx/pk/appaxis/fxpack2/pack.json" && rm -f "$fx/pk/appaxis/fxpack2/pack.json.bak"
  sed -i.bak 's#"axis": "backend"#"axis": "mobile"#' "$fx/pk/badaxis/fxpack2/pack.json" && rm -f "$fx/pk/badaxis/fxpack2/pack.json.bak"

  # The standard wire contract — naming, edition, rival codes. The canonical contract is read from the real file (guides/contracts/)
  local wj
  for v in wcok wcrival; do
    wj="$fx/pk/$v/fxpack2/pack.json"
    sed -i.bak 's#"wireContract": "none"#"wireContract": "http-standard@1"#' "$wj" && rm -f "$wj.bak"
  done
  wj="$fx/pk/wcbadver/fxpack2/pack.json"
  sed -i.bak 's#"wireContract": "none"#"wireContract": "http-standard@9"#' "$wj" && rm -f "$wj.bak"
  wj="$fx/pk/wcmissing/fxpack2/pack.json"
  sed -i.bak '/"wireContract"/d' "$wj" && rm -f "$wj.bak"
  printf '\n```ts\nconst AUTH_CODE = %s\n```\n' "'UNAUTHORIZED'" >> "$fx/pk/wcrival/fxpack2/resources/b.md"

  # ⑯ a scoped package is not mistaken for a competing product (measured on node-nest — a false positive)
  # `@nestjs/platform-express` is Nest's default HTTP adapter, not a choice of Express.
  # A flattened substring match cannot separate the two, so a correct pack FAILed.
  sed -i.bak 's#"fixesVariants": { "orm": "prisma" }#"fixesVariants": { "framework": "nestjs" }#; s#"zod@4", "prisma@6"#"zod@4", "@nestjs/core@11", "@nestjs/platform-express@11"#' \
    "$fx/pk/fvscope/fxpack2/pack.json" && rm -f "$fx/pk/fvscope/fxpack2/pack.json.bak"
  # The paired positive — with real Express present it must still be caught as a contradiction (guards against a miss)
  sed -i.bak 's#"fixesVariants": { "orm": "prisma" }#"fixesVariants": { "framework": "nestjs" }#; s#"zod@4", "prisma@6"#"zod@4", "@nestjs/core@11", "express@5"#' \
    "$fx/pk/fvscopebad/fxpack2/pack.json" && rm -f "$fx/pk/fvscopebad/fxpack2/pack.json.bak"

  # ⑰ an env schema declared as class fields also counts as a declaration (measured on node-nest — a false positive)
  # On the class-validator axis the schema is a **class** rather than an object, and a type sits in the value position.
  # A regex that knows only the call·property-access forms saw 0 declarations and caught the env use as undeclared.
  cat > "$fx/pk/envclass/fxpack2/resources/a.md" <<'FXP16'
# Schema and environment variables

<!-- file: src/env.ts -->
```ts
import { z } from 'zod'

export class EnvVars {
  DATABASE_URL!: string
  PORT: number = 3000
}

export const EnvSchema = z.object({ PORT: z.string() })
```

`EnvSchema` is used by the boot path in b.md.
FXP16
  printf '\n```ts\nconst dsn = env.DATABASE_URL\nconst port = env.PORT\n```\n' \
    >> "$fx/pk/envclass/fxpack2/resources/b.md"

  # The paired positive — using a key absent from the class must still be caught (guards against a miss)
  cp "$fx/pk/envclass/fxpack2/resources/a.md" "$fx/pk/envclassbad/fxpack2/resources/a.md"
  printf '\n```ts\nconst dsn = env.DATABASE_URL\nconst who = env.UNDECLARED_KEY\n```\n' \
    >> "$fx/pk/envclassbad/fxpack2/resources/b.md"

  # ① the proof-example column itself is missing (the old 6-column format)
  cat > "$fx/pk/polnoex/fxpack2/policies.md" <<'FXP1'
## Machine checks

| id | verdict | scope | regex | exception file | description |
| --- | --- | --- | --- | --- | --- |
| `no-console` | forbid | guide | `console\.log\(` | — | use the structured logger only |
FXP1

  # ② the proof example is not caught by its own regex — it exposes a dead regex
  cat > "$fx/pk/polbadex/fxpack2/policies.md" <<'FXP2'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | description |
| --- | --- | --- | --- | --- | --- | --- |
| `no-console` | forbid | guide | `console\.error\(` | — | `console.log(user)` | the example and the regex disagree |
FXP2

  # ③ the forbid proof example really exists in the pack body — it violates its own policy
  cat > "$fx/pk/polrealex/fxpack2/policies.md" <<'FXP3'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-zod` | forbid | guide | `from 'zod'` | — | `import { z } from 'zod'` | `export { s } from 'zod'` | it is right there in the body |
FXP3

  # ④·⑤ security shapes — the two shapes the measurement (2026-08-23) found in all four shipped copies
  cat > "$fx/pk/secorigin/fxpack2/resources/c.md" <<'FXP4'
# Return path

```ts
export function safeReturnTo(raw: string, fallback = '/') {
  const url = new URL(raw, window.location.origin);
  if (url.origin !== window.location.origin) return fallback;
  return url.pathname + url.search;
}
```
FXP4
  cat > "$fx/pk/secprefix/fxpack2/resources/c.md" <<'FXP5'
# Return path

```ts
export function safeReturnTo(raw: string, fallback = '/') {
  if (!raw.startsWith('/')) return fallback;
  return raw;
}
```
FXP5
  # A test that cannot prove blocking — only failure assertions and no success assertion.
  # It passes even when the implementation is failed wholesale, so it is not a "guard" (measured on node-api).
  cat > "$fx/pk/noproof/fxpack2/resources/b.md" <<'FXP12'
# Boot

```ts
import { EnvSchema } from '@/env'

export function boot(raw) {
  return EnvSchema.parse(raw)
}
```

`boot` is called exactly once by the entry point.

```ts
it('reading another user record gives 404', async () => {
  const res = await request(app).get('/x')
  expect(res.status).toBe(404)
})
```
FXP12

  # A request-derived redirect **rides in prose and tables too** — looking only at fences misses it.
  # In the node-api measurement a cell of the misuse table told the reader to read Referer without validation.
  cat > "$fx/pk/secrefer/fxpack2/resources/c.md" <<'FXP7'
# Misuse list

| old habit | current shape |
| --- | --- |
| `res.redirect('back')` | the special handling is gone. Read `req.get('Referer')` directly |
FXP7

  # Harmless control: the repaired shape must pass (a false positive makes a gate unusable just as much as a miss)
  cat > "$fx/pk/secok/fxpack2/resources/c.md" <<'FXP6'
# Return path

```ts
export function safeReturnTo(raw: string, fallback = '/') {
  const url = new URL(raw, window.location.origin);
  if (url.origin !== window.location.origin) return fallback;
  const p = url.pathname;
  if (!p.startsWith('/') || p.startsWith('//')) return fallback;
  return p + url.search;
}
```
FXP6

  # ⑪ the shape column is empty — a sibling cluster ends up guessing the signature
  sed -i.bak 's#| `boot` | b.md | `src/boot.ts`. `boot(raw: unknown) => Env` — throws on failure |#| `boot` | b.md | — |#' \
    "$fx/pk/noshape/fxpack2/ledger.md" && rm -f "$fx/pk/noshape/fxpack2/ledger.md.bak"

  # ⑫ the argument count the shape declares differs from the real definition
  sed -i.bak 's#`boot(raw: unknown) => Env` — throws on failure#`boot(raw: unknown, opts: Opts) => Env` — throws on failure#' \
    "$fx/pk/badarity/fxpack2/ledger.md" && rm -f "$fx/pk/badarity/fxpack2/ledger.md.bak"

  # ⑭ a requires symbol is called but the shape carries no signature — the seam guesses the argument order
  printf '\n```ts\nlogger(env, "boot")\n```\n' >> "$fx/pk/reqnosig/fxpack2/resources/b.md"

  # ⑬ a whole file uses a ledger symbol without procuring it — copying it verbatim is a ReferenceError
  cat > "$fx/pk/noimport/fxpack2/resources/b.md" <<'FXP13'
# Boot

<!-- file: src/boot.ts -->
```ts
// src/boot.ts
export function boot(raw) {
  return EnvSchema.parse(raw)
}
```

`boot` is called exactly once by the entry point.
FXP13

  # ⑥ the file the ledger assigned has no definition — the fan-in defect of parallel authoring
  sed -i.bak 's#| `boot` | b.md |#| `boot` | a.md |#' "$fx/pk/ledgerbad/fxpack2/ledger.md" && rm -f "$fx/pk/ledgerbad/fxpack2/ledger.md.bak"

  # ⑦ the pack exports a symbol it declared in requires (measured: useTasksQuery in react-vite)
  sed -i.bak 's#| `logger` | project |#| `boot` | project |#' "$fx/pk/reqexport/fxpack2/ledger.md" && rm -f "$fx/pk/reqexport/fxpack2/ledger.md.bak"

  # ⑧ the declared variant contradicts pkgs — the assembly-time cross-check passes falsely
  sed -i.bak 's#"prisma@6"#"drizzle-orm@0"#' "$fx/pk/fvbad/fxpack2/pack.json" && rm -f "$fx/pk/fvbad/fxpack2/pack.json.bak"


  # ⑬ the policy table is there but the `## Machine checks` heading is missing — **silent zero enforcement**
  # That really happened in the firebase pack and the gate emitted only a WARN. An enforcement device
  # that is green while doing nothing is the very failure mode this repository exists to eliminate.
  sed -i.bak 's/^## Machine checks$/## Policies/' "$fx/pk/polnohdr/fxpack2/policies.md" \
    && rm -f "$fx/pk/polnohdr/fxpack2/policies.md.bak"

  # ⑭ a data-file fence carries a **string literal** identical to a ledger symbol — this must not be a false positive
  # (measured in the firebase pilot: "queryScope": "COLLECTION" in firestore.indexes.json)
  cat > "$fx/pk/jsonfence/fxpack2/resources/c.md" <<'FXP14'
# Configuration

<!-- file: config/index.json -->
```json
{
  "scope": "boot",
  "schema": "EnvSchema"
}
```
FXP14
  sed -i.bak 's#{ "file": "b.md", "nav": "Boot" }#{ "file": "b.md", "nav": "Boot" },\
    { "file": "c.md", "nav": "Configuration" }#' "$fx/pk/jsonfence/fxpack2/pack.json" \
    && rm -f "$fx/pk/jsonfence/fxpack2/pack.json.bak"

  # ⑮ the file: scope of a require policy names a file that does not exist — **silent zero enforcement**
  # Leaving it as `guide` degrades into «anywhere in the pack at least once», so it was narrowed to the owning file,
  # but getting that filename wrong made the policy do nothing while being reported as «deferred until after assembly».
  cat > "$fx/pk/polbadfile/fxpack2/policies.md" <<'FXP15'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | description |
| --- | --- | --- | --- | --- | --- | --- |
| `rowcount-checked` | require | file:nosuch.md | `\.rowcount\b` | — | `if result.rowcount == 0:` | it names an owning file and that file does not exist |
FXP15

  # ⑨ vocabulary policy — does the forbid row L0 issues catch the vocabulary fork of parallel authoring?
  cat > "$fx/pk/vocab/fxpack2/policies.md" <<'FXP9'
## Machine checks

| id | verdict | scope | regex | exception file | proof example | description |
| --- | --- | --- | --- | --- | --- | --- |
| `vocab-task` | forbid | guide | `\bnote(s)?\b` | — | `const notes = []` | the domain vocabulary is pinned to Task (issued by L0) |
FXP9
  printf '\n```ts\nexport const notes = []\n```\n' >> "$fx/pk/vocab/fxpack2/resources/b.md"
  sed -i.bak 's#| `boot` | b.md | boot |#| `boot` | b.md | boot |\n| `notes` | b.md | vocabulary violation |#' "$fx/pk/vocab/fxpack2/ledger.md" && rm -f "$fx/pk/vocab/fxpack2/ledger.md.bak"

  # ⑬ harmless: the origin comparison of a link intercept. It is not return-path validation but the verdict on
  # **whether to intercept**, and not intercepting an external link is exactly right. Treating an origin comparison
  # itself as a dangerous shape makes a correct implementation FAIL (it really did on vanilla).
  cat > "$fx/pk/secintercept/fxpack2/resources/c.md" <<'FXP15'
# Link intercept

```ts
export function interceptLinks(root: Element, navigate: (p: string) => void) {
  const onClick = (e: MouseEvent) => {
    const a = (e.target as Element)?.closest('a[href]')
    if (!(a instanceof HTMLAnchorElement)) return
    const url = new URL(a.href, window.location.origin)
    if (url.origin !== window.location.origin) return
    e.preventDefault()
    navigate(url.pathname + url.search)
  }
  root.addEventListener('click', onClick)
  return () => root.removeEventListener('click', onClick)
}
```
FXP15
  sed -i.bak 's#{ "file": "b.md", "nav": "Boot" }#{ "file": "b.md", "nav": "Boot" },\
    { "file": "c.md", "nav": "Link intercept" }#' "$fx/pk/secintercept/fxpack2/pack.json" && rm -f "$fx/pk/secintercept/fxpack2/pack.json.bak"
  sed -i.bak 's#^| `boot` | b.md |#| `interceptLinks` | c.md | `interceptLinks(root, navigate)` — returns a teardown function | intercept |\
| `boot` | b.md |#' "$fx/pk/secintercept/fxpack2/ledger.md" && rm -f "$fx/pk/secintercept/fxpack2/ledger.md.bak"

  # ⑫ the type symbols of a JS pack are declared only with a JSDoc `@typedef`.
  # `iscomment()` drops lines starting with `*`, so such a declaration **cannot exist** in codelines() —
  # on vanilla (the first JavaScript axis) a FAIL of "no definition" came out even though it was defined.
  # That is where the checker knew only one language, and the two variants block the false positive and the miss respectively.
  for m in jstypedef jstypedefgone; do
    sed -i.bak 's#^| `boot` | b.md |#| `FxTask` | b.md | `/** @typedef {{ id: string }} FxTask */` — a JSDoc type | domain type |\
| `boot` | b.md |#' "$fx/pk/$m/fxpack2/ledger.md" && rm -f "$fx/pk/$m/fxpack2/ledger.md.bak"
  done
  # The real declaration goes only into jstypedef. In jstypedefgone it is in the ledger only, not in the body
  printf '\n```js\n/** @typedef {{ id: string }} FxTask */\nexport const FX_TASK_KEY = "task"\n```\n' \
    >> "$fx/pk/jstypedef/fxpack2/resources/b.md"

  # ⑬ when one ledger row carries two symbols (`a` · `b`), the hub imports the **second** one.
  # While ledger symbol extraction took only the first backtick token, the second counted as «not in the ledger»
  # and was caught as a ghost (measured: `db` in aws-container). The prov.tsv parser was already splitting them,
  # so the defect was two places reading the same cell differently — it was the gate, not the pack.
  sed -i.bak 's#^| `boot` | b.md |#| `pool` · `db` | b.md | `Pool` · `db` — the connection and the ORM handle | client |\
| `boot` | b.md |#' "$fx/pk/multisym/fxpack2/ledger.md" && rm -f "$fx/pk/multisym/fxpack2/ledger.md.bak"
  cat >> "$fx/pk/multisym/fxpack2/PACK.md" <<'FXMS'

<!-- pack-slot: common-imports-axis -->
## Common Imports

```ts
import { db } from '@/db/client'
```
<!-- /pack-slot -->
FXMS
  printf '\n<!-- file: src/db/client.ts -->\n```ts\n// src/db/client.ts\nexport const pool = { end() {} }\nexport const db = { pool }\n```\n' \
    >> "$fx/pk/multisym/fxpack2/resources/b.md"

  # ⑭ a ledger symbol name appears as a word in the **template literal text** of a whole file.
  # While only the two quote kinds were stripped, prose inside backticks read as a module binding use and a correct file
  # was caught as unprocured (measured: `not a Task shape: ${where}` in vanilla).
  printf '\n<!-- file: src/fx-msg.ts -->\n```ts\n// src/fx-msg.ts\nexport function fxMsg(where: string): string {\n  return `not a boot shape: ${where}`\n}\n```\n' \
    >> "$fx/pk/tpllit/fxpack2/resources/b.md"

  # ⑪ an unfinished pack: a resource pack.json declares has no real file.
  # A pack that froze only L0 (the contract) and had not yet written the resources really was in the repository, and
  # judging possession by «the directory exists» makes it indistinguishable from a finished one, so half a pack gets installed.
  rm -f "$fx/pk/ghostres/fxpack2/resources/b.md"

  # ⑩ harmless: an identical code fence across files is REVIEW, not FAIL (a common import block really exists)
  cat >> "$fx/pk/dupfence/fxpack2/resources/a.md" <<'FXP10'

```ts
import { z } from 'zod'
import { boot } from '@/boot'
import { EnvSchema } from '@/env'
```
FXP10
  cat >> "$fx/pk/dupfence/fxpack2/resources/b.md" <<'FXP11'

```ts
import { z } from 'zod'
import { boot } from '@/boot'
import { EnvSchema } from '@/env'
```
FXP11
  return 0
}

_fx_assert() {
  local dir="$1" want="$2" label="$3"; shift 3
  local out code=0
  out=$(bash "$0" --guide "$dir" "$@" 2>&1) || code=$?
  if [ "$code" -eq "$want" ]; then
    ok "$label → exit $code"
  else
    bad "$label → exit $code (expected $want)" "$(printf '%s' "$out" | grep -E '✗|pass ' | head -3 | tr '\n' ';')"
  fi
}

_fx_build() {
  local fx="$1" b="$1/clean/sample-backend-guide" m
  mkdir -p "$b/resources" || return 1

  cat > "$b/SKILL.md" <<'FXSKILL'
---
name: sample-backend-guide
description: "Self-test fixture backend guide. Use when creating or modifying endpoints, schemas, or tests."
---
<!-- orangekit-guide: generated 2026-01-01 stack=none+none+none+none pkgs=zod@4 -->

## Quick Start

### New Endpoint

- [ ] fix the schema
- [ ] write the handler
- [ ] confirm authentication
- [ ] ownership filter
- [ ] error mapping
- [ ] add tests

### New Schema

- [ ] fix the fields
- [ ] duplicate the constraints
- [ ] migration
- [ ] update the queries
- [ ] confirm the types
- [ ] add tests

## Architecture Overview

A request flows handler → service → repository.

## Directory Structure

routes/ services/ db/ live under src/.

## Core Principles (5 Key Rules)

### 1. Validate input with a schema
Parse it on the first line of the handler.

### 2. Read environment variables only through a validated module
Fail at boot time.

### 3. Enforce ownership in the query condition
Never trust the caller.

### 4. Do not distinguish absence from no permission
No existence leaks.

### 5. Map errors through a code table
Status codes are decided in one place.

## Common Imports

For the default import bundle see resources/a.md.

## HTTP Status Codes & Anti-Patterns

Only these five are used: 400 · 401 · 404 · 409 · 500.

## Navigation Guide

| what you want to do | file to read |
| --- | --- |
| schema·environment variables | `resources/a.md` |
| boot and wiring | `resources/b.md` |
| handlers | `resources/c.md` |
| error handling | `resources/d.md` |
| tests | `resources/e.md` |
| operations | `resources/f.md` |
FXSKILL

  cat > "$b/resources/a.md" <<'FXA'
# Schema and environment variables

```ts
import { z } from 'zod'

export const EnvSchema = z.object({
  PORT: z.string(),
  DATABASE_URL: z.string(),
})
```

```ts
export function connect(url) {
  return url
}
```

```ts
// ✅ a response outside the contract is turned into BAD_SHAPE — the marker is ✅ and BAD_SHAPE is a contract identifier
export function parseShape(v) {
  return v
}
```

`connect` is used by the boot path in b.md.
FXA

  cat > "$b/resources/b.md" <<'FXB'
# Boot

```ts
import { EnvSchema, connect } from '@/a'

export function boot(env) {
  return connect(env.DATABASE_URL)
}
```

After validating with `EnvSchema` it listens on `env.PORT`. `boot` is called by c.md.
FXB

  printf '# Handlers\n\nUse the wiring `boot` built as it is. Validate the response with `parseShape` and put `nextCursor` in the list.\n' > "$b/resources/c.md"
  printf '# Error handling\n\nThe code table is in the hub.\n'          > "$b/resources/d.md"
  printf '# Tests\n\nWrite the happy path and a validation failure together. Run them with `npm run test`.\n' > "$b/resources/e.md"
  printf '# Operations\n\nThe health check reports ready only after confirming the dependencies.\n' > "$b/resources/f.md"

  cat > "$fx/clean/ledger-ok.md" <<'FXL1'
| symbol | definition file | consumer |
| --- | --- | --- |
| `EnvSchema` | a.md | b.md |
| `connect` | a.md | b.md |
| `boot` | b.md | c.md |
| `parseShape` | a.md | c.md |
FXL1
  cat > "$fx/clean/ledger-bad.md" <<'FXL2'
| symbol | definition file | consumer |
| --- | --- | --- |
| `EnvSchema` | a.md | b.md |
| `connect` | a.md | b.md |
| `boot` | b.md | d.md |
| `parseShape` | a.md | c.md |
FXL2
  cat > "$fx/clean/ledger-short.md" <<'FXL3'
| symbol | definition file | consumer |
| --- | --- | --- |
| `EnvSchema` | a.md | b.md |
| `connect` | a.md | b.md |
FXL3

  for m in dangling envkey envhelper dupexport budget fence section nostamp leak; do
    mkdir -p "$fx/$m" && cp -R "$b" "$fx/$m/" || return 1
  done

  printf '| missing file | `resources/missing.md` |\n' >> "$fx/dangling/sample-backend-guide/SKILL.md"
  printf '\n```ts\nconst timeout = env.REQUEST_TIMEOUT_MS\n```\n' >> "$fx/envkey/sample-backend-guide/resources/b.md"
  # A key declared through a helper call is consumed as is — this is correct code, so it must pass
  printf '\n```ts\nexport const ms = (max) => max\nexport const Extra = {\n  DRAIN_DELAY_MS: ms(60000),\n}\n```\n' >> "$fx/envhelper/sample-backend-guide/resources/a.md"
  printf '\n```ts\nconst drain = env.DRAIN_DELAY_MS\n```\n' >> "$fx/envhelper/sample-backend-guide/resources/b.md"
  printf '\n```ts\nexport function connect(url, options) {\n  return url\n}\n```\n' >> "$fx/dupexport/sample-backend-guide/resources/c.md"
  awk 'BEGIN{ for (i=0; i<310; i++) print "padding line — creates a budget overrun" }' >> "$fx/budget/sample-backend-guide/resources/d.md"
  printf '\n```ts\nconst unclosed = 1\n' >> "$fx/fence/sample-backend-guide/resources/e.md"
  sed -i.bak 's/^## Common Imports$/The default import bundle:/' "$fx/section/sample-backend-guide/SKILL.md" && rm -f "$fx/section/sample-backend-guide/SKILL.md.bak"
  sed -i.bak '/orangekit-guide: generated/d' "$fx/nostamp/sample-backend-guide/SKILL.md" && rm -f "$fx/nostamp/sample-backend-guide/SKILL.md.bak"
  printf '\nRun the migration with prisma migrate.\n' >> "$fx/leak/sample-backend-guide/resources/f.md"
  mkdir -p "$fx/leakword" "$fx/leakcap"
  cp -R "$fx/clean/sample-backend-guide" "$fx/leakword/" && cp -R "$fx/clean/sample-backend-guide" "$fx/leakcap/"
  printf '\nThe type system cannot express this invariant, so the test pins it.\n' >> "$fx/leakword/sample-backend-guide/resources/f.md"
  printf '\nMiddleware order is the same as in Express.\n' >> "$fx/leakcap/sample-backend-guide/resources/f.md"

  # ── pack/seam fixtures (the new surface that appeared in v3.12.0) ──
  # Shipping the axis pack and the seam separately creates two new classes of defect:
  #   ① a symbol the pack consumes but the seam does not define (the pack example becomes unrunnable)
  #   ② the seam breaking a cross-file invariant the pack declared (26 of the 57 measured audit findings were this class)
  # Both prove their blocking. Whether the exception column actually takes effect is proven alongside —
  # if the exception is ignored, legitimate code is stamped a permanent violation and the gate becomes unusable.
  local pk="$fx/pg/backend/fxpack"
  mkdir -p "$pk" || return 1

  cat > "$pk/ledger.md" <<'FXLED'
## requires
| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `connect` | project | boot path | owned by the seam |
| `neverProvided` | project | a symbol the seam does not give | for the block proof |
FXLED

  cat > "$pk/ledger-ok.md" <<'FXLEDOK'
## requires
| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `connect` | project | boot path | owned by the seam |
| `SomeGeneratedType` | generated | a tool artifact | to prove the check exclusion |
FXLEDOK

  cat > "$pk/policies.md" <<'FXPOL'
## Machine checks
| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `zod-present` | require | guide | `from 'zod'` | — | `import { z } from 'zod'` | `import { v } from 'valibot'` | the schema library is pinned |
FXPOL

  cat > "$pk/policies-forbid.md" <<'FXPOLV'
## Machine checks
| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-zod` | forbid | guide | `from 'zod'` | — | `import { z } from 'zod'` | `export { s } from 'zod'` | for the block proof |
FXPOLV

  cat > "$pk/policies-require-missing.md" <<'FXPOLR'
## Machine checks
| id | verdict | scope | regex | exception file | proof example | description |
| --- | --- | --- | --- | --- | --- | --- |
| `must-have-graphql` | require | guide | `from 'graphql'` | — | `import { gql } from 'graphql'` | for the block proof |
FXPOLR

  cat > "$pk/policies-excepted.md" <<'FXPOLE'
## Machine checks
| id | verdict | scope | regex | exception file | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-zod` | forbid | guide | `from 'zod'` | `a.md` | `import { z } from 'zod'` | `export { s } from 'zod'` | excepting the only file it appears in must make it pass |
FXPOLE

  printf '{ "axis": "backend", "pack": "backend/fxpack", "packFiles": ["a.md"], "seamFiles": ["b.md","c.md","d.md","e.md","f.md"] }\n' > "$fx/clean/asm.json"
  return 0
}

# ════════════════════════════════════════════════════════════════════
MODE=""; GUIDE=""; LEDGER=""; FORBID=""; PM=""; GENERATED=0
CONTRACT=""; FE=""; BE=""; ASSEMBLY=""; CLAIMS_OUT=""; PACK_LEDGER_NAME="ledger.md"; PACK_POLICIES_NAME="policies.md"
REGRESS=0
# Word splitting happens **only at newlines and tabs**. There are more than 20 places that expand a file list
# (`$(guide_files …)` · `$FILES`) unquoted, and with the default IFS a space in the path (`My Projects` · a Windows user home)
# split it, so the gate read 0 files and **passed everything** (measured: reported 0 version claims · no tests).
# Loops that built a space-separated list were switched to newlines — new loops do not use space-separated lists either.
IFS=$'\n\t'
PLUGIN_GUIDES="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/guides"

[ $# -eq 0 ] && { printf "no arguments (see --help)\n" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --guide)     MODE="guide"; GUIDE="${2:-}"; shift 2 || exit 2 ;;
    --pack)      MODE="pack";  GUIDE="${2:-}"; shift 2 || exit 2 ;;
    --pair)      MODE="pair"; shift ;;
    --self-test) MODE="selftest"; shift ;;
    --regress)   MODE="selftest"; REGRESS=1; shift ;;
    --contract)  CONTRACT="${2:-}"; shift 2 || exit 2 ;;
    --frontend)  FE="${2:-}"; shift 2 || exit 2 ;;
    --backend)   BE="${2:-}"; shift 2 || exit 2 ;;
    --ledger)    LEDGER="${2:-}"; shift 2 || exit 2 ;;
    --forbid)    FORBID="${2:-}"; shift 2 || exit 2 ;;
    --pm)        PM="${2:-}"; shift 2 || exit 2 ;;
    --assembly)  ASSEMBLY="${2:-}"; shift 2 || exit 2 ;;
    --claims-out) CLAIMS_OUT="${2:-}"; shift 2 || exit 2 ;;
    --plugin-guides) PLUGIN_GUIDES="${2:-}"; shift 2 || exit 2 ;;
    --pack-ledger-name)   PACK_LEDGER_NAME="${2:-}"; shift 2 || exit 2 ;;   # --self-test only
    --pack-policies-name) PACK_POLICIES_NAME="${2:-}"; shift 2 || exit 2 ;; # --self-test only
    --generated) GENERATED=1; shift ;;
    -h|--help)   sed -n '2,28p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
    *)           printf "unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  guide) [ -n "$GUIDE" ] || { printf -- "--guide <directory> is required\n" >&2; exit 2; }; run_guide "$GUIDE" ;;
  pack)  [ -n "$GUIDE" ] || { printf -- "--pack <directory> is required\n" >&2; exit 2; };  run_pack "$GUIDE" ;;
  pair)  run_pair ;;
  selftest) run_self_test ;;
  *)     printf "no mode: --guide · --pack · --pair (see --help)\n" >&2; exit 2 ;;
esac

printf "\n${C_D}────────────────────────────────────────────${C_0}\n"
printf "  pass %s · ${C_Y}WARN %s${C_0} · ${C_C}REVIEW %s${C_0} · ${C_R}FAIL %s${C_0}\n\n" "$PASS" "$WARN" "$REVIEW" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
