#!/bin/bash
# scripts/doctor.sh — orangekit-product self-verification
#
# Designed on the assumption that the project has no CI. So this script either
# **rides along on commands the user already types (pnpm build/test)** or is invoked directly.
#
#   doctor.sh --fast       structural checks (hook spec, rule budget, dangling, manifest)
#   doctor.sh --self-test  inject a real per-event stdin fixture into each hook → compare effects
#   doctor.sh --graph      verify workflow.graph.json (unreachable nodes/edges)
#   doctor.sh --usage      hook heartbeat · skill invocations · edge traversal
#   doctor.sh --lessons    lessons.md category tally + promotion candidates · false-positive narrowing candidates (per guard)
#   doctor.sh --consumer   consumer-layout proof (cache path + running hooks in an empty/pre-first-commit project)
#   doctor.sh --inventory  per-area asset inventory (no verdicts — the input to /harness-evaluation)
#   doctor.sh --all        all of the above (fast · self-test · graph · consumer · usage · lessons · inventory)
#   doctor.sh              = --fast --graph
#
#   --root <dir>           replace the plugin root under test (self-test only)
#
# Exit codes: 0 = pass, 1 = failing items present

set -uo pipefail   # no -e: run every check to the end so the report is complete

# There are two roots — merging them breaks the plugin structure checks inside a consumer project:
#   PLUGIN_ROOT: plugin asset checks (fast/graph/self-test) — the script's own location is the truth
#   PROJ:        project state checks (usage/lessons) — hook logs and lessons live on the consumer side
# --root <dir> : self-test only. Runs the static checks against a synthetic plugin tree.
# Without it the blocking power of the static checks cannot be proven reproducibly (a proof planted
# and deleted by hand does not survive for the next person).
DOCTOR_ROOT_OVERRIDE=""
_args=(); while [ $# -gt 0 ]; do
  case "$1" in
    --root) DOCTOR_ROOT_OVERRIDE="${2:-}"; shift 2 ;;
    *) _args+=("$1"); shift ;;
  esac
done
set -- ${_args+"${_args[@]}"}

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "$DOCTOR_ROOT_OVERRIDE" ] && PLUGIN_ROOT="$(cd "$DOCTOR_ROOT_OVERRIDE" 2>/dev/null && pwd)"
[ -n "$DOCTOR_ROOT_OVERRIDE" ] && [ -z "$PLUGIN_ROOT" ] && { printf -- '--root path not found: %s\n' "$DOCTOR_ROOT_OVERRIDE" >&2; exit 2; }
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT="$PLUGIN_ROOT"
cd "$ROOT" || exit 2

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_D=""; C_0=""; }

ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; }

num() { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

# The T0 budget is canonical **in this one place**. After the check rose to 42 the card body was left quoting "40 lines" —
# the numbers a document quotes are compared against this constant by "declared ↔ real" (evaluation v6 · E-25).
T0_BUDGET=42

# There are three skill roots — the consumer harness (skills/) · the marketing plugin (marketing/skills/) ·
# the harness-authoring plugin (harness/skills/). The consumer does not install the latter two.
# **Hygiene checks look at all three**: if a split creates a blind spot, that split is not an improvement.
# Conversely the description budget and the "declared ↔ real" skill count count **only skills/** —
# because that is all that is resident in a consumer session. The graph is the exception and includes
# harness/skills: harness-evaluation is a node of the feedback loop, and dropping it cuts that loop.
skill_roots() { local d; for d in skills marketing/skills harness/skills; do [ -d "$d" ] && printf '%s\n' "$d"; done; }
skill_dirs()  { local r; while IFS= read -r r; do find "$r" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; done < <(skill_roots); }
skill_mds()   { local d; while IFS= read -r d; do [ -f "$d/SKILL.md" ] && printf '%s\n' "$d/SKILL.md"; done < <(skill_dirs); }
_shared_copies() { local d; while IFS= read -r d; do grep -rl 'orangekit-doctor: shared-copy' "$d/references" "$d/resources" 2>/dev/null; done < <(skill_dirs); }

# Keep only code lines — comments and user-facing message strings are not what is being checked.
# (A linter detecting its own error messages is a defect in the linter)
# BSD sed does not support \| alternation in BRE → -E (ERE) is mandatory
code_lines() {
  sed -E -e 's/^[[:space:]]*#.*$//' \
         -e '/^[[:space:]]*(bad|ok|warn|sec|printf|echo)[[:space:]]/d' "$1" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════
# Static-check fixture helpers (--self-test only)
# ════════════════════════════════════════════════════════════════════

# The minimal synthetic plugin tree that the static checks pass on. Other checks (manifest·hooks etc.)
# may fail here without harm — the verdict is made **only from the presence or absence of a specific message**.
_fx_static_tree() {
  local T="$1"
  mkdir -p "$T/rules" "$T/templates" "$T/skills/sample" "$T/skills/orangekit-init" "$T/scripts" || return 1

  printf -- '<!-- orangekit-rule-version: 0.0.1 -->\n# Routing\n\n| Phase | Condition |\n| --- | --- |\n' \
    > "$T/rules/workflow-routing.md"
  printf -- '---\npaths:\n  - "src/**"\n---\n<!-- orangekit-rule-version: 0.0.1 -->\n# Code\n' \
    > "$T/rules/code-change.md"

  printf -- '# CLAUDE.md\n\n## Harness\n\nRouting is loaded by `.claude/rules/workflow-routing.md`.\n' \
    > "$T/templates/CLAUDE.md.hbs"

  printf -- '---\nname: sample\ndescription: x\n---\nbash ${CLAUDE_SKILL_DIR}/scripts/x.sh\n' \
    > "$T/skills/sample/SKILL.md"

  # The card table matches the real count in rules/ (2). orangekit-init is manual in the graph, so its frontmatter
  # also carries disable-model-invocation (G8 compares the two).
  printf -- '---\nname: orangekit-init\ndescription: x\ndisable-model-invocation: true\n---\ninstall-rules\n\n| File | Load condition |\n| --- | --- |\n| `workflow-routing.md` | always |\n| `code-change.md` | src |\n\nPresets: alpha · beta · none\n' \
    > "$T/skills/orangekit-init/SKILL.md"

  # Minimal assets for the name-list comparison. The baseline is the state where the 2 preset axes and the
  # 1 pre-built seam pair are all listed in the documents. No seam.json is placed — placing one would point the
  # "seam's pack reference exists" check at a pack that is absent and turn the baseline red. _seams_in only looks at directory names, so this is enough.
  mkdir -p "$T/presets/frontend" "$T/presets/backend" "$T/guides/seams/alpha+beta" \
           "$T/docs" "$T/skills/stack-guide-generator/assets" || return 1
  printf -- '{"axis":"frontend","name":"alpha"}\n' > "$T/presets/frontend/alpha.json"
  printf -- '{"axis":"frontend","name":"none"}\n'  > "$T/presets/frontend/none.json"
  printf -- '{"axis":"backend","name":"beta"}\n'   > "$T/presets/backend/beta.json"
  printf -- '{"axis":"backend","name":"none"}\n'   > "$T/presets/backend/none.json"
  # README is compared against the full list of skill names — write all 3 fixture skills to match the baseline
  printf -- '# fx\n\nPresets: alpha · beta · none\n\nPre-built: `alpha` × `beta`\n\nSkills: sample · orangekit-init · stack-guide-generator\n' \
    > "$T/README.md"
  printf -- '# Presets\n\nalpha · beta · none\n' > "$T/docs/presets.md"
  printf -- '# Getting Started\n\nalpha / beta / none\n\nShips `alpha` × `beta`.\n' \
    > "$T/docs/getting-started.md"
  printf -- '# Specification\n\nThere is currently 1 pre-built pair (`alpha`×`beta`).\n' \
    > "$T/skills/stack-guide-generator/assets/guide-skeleton.md"

  # The two places compared by "declared ↔ real". The baseline is the counts written here matching this
  # tree's **real** assets (hooks 1 · rules 2 · skills 3 · nodes 3 · edges 0 · presets 2+2 · packs 0+0).
  # The real hook count comes from hooks.json, so that file must exist for the comparison to actually run —
  # without it the check is skipped as "undecidable", and a skipped check is not a proven check.
  mkdir -p "$T/hooks" "$T/.claude-plugin" || return 1
  printf -- '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/scripts/x.sh"}]}]}}\n' \
    > "$T/hooks/hooks.json"
  printf -- '#!/bin/bash\nexit 0\n' > "$T/scripts/x.sh"
  printf -- '{"plugins":[{"name":"fx","description":"1 hooks that verify themselves. 3 skills + axis guide packs (frontend 0 · backend 0), 2-axis presets (frontend 2 · backend 2)."}]}\n' \
    > "$T/.claude-plugin/marketplace.json"
  printf -- '# Anatomy\n\nReal counts — hooks 1 · T1 rule cards 2 · skills 3 · graph nodes 3 · edges 1\n' \
    > "$T/docs/harness-anatomy.md"

  # Graph: declares 2 skills + 1 hook as nodes. orangekit-init is manual (+ frontmatter dmi), sample is reached
  # by an inbound edge — making sample manual would make the "manual-only declaration ↔ resident flag" fixture
  # demand dmi and the two would collide. The hook node corresponds to the x.sh that hooks.json registers —
  # since the "undeclared hook" check exists, a tree that registers without declaring is **not a defect-free baseline**.
  cat > "$T/workflow.graph.json" <<'FXG'
{
  "version": "0.0.1",
  "nodes": [
    { "id": "sample", "kind": "skill", "path": "skills/sample/SKILL.md" },
    { "id": "orangekit-init", "kind": "skill", "path": "skills/orangekit-init/SKILL.md", "manual": true },
    { "id": "x", "kind": "hook", "path": "scripts/x.sh", "event": "SessionStart", "entry": true }
  ],
  "edges": [ { "from": "orangekit-init", "to": "sample", "cond": "fx" } ]
}
FXG
  return 0
}

# Plant one defect and judge. **Validity comes first.**
#   $1 temp root  $2 name  $3 file the defect goes into (tree-relative)  $4 defect marker (grep -E)
#   $5 expected message  $6 planting command ($T = tree path)
_fx_static_case() {
  local sfx="$1" name="$2" file="$3" mark="$4" want="$5" plant="$6" mode="${7:---fast}"
  local T="$sfx/$name"
  rm -rf "$T"; cp -R "$sfx/base" "$T" 2>/dev/null || { bad "fixture copy failed: $name"; return; }

  # Do not hide a planting failure — hiding it makes the cause of "fixture invalid" unknowable.
  local perr; perr=$(eval "$plant" 2>&1 >/dev/null)

  # ① Validity — did what we meant to plant actually go in? Without this step a no-op proof looked like a pass.
  if ! grep -qE "$mark" "$T/$file" 2>/dev/null; then
    bad "fixture invalid: $name" "defect marker '$mark' is not in $file — the verdict below is meaningless${perr:+ · plant error: $perr}"
    return
  fi

  # ② Detection — in that state, does the check emit the expected message?
  local out; out=$(bash "$0" "$mode" --root "$T" 2>&1)
  # Show the reason on **both** the success and failure paths. Putting it only on the success branch makes it
  # silent exactly when it is needed — a false negative is precisely when you need to see "then what caught instead".
  # Fixtures judged by a warning (!) need their reason visible too: looking only at ✗ makes it impossible to
  # confirm "was it caught for the intended reason" for warn-based fixtures.
  local why=""
  [ -n "${ORANGEKIT_FX_WHY:-}" ] && why=$(printf '%s' "$out" | grep -E '✗|!' | head -2 | sed 's/^  *//' | tr '\n' ';')
  if printf '%s' "$out" | grep -q "$want"; then
    ok "$name → '$want' detected"
  else
    bad "$name → '$want' not detected" "a defect was planted and the check passed it — false negative"
  fi
  [ -n "$why" ] && printf "      ${C_D}%s${C_0}\n" "$why"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# --fast : structural checks
# ════════════════════════════════════════════════════════════════════
run_fast() {
  printf "\n${C_D}orangekit doctor --fast${C_0}  (plugin: %s)\n" "$ROOT"

  # ── 1. forbidden-idiom lint (§1.1 detection) ──
  sec "forbidden idioms (causes of silent failure)"

  local n
  n=$(grep -rl 'BASH_SOURCE\[0\]}")/\.\./\.\.' scripts/ 2>/dev/null | grep -v '/lib/' | wc -l | tr -d ' ')
  n=$(num "$n")
  if [ "$n" -gt 0 ]; then
    bad "relative root computed from BASH_SOURCE: ${n} files" \
        "$(grep -rl 'BASH_SOURCE\[0\]}")/\.\./\.\.' scripts/ 2>/dev/null | grep -v '/lib/' | tr '\n' ' ')"
    printf "      ${C_D}→ points outside the repo once the plugin is distributed. orangekit_root() is required${C_0}\n"
  else
    ok "no relative root computed from BASH_SOURCE"
  fi

  local hits="" n=0
  for f in scripts/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in */lib/*) continue;; esac
    if code_lines "$f" | grep -q '|| *echo *"\?0"\?'; then
      hits="$hits $(basename "$f")"; n=$((n+1))
    fi
  done
  if [ "$n" -gt 0 ]; then
    bad "'|| echo 0' fallback: ${n} files" "$hits — 2 lines land where 1 was expected and integer comparison collapses. orangekit_num() is required"
  else
    ok "no '|| echo 0' fallback"
  fi

  # Unguarded glob pipe — `ls dir/*.md | wc -l` makes ls exit 1 when nothing matches,
  # and the hook's pipefail+ERR trap kills the whole script. It dies precisely "when the count is 0",
  # so the code meant to report 0 goes silent in exactly that situation. `{ ... || true; }` is required.
  # The target is **only scripts that carry an ERR trap**: hooks that source common.sh, or an installer
  # that turns on `set -e`/`-Eeuo` itself. Check scripts (doctor itself) have no `-e`, so a pipe failure
  # does not kill them and they are excluded — including them is a false positive, and false positives neuter the lint.
  local gl="" n=0
  for f in scripts/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in */lib/*) continue;; esac
    # **Look at an actual source, not a mention.** The filter used to fire when a file merely held
    # lib/common.sh as a string, so when doctor.sh passed that path to a subprocess in the rotation-invariant
    # fixture it mistook itself for an ERR-trap holder and raised a false positive. The 5 hooks and 2 installers still match.
    grep -qE '^set -[A-Za-z]*e|^[[:space:]]*(source|\.)[[:space:]]+[^|]*lib/common\.sh' "$f" 2>/dev/null || continue
    while IFS= read -r line; do
      case "$line" in *'|| true'*|*'||true'*) continue;; esac
      gl="$gl $(basename "$f")"; n=$((n+1)); break
    done < <(code_lines "$f" | grep -E 'ls[[:space:]][^|]*\*[^|]*\|')
  done
  if [ "$n" -gt 0 ]; then
    bad "unguarded glob pipe: ${n} files" "$gl — on no match ls exits 1 → pipefail+ERR trap kills the hook. { ... || true; } is required"
  else
    ok "no unguarded glob pipe"
  fi

  # git calls that do not verify HEAD — exit 128 in a repo with 0 commits (right after git init).
  # A new project's first session is exactly that state. Check first with rev-parse -q --verify HEAD.
  local gh="" n=0
  for f in scripts/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in */lib/*) continue;; esac
    code_lines "$f" | grep -qE 'git (log|describe)[[:space:]]|git rev-parse[[:space:]]+(--abbrev-ref[[:space:]]+)?HEAD' || continue
    grep -q 'rev-parse -q --verify HEAD' "$f" 2>/dev/null && continue
    gh="$gh $(basename "$f")"; n=$((n+1))
  done
  if [ "$n" -gt 0 ]; then
    bad "git calls without HEAD verification: ${n} files" "$gh — exit 128 in a repo with 0 commits → the hook dies. Check first with git rev-parse -q --verify HEAD"
  else
    ok "no git calls without HEAD verification"
  fi

  # BSD BRE alternation — grep/sed on macOS do not support \| in BRE.
  # It **does not fail, it silently matches nothing**, so the check passes while catching nothing.
  # Use -E (ERE) and write it with |.
  local bre="" n=0
  for f in scripts/*.sh skills/*/scripts/*.sh marketing/skills/*/scripts/*.sh harness/skills/*/scripts/*.sh; do
    [ -f "$f" ] || continue
    code_lines "$f" 2>/dev/null | grep -qE "(grep|sed)([[:space:]]+-[a-df-zA-Z]+)*[[:space:]]+'[^']*\\\\\\|" || continue
    bre="$bre $(basename "$f")"; n=$((n+1))
  done
  if [ "$n" -gt 0 ]; then
    bad "BRE alternation unsupported on BSD (\\|): ${n} files" "$bre — silently matches nothing on macOS. Use grep -E / sed -E with |"
  else
    ok "no BRE alternation unsupported on BSD"
  fi

  # ── 2. hook output spec (§1.2 detection) ──
  sec "hook output spec (fields supported per event)"

  local hooks_json="hooks/hooks.json"
  if [ ! -f "$hooks_json" ]; then
    bad "hooks/hooks.json missing"
  else
    # Does a script registered on the Stop event write decision/reason?
    local stop_scripts
    stop_scripts=$(command -v jq >/dev/null 2>&1 && jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null | grep -oE '[a-z-]+\.sh' || true)
    local viol=0
    for s in $stop_scripts; do
      [ -f "scripts/$s" ] || continue
      if code_lines "scripts/$s" | grep -qE '"(decision|reason)"[[:space:]]*:'; then
        bad "Stop hook '$s' uses unsupported fields (decision/reason)" \
            "Stop supports only additionalContext/continue/systemMessage. This output is silently ignored"
        viol=$((viol+1))
      fi
    done
    [ "$viol" -eq 0 ] && [ -n "$stop_scripts" ] && ok "Stop hook output spec conformant"

    # For PreCompact, plain stdout does not become context
    local pc_scripts
    pc_scripts=$(command -v jq >/dev/null 2>&1 && jq -r '.hooks.PreCompact[]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null | grep -oE '[a-z-]+\.sh' || true)
    for s in $pc_scripts; do
      [ -f "scripts/$s" ] || continue
      if ! grep -q 'additionalContext' "scripts/$s" 2>/dev/null; then
        bad "PreCompact hook '$s' does not use additionalContext" \
            "plain PreCompact stdout does not enter the context (only SessionStart/UserPromptSubmit do)"
      else
        ok "PreCompact hook '$s' output spec conformant"
      fi
    done

  fi

  # ── 3. hook registration ↔ file existence ──
  sec "hook wiring"
  if [ -f "$hooks_json" ] && command -v jq >/dev/null 2>&1; then
    local missing=0 total=0
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      total=$((total+1))
      local f; f=$(printf '%s' "$cmd" | grep -oE 'scripts/[a-z0-9./-]+\.sh' | head -1)
      [ -n "$f" ] && [ ! -f "$f" ] && { bad "registered hook file missing: $f"; missing=$((missing+1)); }
    done < <(jq -r '.hooks | to_entries[] | .value[]?.hooks[]?.command // empty' "$hooks_json" 2>/dev/null)
    [ "$missing" -eq 0 ] && ok "all ${total} registered hooks exist"
  fi

  # ── 4. rule reachability (§1.3 detection) ──
  sec "rule reachability"

  local rules_lines=0
  [ -d rules ] && rules_lines=$(num "$(cat rules/*.md 2>/dev/null | wc -l | tr -d ' ')")

  if [ "$rules_lines" -gt 0 ]; then
    # Does the plugin manifest have a rules component? (It does not — not a supported type)
    local has_rules_component=0
    [ -f .claude-plugin/plugin.json ] && grep -q '"rules"' .claude-plugin/plugin.json 2>/dev/null && has_rules_component=1

    # Does orangekit-init install rules?
    local installs=0
    if [ -f skills/orangekit-init/SKILL.md ]; then
      grep -qE 'CLAUDE_PLUGIN_ROOT.*/rules/|rules/.*→.*\.claude/rules|\.claude/rules/.*install|install-rules' \
        skills/orangekit-init/SKILL.md 2>/dev/null && installs=1
    fi

    if [ "$has_rules_component" -eq 0 ] && [ "$installs" -eq 0 ]; then
      bad "no reach path for the ${rules_lines} lines in rules/ to get to a project" \
          "the plugin manifest has no 'rules' component type, and orangekit-init has no install step either"
    else
      ok "reach path secured for the ${rules_lines} lines in rules/ (orangekit-init install step)"
    fi
  fi

  # dangling .claude/rules references
  #
  # A document such as a migration guide that lists "things to remove" legitimately mentions
  # paths that do not exist. Rather than quietly excluding by filename, an explicit marker is required:
  #   <!-- orangekit-doctor: allow-stale-refs -->
  local scan_files=()
  while IFS= read -r sf; do
    grep -q 'orangekit-doctor: allow-stale-refs' "$sf" 2>/dev/null || scan_files+=("$sf")
  done < <(find rules skills agents templates -name '*.md' -type f 2>/dev/null)

  local dang=0 checked=0 dlist=""
  for p in $( [ ${#scan_files[@]} -gt 0 ] && grep -hoE '\.claude/rules/[a-z0-9-]+\.md' "${scan_files[@]}" 2>/dev/null | sort -u); do
    checked=$((checked+1))
    local base; base=$(basename "$p")
    if [ ! -f "rules/$base" ] && [ ! -f ".claude/rules/$base" ]; then
      dang=$((dang+1)); dlist="$dlist $base"
    fi
  done
  if [ "$dang" -gt 0 ]; then
    bad "dangling .claude/rules references ${dang}/${checked}" "do not exist:$dlist"
  elif [ "$checked" -gt 0 ]; then
    ok "\.claude/rules references — all ${checked} exist"
  fi

  # The always-loaded axis (§R1) — Claude Code loads every .claude/rules/*.md without `paths:`
  # unconditionally, every session. Task routing and reference freshness are needed "before any file
  # has been opened", so they must not be conditional. The moment paths is attached they silently stop appearing.
  local always=""
  for rc in rules/*.md; do
    [ -f "$rc" ] || continue
    grep -q '^paths:' "$rc" 2>/dev/null || always="$always $(basename "$rc")"
  done
  if [ -z "$always" ]; then
    bad "no always-loaded rule card" "every card in rules/ is paths-conditional — task routing does not reach the start of a session"
  elif [ ! -f rules/workflow-routing.md ] || grep -q '^paths:' rules/workflow-routing.md 2>/dev/null; then
    bad "workflow-routing.md is not always-loaded" "delete its paths — the moment it is attached the card stops appearing at session start"
  else
    ok "always-loaded cards:$always"
  fi

  # If the card table in orangekit-init Step 7 diverges from what is really in rules/, the user loses the
  # basis for judging whether the install finished. The table is a copy, so report the moment the counts split.
  if [ -f skills/orangekit-init/SKILL.md ]; then
    local nrules ntable
    nrules=$(num "$(ls -1 rules/*.md 2>/dev/null | wc -l | tr -d ' ')")
    ntable=$(num "$(grep -cE '^\| `[a-z-]+\.md` \|' skills/orangekit-init/SKILL.md 2>/dev/null)")
    if [ "$nrules" -ne "$ntable" ]; then
      bad "orangekit-init card table ${ntable} ≠ rules/ ${nrules}" "the install guidance diverges from the real assets"
    else
      ok "orangekit-init card table ${ntable} = rules/ real"
    fi
  fi

  # Prevent a split canonical source — if the Phase table comes back into .hbs it diverges from the card
  if [ -f templates/CLAUDE.md.hbs ] && grep -qE '^\| *P0|^\| *Phase *\|' templates/CLAUDE.md.hbs 2>/dev/null; then
    bad "Phase table reappeared in CLAUDE.md.hbs" "the canonical source is rules/workflow-routing.md — a copy is a source of drift"
  else
    ok "Phase table canonical source is single (rules/workflow-routing.md)"
  fi

  # T0 budget — a machine enforces the 42-line ceiling the comment in operating-contract.md promises.
  # Going over is not "delete something" but a decision point — present the options and the real difference, and let a person choose.
  local t0="templates/operating-contract.md"
  if [ -f "$t0" ]; then
    local t0n; t0n=$(num "$(wc -l < "$t0")")
    if [ "$t0n" -le "$T0_BUDGET" ]; then
      ok "T0 operating contract ${t0n}/${T0_BUDGET} lines"
    else
      bad "T0 operating contract ${t0n} lines — exceeds budget ${T0_BUDGET} lines" "$(printf 'Do not delete the norms. Pick one of the three below — each loses something different.\n      1) move it down to a T1 card  — reach kept, always-on lost (it appears only when you touch that path)\n      2) rewrite it shorter         — always-on kept, information at risk of being shaved\n      3) raise the budget           — both kept, the per-session cost grows (raise this check'"'"'s %s too)' "$T0_BUDGET")"
    fi

    # When a normative clause disappears from T0 it propagates silently — a check that only looks at line count passes a deletion.
    # These clauses are declared canonical and quoted by: orangekit-planner · reversibility · harness-anatomy (2)
    local t0miss=""
    for _a in 'Reversibility classification' 'Work entry' 'Minimal change' 'Verification' 'Decision point' 'Language'; do
      grep -qF -- "**${_a}**" "$t0" 2>/dev/null || t0miss="$t0miss ${_a}"
    done
    if [ -n "$t0miss" ]; then
      bad "normative clauses disappeared from T0:$t0miss" "there are places that declare these clauses canonical and quote them — to delete one, fix the quoting sites with it"
    else
      ok "all 6 T0 normative clauses present"
    fi

    # T0's response-language placeholder ↔ session-brief's substituter.
    # **Either both exist or neither does.** With only one, it breaks silently in opposite directions:
    #   placeholder only → `{{RESPONSE_LANGUAGE}}` leaks into the context verbatim every session
    #   substituter only → T0 pins the language and the project setting never reaches it
    # The latter was the state up to v3.25 — even with language in the config, T0's Korean won.
    local t0ph=0 sbsub=0
    grep -qF '{{RESPONSE_LANGUAGE}}' "$t0" 2>/dev/null && t0ph=1
    grep -qF '{{RESPONSE_LANGUAGE}}' scripts/session-brief.sh 2>/dev/null && sbsub=1
    if [ "$t0ph" -eq 1 ] && [ "$sbsub" -eq 1 ]; then
      ok "response-language placeholder ↔ substituter are consistent"
    elif [ "$t0ph" -eq 1 ]; then
      bad "nothing to substitute the T0 placeholder" "session-brief.sh has no {{RESPONSE_LANGUAGE}} substitution — the placeholder leaks into the context every session"
    elif [ "$sbsub" -eq 1 ]; then
      bad "substituter exists but T0 has no placeholder" "the **Language** clause of operating-contract.md is pinning the language — the project setting does not reach it"
    else
      warn "response language is pinned in T0" "the project cannot choose its language"
    fi

    # Language-list drift — every code init offers must appear in both the hbs branches and the schema examples.
    # If even one is missing, only projects that picked that language see a raw code in CLAUDE.md.
    local lmiss="" _l
    for _l in ko en id vi; do
      grep -qF "\"$_l\"" templates/CLAUDE.md.hbs 2>/dev/null || lmiss="$lmiss hbs:$_l"
      grep -qF "\"$_l\"" schema/orangekit.config.schema.json 2>/dev/null || lmiss="$lmiss schema:$_l"
      grep -qF "\`$_l\`" skills/orangekit-init/SKILL.md 2>/dev/null || lmiss="$lmiss init:$_l"
    done
    if [ -n "$lmiss" ]; then
      bad "language lists disagree:$lmiss" "the init options · the CLAUDE.md.hbs branches · the schema examples must be the same three"
    else
      ok "language lists agree (init ↔ hbs ↔ schema)"
    fi
  else
    bad "T0 operating contract file missing: $t0"
  fi

  # Rule-card version stamp — without it install-rules reads 0.0.0 and skips the update forever
  local nostamp=""
  for rf in rules/*.md; do
    [ -f "$rf" ] || continue
    grep -q 'orangekit-rule-version:' "$rf" 2>/dev/null || nostamp="$nostamp $(basename "$rf")"
  done
  if [ -n "$nostamp" ]; then
    bad "rule cards without a version stamp:$nostamp" "install-rules.sh cannot decide whether to update"
  else
    ok "rule-card version stamps complete"
  fi

  # card → reference link existence (the reach path of progressive loading)
  # A large card moves its body down into references/ and points at it with a link. If the link breaks,
  # the model is pointed at a "file it cannot read" and that knowledge silently fails to arrive.
  local rdang=0 rchecked=0 rc rlnk
  for rc in "$ROOT"/rules/*.md; do
    [ -f "$rc" ] || continue
    while IFS= read -r rlnk; do
      [ -z "$rlnk" ] && continue
      rchecked=$((rchecked+1))
      [ -f "$ROOT/${rlnk#../}" ] || { bad "$(basename "$rc") → $rlnk missing" "progressive loading is cut"; rdang=$((rdang+1)); }
    done < <(grep -ohE '\.\./references/[A-Za-z0-9._/-]+\.md' "$rc" 2>/dev/null | sort -u)
  done
  [ "$rdang" -eq 0 ] && ok "card→reference links — all ${rchecked} exist"

  # Does a § reference point at a section that exists — splitting a large card leaves the moved section's number behind.
  # This is the machine half of "post-change back-trace: look at the side where the name disappeared". A range (§1~8)
  # only looks at the leading number — a verdict tilted toward missing things, not toward calling something absent that is there.
  local sdang=0 schk=0 card secs num
  for card in "$ROOT"/rules/*.md; do
    [ -f "$card" ] || continue
    secs=$(grep -oE '^## [0-9]+\.' "$card" 2>/dev/null | grep -oE '[0-9]+' | tr '\n' ' ')
    [ -z "$secs" ] && continue
    for num in $(grep -ohE '§[0-9]+' "$card" 2>/dev/null | grep -oE '[0-9]+' | sort -u); do
      schk=$((schk+1))
      case " $secs " in *" $num "*) ;; *)
        bad "$(basename "$card") §${num} — that section does not exist" "the number of a section moved during a split was left behind"; sdang=$((sdang+1)) ;;
      esac
    done
    # Apply the same standard to this card's reference directory ("card §N")
    local rdir="$ROOT/references/$(basename "$card" .md)"
    [ -d "$rdir" ] || continue
    for num in $(grep -rohE 'card §[0-9]+' "$rdir" 2>/dev/null | grep -oE '[0-9]+' | sort -u); do
      schk=$((schk+1))
      case " $secs " in *" $num "*) ;; *)
        bad "references/$(basename "$rdir") → card §${num} missing" "the number of a section moved during a split was left behind"; sdang=$((sdang+1)) ;;
      esac
    done
  done
  [ "$sdang" -eq 0 ] && ok "card § references — all ${schk} point at sections that exist"

  # ── 5. agent contract ──
  sec "agent contract"
  local aok=0 atot=0
  for f in agents/*.md; do
    [ -f "$f" ] || continue
    atot=$((atot+1))
    local fm miss=""
    fm=$(awk '/^---$/{c++;next} c==1' "$f" 2>/dev/null)
    for k in name description tools model; do
      printf '%s' "$fm" | grep -q "^${k}:" || miss="$miss $k"
    done
    if [ -n "$miss" ]; then
      bad "$(basename "$f"): missing frontmatter →$miss"
    else
      aok=$((aok+1))
    fi
  done
  [ "$atot" -gt 0 ] && [ "$aok" -eq "$atot" ] && ok "all ${atot} agents have a complete contract"

  # ── 6. skill hygiene ──
  sec "skill description hygiene"
  local stot=0 blk=0 proj=0 sm
  while IFS= read -r sm; do
    [ -z "$sm" ] && continue
    stot=$((stot+1))
    grep -q '^description: |' "$sm" 2>/dev/null && blk=$((blk+1))
    grep -q '(project)' "$sm" 2>/dev/null && proj=$((proj+1))
  done < <(skill_mds)
  [ "$blk" -gt 0 ] && warn "block-scalar description ${blk}/${stot}" "a single line is recommended (it invites sprawl)" || ok "no block scalars"
  [ "$proj" -gt 0 ] && warn "'(project)' suffix ${proj}/${stot}" "meaningless for routing, it only takes up permanent resident cost" || ok "no '(project)' suffix"

  # manual-only declaration ↔ disable-model-invocation agreement (both directions)
  #   A description is resident even if the skill is never invoked (docs/platform-contract.md §2.4).
  #   Writing "manual invocation only" without the flag means **the declaration and the billing disagree** — wasted every session.
  #   Conversely, attaching it to a skill that routing points at for automatic firing means the model can never call it and routing is cut.
  local manual_unflagged="" flagged_routed="" legacy_key="" sname sdir
  while IFS= read -r sm; do
    [ -z "$sm" ] && continue
    sdir=$(dirname "$sm"); sname=$(basename "$sdir")
    local has_flag=0 says_manual=0 fm
    # Look at the **whole frontmatter block**. Looking only at the first `description:` line misses a declaration
    # written on a continuation line of a folded description — manual-only skills went resident through that gap.
    fm=$(awk '/^---$/{n++; if(n==2) exit} n==1' "$sm" 2>/dev/null)
    printf '%s\n' "$fm" | grep -q '^disable-model-invocation:[[:space:]]*true' && has_flag=1
    printf '%s\n' "$fm" | grep -q 'manual invocation only' && says_manual=1
    # A key that is not in the platform contract is silently ignored — whoever declared it believes it took.
    printf '%s\n' "$fm" | grep -q '^trigger:' && legacy_key="$legacy_key $sname"
    if [ "$says_manual" -eq 1 ] && [ "$has_flag" -eq 0 ]; then
      manual_unflagged="$manual_unflagged $sname"
    fi
    if [ "$has_flag" -eq 1 ]; then
      if grep -q "\`/${sname}\`" "$ROOT/rules/workflow-routing.md" 2>/dev/null; then
        flagged_routed="$flagged_routed $sname(routing)"
      elif grep -A3 "\"id\": \"${sname}\"" "$ROOT/workflow.graph.json" 2>/dev/null | grep -q '"phase"'; then
        flagged_routed="$flagged_routed $sname(graph phase)"
      # Does another skill **invoke** it? This must be distinguished from a "boundary" declaration that merely
      # mentions the name ("the one that looks at … is `/x`") — a false positive makes people turn the check off.
      # So it counts only when an invoking verb is on the same line. The verdict is tilted toward missing (false negative).
      elif [ "$(grep -rh -- "\`/${sname}\`" "$ROOT"/skills/*/SKILL.md "$ROOT"/marketing/skills/*/SKILL.md "$ROOT"/harness/skills/*/SKILL.md 2>/dev/null \
               | grep -cE '[Ii]nvokes?|[Cc]alls?|[Ee]xecutes?|[Dd]elegates? to|in sequence')" -gt 0 ]; then
        flagged_routed="$flagged_routed $sname(invoked by another skill)"
      fi
    fi
  done < <(skill_mds)
  if [ -n "$legacy_key" ]; then
    bad "frontmatter key 'trigger:' is not in the platform contract:$legacy_key" \
        "it has no effect at all. Manual-only is 'disable-model-invocation: true' (docs/platform-contract.md §2.4)"
  else
    ok "all frontmatter keys are within the contract"
  fi
  if [ -n "$manual_unflagged" ]; then
    bad "manual-only but the description is resident:$manual_unflagged" \
        "put 'disable-model-invocation: true' in the frontmatter and the per-session resident cost becomes 0 (docs/platform-contract.md §2.4)"
  else
    ok "manual-only declaration ↔ resident flag agree"
  fi
  if [ -n "$flagged_routed" ]; then
    bad "model invocation blocked on an automatic-firing target:$flagged_routed" \
        "a skill that routing or the graph points at for automatic firing must be callable by the model — remove the flag or take it out of routing"
  else
    ok "blocked model invocation does not cut routing"
  fi

  # Wording that fights the native tooling
  local nfight=0 sr
  while IFS= read -r sr; do
    grep -rq 'takes precedence over the skill-creator plugin' "$sr" 2>/dev/null && nfight=1
  done < <(skill_roots)
  if [ "$nfight" -eq 1 ]; then
    bad "wording that pushes out a native skill (skill-creator) exists" "do not fight the platform natives (P6)"
  else
    ok "no wording that pushes out a native"
  fi

  # ── 6.5 skill-internal references (B-6) ──
  # The existence of the relative references/·assets/·resources/ paths a SKILL.md points at.
  # The existing dangling check looked only at .claude/rules, and that blind spot hid 5 cases for 4 months.
  sec "skill-internal references"
  local sdang=0 schecked=0
  local sd
  while IFS= read -r sd; do
    [ -f "$sd/SKILL.md" ] || continue
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      schecked=$((schecked+1))
      # Skill directory first, plugin root as fallback (allows ${CLAUDE_PLUGIN_ROOT}/scripts/* references)
      if [ ! -f "$sd/$ref" ] && [ ! -f "$ref" ]; then
        bad "$(basename "$sd") → $ref missing"; sdang=$((sdang+1))
      fi
    done < <(grep -ohE '(skills/[A-Za-z0-9._-]+/)?(references|assets|resources|scripts)/[A-Za-z0-9._/-]+\.(md|json|csv|txt|py|sh|html|hbs)' "$sd/SKILL.md" 2>/dev/null | sort -u)
  done < <(skill_dirs)
  [ "$sdang" -eq 0 ] && ok "skill-internal references — all ${schecked} exist"

  # Hardcoded .claude/skills/ — when a plugin skill dictates the project override path,
  # that command fails in a project without an override (plugin-only install).
  local hc=0
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    warn "hardcoded .claude/skills/ path: $hit" "change it to be relative to \${CLAUDE_SKILL_DIR}"
    hc=$((hc+1))
  done < <(skill_mds | while IFS= read -r sm; do grep -lE 'python3 \.claude/skills/|bash \.claude/skills/' "$sm" 2>/dev/null; done)
  [ "$hc" -eq 0 ] && ok "no hardcoded .claude/skills/ in script invocations"

  # Bundled-script path notation — the only things Claude Code substitutes are \${CLAUDE_SKILL_DIR} and
  # \${CLAUDE_PLUGIN_ROOT}. A homemade notation such as <skill-dir> **substitutes nothing**.
  # In this repo the relative path happens to be right so it never shows, but in a consumer the skill lives
  # in the plugin cache, so the model has to guess the path and the invocation fails.
  local bogus=0
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    bad "script path notation that is not substituted: $hit" "only \${CLAUDE_SKILL_DIR} or \${CLAUDE_PLUGIN_ROOT} are substituted"
    bogus=$((bogus+1))
  # BSD grep does not support \| alternation in BRE → -E (ERE) is mandatory.
  # (code_lines() at the top of this file already records the same trap for sed)
  done < <(skill_roots | while IFS= read -r sr; do grep -rnE '<skill[-_]dir>|\{skill[-_]dir\}|<Base directory>' "$sr" 2>/dev/null; done | cut -c1-120)
  [ "$bogus" -eq 0 ] && ok "bundled-script path notation is correct (\${CLAUDE_SKILL_DIR})"

  # Content drift between shared-copy pairs (the known failure mode of a shared-copy structure)
  # Same name ≠ a copy (complete-examples.md has independent content per skill). Instead of guessing by
  # filename, only files that declare the 'orangekit-doctor: shared-copy' marker are checked as a pair.
  local drift=0
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    local first="" f2
    while IFS= read -r f2; do
      if [ -z "$first" ]; then first="$f2"
      elif ! diff -q "$first" "$f2" >/dev/null 2>&1; then
        warn "shared copies differ: $first ↔ $f2" "copy drift — pick one as the original and sync"
        drift=$((drift+1))
      fi
    done < <(_shared_copies | grep "/$base$" | sort)
  done < <(_shared_copies | xargs -I{} basename {} | sort | uniq -d)
  [ "$drift" -eq 0 ] && ok "no shared-copy drift"

  # Empty section heading — a heading with no body, followed by a heading at the same or shallower level.
  # The description promises that section exists while the body is empty, so **the structure differs run to run**
  # (measured: in E1 of enhancement-ab-v1 one empty Step turned a 4-section contract into 0/4).
  # This defect was only ever seen by a person enhancing a skill, and no machine looked at it, so it survived.
  # A '## ' inside a code fence is an example, not a section — it is not counted (false positives make people turn checks off).
  local emptyh=0 eh
  while IFS= read -r eh; do
    [ -z "$eh" ] && continue
    warn "empty section heading: $eh" "the body the heading promised is missing — fill it or delete the heading"
    emptyh=$((emptyh+1))
  done < <(skill_mds | while IFS= read -r sm; do
      awk -v F="$sm" '
        /^```/ { fence = !fence; prev=""; next }
        fence  { next }
        /^#+ / { lvl = index($0, " ") - 1
                 if (lvl >= 2 && prev != "" && lvl <= plvl) print F ": " prev
                 prev = (lvl >= 2 ? $0 : "")
                 plvl = lvl
                 next }
        NF     { prev = "" }
      ' "$sm"
    done)
  [ "$emptyh" -eq 0 ] && ok "no empty section headings"

  # Orphan resources — a bundled file referenced neither from SKILL.md, nor from any file SKILL.md reaches,
  # nor from anywhere in the repo. The "skill-internal references" check above looks only in the
  # **declared→real** direction. The reverse (real→declared) was blind, so a wiring break where the body was empty while only the reference floated survived.
  #
  # The verdict is a **transitive closure**. ui-ux-design's core.py is imported by search.py, not by SKILL.md —
  # counting only direct references calls a live file dead. A call from anywhere in the repo (outside the skill
  # directory) also counts as alive: guide-gate.sh is called by CLAUDE.md and npm test.
  #
  # The comparison also looks at **the name with the extension stripped**. References do not arrive as filenames —
  # `from design_system import` (a Python import) · `--stack nextjs` (a path assembled from an argument) ·
  # `profiles/$lang.sh` (variable substitution). Looking only at names with extensions makes all three false positives.
  # The price is that short names like `core`·`python` accidentally hit prose and let a real orphan through —
  # **an intentional choice tilted toward false negatives**. A false positive makes a person turn the check off,
  # whereas a false negative gets picked up by the next strengthening of the check.
  local orphan=0 od
  while IFS= read -r od; do
    [ -f "$od/SKILL.md" ] || continue
    local cand; cand=$(find "$od" -type f ! -name SKILL.md ! -path '*/.*' 2>/dev/null | sort)
    [ -z "$cand" ] && continue
    local reach="$od/SKILL.md" round c stem rf hit newreach outside
    for round in 1 2 3; do
      newreach="$reach"
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        case $'\n'"$newreach"$'\n' in *$'\n'"$c"$'\n'*) continue;; esac
        stem=$(basename "$c"); base=${stem%.*}; hit=0
        while IFS= read -r rf; do
          [ -z "$rf" ] && continue
          grep -qF "$stem" "$rf" 2>/dev/null && { hit=1; break; }
          grep -qF "$base" "$rf" 2>/dev/null && { hit=1; break; }
        done <<< "$reach"
        [ "$hit" -eq 1 ] && newreach="$newreach
$c"
      done <<< "$cand"
      [ "$newreach" = "$reach" ] && break
      reach="$newreach"
    done
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      case $'\n'"$reach"$'\n' in *$'\n'"$c"$'\n'*) continue;; esac
      stem=$(basename "$c"); base=${stem%.*}
      outside=$(grep -rlF "$base" . --exclude-dir=.git --exclude-dir=node_modules \
                  --exclude-dir=.ua --exclude-dir=dev 2>/dev/null | grep -v "^\./${od}/" | head -1)
      [ -n "$outside" ] && continue
      warn "orphan resource: $c" "unreachable transitively from SKILL.md and from the repo — rewire it or drop it"
      orphan=$((orphan+1))
    done <<< "$cand"
  done < <(skill_dirs)
  [ "$orphan" -eq 0 ] && ok "no orphan resources"

  # Plugin-relative paths inside a code block — `rules/x.md` in prose is a citation naming the canonical location,
  # but `grep … rules/workflow-routing.md` in a code block is **executed**. In a consumer that path does not exist
  # (it is `.claude/rules/…` or inside the plugin cache) — it must be written with `${CLAUDE_PLUGIN_ROOT}` to be substituted (evaluation v6 · E-34).
  # Prose is not examined: turning every citation of the canonical source into a variable makes it unreadable.
  local bp_bad=0 bp_list="" bpf bph
  while IFS= read -r bpf; do
    [ -f "$bpf" ] || continue
    grep -q 'orangekit-doctor: allow-bare-paths' "$bpf" 2>/dev/null && continue
    bph=$(awk '/^```/{f=!f; next} f' "$bpf" 2>/dev/null \
      | grep -E '(^|[^A-Za-z0-9_/.$}-])(rules|scripts|skills|guides|templates|presets)/[A-Za-z0-9_.*/-]+' \
      | grep -vE 'CLAUDE_PLUGIN_ROOT|CLAUDE_SKILL_DIR|\.claude/|^[[:space:]]*#' | head -1)
    [ -z "$bph" ] && continue
    bp_bad=$((bp_bad+1)); bp_list="$bp_list
      · $bpf: $(printf '%s' "$bph" | cut -c1-80)"
  done < <({ skill_mds; find skills -type f \( -path '*/references/*.md' -o -path '*/assets/*.md' \) 2>/dev/null; } | sort -u)
  if [ "$bp_bad" -gt 0 ]; then
    bad "plugin-relative paths in code blocks in ${bp_bad} files:$bp_list" "executed in a consumer it is a 'missing file' — write \${CLAUDE_PLUGIN_ROOT}/… (citing prose stays as it is)"
  else
    ok "code-block path notation is correct (no plugin-relative paths)"
  fi

  # ── 6.6 port residue ──
  #
  # Assets carried over from the original repo keep **sentences that were true then and became false in the
  # distribution context**. They were not written wrong; they were written right and turned wrong by the move,
  # so the sentence itself reads naturally and a human eye slides past it. Measured: 4 residues survived
  # 4.5 months · 89 commits · 14 rounds of strengthening doctor · 5 harness evaluations (entered 2026-04-14 → found 2026-09-02).
  #
  # There are three reasons the existing checks miss them. ① "declared ↔ real" compares **numbers only**, and a
  # rename does not change a number ② the dangling check looks at one pattern, `.claude/rules/*.md`
  # ③ most hygiene checks read only SKILL.md, leaving references/·resources/ blind.
  # So this section looks **recursively**.
  sec "port residue"

  # Scan targets — assets that are distributed to consumers or that generate consumer documents.
  # dev/ is not included: it is a development record, so describing an old name there is normal.
  local _pr_targets=() _pt
  # harness/ is not included: this section looks at residue in assets **distributed to consumers**, and
  # harness/ is a plugin only the author installs, so its own name and plugin paths are normal description.
  for _pt in skills rules agents templates guides marketing; do
    [ -d "$_pt" ] && _pr_targets+=("$_pt")
  done

  # ① A skill name that appeared on a consumer path — a 3-minute verdict.
  #    Generated output (frontend-guide·backend-guide·app-guide) is normal, since the consumer's .claude/skills/ is its real home.
  #    A plugin skill **lives in the plugin cache and is never placed in a consumer's .claude/** —
  #    writing that it is there sends the model to read a path that does not exist.
  #    If it is neither, it is a dead reference left behind by a rename or retirement.
  local _pr_bad=0 _pr_chk=0
  if [ ${#_pr_targets[@]} -gt 0 ]; then
    local _sname
    while IFS= read -r _sname; do
      [ -z "$_sname" ] && continue
      _pr_chk=$((_pr_chk+1))
      case "$_sname" in
        frontend-guide|backend-guide|app-guide) continue ;;   # generated output — normal
      esac
      if [ -f "skills/$_sname/SKILL.md" ] || [ -f "marketing/skills/$_sname/SKILL.md" ] || [ -f "harness/skills/$_sname/SKILL.md" ]; then
        bad "plugin skill on a consumer path: .claude/skills/$_sname" \
            "plugin skills live in the cache. Only generated output (frontend-guide·backend-guide·app-guide) goes in a consumer's .claude/skills/"
        _pr_bad=$((_pr_bad+1))
      else
        bad "dead skill reference: .claude/skills/$_sname" \
            "no such skill exists — the reference was not followed after a rename or retirement (harness-change \"post-change back-trace\")"
        _pr_bad=$((_pr_bad+1))
      fi
    # If `deprecated` is on the same line it is a retirement path-conversion example (harness-change "Shadow mirror").
    # Real residue does not describe a retirement, so this exemption does not hide a defect.
    done < <(grep -rhE '\.claude/skills/[A-Za-z0-9._-]+' "${_pr_targets[@]}" 2>/dev/null \
             | grep -v 'deprecated' \
             | grep -oE '\.claude/skills/[A-Za-z0-9._-]+' | sed 's|.*/||' | sort -u)
  fi
  if [ "$_pr_bad" -eq 0 ]; then
    ok "skill names on consumer paths — all ${_pr_chk} fine"
  fi

  # ② Repo-name leak — the name set is derived from the manifests (hardcoding kept to a minimum).
  #    Only the original repo name cannot be derived, so it is spelled out. If these names get baked into
  #    distributed assets as examples or defaults, a consumer receives somebody else's project name.
  #    Lines with a URL are exempt — this repo is the schema's real host (orangekit-init's $schema).
  # No dependence on jq — the same convention as the other manifest reads in this file (grep -m1 + sed -E).
  _pr_name() {  # $1 file
    [ -f "$1" ] || return 0
    grep -m1 '"name"' "$1" 2>/dev/null | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  }
  # Directory names are not used — the checkout name can be changed by the user, and a short common value like
  # `base`·`src` would hit all sorts of prose and make the check unusable (measured in the fixture tree).
  # Only the manifest declarations are used, and anything under 6 characters is discarded.
  #
  # One more name is discarded: the **segment prefix of the plugin name**. Once the repository and the
  # marketplace are named after the product itself (`orangekit`, with the plugin `orangekit-product`),
  # that name stops being somebody else's project name and becomes the product's own identifier
  # namespace — `.claude/.orangekit/`, `orangekit-planner`, `orangekit.config.json`. A consumer is
  # *supposed* to receive those. Left in the set it matched 164 legitimate lines and the check became
  # unusable, which is worse than not having it. The longer names stay: `orangekit-product` and the
  # original repo name are still forbidden, and the self-test fixture plants one of them to prove the
  # block is alive.
  local _plugin_self; _plugin_self="$(_pr_name .claude-plugin/plugin.json)"
  local _self_names="" _n
  for _n in "$_plugin_self" \
            "$(_pr_name package.json)" \
            "$(_pr_name .claude-plugin/marketplace.json)" \
            "OrangeKitClaudeCodeDevkit"; do
    [ ${#_n} -ge 6 ] || continue
    # A proper segment prefix of the plugin name — the namespace, not a foreign project name.
    [ "$_n" != "$_plugin_self" ] && case "$_plugin_self" in "$_n"-*) continue ;; esac
    _self_names="$_self_names $_n"
  done
  local _leak=0 _lhit
  if [ ${#_pr_targets[@]} -gt 0 ] && [ -n "$_self_names" ]; then
    for _n in $_self_names; do
      while IFS= read -r _lhit; do
        [ -z "$_lhit" ] && continue
        bad "repo name leak: $_lhit" \
            "this is an asset distributed to consumers — replace it with a placeholder (URLs are exempt)"
        _leak=$((_leak+1))
      done < <(grep -rnF -- "$_n" "${_pr_targets[@]}" 2>/dev/null \
               | grep -vE 'https?://' | cut -c1-110)
    done
  fi
  if [ "$_leak" -eq 0 ]; then
    ok "self-name check on distributed assets passed"   # must not partially contain the failure message — the baseline grep would read a success as a false positive
  fi

  # ③ **Plugin-context paths** in the body of a rule card — the third face of the same incident as ①②.
  #    ①② look at a **name** that moved; this looks at a **path** that moved.
  #    install-rules.sh ships T1 cards into the consumer's `.claude/rules/`, so relative paths in the body
  #    are resolved **from the consumer root**. Writing a path that is true in the plugin repo verbatim
  #    sends the model to read a file that does not exist — it was not written wrong, it was written right
  #    and turned wrong by the move, so a human eye slides past it (harness-change "post-change back-trace").
  #    Measured: one card, harness-change.md, had 6 of them (agents/·docs/×2·rules/·scripts/×2) and every one
  #    was a missing file in the consumer layout. The notation convention is `<plugin-root>/…`.
  #
  #    The test is **does it exist in the plugin**. That is the only machine evidence of "the author wrote this
  #    in a plugin context". A path that does not exist is out of scope for this check —
  #    it cannot be distinguished from normal prose pointing ahead at a file the consumer will create.
  local _pc_bad=0 _pc_n=0 _pcp _pcc
  # Artifacts the project owns and the harness **creates when needed**. Their absence in a new consumer is
  # normal, so they are exempt. Before growing this list, first ask "is it really project-owned" —
  # an exemption is the only direction that blunts a check.
  local _pc_owned=" docs/lessons.md docs/lessons-archive.md docs/decisions.md docs/decisions-archive.md dev/docs/ "
  if [ -d rules ]; then
    for _pcc in rules/*.md; do
      [ -f "$_pcc" ] || continue
      while IFS= read -r _pcp; do
        [ -z "$_pcp" ] && continue
        case "$_pc_owned" in *" $_pcp "*) continue ;; esac
        [ -e "$_pcp" ] || continue
        _pc_n=$((_pc_n+1))
        bad "plugin-context path in a rule card: $_pcc → $_pcp" \
            "in the consumer's .claude/rules/ this relative path is a missing file. Write it as \`<plugin-root>/$_pcp\`"
        _pc_bad=$((_pc_bad+1))
      done < <(grep -ohE '`[a-z][a-zA-Z0-9._-]*/[a-zA-Z0-9./_-]+`' "$_pcc" 2>/dev/null | tr -d '`' | sort -u)
    done
  fi
  [ "$_pc_bad" -eq 0 ] && ok "rule-card path notation is correct (relative to the consumer root)"

  # ── 7. manifest consistency ──
  #
  # The version is scattered across 4 places. The check used to look only at the first two; it is widened to
  # the README badge and marketplace.json — nobody caught the latter two, so they could ship out of sync.
  # ── 6.8 axis guide packs (v3.12.0) ──
  # The pre-built unit came down from the combination to the axis. A pack is an asset, not a skill, so
  # the skill checks do not reach it — here we look at contract completeness and baseline age.
  if [ -d guides ]; then
    sec "axis guide packs"
    local pk pn pmiss=0 pold=0 pcount=0 pstale=""
    for pk in guides/frontend/*/ guides/backend/*/ guides/app/*/; do
      [ -d "$pk" ] || continue
      pcount=$((pcount+1)); pn=${pk%/}; pn=${pn#guides/}
      for req in PACK.md ledger.md policies.md pack.json; do
        [ -f "$pk$req" ] || { bad "pack $pn: $req missing" "all 4 pack contract files must exist for the gate to check the boundary"; pmiss=$((pmiss+1)); }
      done
      # Every resource must carry a shipping stamp for install-guide.sh to judge an idempotent update
      local nost; nost=$({ grep -L '^<!-- orangekit-pack:' "$pk"resources/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
      [ "$(num "$nost")" -gt 0 ] && { bad "pack $pn: ${nost} resources without a stamp" "without a stamp a user's edits cannot be told apart from an old version"; pmiss=$((pmiss+1)); }
      # Baseline age — an unaudited pre-built guide is worse than no guide
      local vd; vd=$({ grep -m1 -oE 'verified [0-9]{4}-[0-9]{2}-[0-9]{2}' "$pk"PACK.md 2>/dev/null || true; } | awk '{print $2}')
      if [ -z "$vd" ]; then warn "pack $pn: no verified date in PACK.md"; else
        local vts nts age
        vts=$(num "$(date -j -f %Y-%m-%d "$vd" +%s 2>/dev/null || date -d "$vd" +%s 2>/dev/null || true)")
        nts=$(num "$(date +%s)")
        if [ "$vts" -gt 0 ] && [ "$nts" -gt "$vts" ]; then
          age=$(( (nts - vts) / 86400 ))
          [ "$age" -ge 180 ] && { pstale="$pstale $pn(${age}d)"; pold=$((pold+1)); }
        fi
      fi
    done
    [ -n "$pstale" ] && warn "pack baselines older than 6 months:$pstale" "check whether a major version moved, audit, and refresh verified"
    [ "$pmiss" -eq 0 ] && ok "${pcount} axis packs have complete contracts and stamps"
    # Does the pack a seam points at exist?
    local sm smiss=0
    for sm in guides/seams/*/seam.json; do
      [ -f "$sm" ] || continue
      while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        [ -d "guides/$ref" ] || { bad "seam $(basename "$(dirname "$sm")"): pack $ref missing"; smiss=$((smiss+1)); }
      done < <({ grep -oE '"(frontend|backend|app)Pack"[[:space:]]*:[[:space:]]*"[^"]+"' "$sm" 2>/dev/null || true; } | sed -E 's/.*"([^"]+)"$/\1/')
    done
    [ "$smiss" -eq 0 ] && ok "seam pack references exist"
  fi

  sec "manifest"
  local pv cv rv mism=""
  pv=$(grep -m1 '"version"' package.json 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  cv=$(grep -m1 '"version"' .claude-plugin/plugin.json 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  rv=$(grep -m1 -oE 'version-[0-9]+\.[0-9]+\.[0-9]+' README.md 2>/dev/null | sed 's/version-//')
  if [ -z "$pv" ]; then
    bad "could not read the version from package.json"
  else
    [ "$cv" = "$pv" ] || mism="$mism plugin.json=${cv:-none}"
    [ "$rv" = "$pv" ] || mism="$mism README-badge=${rv:-none}"
    # The version appears in 2 places inside marketplace.json — the marketplace metadata + the entry for **this plugin**.
    # This repo hosts three plugins (orangekit-marketing and orangekit-harness are versioned independently), and scraping every
    # "version" in the file would compare somebody else's version against the baseline and **fail as a false positive**. Narrow to the entry.
    # A missing jq is undecidable — do not block, skip it, but do not go silent either (the three-state discipline).
    local mpname mtot=0 mbad=0 mv mskip=0
    mpname=$(grep -m1 '"name"' .claude-plugin/plugin.json 2>/dev/null | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if command -v jq >/dev/null 2>&1; then
      while IFS= read -r mv; do
        [ -z "$mv" ] && continue
        mtot=$((mtot+1))
        [ "$mv" = "$pv" ] || mbad=$((mbad+1))
      done < <(jq -r --arg n "$mpname" \
                 '[.metadata.version?, (.plugins[]?|select(.name==$n)|.version)] | map(select(.!=null)) | .[]' \
                 .claude-plugin/marketplace.json 2>/dev/null)
      [ "$mtot" -eq 0 ] && mism="$mism marketplace.json=unreadable"
      [ "$mbad" -gt 0 ] && mism="$mism marketplace.json(${mbad}/${mtot} places disagree)"
    else
      mskip=1
    fi
    if [ -n "$mism" ]; then
      bad "version mismatch (baseline package.json=$pv):$mism" \
          "raise all 4 at once — plugin.json · package.json · README badge · marketplace.json"
    elif [ "$mskip" -eq 1 ]; then
      warn "marketplace.json version comparison undecidable — no jq" \
           "plugin.json · package.json · README badge — those 3 agree ($pv)"
    else
      ok "version agrees in all 4 places ($pv · including ${mtot} in marketplace)"
    fi

    # Release reach — even when those 4 agree, **it has not shipped.** Everything compared is a local file,
    # so raising only the version without tagging and pushing means consumers keep receiving the old version.
    # In reality, while 3.18.0 was raised 17 times, what shipped was 2.0.0 (evaluation v3 · E-08·E-12).
    # The remote is not queried — the network crosses a boundary (P7), and a check that cannot run offline is not a check.
    # Stay silent when there is no .git: a consumer cache has no .git, and warning there would give every
    # consumer a warning that never goes away.
    local pname rtag
    pname=$(grep -m1 '"name"' .claude-plugin/plugin.json 2>/dev/null | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    rtag="${pname:-plugin}--v${pv}"
    if [ -e .git ] && command -v git >/dev/null 2>&1; then
      if git rev-parse -q --verify "refs/tags/$rtag" >/dev/null 2>&1; then
        # A tag **existing** and **HEAD having shipped** are different things. When asset commits pile up behind
        # a tag the name passes while consumers receive none of those commits — 13 commits sat behind the 3.28.0
        # tag in exactly that state (evaluation v7 · E-52). Raising the version changes the tag name and falls
        # through to the "not shipped" warning above, so this warning points at "when to raise".
        local after_tag
        after_tag=$(num "$(git rev-list --count "$rtag..HEAD" -- skills agents rules hooks scripts templates guides references presets schema workflow.graph.json 2>/dev/null)")
        if [ "$after_tag" -gt 0 ]; then
          warn "release tag exists ($rtag) — ${after_tag} asset commits behind it are unshipped" \
               "consumers only get the assets as of the tag. Raise the version in 4 places → commit → 'claude plugin tag --push'"
        else
          ok "release tag exists ($rtag) · 0 asset commits since the tag"
        fi
      else
        warn "version $pv not shipped — no release tag '$rtag'" \
             "commit, then 'claude plugin tag --push'. Raising the version without a tag leaves consumers on the old version"
      fi
    fi
  fi
  [ -f plugin.json ] && bad "duplicate plugin.json at the root" "Claude Code reads only .claude-plugin/plugin.json" \
                     || ok "manifest is single"
  # Claude Code discovers hooks/hooks.json automatically. If the manifest points at the same file again,
  # the whole plugin load is refused as a "duplicate of an already-loaded file" — claude plugin validate does not catch this
  if grep -qE '"hooks"[[:space:]]*:[[:space:]]*"(\./)?hooks/hooks\.json"' .claude-plugin/plugin.json 2>/dev/null; then
    bad "manifest hooks duplicates the default path hooks/hooks.json" "the file is auto-discovered, so the plugin load is refused — delete that line"
  else
    ok "manifest hooks does not duplicate the default path"
  fi

  # ── 7.5 declared ↔ real (RC5) ──
  #
  # A number written by hand into a document is certain to go stale. While the README said "24 nodes · 41 edges"
  # the real graph had become 49/67, and three different skill counts — 34·35·31 — coexisted.
  # Do not expect a person to compare them; a machine keeps them aligned.
  sec "declared ↔ real"

  local claims=0 wrong=0
  _claim() {  # $1 label  $2 value pulled from the document  $3 real  $4 file
    [ -z "$2" ] && return 0
    claims=$((claims+1))
    [ "$2" = "$3" ] && return 0
    bad "$4: $1 claim $2 ≠ real $3"; wrong=$((wrong+1))
  }

  # Count the real assets once. The documents being compared grew to three (README · marketplace.json · the anatomy
  # document), and counting separately in each would make **the check itself hold three copies**.
  # Undecidable (no jq · no file) is left as an empty string and only that item is skipped — the three-state discipline.
  local real_sk real_ru real_fe real_be real_ap
  local real_nd="" real_ed="" real_hk=""
  real_sk=$(num "$(find skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')")
  real_ru=$(num "$({ ls -1 rules/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')")
  real_fe=$(num "$({ ls -1 presets/frontend/*.json 2>/dev/null || true; } | wc -l | tr -d ' ')")
  real_be=$(num "$({ ls -1 presets/backend/*.json 2>/dev/null || true; } | wc -l | tr -d ' ')")
  real_ap=$(num "$({ ls -1 presets/app/*.json 2>/dev/null || true; } | wc -l | tr -d ' ')")
  # Only the pack count **does not fold absence into 0.** --consumer's cache copy excludes guides/, so counting 0
  # there would flag a normal tree as a false positive — missing and zero are different things (the three-state discipline).
  local real_fp="" real_bp="" real_apk=""
  if [ -d guides/frontend ] && [ -d guides/backend ]; then
    real_fp=$(num "$(find guides/frontend -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')")
    real_bp=$(num "$(find guides/backend -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')")
    # The app axis arrived later — no directory means 0 packs (that guides/ exists is already established)
    real_apk=$(num "$(find guides/app -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')")
  fi
  if command -v jq >/dev/null 2>&1 && [ -f workflow.graph.json ]; then
    real_nd=$(num "$(jq -r '.nodes|length' workflow.graph.json 2>/dev/null)")
    real_ed=$(num "$(jq -r '.edges|length' workflow.graph.json 2>/dev/null)")
  fi
  # The denominator for hooks is the number of **unique scripts**. Using the number of registered entries makes it
  # permanently short because handoff.sh alone is hooked to two events — use the same formula as session-brief and --usage.
  if [ -f hooks/hooks.json ] && command -v jq >/dev/null 2>&1; then
    real_hk=$(num "$(jq -r '[.hooks|to_entries[].value[]?.hooks[]?.command
                    | capture("(?<f>[a-z0-9-]+)\\.sh").f] | unique | length' hooks/hooks.json 2>/dev/null)")
  fi

  # A line budget is **a hand-written number too** — yet only counts were compared and this was empty.
  # In fact, after the T0 budget rose 40→42, five documents stayed at 40, and the current file (41 lines)
  # had already passed the budget every document stated while nobody failed.
  # Per-script line counts are not included — they are a side branch of the design document, not a budget.
  local real_t0 real_rl
  real_t0=$(num "$(wc -l < templates/operating-contract.md 2>/dev/null)")
  real_rl=$(num "$({ cat rules/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')")

  if [ -f README.md ]; then
    if [ -n "$real_nd" ]; then
      _claim "graph nodes" "$(grep -oE '[0-9]+ nodes' README.md | head -1 | grep -oE '^[0-9]+')" "$real_nd" "README.md"
      _claim "graph edges" "$(grep -oE '[0-9]+ edges' README.md | head -1 | grep -oE '^[0-9]+')" "$real_ed" "README.md"
    fi
    _claim "skill count" "$(grep -oE '\| \*\*Skills\*\* \| [0-9]+' README.md | grep -oE '[0-9]+$')" "$real_sk" "README.md"
    _claim "T1 card count" "$(grep -oE 'T1 [0-9]+ cards' README.md | head -1 | sed -E 's/T1 ([0-9]+) cards/\1/')" "$real_ru" "README.md"
    # Format "T0 N lines + T1 M cards L lines". Strip the comma before comparing (the document writes 1,080)
    # Sweeping with `grep -oE '[0-9]+'` mixes in **a digit from the label** — the 0 in "T0" was picked up as the value.
    # That is the second time "declared ↔ real" caught the same mistake in itself. Extract with a capture group.
    _claim "T0 line count" "$(grep -m1 -oE 'T0 [0-9]+ lines' README.md | sed -E 's/T0 ([0-9]+) lines/\1/')" "$real_t0" "README.md"
    # Look at **both** "T1 M cards L lines" and "T1 L lines". While `-m1` looked only at the first match, the second
    # value in the v2 comparison table stayed stuck at 1,080 (evaluation v6 · E-31).
    local _t1v
    for _t1v in $(grep -oE 'T1( [0-9]+ cards)? [0-9,]+ lines' README.md | grep -oE '[0-9,]+ lines' | sed -E 's/ lines//; s/,//g' | sort -u); do
      _claim "T1 total line count" "$_t1v" "$real_rl" "README.md"
    done
    # The skill count in the v2→v3 comparison table — the bold value in `| Skills | 37 | **26** |`. The "| **Skills** |" pattern above does not see this row.
    _claim "skill count (comparison table)" "$(grep -oE '^\| Skills \| [0-9]+ \| \*\*[0-9]+' README.md | grep -oE '\*\*[0-9]+' | tr -d '*')" "$real_sk" "README.md"
    # Preset counts per axis. The vue axis really existed in the presets·packs·seams·init menu but never appeared in
    # any of the 3 consumer documents, and the README claimed 4 for frontend. The check had stopped at the neighbouring
    # row of the same table — this is where the path that adds an axis meets the documents (evaluation v5 · E-15).
    # With three axes (web screens · app · backend) the notation is now '3-axis F+A+B'. _claim passes an empty value as undecidable,
    # so if the notation and this regex drift apart **the check dies silently** — the 'axis notation missing' failure below catches that
    local rd_pre
    rd_pre=$(grep -oE '3-axis [0-9]+\+[0-9]+\+[0-9]+' README.md | head -1)
    [ -z "$rd_pre" ] && [ -d presets/app ] && bad "README.md: preset axis notation missing — no '3-axis frontend+app+backend' notation, so the count comparison does not run"
    _claim "frontend preset count" "$(printf '%s' "$rd_pre" | sed -E 's/3-axis ([0-9]+)\+([0-9]+)\+([0-9]+)/\1/')" "$real_fe" "README.md"
    _claim "app preset count"      "$(printf '%s' "$rd_pre" | sed -E 's/3-axis ([0-9]+)\+([0-9]+)\+([0-9]+)/\2/')" "$real_ap" "README.md"
    _claim "backend preset count"  "$(printf '%s' "$rd_pre" | sed -E 's/3-axis ([0-9]+)\+([0-9]+)\+([0-9]+)/\3/')" "$real_be" "README.md"
  fi

  # marketplace.json is the only description a consumer reads **before installing**. Yet while the comparison
  # stopped at the README, this was stuck at "4 hooks · 7 backend packs · 8 backend presets" (real: 5 · 8 · 9).
  # The place where a stale number lives longest was the last place to get checked.
  local MP=".claude-plugin/marketplace.json"
  if [ -f "$MP" ]; then
    local mp_pack mp_pre
    mp_pack=$(grep -oE 'packs \(frontend [0-9]+( · app [0-9]+)? · backend [0-9]+\)' "$MP" 2>/dev/null | head -1)
    mp_pre=$(grep -oE 'presets \(frontend [0-9]+ · app [0-9]+ · backend [0-9]+\)' "$MP" 2>/dev/null | head -1)
    [ -z "$mp_pre" ] && [ -d presets/app ] && bad "$MP: preset axis notation missing — no 'presets (frontend N · app N · backend N)' notation, so the count comparison does not run"
    [ -n "$real_hk" ] && _claim "hook count" \
      "$(grep -oE '[0-9]+ hooks' "$MP" 2>/dev/null | head -1 | grep -oE '[0-9]+')" "$real_hk" "$MP"
    _claim "skill count" "$(grep -oE '[0-9]+ skills' "$MP" 2>/dev/null | head -1 | grep -oE '[0-9]+')" "$real_sk" "$MP"
    if [ -n "$real_fp" ]; then
      _claim "frontend pack count" "$(printf '%s' "$mp_pack" | grep -oE '[0-9]+' | head -1)" "$real_fp" "$MP"
      _claim "backend pack count" "$(printf '%s' "$mp_pack" | grep -oE '[0-9]+' | tail -1)" "$real_bp" "$MP"
      # With 0 app packs, no notation is correct. With 1 or more and no notation, the pre-install description is false
      _claim "app pack count" "$(printf '%s' "$mp_pack" | { grep -oE 'app [0-9]+' || echo 'app 0'; } | grep -oE '[0-9]+')" "$real_apk" "$MP"
    fi
    _claim "frontend preset count" "$(printf '%s' "$mp_pre"  | grep -oE '[0-9]+' | head -1)" "$real_fe" "$MP"
    _claim "app preset count"      "$(printf '%s' "$mp_pre"  | grep -oE '[0-9]+' | sed -n 2p)" "$real_ap" "$MP"
    _claim "backend preset count" "$(printf '%s' "$mp_pre"  | grep -oE '[0-9]+' | tail -1)" "$real_be" "$MP"
  fi

  # The anatomy document writes the harness's numbers into its body — that is, **a copy this repo made itself**.
  # If you make a copy, make the comparison path with it. When the format breaks, warn instead of going silent:
  # skipping quietly recreates the "thought it was checked but was not" state, and that is this check's original disease.
  local AN="docs/harness-anatomy.md"
  if [ -f "$AN" ]; then
    local anl
    anl=$(grep -m1 -oE 'hooks [0-9]+ · T1 rule cards [0-9]+ · skills [0-9]+ · graph nodes [0-9]+ · edges [0-9]+' "$AN" 2>/dev/null)
    if [ -z "$anl" ]; then
      warn "no real-comparison line in $AN" "format: 'hooks N · T1 rule cards N · skills N · graph nodes N · edges N'"
    else
      # Extract with capture groups. Sweeping with `grep -oE '[0-9]+'` mixes in **a digit from the label** —
      # the 1 in "T1" came in as a value and shifted all five slots by one (this check caught it in itself).
      local a_hk a_ru a_sk a_nd a_ed
      read -r a_hk a_ru a_sk a_nd a_ed <<< "$(printf '%s' "$anl" \
        | sed -E 's/^hooks ([0-9]+) · T1 rule cards ([0-9]+) · skills ([0-9]+) · graph nodes ([0-9]+) · edges ([0-9]+)$/\1 \2 \3 \4 \5/')"
      [ -n "$real_hk" ] && _claim "hook count" "$a_hk" "$real_hk" "$AN"
      _claim "T1 card count" "$a_ru" "$real_ru" "$AN"
      _claim "skill count" "$a_sk" "$real_sk" "$AN"
      if [ -n "$real_nd" ]; then
        _claim "graph nodes" "$a_nd" "$real_nd" "$AN"
        _claim "graph edges" "$a_ed" "$real_ed" "$AN"
      fi
    fi
  fi

  # Copies of the skill count live in two manuals too — "no need to memorize N" (user-manual) ·
  # "N totaling a 12,000-byte budget" (operations-manual). The 26→25 cleanup fixed only the three patterns above
  # and left these two (evaluation v7 · E-50). The anatomy document's "manual-only N" is a hand-written number as
  # well — skill-enhancer went in and it was written as 6 while the real dmi count was 5 (E-49).
  _claim "skill count" "$(grep -m1 -oE '[0-9]+ skills — no need to memorize' docs/user-manual.md 2>/dev/null | grep -oE '^[0-9]+')" "$real_sk" "docs/user-manual.md"
  _claim "skill count" "$(grep -m1 -oE '[0-9]+ totaling 12,000 bytes' docs/operations-manual.md 2>/dev/null | grep -oE '^[0-9]+')" "$real_sk" "docs/operations-manual.md"
  if [ -f "$AN" ]; then
    local real_dmi
    real_dmi=$(num "$({ grep -l '^disable-model-invocation:[[:space:]]*true' skills/*/SKILL.md 2>/dev/null || true; } | wc -l | tr -d ' ')")
    _claim "manual-only count" "$(grep -m1 -oE 'manual invocation only\*\* \(`disable-model-invocation`\) \|[^|]*— \*\*[0-9]+\*\*' "$AN" 2>/dev/null | grep -oE '\*\*[0-9]+\*\*$' | tr -d '*')" "$real_dmi" "$AN"
  fi

  # The same document hand-writes "what security-check blocks — N kinds" as well. The real value is the number of
  # block-reason titles in the hook (same formula as "block reasons ↔ fixtures" above). Adding remote deletion to the
  # force-push gate turned 23 into 24, and without this comparison three places in the illustrated manual would have stayed at 23 (evaluation v9 · E-61).
  local real_blk mb
  real_blk=$(num "$({ grep -oE '^[[:space:]]*(&& |\|\| )?(dblock|block) "[^"]+"' scripts/security-check.sh 2>/dev/null || true; } \
              | sed -E 's/^[[:space:]]*(&& |\|\| )?(dblock|block) "//; s/"$//; s/ \(\$[a-z_]+\)$//' | sort -u | wc -l | tr -d ' ')")
  if [ "$real_blk" -gt 0 ]; then
    for mb in $(grep -oE '[Ss]creens [0-9]+ patterns|blocks — all [0-9]+<|[0-9]+ things that get blocked' docs/manual/user.html 2>/dev/null | grep -oE '[0-9]+' | sort -u); do
      _claim "block reason count" "$mb" "$real_blk" "docs/manual/user.html"
    done
  fi

  # The check above uses `grep -m1` and sees **only the first match of one format**. If the same document writes
  # the same number again in different words, it is invisible — in fact the anatomy document wrote a different
  # number 556 lines later, while that very file was warning that "a number written by hand into a document is
  # certain to go stale". Widen the format but **limit it to lines that mention workflow.graph.json**: a historical
  # sentence (while the README said "N nodes · N edges"…) is not a comparison target, and it naturally drops out
  # because that line has no filename.
  if [ -n "$real_nd" ]; then
    local gline gnode gedge gsrc
    while IFS=: read -r gsrc gline; do
      [ -z "$gline" ] && continue
      gnode=$(printf '%s' "$gline" | grep -oE '[0-9]+ nodes · [0-9]+ edges' | head -1 | sed -E 's/([0-9]+) nodes · ([0-9]+) edges/\1/')
      gedge=$(printf '%s' "$gline" | grep -oE '[0-9]+ nodes · [0-9]+ edges' | head -1 | sed -E 's/([0-9]+) nodes · ([0-9]+) edges/\2/')
      _claim "graph nodes (body)" "$gnode" "$real_nd" "$gsrc"
      _claim "graph edges (body)" "$gedge" "$real_ed" "$gsrc"
    done < <(grep -lF 'workflow.graph.json' README.md CLAUDE.md docs/*.md 2>/dev/null \
             | while IFS= read -r gf; do
                 grep -HF 'workflow.graph.json' "$gf" 2>/dev/null \
                   | grep -E '[0-9]+ nodes · [0-9]+ edges' | cut -d: -f1,2- \
                   | sed -E "s|^([^:]*):|\\1:|"
               done)
  fi
  # The T0 budget figure — the budget a document quotes must equal this script's constant (E-25).
  # `budget N lines` is also used for the CLAUDE.md budget (60), so look only at lines talking about T0 / the operating contract.
  local bf bv
  for bf in README.md rules/harness-change.md docs/harness-anatomy.md templates/operating-contract.md; do
    [ -f "$bf" ] || continue
    for bv in $(grep -E 'T0|operating contract|operating-contract' "$bf" 2>/dev/null | grep -oE 'budget[ :]*[0-9]+ lines|[0-9]+-line budget' | grep -oE '[0-9]+' | sort -u); do
      _claim "T0 budget" "$bv" "$T0_BUDGET" "$bf"
    done
  done
  # The number of T0 lines actually **injected** (after comments are stripped) — the anatomy document writes it as "actually injects N lines"
  local real_t0i
  real_t0i=$(num "$(sed '/<!--/,/-->/d' templates/operating-contract.md 2>/dev/null | sed '/./,$!d' | wc -l | tr -d ' ')")
  # Sweeping with `[0-9]+` picks up the 0 in "T0" — the third time this file caught the same mistake in itself. Pull out only "N lines".
  for bv in $(grep -oE 'injects [0-9]+ lines|operating contract [0-9]+ lines' docs/harness-anatomy.md 2>/dev/null | grep -oE '[0-9]+ lines' | sed -E 's/ lines//' | sort -u); do
    _claim "T0 injected line count" "$bv" "$real_t0i" "docs/harness-anatomy.md"
  done

  # The graph kind table — the `| \`kind\` | N |` rows in §04 of the anatomy document. tool was written as 1 while skill-creator arrived (E-31).
  if [ -n "$real_nd" ] && [ -f docs/harness-anatomy.md ]; then
    local kk kn
    while IFS=$'\t' read -r kk kn; do
      [ -z "$kk" ] && continue
      _claim "graph kind($kk)" "$kn" "$(num "$(jq -r --arg k "$kk" '[.nodes[] | select(.kind==$k)] | length' workflow.graph.json 2>/dev/null)")" "docs/harness-anatomy.md"
    done < <(grep -oE '^\| `(skill|stage|hook|agent|store|tool|terminal)` \| [0-9]+ \|' docs/harness-anatomy.md \
             | sed -E 's/^\| `([a-z]+)` \| ([0-9]+) \|/\1\t\2/')
  fi

  # Agent tool lists — are the tables in the README and the anatomy document the same set as the frontmatter `tools:`?
  # After WebFetch went into planner, both documents were left listing only four (E-31).
  local af an at dt dl
  for af in agents/*.md; do
    [ -f "$af" ] || continue
    an=$(basename "$af" .md)
    at=$(grep -m1 -E '^tools:' "$af" | sed 's/^tools:[[:space:]]*//' | tr ',·' '\n\n' | tr -d ' ' | grep -v '^$' | sort | tr '\n' ' ')
    [ -z "$at" ] && continue
    for dl in README.md docs/harness-anatomy.md; do
      [ -f "$dl" ] || continue
      # What is inside the parentheses (`disallowedTools`: …) is a note, not part of the tool list — strip it before comparing
      dt=$(grep -m1 -E "^\| \`$an\` \|" "$dl" | awk -F'|' '{print $3}' | sed -E 's/\([^)]*\)//g' | tr ',·' '\n\n' | tr -d ' ' | grep -v '^$' | sort | tr '\n' ' ')
      [ -z "$dt" ] && continue
      _claim "$an tool list" "$dt" "$at" "$dl"
    done
  done
  # ── "file X is N lines" claims ──
  # A different shape from the counts above: not how many assets exist, but how big a named file is.
  # Skills use it as a reading budget ("read only the section you need"), so a stale number sends the
  # model to read a file four times smaller than advertised. Measured on three of four live claims:
  # 1,132 vs 1,225 · 291 vs 308 · ~982 vs 250. Nothing was comparing them.
  # lessons.md / lessons-archive.md are excluded on purpose — an entry there **records** a number that
  # was wrong at the time, so "correcting" it would destroy the evidence the entry exists to keep.
  local lc_file lc_ln lc_path lc_want lc_approx lc_real lc_base lc_n=0
  while IFS=$'\t' read -r lc_file lc_ln lc_path lc_want lc_approx; do
    [ -z "$lc_path" ] && continue
    lc_base="$(dirname "$lc_file")/$lc_path"
    [ -f "$lc_base" ] || lc_base="$lc_path"
    [ -f "$lc_base" ] || continue          # unresolvable → undecidable, not a failure
    lc_real=$(num "$(wc -l < "$lc_base" | tr -d ' ')")
    lc_n=$((lc_n+1)); claims=$((claims+1))
    if [ "$lc_approx" = "1" ]; then
      # An approximate claim is allowed to drift, but not by an order of magnitude.
      [ "$lc_real" -gt 0 ] && [ $(( (lc_want > lc_real ? lc_want - lc_real : lc_real - lc_want) * 100 / lc_real )) -gt 15 ] && \
        warn "$lc_file:$lc_ln: '$lc_path' claimed ~$lc_want lines, really $lc_real" "an approximate claim may drift, but this is not drift"
    elif [ "$lc_want" != "$lc_real" ]; then
      bad "$lc_file:$lc_ln: '$lc_path' claimed $lc_want lines, really $lc_real" \
          "a hand-written size goes stale. Skills use it as a reading budget"
      wrong=$((wrong+1))
    fi
  done < <(
    { git ls-files '*.md' 2>/dev/null || find . -name '*.md' -not -path './node_modules/*'; } \
    | grep -vE '^(\./)?docs/lessons(-archive)?\.md$' \
    | while IFS= read -r f; do [ -f "$f" ] && awk -v F="$f" '
        {
          if ($0 !~ /[0-9,]+ lines/) next
          # A budget declaration ("a 42-line budget") is not a size claim — the T0 budget is compared
          # by the _claim calls above. Without this line the check produces a false positive on its
          # first real run, and a false positive is what makes a check get switched off (measured).
          if ($0 ~ /budget/) next
          line = $0
          # the path: a markdown link target or a backticked path, whichever comes first
          if (match(line, /\]\([^)]+\.(md|sh|json|html)\)/))      { pth = substr(line, RSTART+2, RLENGTH-3) }
          else if (match(line, /`[A-Za-z0-9_.\/-]+\.(md|sh|json|html)`/)) { pth = substr(line, RSTART+1, RLENGTH-2) }
          else next
          if (!match(line, /~?[0-9,]+ lines/)) next
          num = substr(line, RSTART, RLENGTH)
          approx = (num ~ /^~/) ? 1 : 0
          gsub(/[^0-9]/, "", num)
          if (num == "") next
          printf "%s\t%d\t%s\t%s\t%d\n", F, FNR, pth, num, approx
        }' "$f"; done
  )
  [ "$lc_n" -gt 0 ] && ok "${lc_n} file-size claims checked against the real files"

  [ "$wrong" -eq 0 ] && [ "$claims" -gt 0 ] && ok "${claims} numeric claims in the documents match reality"

  # ── name-list comparison ──
  # _claim above looks only at **numbers**. It cannot catch the class where the count is right but a name is not listed.
  # The same failure was observed twice: ① the vue axis really existed in the presets·packs·init menu but was missing
  # from 3 consumer documents (evaluation v5 · E-15 — only the count comparison went in then) ② after that, a third
  # pre-built seam (vue+node-api) shipped and again was not listed in the same 3 places.
  # Hardcoding the files that hold the enumeration is the point of this check — those files *are* the enumeration sites.
  # A missing file does not block (harness-change "a guard has three states" — undecidable).
  local nm_bad=0 nm_chk=0

  _names_in() {  # $1 document  $2 label  $3 names (space separated)
    local doc="$1" label="$2" names="$3" n miss=""
    [ -f "$doc" ] || return 0
    [ -n "$names" ] || return 0
    for n in $names; do
      grep -qF -- "$n" "$doc" || miss="$miss $n"
    done
    nm_chk=$((nm_chk+1))
    [ -z "$miss" ] && return 0
    bad "$doc: $label missing —$miss" "the path that added an axis did not pass through this document"
    nm_bad=$((nm_bad+1)); return 0
  }

  # A seam's directory name is `vue+node-api` while the documents write it as `vue` × `node-api`.
  # Demanding an exact match would FAIL a correct document. But leaving it loose as `fe.*be` means
  # **a line enumerating presets satisfies it by accident** — one line holds the frontend list and the backend
  # list together, so `vue.*node-api` matches (measured: false negatives at README:43 · getting-started:29).
  # So only **the two names adjacent across a single separator** are accepted.
  _seams_in() {  # $1 document  $2 seam directory names (space separated)
    local doc="$1" seams="$2" s fe be miss=""
    [ -f "$doc" ] || return 0
    [ -n "$seams" ] || return 0
    for s in $seams; do
      fe=${s%%+*}; be=${s##*+}
      grep -qE -- "$fe\`?[[:space:]]*(×|\+)[[:space:]]*\`?$be" "$doc" || miss="$miss $s"
    done
    nm_chk=$((nm_chk+1))
    [ -z "$miss" ] && return 0
    bad "$doc: pre-built seam missing —$miss" "this combination ships but the document does not know it"
    nm_bad=$((nm_bad+1)); return 0
  }

  local pnames snames doc
  pnames=$({ ls -1 presets/frontend/*.json presets/app/*.json presets/backend/*.json 2>/dev/null || true; } \
           | sed -E 's|.*/||; s|\.json$||' | sort -u | tr '\n' ' ')
  snames=$({ ls -1d guides/seams/*/ 2>/dev/null || true; } \
           | sed -E 's|.*/([^/]+)/$|\1|' | sort -u | tr '\n' ' ')

  for doc in README.md docs/presets.md docs/getting-started.md skills/orangekit-init/SKILL.md; do
    _names_in "$doc" "preset names" "$pnames"
  done
  # Skill names — the README is the only list a consumer reads before installing. 7 skills were in neither the README
  # nor docs, and one of them (test-driven-development) had 0 inbound edges outside the graph (evaluation v6 · E-32).
  _names_in README.md "skill names" "$(ls -1 skills 2>/dev/null | tr '\n' ' ')"
  # The illustrated manual (docs/manual/*.html) enumerates every skill as a `p-skill">/<name>` pill — the largest
  # consumer surface (4 files, 400KB), yet no comparison reached it, and after the 3.29.0 harness split the place where
  # names went stale outside any machine was exactly here and the README table (evaluation v8 · E-57). Compare **the name
  # set, not the count** — a count can legitimately differ with framing ("26 = devkit 25 + harness 1") but a set cannot.
  # The real assets are the development harness's two roots (skills/ · harness/skills/). marketing/ is an independent
  # plugin and out of the illustrated manual's scope. A document with no pill format, or a missing file, is undecidable — pass (three states).
  _manual_skills_in() {  # $1 document
    local doc="$1" real listed miss ghost
    [ -f "$doc" ] || return 0
    listed=$(grep -oE 'p-skill">/[a-z0-9-]+' "$doc" 2>/dev/null | sed 's|.*/||' | sort -u)
    [ -n "$listed" ] || return 0
    real=$(find skills harness/skills -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sed 's|.*/||' | sort -u)
    miss=$(comm -23 <(printf '%s\n' "$real") <(printf '%s\n' "$listed") | tr '\n' ' ')
    ghost=$(comm -13 <(printf '%s\n' "$real") <(printf '%s\n' "$listed") | tr '\n' ' ')
    nm_chk=$((nm_chk+1))
    [ -z "$miss$ghost" ] && return 0
    bad "$doc: manual skill list ≠ real${miss:+ — missing $miss}${ghost:+ — ghost $ghost}" \
        "the path that added and removed a skill did not pass through the illustrated manual — fix the pills and regenerate the variants with manual-variants.py"
    nm_bad=$((nm_bad+1)); return 0
  }
  for doc in docs/manual/user.html; do
    _manual_skills_in "$doc"
  done
  for doc in README.md docs/getting-started.md skills/stack-guide-generator/assets/guide-skeleton.md; do
    _seams_in "$doc" "$snames"
  done
  [ "$nm_bad" -eq 0 ] && [ "$nm_chk" -gt 0 ] && ok "${nm_chk} name lists in the documents match reality (presets·seams·manual skills)"

  # ── card `paths:` ↔ the load-condition table in the documents ──
  #
  # A third class, neither a number nor a name. A card's `paths:` sets **cost and reach at the same time**
  # (the breadth of conditional cards determines how much is resident in a coding session — evaluation v6 E-35),
  # yet the table describing it was maintained by hand. `skills/orangekit-init/SKILL.md` **merely wrote** below the
  # table that "this table must reflect the real frontmatter in rules/" and nothing compared them.
  # Measured: in that state 4 entries were stale — harness-change's `rules/**`·`agents/**`·`skills/**`
  # (paths never actually declared) · `dev/docs/**` (left behind after narrowing) · ui-design's
  # `**/*.{tsx,jsx,...}` (left behind after narrowing, in 2 places).
  #
  # The test is a **subset**: every glob written in the table must be in the declaration, but the table is under no
  # obligation to enumerate the whole declaration (a document has the right to summarize). So it catches only "stale
  # globs" and passes "omissions" — the opposite would become pressure to make the table hard to read.
  local gl_bad=0 gl_chk=0

  # Brace expansion. Puts `dev/docs/{prd,database}/**` and the 5 declared lines into the same form.
  # eval is used but **the character set is validated first** — there are no quotes·$·backticks·;·spaces,
  # so nothing beyond expansion can be interpreted. If validation fails, the original is emitted unexpanded.
  _glob_expand() {
    case "$1" in
      *'{'*)
        if printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.,*/{}-]+$'; then
          eval "printf '%s\n' $1" 2>/dev/null && return 0
        fi
        printf '%s\n' "$1" ;;
      *) printf '%s\n' "$1" ;;
    esac
  }

  _paths_row() {  # $1 document
    local doc="$1" card decl row cell g miss
    [ -f "$doc" ] || return 0
    for card in rules/*.md; do
      [ -f "$card" ] || continue
      # Declaration — expand and collect the paths globs from the frontmatter
      decl=$({ awk '/^---$/{n++; next} n==1 && /^[[:space:]]*-[[:space:]]*"/{print}' "$card" 2>/dev/null \
              | sed -E 's/.*"([^"]*)".*/\1/' || true; })
      [ -n "$decl" ] || continue                     # an always-loaded card has no table to compare
      local dexp=""
      while IFS= read -r g; do
        [ -z "$g" ] && continue
        dexp="$dexp $(_glob_expand "$g" | tr '\n' ' ')"
      done < <(printf '%s\n' "$decl")

      # The table row in the document — the line whose first cell is `<card name>`
      row=$({ grep -m1 -F "| \`$(basename "$card")\`" "$doc" 2>/dev/null || true; })
      [ -n "$row" ] || continue
      # Pull only backticked globs from the second cell. With no glob it is a prose summary, so not a comparison target.
      cell=$(printf '%s' "$row" | awk -F'|' '{print $3}')
      miss=""
      while IFS= read -r g; do
        [ -z "$g" ] && continue
        local ge
        while IFS= read -r ge; do
          [ -z "$ge" ] && continue
          case " $dexp " in *" $ge "*) ;; *) miss="$miss $g" ;; esac
        done < <(_glob_expand "$g")
      done < <(printf '%s' "$cell" | grep -oE '`[^`]*\*[^`]*`' | tr -d '`' | sort -u)
      gl_chk=$((gl_chk+1))
      if [ -n "$miss" ]; then
        bad "$doc: $(basename "$card") load-condition table claims a glob that is not declared —$miss" \
            "the path that narrowed or widened the card's paths: did not pass through this table"
        gl_bad=$((gl_bad+1))
      fi
    done
    return 0
  }
  _paths_row docs/harness-anatomy.md
  _paths_row skills/orangekit-init/SKILL.md
  [ "$gl_bad" -eq 0 ] && [ "$gl_chk" -gt 0 ] && ok "${gl_chk} card paths ↔ document load-condition tables agree"

  # Orphan assets — files in templates/ that nobody references.
  # CLAUDE.md.hbs was in that state (orangekit-init was using an inline copy, so nobody read it).
  local orph=0 ochk=0 ob
  while IFS= read -r tf; do
    [ -f "$tf" ] || continue
    ochk=$((ochk+1)); ob=$(basename "$tf")
    grep -rlF "$ob" --include='*.md' --include='*.sh' --include='*.json' \
      rules skills scripts agents templates docs CLAUDE.md README.md 2>/dev/null \
      | grep -vxF "$tf" | grep -q . && continue
    bad "orphan asset: $tf" "nobody references it — it is either a dead asset or a wiring gap"; orph=$((orph+1))
  done < <(find templates -type f 2>/dev/null)
  [ "$orph" -eq 0 ] && [ "$ochk" -gt 0 ] && ok "all ${ochk} files in templates/ are referenced"

  # Platform contract freshness (RC1) — the platform moves. A stale contract is more dangerous than none.
  local pc="docs/platform-contract.md"
  if [ ! -f "$pc" ]; then
    bad "$pc missing" "without a canonical source for platform behaviour you end up asserting from memory"
  else
    local oldest="" d dd now age
    now=$(date +%s)
    while IFS= read -r d; do
      dd=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null || date -d "$d" +%s 2>/dev/null || printf '')
      [ -z "$dd" ] && continue
      age=$(( (now - dd) / 86400 ))
      [ "$age" -gt 180 ] && oldest="$oldest $d(${age}d)"
    done < <(grep -oE 'checked: [0-9]{4}-[0-9]{2}-[0-9]{2}' "$pc" | awk '{print $2}')
    if [ -n "$oldest" ]; then
      warn "platform contract entries older than 180 days:$oldest" "re-confirm against the official documentation and refresh the date"
    else
      ok "platform contract check dates are current (within 180 days)"
    fi
  fi

  # ── 8. repo working norms (§ applying reach-path verification to this repo itself) ──
  #
  # This repo does not load its own rules/ — the plugin component types have no rules, and there is no
  # .claude/rules/ here either. The only path by which the norms for changing the harness arrive is the
  # root CLAUDE.md. A machine guards that reach (preventing a repeat of v2, where 697 lines of rules
  # reached nowhere for 4 months).
  sec "repo working norms"

  if [ ! -f CLAUDE.md ]; then
    bad "CLAUDE.md missing" "there is no path for the harness-change norms to reach a session (rules/ is for consumer distribution and is not loaded here)"
  else
    local cn; cn=$(num "$(wc -l < CLAUDE.md 2>/dev/null | tr -d ' ')")
    if [ "$cn" -le 60 ]; then
      ok "CLAUDE.md ${cn}/60 lines"
    else
      bad "CLAUDE.md ${cn} lines — over the 60-line budget" "this is injected into every session. Move the detail down into docs/ and leave only a pointer"
    fi

    # Dangling reference paths. Only ones containing a slash are examined — so that a filename the norms
    # mention as "do not create" (orangekit.config.json and the like) is not mistaken for a requirement that it exist.
    local cdang=0 cchk=0 p
    for p in $(grep -ohE '(\.?[A-Za-z0-9_-]+/)+[A-Za-z0-9_.-]+\.(md|sh|json)' CLAUDE.md 2>/dev/null | sort -u); do
      cchk=$((cchk+1))
      [ -e "$p" ] || { bad "CLAUDE.md → $p missing" "the canonical source the norms point at is gone — a broken reference breaks the norm"; cdang=$((cdang+1)); }
    done
    [ "$cdang" -eq 0 ] && ok "CLAUDE.md references — all ${cchk} exist"
  fi

  # Unimplemented fields in the schema
  if grep -q 'disabledSkills\|activeSkills' schema/orangekit.config.schema.json presets/*.json presets/*/*.json 2>/dev/null; then
    warn "unimplemented fields (activeSkills/disabledSkills) exist in the schema and presets" \
         "no code reads them to turn skills on and off. The gating does not work"
  else
    ok "no unimplemented gating fields"
  fi

  # The configuration surface ↔ the code that reads it. If no script, skill, or card reads a top-level field a
  # document promised with a section (`### key`), declared ≠ real — `workflow.p0/p6.enabled`·`customResources` were
  # in that state (evaluation v6 · E-30). There are two answers: implement it, or delete the declaration. This check only makes one of the two happen.
  # The schema and the init template are the **writing** side, so they do not count as evidence of reading.
  local cf="docs/configuration.md" ck cmiss="" cchk=0
  if [ -f "$cf" ]; then
    while IFS= read -r ck; do
      [ -z "$ck" ] && continue
      cchk=$((cchk+1))
      # There are three reading forms: a jq path (`.domains.`) · a quoted key (`"domains"`) · a template variable (`{{#if domains.x}}`)
      grep -rqE "(^|[^A-Za-z0-9_-])${ck}[.\"'}[:space:]]" scripts rules templates agents skills/*/SKILL.md skills/*/scripts 2>/dev/null \
        || cmiss="$cmiss $ck"
    done < <(grep -oE '^### [a-zA-Z]+$' "$cf" 2>/dev/null | sed 's/^### //' | sort -u)
    if [ -n "$cmiss" ]; then
      bad "configuration fields declared with no code reading them:$cmiss" "no code reads the fields the sections of $cf promise — implement them or delete the sections"
    elif [ "$cchk" -gt 0 ]; then
      ok "all ${cchk} configuration fields have code that reads them"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════
# --self-test : per-event fixture injection
# ════════════════════════════════════════════════════════════════════
run_self_test() {
  printf "\n${C_D}orangekit doctor --self-test${C_0}\n"
  sec "hook fixture injection"

  # Fixture injection points CLAUDE_PROJECT_DIR at **this repo** (below). That is intentional — making the hook
  # look at the real project is what self-test is, and verification against a synthetic project is done separately
  # by --consumer. But as a side effect the heartbeat·edges·baseline got mixed into the real usage record, and
  # --usage's "which path actually runs" became an assertion rather than a measurement (evaluation v3 · E-09).
  # So **what it looks at stays put and only what it writes** is redirected to a temporary directory.
  local stdir sfx=""
  stdir=$(mktemp -d 2>/dev/null) || stdir=""
  # There is only one RETURN trap — the $sfx of the static fixtures below is cleaned up here as well.
  # (Setting it twice makes the later one overwrite the earlier and leaves a temp directory behind)
  trap 'rm -rf "${stdir:-/nonexistent}" "${sfx:-/nonexistent}"; unset ORANGEKIT_STATE_DIR ORANGEKIT_HANDOFF_DIR' RETURN
  if [ -n "$stdir" ]; then
    export ORANGEKIT_STATE_DIR="$stdir"
    # Redirect handoff too. Isolating only the state log lets a fixture write real files into dev/handoff/
    # and the rotation pushes out real restore material (evaluation v5 · E-13).
    export ORANGEKIT_HANDOFF_DIR="$stdir/handoff"
  else
    warn "failed to create a temporary state directory" "fixture records get mixed into the real log — instrumentation contamination"
  fi

  local fx="scripts/fixtures"
  [ -d "$fx" ] || { bad "fixture directory missing: $fx"; return; }

  local hooks_json="hooks/hooks.json"
  command -v jq >/dev/null 2>&1 || { bad "jq required"; return; }

  # **Proof** of instrumentation isolation. It looks at behaviour, not at the shape of the code (a regex lint) —
  # the moment a fixture injection touches a real artifact, it fails. The state log was already redirected with
  # ORANGEKIT_STATE_DIR, but dev/handoff/ was left out and the rotation pushed out real files (evaluation v5 · E-13).
  local hd_before hd_after
  hd_before=$({ ls -1 dev/handoff 2>/dev/null || true; } | sort | tr '\n' ' ')

  local total=0 good=0
  # **Measure** the fixtures consumed. Re-deriving which fixture is used on the checking side
  # (reimplementing the ${event}.json interpolation + the literal references) creates one more copy,
  # and the moment the selection logic changes the check goes quietly wrong. Accumulate only what was actually fed.
  local used=""
  # Read the event → script mapping from hooks.json and run each with that event's fixture
  while IFS=$'\t' read -r event cmd; do
    [ -z "$cmd" ] && continue
    local f; f=$(printf '%s' "$cmd" | grep -oE 'scripts/[a-z0-9./-]+\.sh' | head -1)
    [ -n "$f" ] && [ -f "$f" ] || continue
    total=$((total+1))

    local fixture="$fx/${event}.json"
    [ -f "$fixture" ] || fixture="$fx/default.json"
    [ -f "$fixture" ] || { bad "$(basename "$f") [$event]: fixture missing"; continue; }
    used="$used$(basename "$fixture")
"

    local out err code
    out=$(CLAUDE_PROJECT_DIR="$ROOT" bash "$f" < "$fixture" 2>/tmp/orangekit_st_err); code=$?
    err=$(cat /tmp/orangekit_st_err 2>/dev/null); rm -f /tmp/orangekit_st_err

    if [ "$code" -ne 0 ] && [ "$code" -ne 2 ]; then
      bad "$(basename "$f") [$event]: exit $code" "${err:0:160}"
      continue
    fi
    if [ -n "$err" ]; then
      bad "$(basename "$f") [$event]: output on stderr" "${err:0:160}"
      continue
    fi
    # If there is output, check that it is in a form the event supports
    if [ -n "$out" ]; then
      case "$event" in
        Stop|SubagentStop|PreCompact|SessionEnd)
          if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
            if printf '%s' "$out" | jq -e 'has("decision") or has("reason")' >/dev/null 2>&1; then
              bad "$(basename "$f") [$event]: unsupported field in the output"; continue
            fi
          else
            bad "$(basename "$f") [$event]: plain-text output (this event requires JSON)"; continue
          fi
          ;;
      esac
    fi
    good=$((good+1))
    ok "$(basename "$f") [$event] → exit $code"
  done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[]?.hooks[]? | "\($e)\t\(.command)"' "$hooks_json" 2>/dev/null)

  printf "\n  hook self-test: ${good}/${total}\n"

  hd_after=$({ ls -1 dev/handoff 2>/dev/null || true; } | sort | tr '\n' ' ')
  if [ "$hd_before" = "$hd_after" ]; then
    ok "fixtures did not touch real artifacts (dev/handoff unchanged)"
  else
    bad "a fixture modified dev/handoff/" \
        "the instrumentation contaminates the data it measures — check the orangekit_handoff_dir() isolation"
  fi

  # Fallback proof — every registered event has a named fixture, so the `default.json` fallback above
  # **has never once executed**. A path that has never executed has no evidence that it works.
  # Whether the self-test burns in a new hook event the moment it is added hangs on this.
  local synth_fixture pcode=0
  synth_fixture="$fx/__orangekit_unregistered_event__.json"
  [ -f "$synth_fixture" ] || synth_fixture="$fx/default.json"
  if [ ! -f "$synth_fixture" ]; then
    bad "default.json missing" "there is no fallback for an unregistered event — a new hook enters the self-test blind spot"
  else
    CLAUDE_PROJECT_DIR="$ROOT" bash scripts/session-brief.sh < "$synth_fixture" >/dev/null 2>&1 || pcode=$?
    used="$used$(basename "$synth_fixture")
"
    if [ "$pcode" -eq 0 ] || [ "$pcode" -eq 2 ]; then
      ok "fixture fallback works (unregistered event → default.json → exit $pcode)"
    else
      bad "the fixture fallback is broken (exit $pcode)" "adding a new hook event will not get it burned in by the self-test"
    fi
  fi

  # ── positive fixtures (B-7): proving 'it blocks', not 'it is alive' ──
  # A harmless fixture only confirms exit 0. Whether input that ought to be blocked is actually
  # blocked with exit 2 needs a separate proof (v2 lesson: alive ≠ working).
  sec "positive fixtures (block verification)"
  # Prove each tool path separately. While the matcher was only Edit|Write|MultiEdit, a secret written by a Bash
  # heredoc had 0 blocking, and passing only the Write fixture kept that fact invisible (evaluation v5 · E-20).
  # A hole in coverage is **invisible without a per-path fixture**.
  local bfx bcode blabel bwant brest bout
  # A destructive command is on **a different axis** from a secret (it writes no file at all and makes something irreversible).
  # Different axes need separate fixtures — a passing secret fixture can coexist with 0 coverage on this side.
  #
  # The third field is the **expected reason**. Looking only at exit 2 passes a secret fixture even when it trips the
  # destructive-command branch — the fixtures were split to prove per-axis coverage and then nobody looked at which
  # axis caught it. The reason uses only **argument 1 (the title)** of `block`:
  # argument 2 (the pattern hint) contains a literal pattern (security-check.sh's "pattern: sk-proj-"),
  # so writing it here would get doctor.sh itself blocked by that hook.
  # The list is an array — the "block reasons ↔ fixtures" check below reads this array again.
  # Evaluation v6: of 22 blocking points, only 4 were proven by a fixture (E-29). One bypass (E-21) lived
  # for 4 months in a spot with no fixture — a reason's blocking is proven only when that reason has a fixture.
  local POS_FX=(
    "PreToolUse-block.json:Write secret injection:hardcoded AWS Access Key ID"
    "PreToolUse-bash-block.json:Bash heredoc secret injection:hardcoded AWS Access Key ID"
    "PreToolUse-bash-destructive.json:Bash destructive command:TRUNCATE — emptying an entire table"
    "PreToolUse-bash-heredoc-sql.json:DB client heredoc:DROP of a table/database/schema via DDL"
    "PreToolUse-bash-selfref-destructive.json:self-reference bypass attempt (destruction):DROP of a table/database/schema via DDL"
    "PreToolUse-bash-selfref-secret.json:self-reference bypass attempt (secret):hardcoded AWS Access Key ID"
    "PreToolUse-bash-commit-then-drop.json:execution segment after a commit message:DROP of a table/database/schema via DDL"
    # Command-substitution bypass — pins the regression where the E-22 false-positive repair also exempted the execution path.
    # A worked example of the discipline that an exemption (_message_cmd) must be proven **as strongly as** a blocking point.
    "PreToolUse-bash-commit-cmdsub.json:command substitution inside a commit message:DROP of a table/database/schema via DDL"
    "PreToolUse-bash-gh-body-cmdsub.json:command substitution inside a PR body:DROP of a table/database/schema via DDL"
    "PreToolUse-bash-stderr-null-write.json:stderr discarded + file write:hardcoded AWS Access Key ID"
    "PreToolUse-bash-delete-nowhere.json:DELETE without WHERE:DELETE FROM without WHERE"
    "PreToolUse-bash-supabase-reset.json:supabase reset:supabase db reset — resetting the local DB"
    "PreToolUse-bash-prisma-reset.json:prisma reset:prisma schema reset"
    "PreToolUse-bash-alembic-base.json:reverting every migration:reverting every migration"
    "PreToolUse-bash-filter-branch.json:git history rewrite:git history rewrite / mirror push"
    "PreToolUse-bash-force-push-main.json:force push to a shared branch:force push to a shared branch"
    "PreToolUse-bash-force-push-plus.json:+refspec force push (bypass attempt):force push to a shared branch"
    "PreToolUse-bash-push-delete-main.json:remote deletion of a shared branch:remote deletion of a shared branch"
    "PreToolUse-secret-github-pat.json:GitHub PAT:hardcoded GitHub Personal Access Token"
    "PreToolUse-secret-github-oauth.json:GitHub OAuth token:hardcoded GitHub token"
    "PreToolUse-secret-stripe.json:Stripe:hardcoded Stripe Secret Key"
    "PreToolUse-secret-toss.json:TossPayments:hardcoded TossPayments Secret Key"
    "PreToolUse-secret-kakao.json:KakaoPay:hardcoded KakaoPay secret"
    "PreToolUse-secret-openai.json:OpenAI:hardcoded OpenAI API Key"
    "PreToolUse-secret-anthropic.json:Anthropic:hardcoded Anthropic API Key"
    "PreToolUse-secret-google.json:Google:hardcoded Google API Key"
    "PreToolUse-secret-supabase-new.json:Supabase new-style key:hardcoded Supabase Secret Key"
    "PreToolUse-secret-supabase-service-role.json:Supabase service_role JWT:hardcoded Supabase Service Role Key"
    "PreToolUse-secret-supabase-jwt.json:Supabase JWT (no anon marker):suspected hardcoded Supabase JWT key"
    "PreToolUse-secret-pem.json:PEM private key:hardcoded Private Key"
    "PreToolUse-secret-gcp-sa.json:GCP service account JSON:hardcoded GCP Service Account JSON"
    "PreToolUse-secret-package-json.json:package.json secret:secret inside package.json"
  )
  # Fill a fixture's `@@FILL<n>@@` with n characters at run time. **So that the credential shapes the scanner catches**
  # (detectors like Stripe's that look only at a pattern with no checksum) **are not left in a file** — if they stay in
  # the repo, GitHub push protection blocks the push, and allow-listing it leaves the pattern in history forever.
  # What is fed to the hook is the fully assembled string, so the strength of the block proof is unchanged.
  _fx_fill() {   # $1 fixture path → stdout
    awk '{
      while (match($0, /@@FILL[0-9]+@@/)) {
        tok = substr($0, RSTART, RLENGTH)
        n = substr(tok, 7, length(tok) - 8) + 0
        s = ""; for (i = 0; i < n; i++) s = s "x"
        $0 = substr($0, 1, RSTART - 1) s substr($0, RSTART + RLENGTH)
      }
      print
    }' "$1"
  }

  for bfx in "${POS_FX[@]}"; do
    brest="${bfx#*:}"; bfx="$fx/${bfx%%:*}"
    blabel="${brest%%:*}"; bwant="${brest#*:}"
    if [ -f "$bfx" ] && [ -f scripts/security-check.sh ]; then
      bcode=0
      bout=$(_fx_fill "$bfx" | CLAUDE_PROJECT_DIR="$ROOT" bash scripts/security-check.sh 2>&1) || bcode=$?
      used="$used$(basename "$bfx")
"
      if [ "$bcode" -ne 2 ]; then
        bad "security-check: exit $bcode on $blabel" "the blocking hook failed to catch what it must catch — false negative"
      elif printf '%s' "$bout" | grep -qF "$bwant"; then
        ok "security-check: $blabel → exit 2 ('$bwant' — the intended reason)"
      else
        bad "security-check: $blabel was blocked for a different reason" \
            "expected '$bwant' / actual '$(printf '%s' "$bout" | grep -m1 'Blocked:' | sed 's/^[^:]*: *//')' — per-axis coverage is not proven"
      fi
    else
      warn "positive fixture missing ($bfx)" "the blocking power of that tool path is unproven"
    fi
  done

  # False-positive defence — an investigation command that **contains a secret string but writes no file** must pass.
  # A false positive makes the user turn the hook off, and a hook that is off blocks nothing.
  local okfx oklabel
  # Proves the three false positives reproduced in evaluation v6 (E-22 commit message · E-23 `2>/dev/null` · E-44 the
  # `; psql` string inside a file heredoc) together with a single self-referencing command passing.
  for okfx in "PreToolUse-bash-ok.json:investigation command containing a secret string" \
              "PreToolUse-bash-destructive-ok.json:investigation command containing destructive syntax" \
              "PreToolUse-bash-heredoc-authoring-ok.json:interpreter heredoc authoring command" \
              "PreToolUse-bash-selfref-ok.json:single command that runs doctor" \
              "PreToolUse-bash-commit-msg-ok.json:commit message containing DDL vocabulary" \
              "PreToolUse-bash-gh-title-ok.json:PR title containing DDL vocabulary" \
              "PreToolUse-bash-stderr-null-ok.json:investigation command with only stderr discarded" \
              "PreToolUse-bash-heredoc-file-dbstring-ok.json:DB client string in a file heredoc body" \
              "PreToolUse-bash-heredoc-after-dbcmd-ok.json:interpreter heredoc in a segment after a DB command"; do
    oklabel="${okfx#*:}"; okfx="$fx/${okfx%%:*}"
    [ -f "$okfx" ] || { warn "false-positive fixture missing ($okfx)" "the false-positive defence on that path is unproven"; continue; }
    used="$used$(basename "$okfx")
"
    bcode=0
    CLAUDE_PROJECT_DIR="$ROOT" bash scripts/security-check.sh < "$okfx" >/dev/null 2>&1 || bcode=$?
    if [ "$bcode" -eq 0 ]; then
      ok "security-check: $oklabel → exit 0 (no false positive)"
    else
      bad "security-check: exit $bcode on a harmless $oklabel" "false positive — the reason hooks get turned off"
    fi
  done

  # ── the undecidable branch of force push (three states) ────────────
  # A static fixture cannot prove it — undecidable arises only from a git state, **a repo with 0 commits**.
  # The expectation is not a block (exit 2) but a pass (exit 0) plus an explicit "undecidable". Folding it is a false positive.
  local ud udcode udout
  ud=$(mktemp -d 2>/dev/null) || ud=""
  if [ -n "$ud" ] && git -C "$ud" init -q 2>/dev/null; then
    udcode=0
    udout=$(jq -nc '{tool_name:"Bash",tool_input:{command:"git push -f"}}' \
      | ( cd "$ud" && CLAUDE_PROJECT_DIR="$ud" bash "$ROOT/scripts/security-check.sh" 2>&1 >/dev/null )) || udcode=$?
    if [ "$udcode" -eq 0 ] && printf '%s' "$udout" | grep -q 'Undecidable'; then
      ok "security-check: force-push target undecidable → exit 0 + explicit report (three states)"
    else
      bad "security-check: the undecidable branch gave exit $udcode / $(printf '%s' "$udout" | grep -c 'Undecidable') reports" \
          "an undecidable verdict was folded into a block, or passed silently"
    fi
  else
    warn "failed to create a temporary git repo" "the undecidable branch is unproven"
  fi
  rm -rf "${ud:-/nonexistent}"

  # ── Scratch-DB drop exemption — the exemption and the protection in one place ─────────────────────
  # A static fixture cannot prove it — the exemption depends on the project config (the connection URL in .env) and the record of earlier commands
  # (created-dbs). Prove the exemption (exit 0) and the protection (exit 2) **together**: looking only at the exemption misses
  # the hole widening, and looking only at the protection misses the false positive coming back (benchmark B2: 17 scratch-DB blocks).
  # The environment is emptied (env -i) — if the developer shell's DATABASE_URL changes the verdict, it is not a proof.
  local sd sdwant sdcase sdcmd sdcode sddir sderr sdenv sdok=0 sdbad=0
  local D='DROP DATABASE' C='CREATE DATABASE'
  sd=$(mktemp -d 2>/dev/null) || sd=""
  if [ -n "$sd" ] && command -v jq >/dev/null 2>&1; then
    mkdir -p "$sd/proj" "$sd/nocfg" "$sd/envonly"
    printf 'DATABASE_URL=postgres://u:p@localhost:5432/app\n' > "$sd/proj/.env"
    while IFS='|' read -r sdwant sdcase sdcmd; do
      [ -z "$sdwant" ] && continue
      # Three sources of the connection URL: a .env file · environment variables only (no .env — the benchmark is this condition) · none
      sddir="$sd/proj"; sdenv=""
      case "$sdcase" in
        "no connection config") sddir="$sd/nocfg" ;;
        environment\ variable\ only*) sddir="$sd/envonly"; sdenv="postgres://u:p@localhost:5432/app" ;;
      esac
      sdcode=0
      # Look at stderr too — even when the verdict is right, if the ERR trap rang the hook tripped midway
      sderr=$(jq -nc --arg c "$sdcmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$sddir" ORANGEKIT_STATE_DIR="$sddir/.state" \
            ${sdenv:+DATABASE_URL="$sdenv"} bash "$ROOT/scripts/security-check.sh" 2>&1 >/dev/null) || sdcode=$?
      if [ "$sdcode" = "$sdwant" ] && ! printf '%s' "$sderr" | grep -q 'ERROR line'; then
        sdok=$((sdok+1))
      else
        sdbad=$((sdbad+1))
        bad "security-check scratch DB: $sdcase → exit $sdcode (expected $sdwant)$(printf '%s' "$sderr" | grep -m1 -o 'ERROR line [0-9]*' | sed 's/^/ · /')" \
            "$([ "$sdwant" = 0 ] && printf 'false positive — cleanup of a scratch DB the agent created is blocked' || printf 'false negative — deleting a DB that must be protected gets through')"
      fi
    done <<EOF
0|scratch DB re-created in the same command|psql -c "$D IF EXISTS app_fresh" -c "$C app_fresh"
0|DB created earlier — creation|psql -c "$C rv_scratch"
0|DB created earlier — cleanup|psql -c "$D rv_scratch"
2|project DB (connection URL in .env)|psql -c "$D app"
2|project DB reset (drop and re-create)|psql -c "$D IF EXISTS app" -c "$C app"
2|system DB|psql -c "$D IF EXISTS postgres" -c "$C postgres"
2|DB never created (another project)|psql -c "$D other_project_dev"
2|name is a variable|psql -c "$D IF EXISTS \$N" -c "$C \$N"
2|CREATE only written to a file|echo "$C wfile" > x.sql && psql -c "$D wfile"
2|no connection config|psql -c "$D IF EXISTS app_fresh" -c "$C app_fresh"
0|environment variable only — scratch DB|psql -c "$D IF EXISTS app_fresh" -c "$C app_fresh"
2|environment variable only — project DB|psql -c "$D IF EXISTS app" -c "$C app"
EOF
    [ "$sdbad" -eq 0 ] && ok "security-check: scratch-DB exemption $sdok/$sdok — only DBs the agent created open, project·system·someone else's DBs stay blocked"
  else
    warn "temporary directory or jq missing" "the boundary of the scratch-DB exemption is unproven"
  fi
  rm -rf "${sd:-/nonexistent}"

  # ── Shell-computed names and table drops — expand to values, prove by measurement ──────────────
  # The roots of the three residual false positives (benchmark B3): ① the name is a value (a loop variable · an assignment), not characters, yet the hook saw only characters ② a table has no proof rule, so
  # DROP TABLE was blocked in every case. So loops and assignments in the same command are expanded to values before judging, and DROP TABLE is exempted only when a read-only query
  # **measures** "absent · empty". Exemption (exit 0) and protection (exit 2) are proven together — the measurement is answered by a fake psql through files.
  # When it cannot be measured (no psql · connection failure · another DB · CASCADE · has rows) it must be blocked as today — undecidable is never collapsed into a pass.
  local td tdline tdwant tdlabel tdtbl tdcmd tdrest tdcode tderr tdpath tdok=0 tdbad=0
  td=$(mktemp -d 2>/dev/null) || td=""
  if [ -n "$td" ] && command -v jq >/dev/null 2>&1; then
    mkdir -p "$td/proj" "$td/bin" "$td/tbl"
    printf 'DATABASE_URL=postgres://u:p@localhost:5432/app\n' > "$td/proj/.env"
    cat > "$td/bin/psql" <<'STUB'
#!/bin/bash
# Fake psql — answers the hook's read-only queries through files: if $FAKE_PSQL_DIR/<table> exists the table exists, and if its content is rows it has rows
[ -f "$FAKE_PSQL_DIR/.down" ] && exit 2
q=""; while [ $# -gt 0 ]; do [ "$1" = "-c" ] && { q="$2"; break; }; shift; done
t=$(printf '%s' "$q" | sed -nE "s/.*to_regclass\('([^']*)'\).*/\1/p")
if [ -n "$t" ]; then [ -f "$FAKE_PSQL_DIR/$t" ] && echo t || echo f; exit 0; fi
t=$(printf '%s' "$q" | sed -nE 's/.*FROM ([^ ]*) LIMIT 1.*/\1/p')
[ "$(cat "$FAKE_PSQL_DIR/$t" 2>/dev/null)" = rows ] && echo t || echo f
STUB
    chmod +x "$td/bin/psql"
    _td_run() {   # $1 want  $2 label  $3 tables  $4 command
      local kv js tdurl="postgres://u:p@localhost:5432/app"
      rm -rf "$td/tbl"; mkdir -p "$td/tbl"
      for kv in ${3//,/ }; do case "$kv" in -|nostub|noenvurl|"") ;; down) : > "$td/tbl/.down" ;; *) printf '%s' "${kv#*=}" > "$td/tbl/${kv%%=*}" ;; esac; done
      tdpath="$td/bin:$PATH"; [ "$3" = nostub ] && tdpath="$PATH"; [ "$3" = noenvurl ] && tdurl=""
      tdcode=0
      tderr=$(jq -nc --arg c "$4" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | env -i PATH="$tdpath" HOME="$HOME" CLAUDE_PROJECT_DIR="$td/proj" ORANGEKIT_STATE_DIR="$td/proj/.state" FAKE_PSQL_DIR="$td/tbl" ${tdurl:+DATABASE_URL="$tdurl"} \
            bash "$ROOT/scripts/security-check.sh" 2>&1 >/dev/null) || tdcode=$?
      # Even when the verdict is right, an ERR trap that fired means the hook tripped midway, and a block must come for the **intended reason** (data destruction)
      if [ "$tdcode" = "$1" ] && ! printf '%s' "$tderr" | grep -q 'ERROR line' \
         && { [ "$1" = 0 ] || printf '%s' "$tderr" | grep -qF 'table/database/schema'; }; then
        tdok=$((tdok+1))
      else
        tdbad=$((tdbad+1))
        bad "security-check shell values · tables: $2 → exit $tdcode (expected $1)$(printf '%s' "$tderr" | grep -m1 -o 'ERROR line [0-9]*' | sed 's/^/ · /')" \
            "$([ "$1" = 0 ] && printf 'false positive — cleanup of a scratch object is blocked' || printf 'missed detection — a deletion that must be protected gets through')"
      fi
    }
    while IFS= read -r tdline; do
      [ -z "$tdline" ] && continue
      tdwant=${tdline%%@@*}; tdrest=${tdline#*@@}; tdlabel=${tdrest%%@@*}; tdrest=${tdrest#*@@}; tdtbl=${tdrest%%@@*}; tdcmd=${tdrest#*@@}
      tdcmd=${tdcmd//@D@/DROP DATABASE}; tdcmd=${tdcmd//@C@/CREATE DATABASE}; tdcmd=${tdcmd//@T@/DROP TABLE}
      _td_run "$tdwant" "$tdlabel" "$tdtbl" "$tdcmd"
    done <<'CASES'
0@@two scratch DBs are created (recorded)@@-@@A=x; psql "$A" -qc "@C@ ot_final"; psql "$A" -qc "@C@ ot_work"
0@@recorded scratch DBs cleaned up with a loop [B3 run5]@@-@@A=x; for d in ot_final ot_work; do psql "$A" -qc "@D@ IF EXISTS $d"; done; echo done
0@@loop in the ${d} form@@-@@for d in ot_final ot_work; do psql -qc "@D@ IF EXISTS ${d}"; done
2@@the project DB is mixed into the loop@@-@@for d in ot_final app; do psql -qc "@D@ IF EXISTS $d"; done
2@@a DB that was never created, via a loop@@-@@for d in other1 other2; do psql -qc "@D@ IF EXISTS $d"; done
2@@loop over a variable list (cannot be expanded)@@-@@for d in $LIST; do psql -qc "@D@ IF EXISTS $d"; done
2@@glob loop@@-@@for d in app_*; do psql -qc "@D@ IF EXISTS $d"; done
2@@nested loops are not expanded@@-@@for d in ot_final ot_work; do for e in 1 2; do psql -qc "@D@ IF EXISTS $d"; done; done
0@@a name unique to each run (date)@@-@@N=app_fresh_$(date +%s); psql -qc "@C@ $N"; psql -qc "@D@ $N"
0@@a name unique to each run ($$)@@-@@N=scratch_$$; psql -qc "@D@ IF EXISTS $N"
0@@a literal name created in the same command@@-@@N=tmpdb1; psql -qc "@C@ $N"; psql -qc "@D@ $N"
2@@the assigned value is the project DB@@-@@N=app; psql -qc "@D@ $N"
2@@assigned by command substitution (cannot be expanded)@@-@@N=$(cat name.txt); psql -qc "@D@ $N"
2@@re-assigned to the project DB just before the drop@@-@@N=scratch1; psql -qc "@C@ $N"; N=app; psql -qc "@D@ $N"
2@@a system DB through a variable@@-@@N=postgres; psql -qc "@D@ $N"
0@@the table is absent (defensive IF EXISTS) [B3 run6]@@-@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS phase1_snapshot_check" 2>/dev/null; echo ok
0@@a not-yet-existing probe table created and dropped in the same command [B3 run5]@@-@@echo 'CREATE TABLE tmp_probe (id int);' > migrations/0000_probe.sql && npm run db:migrate 2>&1 | tail -2; rm migrations/0000_probe.sql; psql "$DATABASE_URL" -qc "@T@ tmp_probe; DELETE FROM schema_migrations WHERE name='0000_probe.sql';"
0@@the table exists but is empty@@scratch_t=empty@@psql "$DATABASE_URL" -qc "@T@ scratch_t"
2@@a table that has rows@@users=rows@@psql "$DATABASE_URL" -qc "@T@ users"
2@@even when empty, CASCADE deletes dependent objects@@scratch_t=empty@@psql "$DATABASE_URL" -qc "@T@ scratch_t CASCADE"
0@@CASCADE on an absent table (nothing to delete)@@-@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost CASCADE"
0@@several tables, all absent@@-@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS a1, b1"
2@@one of several tables has rows@@b1=rows@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS a1, b1"
2@@cannot connect to the DB (undecidable → blocked)@@down@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@psql is not on PATH (undecidable → blocked)@@nostub@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@psql pointing at another DB (URL variable)@@-@@psql "$ADMIN_URL" -qc "@T@ IF EXISTS ghost"
2@@psql -d another DB@@-@@psql -d other -qc "@T@ IF EXISTS ghost"
2@@psql -h another host@@-@@psql -h db.prod.example "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@a quoted mixed-case identifier@@-@@psql "$DATABASE_URL" -qc '@T@ IF EXISTS "Users"'
2@@DROP SCHEMA is never exempt@@-@@psql "$DATABASE_URL" -qc 'DROP SCHEMA public CASCADE; CREATE SCHEMA public'
2@@a client that is not psql (mysql)@@-@@mysql -e "@T@ IF EXISTS ghost"
2@@a DB drop and a table with rows in one list@@users=rows@@psql "$DATABASE_URL" -qc "@D@ IF EXISTS app_x; @T@ users"
2@@the same command overrides DATABASE_URL (measured DB ≠ executed DB)@@-@@DATABASE_URL=postgres://x/prod psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@the same command exports a different DATABASE_URL@@-@@export DATABASE_URL="${DATABASE_URL%/*}/other"; psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@the same command sets PGHOST@@-@@PGHOST=prod.example psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
2@@psql with no connection argument (connects with the PG* defaults)@@-@@psql -qc "@T@ IF EXISTS ghost"
2@@DATABASE_URL only in .env, not in the environment variables@@noenvurl@@psql "$DATABASE_URL" -qc "@T@ IF EXISTS ghost"
CASES
    # In heredoc SQL the DROP is on a different line from psql, so the connection cannot be proven — it is blocked as today (a known limit)
    _td_run 2 "DROP TABLE in heredoc SQL (connection unproven)" - "$(printf 'psql "$DATABASE_URL" <<%sSQL%s\nDROP TABLE IF EXISTS t1;\nSQL' "'" "'")"
    [ "$tdbad" -eq 0 ] && ok "security-check: shell-value expansion · table measurement $tdok/$tdok — only provable scratch objects open; project, system and unmeasurable stay blocked"
  else
    warn "temp directory or jq missing" "the boundary of shell-value expansion and table measurement is unproven"
  fi
  rm -rf "${td:-/nonexistent}"

  # ── Prior-knowledge gate (rule cards · skills) ──────────────────────────────
  # An agent finishes its judgement in its head and goes straight to writing the file — a `paths:` card comes up only when read and a skill is called only when
  # the model picks it (benchmark B3: card reached before the first table 1/3, TDD skill called 0/9).
  # The gate sends back, once, the first write made before the card · skill that owns the path has entered this session.
  # To prove: ① if not called, exit 2 **naming that item** ② once per session per item (no infinite loop)
  # ③ if called, pass (a Read to the end · cat · a Read of a matching file · a Skill call · a /command) ④ compaction and partial reads are void
  # ⑤ Bash writes (heredoc · sed -i) get the same verdict, and a `>` inside a heredoc body is not a write ⑥ overwrites · Edit · out of jurisdiction · undecidable pass
  # ⑦ the TDD skill only when a test runner exists, and test files are excluded.
  local nd gwant gexp gtool garg gtr gsid glabel gcode gerr gok=0 gbad=0 gphase
  nd=$(mktemp -d 2>/dev/null) || nd=""
  if [ -n "$nd" ] && command -v jq >/dev/null 2>&1; then
    mkdir -p "$nd/.claude/rules" "$nd/migrations" "$nd/tr"
    for glabel in data-modeling ui-design code-change workflow-routing; do cp "$ROOT/rules/$glabel.md" "$nd/.claude/rules/"; done
    : > "$nd/migrations/0001_init.sql"
    _tl() {   # one transcript line: C | R path [limit] | B command | S skill | U user sentence
      case "$1" in
        C) jq -nc '{type:"system",subtype:"compact_boundary"}' ;;
        R) jq -nc --arg v "$2" --arg l "${3:-}" '{type:"assistant",message:{content:[{type:"tool_use",name:"Read",input:({file_path:$v} + (if $l=="" then {} else {limit:($l|tonumber)} end))}]}}' ;;
        B) jq -nc --arg v "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$v}}]}}' ;;
        S) jq -nc --arg v "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:"Skill",input:{skill:$v}}]}}' ;;
        U) jq -nc --arg v "$2" '{type:"user",message:{content:$v}}' ;;
      esac; }
    local rr="$nd/.claude/rules"
    : > "$nd/tr/none.jsonl"
    _tl R "$rr/data-modeling.md" > "$nd/tr/read.jsonl"
    { _tl R "$rr/data-modeling.md"; _tl C; } > "$nd/tr/compacted.jsonl"
    _tl R "$nd/migrations/0001_init.sql" > "$nd/tr/native.jsonl"
    _tl B "cat .claude/rules/data-modeling.md stack.md | head -400" > "$nd/tr/cat.jsonl"
    _tl B "head -60 .claude/rules/data-modeling.md" > "$nd/tr/head.jsonl"
    _tl R "$rr/data-modeling.md" 60 > "$nd/tr/partial.jsonl"
    _tl R "$rr/code-change.md" > "$nd/tr/code.jsonl"
    { _tl R "$rr/code-change.md"; _tl S "orangekit-product:test-driven-development"; } > "$nd/tr/code-tdd.jsonl"
    _tl S "orangekit-product:dev-docs-generator" > "$nd/tr/docs-skill.jsonl"
    _tl U "<command-name>/dev-docs-generator</command-name> feature 1" > "$nd/tr/docs-cmd.jsonl"
    _gate() {   # $1 tool $2 path or command (\n allowed) $3 transcript (-=none) $4 session
      local a; a=$(printf '%b' "$2")
      jq -nc --arg t "$1" --arg a "$a" --arg tp "$3" --arg s "$4" --arg cwd "$nd" \
        '{session_id:$s,cwd:$cwd,tool_name:$t,hook_event_name:"PreToolUse"}
         + (if $t=="Bash" then {tool_input:{command:$a}} else {tool_input:{file_path:$a,content:"x",old_string:"a",new_string:"b"}} end)
         + (if $tp=="-" then {} else {transcript_path:$tp} end)' \
        | env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$nd" ORANGEKIT_STATE_DIR="$nd/.state" CLAUDE_PLUGIN_ROOT="$ROOT" \
            bash "$ROOT/scripts/security-check.sh" >"$nd/out" 2>"$nd/err"
    }
    _gcase() {
      gwant=$1 gexp=$2 gtool=$3 garg=$4 gtr=$5 gsid=$6 glabel=$7
      [ "$gtool" = Bash ] || garg="$nd/$garg"
      [ "$gtr" = - ] || gtr="$nd/tr/$gtr.jsonl"
      gcode=0; _gate "$gtool" "$garg" "$gtr" "$gsid" || gcode=$?
      gerr=$(cat "$nd/err" "$nd/out" 2>/dev/null)
      if [ "$gcode" -eq "$gwant" ] && { [ "$gexp" = "-" ] || printf '%s' "$gerr" | grep -qF -- "$gexp"; }; then
        gok=$((gok+1))
      else
        gbad=$((gbad+1)); bad "prior-knowledge gate: $glabel → exit $gcode (expected $gwant, reason \"$gexp\")" "$(printf '%s' "$gerr" | head -3)"
      fi
    }
    for gphase in norunner runner; do
      [ "$gphase" = runner ] && printf '{"scripts":{"test":"vitest run"}}\n' > "$nd/package.json"
      while IFS='|' read -r gwant gexp gtool garg gtr gsid glabel; do
        [ -z "$gwant" ] && continue
        case "$glabel" in "[$gphase]"*) ;; *) continue ;; esac
        _gcase "$gwant" "$gexp" "$gtool" "$garg" "$gtr" "$gphase-$gsid" "$glabel"
      done <<'CASES'
2|data-modeling.md|Write|migrations/0002_core.sql|none|s1|[norunner] new migration · card not read → blocked, naming the data-modeling card
0|announced once in this session|Write|migrations/0003_more.sql|none|s1|[norunner] second time in the same session → not blocked, a notice (no infinite loop)
2|data-modeling.md|Write|dev/docs/database/rewards.md|none|s2|[norunner] a new DB design doc is blocked by the same card (at design time)
0|-|Write|migrations/0002_core.sql|read|s3|[norunner] card Read to the end → pass
2|data-modeling.md|Write|migrations/0002_core.sql|compacted|s4|[norunner] compacted after reading → must read again
0|-|Write|migrations/0002_core.sql|native|s5|[norunner] a matching file was Read (native load) → pass
0|-|Write|migrations/0002_core.sql|cat|s6|[norunner] whole card read with cat → pass
2|data-modeling.md|Write|migrations/0002_core.sql|head|s7|[norunner] only the front with head → blocked
2|data-modeling.md|Write|migrations/0002_core.sql|partial|s8|[norunner] Read limit 60 (partial read) → blocked
2|ui-design.md|Write|src/components/Card.tsx|read|s9|[norunner] only another card read, then a new UI file → blocked, naming ui-design
0|-|Write|migrations/0001_init.sql|none|s10|[norunner] overwriting an existing file → not blocked
0|-|Edit|migrations/0002_core.sql|none|s11|[norunner] Edit → not blocked
0|-|Write|notes.txt|none|s12|[norunner] a new file in nobody's jurisdiction → not blocked
0|cannot be determined|Write|migrations/0002_core.sql|-|s13|[norunner] no transcript (undecidable) → not blocked, a notice
2|dev-docs-generator|Write|dev/active/feat/plan.md|none|s14|[norunner] new dev doc · skill not called → blocked, naming dev-docs-generator
0|-|Write|dev/active/feat/plan.md|docs-skill|s15|[norunner] dev-docs-generator called through Skill → pass
0|-|Write|dev/active/feat/plan.md|docs-cmd|s16|[norunner] the user called it with /dev-docs-generator → pass
0|-|Write|src/server/points.ts|code|s17|[norunner] no test runner → the TDD skill is not required
2|data-modeling.md|Bash|cat > migrations/0009_x.sql <<'EOF'\nCREATE TABLE a (id int);\nEOF|none|s18|[norunner] new migration via a Bash heredoc → blocked
2|data-modeling.md|Bash|sed -i '' 's/int/bigint/' migrations/0001_init.sql|none|s19|[norunner] editing an existing migration with Bash sed -i → blocked (Bash does not force a Read)
0|-|Bash|cat > notes.txt <<'EOF'\nsee > migrations/0010_y.sql later\nEOF|none|s20|[norunner] a `>` inside a heredoc body is not a write → pass
0|-|Bash|npm test > /tmp/test.log 2>&1|none|s21|[norunner] a log outside the project → pass
0|-|Bash|cat > migrations/0009_x.sql <<'EOF'\nCREATE TABLE a (id int);\nEOF|read|s22|[norunner] Bash heredoc after reading the card → pass
2|test-driven-development|Write|src/server/points.ts|code|s1|[runner] test runner present · new behavior code · TDD not called → blocked
0|-|Write|src/server/points.ts|code-tdd|s2|[runner] TDD skill called → pass
0|-|Write|src/server/points.test.ts|code|s3|[runner] a test file → TDD not required
CASES
    done
    [ "$gbad" -eq 0 ] && ok "security-check: prior-knowledge gate $gok/$gok — write only after calling the owning card · skill (Write · Bash), once per item per session, undecidable passes"
  else
    warn "temp directory or jq missing" "the prior-knowledge gate is unproven"
  fi
  rm -rf "${nd:-/nonexistent}"

  # ── block reasons ↔ fixtures ──────────────────────────────────────
  # "Orphan fixtures" looks only in the fixture→check direction. The reverse — does **each blocking reason** in the
  # hook have a fixture that proves it — was missing, so only 4 of 22 blocking points were proven for 4 months.
  # Pull the reason titles (argument 1 of dblock/block) out of the hook and compare them with the expected reasons in POS_FX above.
  local reason rmiss="" rchk=0
  while IFS= read -r reason; do
    [ -z "$reason" ] && continue
    rchk=$((rchk+1))
    printf '%s\n' "${POS_FX[@]}" | grep -qF -- ":$reason" || rmiss="$rmiss
      · $reason"
  done < <(grep -oE '^[[:space:]]*(&& |\|\| )?(dblock|block) "[^"]+"' scripts/security-check.sh 2>/dev/null \
           | sed -E 's/^[[:space:]]*(&& |\|\| )?(dblock|block) "//; s/"$//; s/ \(\$[a-z_]+\)$//' | sort -u)
  if [ -n "$rmiss" ]; then
    warn "of ${rchk} blocking reasons, these have no fixture:$rmiss" "the blocking of that reason is unproven — alive ≠ working"
  else
    ok "all ${rchk} blocking reasons are proven by a fixture"
  fi

  # ── .env exemption (v3.26.0) ───────────────────────────────────────
  # The **legitimate destination** for a secret is a gitignored .env file, and the hook was blocking writes there
  # too — the block message said "move it to .env.local" while blocking that very file, a contradiction.
  #
  # This exemption **depends on git state**, so a static JSON fixture cannot prove it.
  # A temporary repo is created to control whether the file is ignored. Three — really four — things must be proven:
  #   ① an ignored .env passes   ② a non-ignored .env is still blocked
  #   ③ ordinary source does not regress  ④ when undecidable (outside a repo) there is no exemption
  local sc et ng
  sc="$(pwd)/scripts/security-check.sh"
  et=$(mktemp -d 2>/dev/null) || et=""
  ng=$(mktemp -d 2>/dev/null) || ng=""
  if [ -z "$et" ] || [ -z "$ng" ]; then
    warn "failed to create a temporary directory" "the .env exemption is unproven"
  elif ! git -C "$et" init -q 2>/dev/null; then
    warn "git init failed" "the .env exemption is unproven (no git?)"
  else
    printf '.env.local\n' > "$et/.gitignore"
    mkdir -p "$et/src"
    # The key is **assembled from fragments** — leaving a matching literal in the body of this script would make the
    # hook block its own checking script whenever doctor.sh is edited.
    local kpre='sk-proj-' kbody='SELFTESTKEYAAAABBBBCCCCDDDD'
    local ekey="$kpre$kbody"
    local ecase epath ewant elabel erest ecode ewhere
    for ecase in "$et:.env.local:0:gitignored .env — exemption works" \
                 "$et:.env.production:2:non-gitignored .env — blocking kept" \
                 "$et:src/config.ts:2:ordinary source — no regression" \
                 "$ng:.env.local:2:outside a repo — undecidable, so no exemption"; do
      ewhere="${ecase%%:*}"; erest="${ecase#*:}"
      epath="${erest%%:*}"; erest="${erest#*:}"
      ewant="${erest%%:*}"; elabel="${erest#*:}"
      ecode=0
      jq -nc --arg p "$epath" --arg k "$ekey" \
        '{session_id:"orangekit-doctor-test",cwd:".",tool_name:"Write",hook_event_name:"PreToolUse",tool_input:{file_path:$p,content:("OPENAI_API_KEY=" + $k + "\n")}}' \
        | ( cd "$ewhere" && CLAUDE_PROJECT_DIR="$ewhere" bash "$sc" >/dev/null 2>&1 ) || ecode=$?
      if [ "$ecode" -eq "$ewant" ]; then
        ok ".env exemption: $elabel → exit $ecode"
      else
        bad ".env exemption: $elabel → exit $ecode (expected $ewant)" \
            "$( [ "$ewant" = 0 ] && printf 'writing to the legitimate destination is impossible — real usage is blocked' \
                                 || printf 'the exemption is opened too wide — a secret could get committed' )"
      fi
    done
  fi
  rm -rf "${et:-/nonexistent}" "${ng:-/nonexistent}"

  # ── positive fixtures for the static checks (RC4) ─────────────────
  # The static checks (always-loaded card·substitution notation·split Phase table·card table count·undeclared in graph)
  # used to be proven by planting a defect by hand. That proof is not reproducible, and on one occasion
  # **the fixture was never planted at all and it still looked like a "pass"** (it targeted a filename that did not exist).
  #
  # So it is split into two stages:
  #   1) fixture validity — is the string we meant to plant **actually in** that file
  #   2) detection — in that state, does the check emit that message (+ not before planting)
  # If 1 fails, the result of 2 means nothing.
  sec "positive fixtures for the static checks"

  sfx=$(mktemp -d 2>/dev/null) || { warn "failed to create a temporary directory" "static fixtures skipped"; sfx=""; }
  if [ -n "$sfx" ]; then
    # Cleanup is handled together with $stdir by the RETURN trap at the top of the function
    _fx_static_tree "$sfx/base" || bad "failed to build the static fixture tree"

    if [ -d "$sfx/base" ]; then
      # Baseline: the messages below must **not** appear (false-positive prevention)
      local base_out; base_out=$(bash "$0" --fast --root "$sfx/base" 2>&1; bash "$0" --graph --root "$sfx/base" 2>&1)
      local msg
      for msg in "no always-loaded rule card" "script path notation that is not substituted" \
                 "Phase table reappeared" "card table .* ≠" "skills not declared in the graph" \
                 "not declared" "store with no reader node" "not shipped" \
                 "preset names missing" "pre-built seam missing" "is not in the platform contract" \
                 "plugin skill on a consumer path" "dead skill reference" "repo name leak" \
                 "manual but disable-model-invocation is missing" "phase is not in the routing card" "nodes sharing the same path" \
                 "configuration fields declared with no code" "T0 budget claim" "plugin-relative paths in code blocks" "skill names missing" \
                 "plugin-context path in a rule card" "load-condition table claims a glob that is not declared" \
                 "manual-only count claim" "no graph manual"; do
        printf '%s' "$base_out" | grep -q "$msg" \
          && bad "baseline false positive: '$msg'" "detected with no defect present — the check becomes unusable"
      done
      ok "no baseline fixture false positives"

      _fx_static_case "$sfx" always-rule   'rules/workflow-routing.md' '^paths:' \
        "no always-loaded rule card" 'printf -- "---\npaths:\n  - \"src/**\"\n---\n" | cat - "$T/rules/workflow-routing.md" > "$T/r.tmp" && mv "$T/r.tmp" "$T/rules/workflow-routing.md"'

      # When a reference a card links to has disappeared — the reach path of progressive loading
      _fx_static_case "$sfx" ref-dangling 'rules/code-change.md' 'references/data-modeling/gone' \
        'progressive loading is cut' \
        "printf -- 'Pattern detail is in [gone.md](../references/data-modeling/gone.md).\n' >> \"\$T/rules/code-change.md\""

      # When the load-condition table in a document claims more than the card's paths: (\140 = backtick)
      _fx_static_case "$sfx" paths-table-drift 'docs/harness-anatomy.md' 'lib/\*\*' \
        'load-condition table claims a glob that is not declared' \
        'printf "| \140code-change.md\140 | \140lib/**\140 |\n" >> "$T/docs/harness-anatomy.md"'

      # When a card cites a path in the plugin repo context — once distributed it becomes a missing file
      _fx_static_case "$sfx" card-plugin-path 'rules/code-change.md' 'templates/CLAUDE.md.hbs' \
        'plugin-context path in a rule card' \
        "printf -- 'The template looks at \`templates/CLAUDE.md.hbs\`.\n' >> \"\$T/rules/code-change.md\""

      # When the number of a section moved during a split is left behind in the card
      _fx_static_case "$sfx" section-stale 'rules/code-change.md' '§7' \
        'that section does not exist' \
        "printf -- '## 1. Section\n\nSee §7 for detail.\n' >> \"\$T/rules/code-change.md\""

      # Manual-only declaration ↔ resident flag (both directions)
      _fx_static_case "$sfx" manual-unflagged 'skills/sample/SKILL.md' 'manual invocation only' \
        'manual-only but the description is resident' \
        "perl -pi -e 's/^description: x\$/description: x manual invocation only./' \"\$T/skills/sample/SKILL.md\""

      _fx_static_case "$sfx" flagged-routed 'skills/sample/SKILL.md' 'disable-model-invocation' \
        'model invocation blocked on an automatic-firing target' \
        "perl -pi -e 's/^description: x\$/description: x\\ndisable-model-invocation: true/' \"\$T/skills/sample/SKILL.md\"; printf -- '| P0 | cond | \`/sample\` |\n' >> \"\$T/rules/workflow-routing.md\""

      # A key not in the contract is silently ignored — orangekit-init sat resident with 'trigger: manual' for four months
      _fx_static_case "$sfx" legacy-trigger 'skills/sample/SKILL.md' '^trigger:' \
        'is not in the platform contract' \
        "perl -pi -e 's/^description: x\$/description: x\\ntrigger: manual/' \"\$T/skills/sample/SKILL.md\""

      # A declaration written on **a continuation line** of a folded description. The old check, which read only the first line, missed this.
      _fx_static_case "$sfx" manual-folded 'skills/sample/SKILL.md' 'manual invocation only' \
        'manual-only but the description is resident' \
        "perl -pi -e 's/^description: x\$/description: >-\\n  x\\n  manual invocation only./' \"\$T/skills/sample/SKILL.md\""

      _fx_static_case "$sfx" skill-dir     'skills/sample/SKILL.md' '<skill-dir>' \
        "script path notation that is not substituted" 'printf "bash <skill-dir>/scripts/x.sh\n" >> "$T/skills/sample/SKILL.md"'

      # A section with a heading and no body. Because this defect was only caught when a person looked during
      # an enhancement, 16 of them were left in the repo — once a machine started looking, none can remain.
      _fx_static_case "$sfx" empty-heading 'skills/sample/SKILL.md' '^## Empty' \
        'empty section heading' \
        'printf "\n## Empty\n\n## Next\n\nBody\n" >> "$T/skills/sample/SKILL.md"'

      # A bundled file unreachable from SKILL.md and from the repo. The reverse direction of "skill-internal references".
      _fx_static_case "$sfx" orphan-res 'skills/sample/references/dead.md' 'orphan' \
        'orphan resource' \
        'mkdir -p "$T/skills/sample/references" && printf "# orphan\n" > "$T/skills/sample/references/dead.md"'

      _fx_static_case "$sfx" phase-dup     'templates/CLAUDE.md.hbs' '^| P0' \
        "Phase table reappeared" 'printf "\n| Phase | Condition |\n| --- | --- |\n| P0 | x |\n" >> "$T/templates/CLAUDE.md.hbs"'

      _fx_static_case "$sfx" graph-missing 'skills/orphan-skill/SKILL.md' 'orphan-skill' \
        "skills not declared in the graph" 'mkdir -p "$T/skills/orphan-skill" && printf -- "---\nname: orphan-skill\ndescription: x\n---\n" > "$T/skills/orphan-skill/SKILL.md"' --graph

      # A hook registered but not declared in the graph (the G5 symmetry). While only the skill side was checked,
      # hooks were blind, and the requirement lived in rules/harness-change.md as a norm **only a human reads**.
      _fx_static_case "$sfx" hook-undeclared 'hooks/hooks.json' 'y\.sh' \
        "hooks not declared in the graph" 'jq ".hooks.Stop = [{\"hooks\":[{\"type\":\"command\",\"command\":\"bash scripts/y.sh\"}]}]" "$T/hooks/hooks.json" > "$T/h.tmp" && mv "$T/h.tmp" "$T/hooks/hooks.json" && printf -- "#!/bin/bash\nexit 0\n" > "$T/scripts/y.sh"' --graph

      # The routing card declares an invocation but the graph node has no phase (G6).
      # \140 is a backtick — an octal escape is used so eval does not interpret it as command substitution.
      _fx_static_case "$sfx" phase-unmapped 'rules/workflow-routing.md' '^\| P1' \
        'phase "P1" not declared' 'printf -- "| P1 | x | \\140/sample\\140 |\n" >> "$T/rules/workflow-routing.md"' --graph

      # A store with only writes and no reader node (G7) — not "the document exists" but "it is consumed".
      _fx_static_case "$sfx" store-orphan 'workflow.graph.json' '"store"' \
        "store with no reader node" 'jq ".nodes += [{\"id\":\"memo\",\"kind\":\"store\",\"path\":\"rules/code-change.md\"}] | .edges += [{\"from\":\"sample\",\"to\":\"memo\"}]" "$T/workflow.graph.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/workflow.graph.json"' --graph

      # The graph says manual but the frontmatter has no dmi (G8) — ui-ux-design really was in that state.
      # The marker must be on one line for grep to see it — jq -c produces single-line JSON (pretty-print splits every key onto its own line)
      _fx_static_case "$sfx" manual-no-dmi 'workflow.graph.json' '"id":"sample","kind":"skill","path":"skills/sample/SKILL.md","manual":true' \
        "manual but disable-model-invocation is missing" 'jq -c "(.nodes[] | select(.id==\"sample\")) += {\"manual\": true}" "$T/workflow.graph.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/workflow.graph.json"' --graph

      # The frontmatter is dmi but the graph node has no manual (G8' — the reverse of G8).
      # sample is in no routing·phase·invocation, so it does not collide with "model invocation blocked on an automatic-firing target".
      _fx_static_case "$sfx" dmi-not-manual 'skills/sample/SKILL.md' '^disable-model-invocation' \
        "no graph manual" 'printf -- "---\nname: sample\ndescription: x\ndisable-model-invocation: true\n---\nbash \${CLAUDE_SKILL_DIR}/scripts/x.sh\n" > "$T/skills/sample/SKILL.md"' --graph

      # A phase was attached in the graph but the routing card has no such row (G9 — the reverse of G6).
      _fx_static_case "$sfx" phase-not-in-card 'workflow.graph.json' '"P9"' \
        "phase is not in the routing card" 'jq "(.nodes[] | select(.id==\"sample\")) += {\"phase\": [\"P9\"]}" "$T/workflow.graph.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/workflow.graph.json"' --graph

      # Two nodes point at one file with no note (G10).
      _fx_static_case "$sfx" dup-path 'workflow.graph.json' '"sample2"' \
        "nodes sharing the same path" 'jq ".nodes += [{\"id\":\"sample2\",\"kind\":\"skill\",\"path\":\"skills/sample/SKILL.md\",\"manual\":true}]" "$T/workflow.graph.json" > "$T/g.tmp" && mv "$T/g.tmp" "$T/workflow.graph.json"' --graph

      # A configuration field a document promised with a section that no code reads (E-30).
      _fx_static_case "$sfx" config-ghost-field 'docs/configuration.md' '^### ghostField' \
        "configuration fields declared with no code reading them" 'printf -- "# Configuration\n\n### ghostField\n\nNobody reads it.\n" > "$T/docs/configuration.md"'

      # The T0 budget figure quoted in a card body differs from the check's constant (E-25).
      _fx_static_case "$sfx" t0-budget-drift 'rules/code-change.md' 'budget 40 lines' \
        "T0 budget claim 40 ≠ real" 'printf -- "\nWhen the T0 operating contract goes past budget 40 lines, doctor blocks it.\n" >> "$T/rules/code-change.md"; cp "$T/rules/code-change.md" "$T/rules/harness-change.md"'

      # A plugin-relative path inside a code block that is not substituted (E-34).
      _fx_static_case "$sfx" bare-path-in-fence 'skills/sample/SKILL.md' 'grep -c x rules/workflow-routing.md' \
        "plugin-relative paths in code blocks" 'printf -- "\n\`\`\`bash\ngrep -c x rules/workflow-routing.md\n\`\`\`\n" >> "$T/skills/sample/SKILL.md"'

      # The version was raised but there is no release tag (E-08·E-12). The verdict only runs on a git repo, so the
      # fixture has to git init too — without it, the result is not "detected" but "the check never ran".
      # A preset was added and not written into the consumer documents — the vue axis really was in that state.
      _fx_static_case "$sfx" preset-unlisted 'presets/backend/gamma.json' 'gamma' \
        "preset names missing" 'printf -- "{\"axis\":\"backend\",\"name\":\"gamma\"}\n" > "$T/presets/backend/gamma.json"'

      # A seam shipped and was not written into the documents — vue+node-api really was in that state.
      _fx_static_case "$sfx" seam-unlisted 'guides/seams/alpha+gamma/contract.md' 'alpha' \
        "pre-built seam missing" 'mkdir -p "$T/guides/seams/alpha+gamma" && printf -- "# alpha x gamma\n" > "$T/guides/seams/alpha+gamma/contract.md"'

      # A document claiming a number that differs from reality. Two more comparison targets were added beyond the README,
      # so check that **each added path** actually catches — if one grep is wrong the claim becomes an empty string and is
      # skipped quietly, and that is indistinguishable from a pass.
      _fx_static_case "$sfx" anatomy-drift 'docs/harness-anatomy.md' 'skills 9' \
        "skill count claim 9 ≠ real 3" 'sed "s/skills 3/skills 9/" "$T/docs/harness-anatomy.md" > "$T/a.tmp" && mv "$T/a.tmp" "$T/docs/harness-anatomy.md"'

      # The anatomy document's "manual-only N" — the real dmi count in the fixture tree is 1, orangekit-init (E-49).
      _fx_static_case "$sfx" manual-count-drift 'docs/harness-anatomy.md' '\*\*9\*\*' \
        "manual-only count claim 9 ≠ real 1" 'printf -- "\n| **manual invocation only** (\`disable-model-invocation\`) | \`orangekit-init\` — **9** | x |\n" >> "$T/docs/harness-anatomy.md"'

      # The illustrated manual's skill pill list diverging from reality — the fixture tree really has 3 but only 2 are written (E-57).
      _fx_static_case "$sfx" manual-skill-set-drift 'docs/manual/user.html' 'p-skill' \
        "manual skill list ≠ real" 'mkdir -p "$T/docs/manual" && printf -- "<span class=\"pill p-skill\">/sample</span> <span class=\"pill p-skill\">/orangekit-init</span>\n" > "$T/docs/manual/user.html"'

      # The illustrated manual's block-reason count — give the synthetic hook 2 reasons and make the manual claim 9 (E-61).
      _fx_static_case "$sfx" manual-block-count-drift 'docs/manual/user.html' 'Screens 9 patterns' \
        "block reason count claim 9 ≠ real 2" 'mkdir -p "$T/docs/manual" && printf "dblock \"A\"\ndblock \"B\"\n" > "$T/scripts/security-check.sh" && printf -- "<td>Screens 9 patterns and exits 2 on a hit</td>\n" > "$T/docs/manual/user.html"'

      _fx_static_case "$sfx" marketplace-drift '.claude-plugin/marketplace.json' '9 hooks' \
        "hook count claim 9 ≠ real 1" 'sed "s/1 hooks/9 hooks/" "$T/.claude-plugin/marketplace.json" > "$T/m.tmp" && mv "$T/m.tmp" "$T/.claude-plugin/marketplace.json"'

      _fx_static_case "$sfx" release-untagged 'package.json' '"version"' \
        "not shipped" 'mkdir -p "$T/.claude-plugin" && printf "{\"version\":\"9.9.9\"}\n" > "$T/package.json" && printf "{\"name\":\"fx-plugin\",\"version\":\"9.9.9\"}\n" > "$T/.claude-plugin/plugin.json" && (cd "$T" && git init -q .)'

      # Port residue — the class a rename or a move leaves behind. "Declared ↔ real" looks only at numbers, so in principle it cannot catch this.
      # sample is a skill that really exists in the fixture tree, so this becomes "a plugin skill was written on a consumer path".
      _fx_static_case "$sfx" consumer-skill-path 'skills/sample/SKILL.md' '\.claude/skills/sample' \
        "plugin skill on a consumer path" 'printf -- "- Reference: .claude/skills/sample/SKILL.md\n" >> "$T/skills/sample/SKILL.md"'
      # A name that does not exist splits off as a dead reference — prove each of the check's two branches.
      _fx_static_case "$sfx" dead-skill-ref 'skills/sample/SKILL.md' '\.claude/skills/gone-skill' \
        "dead skill reference" 'printf -- "- Reference: .claude/skills/gone-skill/SKILL.md\n" >> "$T/skills/sample/SKILL.md"'
      # Self-name leak — the name set is derived from the manifests, so use the fixture's plugin.json name.
      _fx_static_case "$sfx" self-name-leak 'skills/sample/SKILL.md' 'OrangeKitClaudeCodeDevkit' \
        "repo name leak" 'printf -- "Example project: OrangeKitClaudeCodeDevkit\n" >> "$T/skills/sample/SKILL.md"'
    fi
  fi

  # ── orphan fixtures ────────────────────────────────────────────────
  # Compare what was **actually fed** above against the directory. Because which fixture is used is not re-derived
  # (the ${event}.json interpolation + the literal references are not reimplemented), it stays in agreement forever
  # even if the selection logic changes. templates/ had this check (orphan assets) while **the fixtures, the
  # self-verification tool itself**, did not, so dead fixtures lived on quietly — the principle exempted only itself.
  sec "fixture consumption"
  local ofx ob orphf=0 ocnt=0
  while IFS= read -r ofx; do
    [ -f "$ofx" ] || continue
    ocnt=$((ocnt+1)); ob=$(basename "$ofx")
    printf '%s' "$used" | grep -qxF "$ob" && continue
    bad "orphan fixture: $ofx" "no check feeds this fixture — it is either a dead asset or a wiring gap"
    orphf=$((orphf+1))
  done < <(find "$fx" -maxdepth 1 -name '*.json' 2>/dev/null | sort)
  [ "$orphf" -eq 0 ] && [ "$ocnt" -gt 0 ] && ok "all ${ocnt} fixtures are consumed"

  # ── heartbeat rotation invariant ──────────────────────────────────
  # **Rotation erases the last evidence of no component.**
  # If this breaks, the liveness indicator reports a live hook as "never run" — measured, that is what happened:
  # security-check was hooked to Edit/Write/Bash alike and took 97% of the log, pushing track-skill's history out
  # of the window. There was no check that would catch an implementation reverting to tail -1000.
  # It looks at **behaviour**, not at the shape of the code.
  sec "heartbeat rotation invariant"
  local rt rn
  rt=$(mktemp -d 2>/dev/null) || rt=""
  if [ -z "$rt" ]; then
    warn "failed to create a temporary directory" "the rotation invariant is unproven"
  else
    { printf 'ghost-hook|2026-01-01T00:00:00Z|x|0\n'
      awk 'BEGIN{ for (i = 0; i < 2100; i++) print "noisy-hook|2026-01-02T00:00:00Z|x|0" }'
    } > "$rt/hookrun.log"
    ORANGEKIT_STATE_DIR="$rt" ORANGEKIT_ROOT="$rt" ORANGEKIT_HOOK_NAME="noisy-hook" \
      bash -c '. "$1/scripts/lib/common.sh"; orangekit_heartbeat 0' _ "$ROOT" >/dev/null 2>&1
    rn=$(num "$(wc -l < "$rt/hookrun.log" 2>/dev/null | tr -d ' ')")
    if awk -F'|' '{print $1}' "$rt/hookrun.log" 2>/dev/null | grep -qx 'ghost-hook'; then
      ok "the last evidence of a pushed-out hook survives rotation (${rn} lines)"
    else
      bad "rotation erased the evidence of a pushed-out hook (${rn} lines)" \
          "the liveness indicator would report a live hook as 'never run'"
    fi
    if [ "$rn" -gt 0 ] && [ "$rn" -le 1100 ]; then
      ok "size after rotation is bounded (${rn} lines ≤ 1100)"
    else
      bad "size after rotation is ${rn} lines" "0 means the log was wiped entirely, and over the ceiling means it grows without bound"
    fi
    # graph.log — of the three logs, only this one had no rotation (evaluation v6 · E-28). Same approach: look at behaviour.
    awk 'BEGIN{ for (i = 0; i < 5100; i++) print "2026-01-01T00:00:00Z|build|security-check" }' > "$rt/graph.log"
    ORANGEKIT_STATE_DIR="$rt" ORANGEKIT_ROOT="$rt" \
      bash -c '. "$1/scripts/lib/common.sh"; orangekit_edge build handoff' _ "$ROOT" >/dev/null 2>&1
    rn=$(num "$(wc -l < "$rt/graph.log" 2>/dev/null | tr -d ' ')")
    if [ "$rn" -gt 0 ] && [ "$rn" -le 2600 ] && tail -1 "$rt/graph.log" | grep -q '|build|handoff$'; then
      ok "graph.log size after rotation is bounded (${rn} lines ≤ 2600) · last edge preserved"
    else
      bad "graph.log rotation failed (${rn} lines)" "either it accumulates without bound or the edge just written disappeared"
    fi
    rm -rf "$rt"
  fi

  # Root resolution check
  sec "root resolution"
  local resolved
  resolved=$(cd "$(dirname scripts/doctor.sh)/.." 2>/dev/null && pwd)
  [ "$resolved" = "$ROOT" ] && ok "resolved root = $ROOT" || bad "root mismatch: $resolved ≠ $ROOT"
}

# ════════════════════════════════════════════════════════════════════
# --graph : graph verification
# ════════════════════════════════════════════════════════════════════
run_graph() {
  printf "\n${C_D}orangekit doctor --graph${C_0}\n"
  sec "workflow graph"

  local g="workflow.graph.json"
  [ -f "$g" ] || { bad "$g missing" "the graph is declared only in prose and cannot be verified (G1)"; return; }
  command -v jq >/dev/null 2>&1 || { warn "no jq — graph verification skipped"; return; }

  jq -e . "$g" >/dev/null 2>&1 || { bad "$g JSON parse failed"; return; }

  # Node existence check
  local missing=0 ntot=0
  while IFS=$'\t' read -r id kind path; do
    [ -z "$id" ] && continue
    ntot=$((ntot+1))
    [ -z "$path" ] || [ "$path" = "null" ] && continue
    if [ ! -e "$path" ]; then
      bad "path of node '$id' ($kind) missing: $path"; missing=$((missing+1))
    fi
  done < <(jq -r '.nodes[]? | "\(.id)\t\(.kind)\t\(.path // "")"' "$g" 2>/dev/null)
  [ "$missing" -eq 0 ] && ok "all ${ntot} nodes exist"

  # beforeWrite — a skill declares "call me before the first write to that path". The prior-knowledge gate reads only this,
  # so a node that is not a skill, an empty path list, or an unknown condition quietly makes it inert
  local bwbad
  bwbad=$(jq -r '.nodes[]? | select(.beforeWrite) | select(.kind!="skill" or ((.beforeWrite.paths // []) | length)==0 or ((.beforeWrite.when // "") | IN("","test-runner") | not)) | .id' "$g" 2>/dev/null)
  if [ -n "$bwbad" ]; then bad "node with an invalid beforeWrite declaration: $(printf '%s' "$bwbad" | tr '\n' ' ')" "a skill node · at least 1 path · when empty or test-runner"
  else ok "$(jq '[.nodes[]? | select(.beforeWrite)] | length' "$g") beforeWrite declarations — skill node · paths · condition valid"; fi

  # Edge target existence
  local ids dang=0 etot=0
  ids=$(jq -r '.nodes[]?.id' "$g" 2>/dev/null)
  while IFS=$'\t' read -r from to; do
    [ -z "$from" ] && continue
    etot=$((etot+1))
    printf '%s\n' "$ids" | grep -qx "$from" || { bad "edge source undefined: $from"; dang=$((dang+1)); }
    printf '%s\n' "$ids" | grep -qx "$to"   || { bad "edge target undefined: $to";  dang=$((dang+1)); }
  done < <(jq -r '.edges[]? | "\(.from)\t\(.to)"' "$g" 2>/dev/null)
  [ "$dang" -eq 0 ] && ok "all ${etot} edges reference valid nodes"

  # Nodes with no inbound edge (unreachable assets) — nodes marked entry are excluded
  local unreach=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    jq -e --arg n "$id" '.nodes[] | select(.id==$n) | (.entry == true) or (.manual == true)' "$g" >/dev/null 2>&1 && continue
    jq -e --arg n "$id" '[.edges[]? | select(.to==$n)] | length > 0' "$g" >/dev/null 2>&1 \
      || { bad "node with no inbound edge: $id" "unreachable asset (the same disease as §1.3). If manual-only is intended, put \"manual\": true on the node"; unreach=$((unreach+1)); }
  done < <(printf '%s\n' "$ids")
  [ "$unreach" -eq 0 ] && ok "no unreachable nodes"

  # Undeclared skills (G5) — the existing check looked only at *declared* nodes, so an asset that was never even
  # declared as a node was a blind spot. That is why nobody caught the 8 planning skills floating with no caller in v3.
  # Compare the asset list (skills/) against the declaration (graph).
  local undecl=0 ulist="" sname
  for sname in skills/*/; do
    [ -d "$sname" ] || continue
    sname=$(basename "$sname")
    [ -f "skills/$sname/SKILL.md" ] || continue
    printf '%s\n' "$ids" | grep -qx "$sname" && continue
    undecl=$((undecl+1)); ulist="$ulist $sname"
  done
  if [ "$undecl" -gt 0 ]; then
    bad "${undecl} skills not declared in the graph" "with no declaration there is no basis for invoking it either —$ulist"
  else
    ok "every skill is declared in the graph"
  fi

  # Undeclared hooks (the G5 symmetry) — the check above only walks skills/. Hooks had no counterpart, so a sixth hook
  # could be registered with no graph node and nobody would know. The requirement lived in rules/harness-change.md
  # **as a norm only a human reads**, and what holds right now is discipline, not a machine.
  # Compare by **path, not id** — session-brief.sh's node id is 'session-start', so a basename comparison
  # would immediately produce a false positive.
  local hundecl=0 hlist="" hpath
  while IFS= read -r hpath; do
    [ -z "$hpath" ] && continue
    jq -e --arg p "$hpath" '[.nodes[]? | select(.kind=="hook" and .path==$p)] | length > 0' \
      "$g" >/dev/null 2>&1 && continue
    hundecl=$((hundecl+1)); hlist="$hlist $hpath"
  done < <(jq -r '.hooks | to_entries[] | .value[]?.hooks[]?.command' hooks/hooks.json 2>/dev/null \
           | grep -oE 'scripts/[a-z0-9./-]+\.sh' | sort -u)
  if [ "$hundecl" -gt 0 ]; then
    bad "${hundecl} hooks not declared in the graph" "registered in hooks.json but no node in the graph — an instrumentation blind spot —$hlist"
  else
    ok "every hook is declared in the graph"
  fi

  # Whether error edges are declared (G4)
  local noerr=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    jq -e --arg n "$id" '.nodes[] | select(.id==$n) | (.on_error // empty) | length > 0' "$g" >/dev/null 2>&1 \
      || noerr=$((noerr+1))
  done < <(jq -r '.nodes[]? | select(.kind=="agent" or .kind=="stage") | .id' "$g" 2>/dev/null)
  [ "$noerr" -gt 0 ] && warn "${noerr} nodes with no error edge" "if the failure path is not in the graph, failures vanish silently (G4)" \
                     || ok "every execution node declares an error edge"

  # Routing-card Phase ↔ graph phase comparison (G6)
  # The routing card asserts the workflow in the P0-A~P6 vocabulary and the graph in stage/skill ids.
  # If the two vocabularies are not joined, a machine cannot answer "is this Phase actually invoked".
  local rc="rules/workflow-routing.md" pmiss=0 ptot=0
  if [ -f "$rc" ]; then
    while IFS=$'\t' read -r ph target; do
      [ -z "$ph" ] && continue
      ptot=$((ptot+1))
      if ! printf '%s\n' "$ids" | grep -qx "$target"; then
        bad "the invocation target of routing card $ph is not in the graph: $target" "an undeclared invocation can be neither checked nor instrumented"
        pmiss=$((pmiss+1)); continue
      fi
      jq -e --arg n "$target" --arg p "$ph" \
        '.nodes[] | select(.id==$n) | (.phase // []) | index($p)' "$g" >/dev/null 2>&1 \
        || { bad "node $target: phase \"$ph\" not declared" "the routing card and the graph assert the same thing in different vocabularies"; pmiss=$((pmiss+1)); }
    done < <(awk -F'|' '/^\| P[0-9]/ {
                ph=$2; gsub(/^[ \t]+|[ \t]+$/,"",ph);
                n=split($4, part, "`");
                for (i=2; i<=n; i+=2) { t=part[i]; sub(/^\//,"",t);
                  if (t ~ /^[a-z][a-z0-9-]+$/) printf "%s\t%s\n", ph, t }
              }' "$rc")
    [ "$pmiss" -eq 0 ] && ok "all ${ptot} routing-card Phase invocations match a graph phase"
  else
    warn "$rc missing — Phase comparison skipped"
  fi

  # Store consumption path (G7)
  # A store must have both a write (inbound) and a read (outbound). A store with no reader node
  # is all cost and a source of drift — not "the document exists" but "the document is consumed".
  # Both conditions that turn the warning off are in your hands: wire a consumption edge, or retire the store.
  local orphan=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    jq -e --arg n "$id" '[.edges[]? | select(.from==$n)] | length > 0' "$g" >/dev/null 2>&1 \
      || { warn "store with no reader node: $id" "wire a consumption edge or retire the store"; orphan=$((orphan+1)); }
  done < <(jq -r '.nodes[]? | select(.kind=="store") | .id' "$g" 2>/dev/null)
  [ "$orphan" -eq 0 ] && ok "every store has a consumption path"

  # Declaring produces and wiring it up is one action — declaring it without linking a store
  # leaves that artifact in a graph blind spot (a stage's produces is not a file, so it is excluded).
  local unlinked=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    jq -e --arg n "$id" '[.edges[]? | select(.from==$n)] | length > 0' "$g" >/dev/null 2>&1 \
      || { bad "produces declared but no output edge: $id" "the artifact cannot be traced in the graph"; unlinked=$((unlinked+1)); }
  done < <(jq -r '.nodes[]? | select(.produces != null and .kind != "stage") | .id' "$g" 2>/dev/null)
  [ "$unlinked" -eq 0 ] && ok "every node declaring produces has an output edge"

  # manual declaration ↔ frontmatter (G8) — if a skill the graph calls "manual-only" fires automatically from its
  # description, the graph is lying. ui-ux-design was in that state and doctor looked only at the frontmatter (evaluation v6 · E-26).
  local gm=0 gmlist="" mid mpath
  while IFS=$'\t' read -r mid mpath; do
    [ -z "$mid" ] && continue
    [ -f "$mpath" ] || continue
    grep -q '^disable-model-invocation:[[:space:]]*true' "$mpath" 2>/dev/null && continue
    gm=$((gm+1)); gmlist="$gmlist $mid"
  done < <(jq -r '.nodes[]? | select(.kind=="skill" and .manual==true) | "\(.id)\t\(.path // "")"' "$g" 2>/dev/null)
  if [ "$gm" -gt 0 ]; then
    bad "graph says manual but disable-model-invocation is missing:$gmlist" "the graph says manual and the description fires automatically — one of them is lying"
  else
    ok "every manual node agrees with its frontmatter"
  fi

  # The reverse (G8') — when the frontmatter is dmi but the graph node has no manual, the graph is drawing that skill
  # as automatically firable. While only G8 existed, orangekit-init and harness-evaluation were in that state
  # (evaluation v7 · E-51). A skill with no node in the graph is caught separately by "skills not declared in the graph".
  local g8r=0 g8rlist="" dpath did
  while IFS= read -r dpath; do
    [ -z "$dpath" ] && continue
    did=$(jq -r --arg p "$dpath" '.nodes[]? | select(.kind=="skill" and .path==$p) | .id' "$g" 2>/dev/null | head -1)
    [ -z "$did" ] && continue
    jq -e --arg n "$did" '.nodes[]? | select(.id==$n and .manual==true)' "$g" >/dev/null 2>&1 && continue
    g8r=$((g8r+1)); g8rlist="$g8rlist $did"
  done < <(grep -l '^disable-model-invocation:[[:space:]]*true' $(skill_mds) 2>/dev/null)
  if [ "$g8r" -gt 0 ]; then
    bad "disable-model-invocation but no graph manual:$g8rlist" "the frontmatter says manual and the graph draws it as automatically firing — put \"manual\": true on the node"
  else
    ok "every dmi skill agrees with graph manual"
  fi

  # graph → card, the reverse (G9) — G6 only checked whether an invocation the card mentioned is in the graph. If the
  # graph attached a phase to a skill and the card has no such row, it is a declaration with no invocation condition (stage is a vocabulary anchor and is excluded).
  local g9=0 g9list="" gph gid
  if [ -f "$rc" ]; then
    while IFS=$'\t' read -r gid gph; do
      [ -z "$gid" ] && continue
      grep -qE "^\| *${gph} *\|" "$rc" 2>/dev/null || { g9=$((g9+1)); g9list="$g9list $gid:$gph"; }
    done < <(jq -r '.nodes[]? | select(.kind=="skill" and .phase != null) | .id as $i | .phase[] | "\($i)\t\(.)"' "$g" 2>/dev/null)
    if [ "$g9" -gt 0 ]; then
      bad "graph phase is not in the routing card:$g9list" "a phase with no card row is a declaration with no invocation condition"
    else
      ok "every graph phase has a row in the routing card"
    fi
  fi

  # Duplicate path (G10) — if two nodes point at one file, one of them is an alias. If that is intended, say so in note.
  local dup
  dup=$(jq -r '[.nodes[]? | select(.path != null and (.note // "") == "")] | group_by(.path) | map(select(length>1)) | .[] | map(.id) | join("+")' "$g" 2>/dev/null)
  if [ -n "$dup" ]; then
    warn "nodes sharing the same path (no note): $(printf '%s' "$dup" | tr '\n' ' ')" "if it is an alias, write the reason in note; otherwise delete one of them"
  else
    ok "no duplicate node paths (among nodes with no note)"
  fi
}

# ════════════════════════════════════════════════════════════════════
# --consumer : consumer-layout proof (RC2)
#
# This repo has no consumer. So the development machine's conditions had become the verification conditions,
# and as a result nobody saw for four months that (ⓐ) handoff dies in a repo with 0 commits, (ⓑ) build-gate
# blocks as a false positive when jq is absent, and (ⓒ) skill script paths only happen to be right here.
#
# Copy the plugin into a cache-like path and run the hooks in **the most fragile project state**.
# ════════════════════════════════════════════════════════════════════
run_consumer() {
  printf "\n${C_D}orangekit doctor --consumer${C_0}  (consumer-layout proof)\n"

  local tmp; tmp=$(mktemp -d 2>/dev/null) || { bad "failed to create a temporary directory"; return; }
  trap 'rm -rf "$tmp"' RETURN
  local cache="$tmp/cache/orangekit-product/x"
  mkdir -p "$cache" || { bad "failed to create the cache path"; return; }

  sec "plugin cache copy"
  # guides/ is large and irrelevant to this verification (install-guide has its own self-test)
  if ! (cd "$ROOT" && tar cf - --exclude=.git --exclude=guides --exclude=dev . ) | (cd "$cache" && tar xf -) 2>/dev/null; then
    bad "cache copy failed"; return
  fi
  [ -f "$cache/scripts/session-brief.sh" ] && ok "plugin assets copied to the cache path" \
    || { bad "cache copy verification failed"; return; }

  # 3 kinds of project — ⓐ is the condition that catches handoff's exit 128
  local ok_all=1
  _consumer_project() {   # $1 label  $2 path  $3 commit or not  $4 create config or not
    mkdir -p "$2" && (cd "$2" && git init -q .) || return 1
    printf 'export const a = 1\n' > "$2/src_a.ts"
    [ "$3" = "commit" ] && (cd "$2" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)
    [ "$4" = "config" ] && printf '{"techStack":{"commands":{"build":"echo build"}}}\n' > "$2/orangekit.config.json"
    return 0
  }

  local label path fixture hook code err out
  for label in "pre-first-commit:none:none" "has-commit:commit:none" "has-config:commit:config"; do
    local nm; nm=${label%%:*}
    local rest=${label#*:}; local docommit=${rest%%:*}; local docfg=${rest#*:}
    path="$tmp/proj-$nm"
    _consumer_project "$nm" "$path" "$docommit" "$docfg" || { bad "$nm: failed to create the project"; continue; }

    sec "hook execution — $nm"
    local fails=0
    while IFS=$'\t' read -r event cmd; do
      [ -z "$cmd" ] && continue
      hook=$(printf '%s' "$cmd" | grep -oE 'scripts/[a-z0-9./-]+\.sh' | head -1)
      [ -n "$hook" ] && [ -f "$cache/$hook" ] || continue
      fixture="$ROOT/scripts/fixtures/${event}.json"
      [ -f "$fixture" ] || fixture="$ROOT/scripts/fixtures/default.json"
      [ -f "$fixture" ] || continue
      code=0
      out=$(CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$path" \
            bash "$cache/$hook" < "$fixture" 2>"$tmp/err") || code=$?
      err=$(cat "$tmp/err" 2>/dev/null)
      if [ "$code" -ne 0 ] && [ "$code" -ne 2 ]; then
        bad "$nm · $(basename "$hook") [$event]: exit $code" "${err:0:140}"; fails=$((fails+1)); ok_all=0
      elif [ -n "$err" ]; then
        bad "$nm · $(basename "$hook") [$event]: output on stderr" "${err:0:140}"; fails=$((fails+1)); ok_all=0
      fi
    done < <(command -v jq >/dev/null 2>&1 && jq -r '.hooks | to_entries[] | .key as $e | .value[]?.hooks[]? | "\($e)\t\(.command)"' "$ROOT/hooks/hooks.json" 2>/dev/null)
    [ "$fails" -eq 0 ] && ok "$nm: all hooks fine (exit 0/2 · no stderr)"
  done

  # Were the rules installed automatically into the project that has a config?
  sec "automatic T1 rule install"
  local rp="$tmp/proj-has-config/.claude/rules"
  local rn; rn=$(num "$({ ls -1 "$rp"/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')")
  local pn; pn=$(num "$({ ls -1 "$ROOT"/rules/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')")
  if [ "$rn" -eq "$pn" ] && [ "$rn" -gt 0 ]; then
    ok "${rn}/${pn} rules installed automatically"
  else
    bad "${rn}/${pn} rules installed automatically" "session-brief's automatic install of what is missing did not work"
  fi
  local always; always=$({ grep -L '^paths:' "$rp"/*.md 2>/dev/null || true; } | head -1)
  [ -n "$always" ] && ok "always-loaded card installed: $(basename "$always")" \
                   || bad "no always-loaded card" "task routing does not reach the session"

  # Progressive loading — did the references a card links to actually arrive in the consumer layout?
  # If only the link is delivered and the file is not, "read it when you need it" becomes "cannot read it".
  local cdang=0 cn=0 crc clnk
  for crc in "$rp"/*.md; do
    [ -f "$crc" ] || continue
    while IFS= read -r clnk; do
      [ -z "$clnk" ] && continue
      cn=$((cn+1))
      [ -f "$rp/$clnk" ] || cdang=$((cdang+1))
    done < <(grep -ohE '\.\./references/[A-Za-z0-9._/-]+\.md' "$crc" 2>/dev/null | sort -u)
  done
  if [ "$cn" -eq 0 ]; then
    ok "no card→reference links (not applicable)"
  elif [ "$cdang" -eq 0 ]; then
    ok "${cn} progressive-loading references reached the consumer"
  else
    bad "${cdang}/${cn} references did not arrive" "install-rules.sh did not install references/ along with them"
  fi

  # Did it refrain from writing into the project with no config (the consent gate)
  [ -d "$tmp/proj-pre-first-commit/.claude/rules" ] \
    && bad "rules were written into an unconfigured project" "the orangekit.config.json gate is leaking" \
    || ok "nothing written into an unconfigured project (consent gate holds)"

  # build-gate's undecidable branch — it must not block
  sec "undecidable branch"
  local bp="$tmp/proj-has-config"
  code=0
  out=$(printf '{"stop_hook_active":false}' | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$bp" \
        bash "$cache/scripts/build-gate.sh" 2>/dev/null) || code=$?
  if [ "$code" -ne 0 ]; then
    bad "build-gate: exit $code with no transcript" "an undecidable verdict was folded into a block — a false positive makes hooks get turned off"
  elif printf '%s' "$out" | grep -q '"continue"[[:space:]]*:[[:space:]]*false'; then
    bad "build-gate: undecidable yet continue:false" "it must not block"
  else
    ok "build-gate: undecidable → no block"
  fi

  # session-brief — does it survive a guide with only resources assembled (no SKILL.md)?
  # That is a normal intermediate state, yet an empty-input grep in the version comparison killed the hook
  # under pipefail and every later notice (unfinished work, rule cards) vanished (consumer field run 2026-10-14).
  # Check exit 0 **and** that a later section's notice still arrives.
  local gp="$tmp/proj-resources-only"
  _consumer_project "resources-only" "$gp" commit config
  mkdir -p "$cache/guides/frontend/fx" "$gp/.claude/skills/frontend-guide/resources" "$gp/.orangekit"
  printf '{"axis":"frontend","name":"fx","packVersion":"9.9.9","pkgs":["react@19"]}\n' > "$cache/guides/frontend/fx/pack.json"
  printf '{"pack":"frontend/fx","packVersion":"0.0.1"}\n' > "$gp/.claude/skills/frontend-guide/assembly.json"
  printf '{"status":"pending","combo":"fx+none","need":["seam:frontend"]}\n' > "$gp/.orangekit/guide-job.json"
  mkdir -p "$cache/guides/backend/fy" "$gp/.claude/skills/backend-guide/resources"
  printf '{"axis":"backend","name":"fy","packVersion":"4.4.4","pkgs":["zod@4"]}\n' > "$cache/guides/backend/fy/pack.json"
  printf '{"pack":"backend/fy","packVersion":"4.4.4"}\n' > "$gp/.claude/skills/backend-guide/assembly.json"
  code=0
  out=$(printf '{}' | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$gp" \
        bash "$cache/scripts/session-brief.sh" 2>/dev/null) || code=$?
  rm -rf "$cache/guides"
  if [ "$code" -ne 0 ]; then
    bad "session-brief: exit $code on a guide with only resources assembled" "an empty-input grep killed the hook under pipefail — every later notice vanishes"
  elif ! printf '%s' "$out" | grep -q 'guide generation unfinished'; then
    bad "session-brief: the unfinished-guide notice did not appear" "it was cut off before reaching the later section"
  elif printf '%s' "$out" | grep -q 'backend-guide('; then
    bad "session-brief: a fix notice appeared for a guide whose pack version is unchanged" "it compares with the plugin version — compare with the same pack's current packVersion"
  else
    ok "session-brief: guide with only resources assembled → exit 0, unfinished notice arrives"
  fi

  # The UI render notice — **it is a notice, not a block.** Prove both.
  # Synthesize a session where the build ran but there is no trace of a render check.
  sec "UI render notice (non-blocking)"
  local up="$tmp/proj-has-commit"
  mkdir -p "$up/src"
  printf 'export const A = () => <div/>;\n' > "$up/src/Card.tsx"
  (cd "$up" && git add -A >/dev/null 2>&1 && git commit -qm ui >/dev/null 2>&1)
  printf 'export const A = () => <div>changed</div>;\n' > "$up/src/Card.tsx"
  mkdir -p "$up/.claude/.orangekit"; : > "$up/.claude/.orangekit/session-baseline.txt"
  rm -f "$up/.claude/.orangekit/ui-notice.stamp"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run build"}}]}}' \
    > "$tmp/ui-transcript.jsonl"
  code=0
  out=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$tmp/ui-transcript.jsonl" \
        | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$up" \
          bash "$cache/scripts/build-gate.sh" 2>/dev/null) || code=$?
  if ! command -v jq >/dev/null 2>&1; then
    warn "UI notice unverified — no jq" "an undecidable verdict is not folded into a pass"
  elif [ "$code" -ne 0 ]; then
    bad "build-gate: exit $code on the UI notice path" "a notice must not change the exit code"
  elif printf '%s' "$out" | grep -q '"continue"[[:space:]]*:[[:space:]]*false'; then
    bad "build-gate: the UI notice went out as a block" "a false-positive block makes the user turn the hook off"
  elif printf '%s' "$out" | grep -q 'no trace that the render was checked'; then
    ok "build-gate: UI change + build only → notice raised, no block"
  else
    bad "build-gate: the UI notice did not appear" "a passing typecheck is being treated as render evidence"
  fi
  # The second call must stay silent — a warning that never goes away teaches people to ignore it.
  out=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$tmp/ui-transcript.jsonl" \
        | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$up" \
          bash "$cache/scripts/build-gate.sh" 2>/dev/null)
  printf '%s' "$out" | grep -q 'no trace that the render was checked' \
    && bad "the UI notice repeats on every Stop" "the once-per-session marker is not working" \
    || ok "UI notice once per session (no repeated warning)"

  # ── verification-command recognition — prove both sides (evaluation v9 · E-60) ─────────────
  # ⓐ it must recognize the bare `pytest` the fastapi preset prescribes — failing to recognize it is a false positive
  #    that blocks a session which ran the harness's own prescription, and a false positive makes hooks get turned off.
  # ⓑ `echo npm run build` is not an execution — passing it on string containment is the v2 stop-guard.
  sec "verification-command recognition (build-gate)"
  local vt="$tmp/verify-transcript.jsonl" vcase vcmd vwant
  # The commands the app-axis presets prescribe (flutter analyze · xcodebuild · gradlew) get the same two-sided proof
  for vcase in "pytest -q|pass" "python -m pytest|pass" "npx tsc --noEmit|pass" "echo npm run build|block" "grep -rn 'pnpm build' README.md|block" \
               "flutter analyze|pass" "flutter test|pass" "xcodebuild -scheme App test|pass" "./gradlew assembleDebug|pass" \
               "flutter pub get|block" "echo flutter test|block"; do
    vcmd="${vcase%|*}"; vwant="${vcase##*|}"
    printf '%s\n' "$(jq -nc --arg c "$vcmd" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}')" > "$vt"
    printf 'export const A = () => <div>%s</div>;\n' "$RANDOM" > "$up/src/Card.tsx"
    code=0
    out=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$vt" \
          | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$up" \
            bash "$cache/scripts/build-gate.sh" 2>/dev/null) || code=$?
    if ! command -v jq >/dev/null 2>&1; then
      warn "verification-command recognition unverified — no jq" "an undecidable verdict is not folded into a pass"; break
    elif printf '%s' "$out" | grep -q '"continue"[[:space:]]*:[[:space:]]*false'; then
      [ "$vwant" = "block" ] && ok "build-gate: '$vcmd' → not an execution → blocked" \
        || bad "build-gate: '$vcmd' was not recognized as an execution → blocked" "a false positive that blocks a session which ran the prescribed verification command — it makes hooks get turned off"
    else
      [ "$vwant" = "pass" ] && ok "build-gate: '$vcmd' → recognized as an execution" \
        || bad "build-gate: '$vcmd' was counted as an execution" "string containment became grounds for passing — the failure of the v2 stop-guard"
    fi
  done

  # ── Dart change detection — drop it from the extension list and a Flutter session passes with no verification ──
  # In a repo where **only** .dart changed, check both: no verification → blocked, and flutter test → passes.
  # Check only one side and both "always block" and "always pass" get through.
  if command -v jq >/dev/null 2>&1; then
    local dp="$tmp/proj-dart" dcase dcmd dwant
    mkdir -p "$dp/lib"
    printf 'void main() {}\n' > "$dp/lib/main.dart"
    (cd "$dp" && git init -q && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1)
    mkdir -p "$dp/.claude/.orangekit"; : > "$dp/.claude/.orangekit/session-baseline.txt"
    for dcase in "echo hi|block" "flutter test|pass"; do
      dcmd="${dcase%|*}"; dwant="${dcase##*|}"
      printf 'void main() { print(%s); }\n' "$RANDOM" > "$dp/lib/main.dart"
      printf '%s\n' "$(jq -nc --arg c "$dcmd" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}')" > "$vt"
      out=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$vt" \
            | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$dp" \
              bash "$cache/scripts/build-gate.sh" 2>/dev/null) || true
      if printf '%s' "$out" | grep -q '"continue"[[:space:]]*:[[:space:]]*false'; then
        [ "$dwant" = "block" ] && ok "build-gate: only .dart changed + no verification → blocked" \
          || bad "build-gate: .dart changed + '$dcmd', yet blocked" "it does not recognize flutter verification"
      else
        [ "$dwant" = "pass" ] && ok "build-gate: .dart changed + '$dcmd' → passes" \
          || bad "build-gate: passed a session where only .dart changed, with no verification" "dart is missing from the source extension list"
      fi
    done
  fi

  # ── response-language reach ───────────────────────────────────────
  # Choosing a language does not end at being written into the config. T0 is hook **output**, not a file,
  # so it only arrives if the substitution actually happens. Alive ≠ working.
  sec "response-language reach"
  local lp="$tmp/proj-lang" lout=""
  mkdir -p "$lp"
  printf '{"project":{"name":"t","language":"id","languageLabel":"Bahasa Indonesia"},"techStack":{"language":"TypeScript"}}\n' \
    > "$lp/orangekit.config.json"
  lout=$(printf '{}' | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$lp" \
         ORANGEKIT_STATE_DIR="$lp/.orangekit" bash "$cache/scripts/session-brief.sh" 2>/dev/null || true)
  if printf '%s' "$lout" | grep -q '{{'; then
    bad "a placeholder was left in T0" "the substitution is not working — {{RESPONSE_LANGUAGE}} leaks into the context every session"
  elif printf '%s' "$lout" | grep -q 'Bahasa Indonesia'; then
    ok "the configured language reached T0 (id → Bahasa Indonesia)"
  else
    bad "the configured language did not reach T0" "project.language in orangekit.config.json is being ignored"
  fi

  # This file has four "language" keys (project·techStack·frontend·backend).
  # Without narrowing the scope, the stack language (TypeScript) is read as the response language.
  printf '%s' "$lout" | grep -q 'TypeScript' \
    && bad "techStack.language was read as the response language" "the scope was not narrowed to the project block" \
    || ok "the stack language is not mistaken for the response language"

  # Unconfigured-project fallback — if the label is empty here, the placeholder leaks verbatim
  lout=$(printf '{}' | CLAUDE_PLUGIN_ROOT="$cache" CLAUDE_PROJECT_DIR="$tmp/proj-pre-first-commit" \
         ORANGEKIT_STATE_DIR="$tmp/proj-pre-first-commit/.orangekit" bash "$cache/scripts/session-brief.sh" 2>/dev/null || true)
  printf '%s' "$lout" | grep -q '{{' \
    && bad "a placeholder was left in an unconfigured project's T0" "the fallback label is empty" \
    || ok "unconfigured-project fallback (no placeholder leak)"

  # Block proof — does a fixture with the substituter torn out actually get blocked by --fast, and **for the intended reason**
  local bcache="$tmp/cache-broken" bout=""
  if cp -R "$cache" "$bcache" 2>/dev/null; then
    perl -pi -e 's/\{\{RESPONSE_LANGUAGE\}\}//g' "$bcache/scripts/session-brief.sh" 2>/dev/null || true
    bout=$(bash "$bcache/scripts/doctor.sh" --fast --root "$bcache" 2>&1 || true)
    printf '%s' "$bout" | grep -q 'nothing to substitute the T0 placeholder' \
      && ok "substituter removed → blocked by --fast (the intended reason)" \
      || bad "the substituter was torn out and --fast passed it" "the placeholder leak is not being detected"
  fi

  # Does doctor itself run outside the plugin?
  sec "execution outside the plugin"
  (cd "$tmp/proj-has-commit" && bash "$cache/scripts/doctor.sh" --fast >/dev/null 2>&1) \
    && ok "doctor --fast from the cache path → exit 0" \
    || bad "doctor --fast from the cache path failed" "a consumer cannot self-verify"
}

# ════════════════════════════════════════════════════════════════════
# --usage : instrumentation
# ════════════════════════════════════════════════════════════════════
run_usage() {
  printf "\n${C_D}orangekit doctor --usage${C_0}  (project: %s)\n" "$PROJ"
  local d="$PROJ/.claude/.orangekit"

  sec "hook heartbeat"
  if [ -f "$d/hookrun.log" ]; then
    # The denominator is the number of **unique scripts**. The number of declared entries must not be used —
    # handoff.sh alone is hooked to both PreCompact and SessionEnd, which makes it structurally impossible for the
    # numerator (distinct script names in the log) to reach the denominator.
    # An indicator that reads 5/6 forever is a warning that never goes away, and it teaches people to ignore it (evaluation v3 · E-11).
    local expected; expected=$(command -v jq >/dev/null 2>&1 \
      && jq -r '[.hooks|to_entries[].value[]?.hooks[]?.command
                 | capture("(?<f>[a-z0-9-]+)\\.sh").f] | unique | length' hooks/hooks.json 2>/dev/null \
      || echo "?")
    printf "  hook runs in recent sessions:\n"
    awk -F'|' '{c[$1]++; last[$1]=$2} END{for(k in c) printf "    %-24s %4d runs  last %s\n", k, c[k], last[k]}' "$d/hookrun.log" | sort
    local distinct; distinct=$(awk -F'|' '{print $1}' "$d/hookrun.log" | sort -u | wc -l | tr -d ' ')
    printf "  live hooks: %s/%s\n" "$(num "$distinct")" "$(num "$expected")"
    # Written with if/else. In `[ ... ] && warn "..." || ok "..."`, warn returns 1 (when the detail argument $2 is
    # absent) so **both** branches run — right after reporting a failure it cancels it with "none" on the same
    # screen and even bumps the PASS counter (evaluation v3 · E-10).
    local fails; fails=$(num "$(awk -F'|' '$4!="0"' "$d/hookrun.log" 2>/dev/null | wc -l | tr -d ' ')")
    if [ "$fails" -gt 0 ]; then
      warn "${fails} abnormal exits" "$(awk -F'|' '$4!="0" {printf "%s(exit %s) ", $1, $4}' "$d/hookrun.log" 2>/dev/null | head -c 160)"
    else
      ok "no abnormal exits"
    fi
  else
    warn "no heartbeat log" "either the hooks have never run, or the instrumentation is not wired"
  fi

  sec "graph edge traversal"
  if [ -f "$d/graph.log" ]; then
    awk -F'|' '{printf "    %s → %s\n", $2, $3}' "$d/graph.log" | sort | uniq -c | sort -rn | head -20
    # Dead edges: declared in the graph but never once walked
    # A dead edge is judged only among **edges the code can emit**.
    # A stage-to-stage transition is model behaviour and no hook can emit it. Reporting those as "dead"
    # creates a warning that never goes away, and a warning that never goes away gets ignored.
    if [ -f workflow.graph.json ] && command -v jq >/dev/null 2>&1; then
      local dead=0
      while IFS=$'\t' read -r from to; do
        [ -z "$from" ] && continue
        grep -q "|${from}|${to}$" "$d/graph.log" 2>/dev/null \
          || { printf "    ${C_Y}unwalked edge${C_0}: %s → %s\n" "$from" "$to"; dead=$((dead+1)); }
      done < <(jq -r '.edges[]? | select(.instrumented == true and (has("conditionalEmit") | not)) | "\(.from)\t\(.to)"' workflow.graph.json 2>/dev/null)
      [ "$dead" -gt 0 ] && warn "${dead} instrumented edges unwalked" "this is a measurement, not an assertion"

      # Conditionally emitted edges are **classified but not warned about.** They are emitted only when a block
      # happens (build-gate→build) or when the cycle comes round (session-start→harness-evaluation), so not being
      # emitted in a normal state is normal. Counting them as dead edges creates a warning that never goes away,
      # and a warning that never goes away teaches people to ignore it (evaluation v3 · E-04).
      while IFS=$'\t' read -r from to why; do
        [ -z "$from" ] && continue
        grep -q "|${from}|${to}$" "$d/graph.log" 2>/dev/null \
          || printf "    ${C_D}unwalked (conditional)${C_0}: %s → %s — %s\n" "$from" "$to" "$why"
      done < <(jq -r '.edges[]? | select(.instrumented == true and has("conditionalEmit")) | "\(.from)\t\(.to)\t\(.conditionalEmit)"' workflow.graph.json 2>/dev/null)
    fi
  else
    warn "no edge traversal log"
  fi

  sec "skill invocations"
  if [ -f "$d/skilluse.log" ]; then
    # $2 in the log is the normalized name the platform gives (`orangekit-product:foo`), while the control group for the
    # never-invoked verdict below is the `skills/` directory name (`foo`). Without stripping the prefix the two never
    # agree, and a skill you just invoked is printed as "no invocation record" on the same screen (evaluation v5 · E-19).
    awk -F'|' '{n=$2; sub(/^[^:]*:/,"",n); c[n]++} END{for(k in c) printf "    %-32s %d\n", k, c[k]}' "$d/skilluse.log" | sort -k2 -rn | head -20

    # Plugin skills with no invocation record within the measurement window — an observation list, not a verdict.
    # Only an asset that stays uninvoked over the long run (months) is proposed to the user as a retirement candidate.
    local unseen="" un=0 sname
    while IFS= read -r sname; do
      [ -z "$sname" ] && continue
      awk -F'|' '{n=$2; sub(/^[^:]*:/,"",n); print n}' "$d/skilluse.log" 2>/dev/null | grep -qx "$sname" \
        || { un=$((un+1)); unseen="$unseen $sname"; }
    done < <(ls -1 "$PLUGIN_ROOT/skills" 2>/dev/null)
    if [ "$un" -gt 0 ]; then
      printf "    ${C_D}no invocation record for %d:%s${C_0}\n" "$un" "$unseen"
      printf "    ${C_D}(normal if the measurement window is short — only long-run silence is a retirement candidate)${C_0}\n"
    fi
  else
    warn "no skill invocation log" "unused-skill verdicts only after instrumentation (anti-goal 8)"
  fi

  sec "resident context cost"
  # The cost that goes in **unconditionally, every session**, regardless of whether anything is invoked. Only T0 had a
  # budget (42 lines) and nobody counted the rest — in particular a skill description is resident in full even if the
  # skill is never used. That is why evaluation axis P5 stayed "unmeasured".
  # The unit is **bytes** (wc -c). Korean runs about 3 bytes per character, so it is larger than a character count —
  # every historical value of the ratchet below was measured in bytes, so match the label, not the value.
  # **No token conversion is done** — the conversion factor differs per model and cannot be verified here.
  # Producing an unverifiable number is anti-goal 8.
  local c_t0 c_route c_desc c_agent c_sum sfile
  # Only T0 has its comments stripped — because session-brief.sh actually removes them right before printing.
  # Claude Code loads workflow-routing.md **as the file is**, so its comments are context too.
  # (Stripping them with sed here would make the measurement lie smaller than reality — measured, a 414-byte difference.)
  c_t0=$(num "$(sed '/<!--/,/-->/d' "$PLUGIN_ROOT/templates/operating-contract.md" 2>/dev/null | wc -c | tr -d ' ')")
  c_route=$(num "$(wc -c < "$PLUGIN_ROOT/rules/workflow-routing.md" 2>/dev/null | tr -d ' ')")
  c_desc=0
  # The reset is `[A-Za-z_-]+:` — frontmatter keys mix in hyphens and capitals (`disable-model-invocation`).
  # With `[a-z_]+:` that line was not a reset and got dragged in behind description. The resident figure (c_desc)
  # comes out the same under both regexes so the ratchet was unaffected, and **only the non-resident value was inflated by 186 bytes** —
  # that was where the saving was being reported as larger than it really was.
  local dtop="" dn dv c_hidden=0 n_hidden=0
  for sfile in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
    [ -f "$sfile" ] || continue
    dv=$(num "$(awk '/^---$/{n++; next} n==1 && /^(name|description):/{p=1} n==1 && /^[A-Za-z_-]+:/ && !/^(name|description):/{p=0} n==1 && p{print} n>=2{exit}' "$sfile" | wc -c | tr -d ' ')")
    dn=$(basename "$(dirname "$sfile")")
    # The description of a skill with disable-model-invocation: true is not resident
    # (docs/platform-contract.md §2.4). Summing it makes the measurement lie larger than reality.
    if grep -q '^disable-model-invocation:[[:space:]]*true' "$sfile" 2>/dev/null; then
      c_hidden=$((c_hidden + dv)); n_hidden=$((n_hidden + 1)); continue
    fi
    c_desc=$((c_desc + dv))
    dtop="${dtop}${dv} ${dn}
"
  done
  # Agent descriptions — **the same in nature as skills, but they were left out because the asset type differs.**
  # They are resident even when not invoked (docs/platform-contract.md §6) and there is not even a non-resident
  # switch equivalent to a skill's disable-model-invocation, **so they cannot be turned off**.
  # `tools:` is counted too because the render of the agent list actually includes `(Tools: …)`
  # (the skill list has no such line, so the loop above counts only name/description).
  # The reset regex differs from the skill loop above — agent frontmatter has keys with capitals such as
  # `disallowedTools:`, and `[a-z_-]+:` does not reset on them so that line gets dragged in (measured +86 bytes).
  c_agent=0
  local afile
  for afile in "$PLUGIN_ROOT"/agents/*.md; do
    [ -f "$afile" ] || continue
    c_agent=$((c_agent + $(num "$(awk '/^---$/{n++; next} n==1 && /^(name|description|tools):/{p=1} n==1 && /^[A-Za-z_-]+:/ && !/^(name|description|tools):/{p=0} n==1 && p{print} n>=2{exit}' "$afile" | wc -c | tr -d ' ')")))
  done
  local n_agent; n_agent=$(num "$({ ls -1 "$PLUGIN_ROOT"/agents/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')")

  c_sum=$((c_t0 + c_route + c_desc + c_agent))

  # Conditional cards — **the part that was missing from the unconditional subtotal.** They are "conditional" because
  # they have paths, but a card with `src/**`·`app/**` and the like comes in as soon as a single source file is read,
  # so in a coding session it is effectively a certain load. Leaving it out of the measurement entirely makes P5 judge
  # on a third of reality (measured: reported 17,063 bytes ↔ coding session 48,450 bytes).
  # The globs are not interpreted — instead of unverifiable sophistication, it is split honestly into **two buckets**.
  local c_src=0 c_oth=0 n_src=0 n_oth=0 rcard
  for rcard in "$PLUGIN_ROOT"/rules/*.md; do
    [ -f "$rcard" ] || continue
    grep -q '^paths:' "$rcard" 2>/dev/null || continue    # always-loaded cards were counted above
    if grep -qE '^\s+- "(src|app|packages|lib)/\*\*"' "$rcard" 2>/dev/null; then
      c_src=$((c_src + $(num "$(wc -c < "$rcard" | tr -d ' ')"))); n_src=$((n_src+1))
    else
      c_oth=$((c_oth + $(num "$(wc -c < "$rcard" | tr -d ' ')"))); n_oth=$((n_oth+1))
    fi
  done

  printf "    %-32s %8s bytes\n" "T0 operating rules" "$c_t0"
  printf "    %-32s %8s bytes\n" "workflow-routing (always loaded)" "$c_route"
  printf "    %-32s %8s bytes\n" "skill description (resident)" "$c_desc"
  printf "    %-32s %8s bytes  ${C_D}cannot be turned off${C_0}\n" "agent description ×${n_agent}" "$c_agent"
  printf "    %-32s %8s bytes\n" "── unconditional subtotal" "$c_sum"
  printf "    %-32s %8s bytes  ${C_D}on reading one source file${C_0}\n" "conditional cards ${n_src} (src/app/lib)" "$c_src"
  printf "    %-32s %8s bytes  ${C_D}when editing that path${C_0}\n" "conditional cards ${n_oth} (other)" "$c_oth"
  printf "    %-32s %8s bytes\n" "── coding session measured" "$((c_sum + c_src))"
  # A total alone does not tell you what to compress — show the top 3 alongside it.
  printf "    ${C_D}top: %s${C_0}\n" "$(printf '%s' "$dtop" | sort -rn | head -3 | awk '{printf "%s %s · ", $2, $1}' | sed 's/ · $//')"
  [ "$n_hidden" -gt 0 ] && printf "    ${C_D}non-resident %d, %s bytes (disable-model-invocation)${C_0}\n" "$n_hidden" "$c_hidden"
  # Honest reporting — state what cannot be counted. T0 is most of session-brief's output and was counted above.
  # What remains is the variable part of the briefing (HEAD·uncommitted count·hook liveness ≈ 400–600 bytes).
  printf "    ${C_D}the variable part of the briefing (HEAD·uncommitted·hook liveness) differs per session and is not included${C_0}\n"
  # Generated-guide descriptions — the previous version stopped at "consumer-side, so not included", but the hub is
  # guides/seams/*/ which the plugin ships, so **it can be counted here.** Leaving out something countable is exactly
  # the optimistic lie the most recent lesson (2026-09-10) pointed at. It is still kept out of the subtotal —
  # it only exists for a consumer who ran orangekit-init and its value depends on which seam, so picking one and
  # adding it to the subtotal would itself be the unverifiable number. Report it as a range.
  local g_min="" g_max="" gdir gpair gh
  for gdir in "$PLUGIN_ROOT"/guides/seams/*/; do
    [ -d "$gdir" ] || continue
    gpair=0
    for gh in "$gdir"frontend/HUB.md "$gdir"backend/HUB.md; do
      [ -f "$gh" ] || continue
      gpair=$((gpair + $(num "$(awk '/^---$/{n++; next} n==1 && /^(name|description):/{p=1} n==1 && /^[A-Za-z_-]+:/ && !/^(name|description):/{p=0} n==1 && p{print} n>=2{exit}' "$gh" | wc -c | tr -d ' ')")))
    done
    [ "$gpair" -eq 0 ] && continue
    # Written with if — `[ ] || [ ] && x` has a precedence that differs from how it looks, and this file already has
    # a precedent of running both branches together in exactly that form (evaluation v3 · E-10).
    if [ -z "$g_min" ] || [ "$gpair" -lt "$g_min" ]; then g_min="$gpair"; fi
    if [ -z "$g_max" ] || [ "$gpair" -gt "$g_max" ]; then g_max="$gpair"; fi
  done
  if [ -n "$g_min" ]; then
    printf "    ${C_D}note: generated guide descriptions %s–%s bytes — resident in the consumer after orangekit-init, excluded from the subtotal because it differs per seam${C_0}\n" "$g_min" "$g_max"
  fi
  printf "    ${C_D}the CLAUDE.md the project authors is not included — the plugin cannot know its content${C_0}\n"
  # The discipline of setting a budget **only after repeated evidence has accumulated** was kept — evaluation v3 (14,219 bytes) ·
  # v4 (11,662) · v5 (11,662) observed it three times running as "4.8× the T0 that has a budget, with no ceiling" (E-07).
  # So the current value is **pinned as the ceiling (a ratchet)**: it only prevents the compressed state from being undone.
  # It warns rather than blocks — this number is a gauge of restraint, not an accuracy gate,
  # and blocking unrelated work would make it the false positive that gets the hook turned off.
  local desc_budget=12000
  if [ "$c_desc" -gt "$desc_budget" ]; then
    warn "skill descriptions ${c_desc} bytes — over the ${desc_budget}-byte budget" \
         "the whole lot is resident every session even if a skill is never invoked. Compress it or move it into the body"
  else
    ok "skill descriptions ${c_desc}/${desc_budget} bytes"
  fi
  ok "resident cost measured — unconditional ${c_sum} (including agents ${c_agent}) · coding session $((c_sum + c_src)) bytes (the verdict is P5)"
}

# ════════════════════════════════════════════════════════════════════
# --lessons : the Act loop
# ════════════════════════════════════════════════════════════════════
run_lessons() {
  printf "\n${C_D}orangekit doctor --lessons${C_0}\n"
  sec "lesson tally"

  local lf="$PROJ/docs/lessons.md"
  [ -f "$lf" ] || { warn "docs/lessons.md missing"; return; }

  local threshold=3 found=0
  printf "  %-24s %5s  %s\n" "category" "count" "status"
  while read -r cnt cat; do
    [ -z "$cat" ] && continue
    local status="—"
    # A false positive is not a promotion target — the rule (rules/lessons.md) says to treat this category as a **narrowing**.
    # Emitting a "promotion candidate" from a category total produces a warning in the opposite direction to the rule on every run (evaluation v6 · E-27).
    if [ "$cat" = "false-positive" ]; then
      status="${C_D}narrowing target — see the per-guard tally under \"false-positive narrowing candidates\" below${C_0}"
    elif [ "$(num "$cnt")" -ge "$threshold" ]; then
      # Does a corresponding rule card exist?
      #   ① the filename matches the category        → a definite corresponding asset
      #   ② the card **deliberately names** the category — in a heading, or as a backticked token.
      #      lessons.md is excluded: it holds the *example list* of categories, so mistaking the
      #      catalogue for a rule reports something unpromoted as promoted.
      #      A bare substring is not enough. The category names are ordinary words (`tooling`,
      #      `naming`, `drift`), so a plain search finds one in almost any prose card and the check
      #      degrades into a rubber stamp: measured, **every** category resolved to some card —
      #      `naming` to data-modeling, `drift` to ui-design — and none of them were promotions.
      local card=""
      for d in "$PLUGIN_ROOT/rules" "$PROJ/.claude/rules"; do
        [ -f "$d/$cat.md" ] && card="$d/$cat.md" && break
      done
      if [ -z "$card" ]; then
        card=$(grep -rlEi --include='*.md' --exclude='lessons.md' -- "^#+ .*[^A-Za-z0-9_-]${cat}([^A-Za-z0-9_-]|\$)|\`${cat}\`" "$PLUGIN_ROOT/rules" "$PROJ/.claude/rules" 2>/dev/null | head -1)
      fi
      if [ -n "$card" ]; then
        status="${C_G}promoted → ${card}${C_0}"
      else
        status="${C_Y}promotion candidate — no corresponding rule card${C_0}"; found=$((found+1))
      fi
    fi
    printf "  %-24s %5s  %b\n" "$cat" "$cnt" "$status"
  done < <(grep -oE '\[category: [^]]+\]' "$lf" 2>/dev/null | sed 's/\[category: //;s/\]//' | sort | uniq -c | sort -rn)

  local total; total=$(num "$(grep -c '^## \[category:' "$lf" 2>/dev/null)")
  printf "\n  %s total" "$total"
  [ -f "$PROJ/docs/lessons-archive.md" ] \
    && printf " · archive %s\n" "$(num "$(grep -c '^## \[category:' "$PROJ/docs/lessons-archive.md" 2>/dev/null)")" \
    || printf " · ${C_Y}no archive file${C_0}\n"

  [ "$found" -gt 0 ] && warn "${found} promotion candidates" "on promotion, move it physically into lessons-archive.md (proven by the file move, not by a declaration)"

  # ── false-positive narrowing candidates — per guard ──
  # Merging the false positives of different guards into one category loses "what should be narrowed". The guard is
  # canonically the entry's `- Guard:` line, and when absent it is inferred from the first script/skill name in the body (the inference is marked).
  # Two or more for the same guard means, per the rule, **narrow the condition or downgrade it to a warning** — do not add a rule.
  sec "false-positive narrowing candidates (per guard)"
  local fp_total fp_hot=0
  fp_total=$(num "$(grep -c '^## \[category: false-positive\]' "$lf" 2>/dev/null)")
  if [ "$fp_total" -eq 0 ]; then
    printf "  (no records)\n"
  else
    while read -r cnt dev; do
      [ -z "$dev" ] && continue
      printf "  %-44s %s\n" "$dev" "$cnt"
      [ "$(num "$cnt")" -ge 2 ] && fp_hot=$((fp_hot+1))
    done < <(awk '
      /^## \[category: /{ if (fp && dev=="") print "(Guard not recorded)"; fp=($0 ~ /false-positive\]/); dev=""; next }
      fp && /^- Guard:/ { d=$0; sub(/^- Guard:[ \t]*/,"",d); if (dev=="") { dev=d; print d }; next }
      fp && dev=="" {
        if (match($0, /[a-z-]+\.sh/))               { dev=substr($0,RSTART,RLENGTH) "(inferred)"; print dev }
        else if (match($0, /skills\/[a-z-]+/))     { dev=substr($0,RSTART,RLENGTH) "(inferred)"; print dev }
        else if ($0 ~ /harness evaluation|harness-evaluation/) { dev="harness-evaluation(inferred)"; print dev } }
      END { if (fp && dev=="") print "(Guard not recorded)" }' "$lf" | sort | uniq -c | sort -rn)
    if [ "$fp_hot" -gt 0 ]; then
      warn "2 or more false positives on the same guard — ${fp_hot} guards" "do not add a rule — narrow that guard's condition or downgrade it to a warning (rules/lessons.md)"
    else
      ok "${fp_total} false positives — fewer than 2 per guard"
    fi
  fi

  # Repeated requests [request: X] — 3 or more makes it an automation (skill promotion) candidate
  sec "repeated request tally"
  local rfound=0 rshown=0
  while read -r cnt req; do
    [ -z "$req" ] && continue
    rshown=1
    local rstatus="—"
    if [ "$(num "$cnt")" -ge "$threshold" ]; then
      if [ -d "$PLUGIN_ROOT/skills/$req" ] || [ -d "$PROJ/.claude/skills/$req" ]; then
        rstatus="${C_G}automated → the corresponding skill exists${C_0}"
      else
        rstatus="${C_Y}automation candidate — no corresponding skill${C_0}"; rfound=$((rfound+1))
      fi
    fi
    printf "  %-24s %5s  %b\n" "$req" "$cnt" "$rstatus"
  done < <(grep -oE '\[request: [^]]+\]' "$lf" 2>/dev/null | sed 's/\[request: //;s/\]//' | sort | uniq -c | sort -rn)
  [ "$rshown" -eq 0 ] && printf "  (no records)\n"
  [ "$rfound" -gt 0 ] && warn "${rfound} automation candidates" "the same request 3+ times — consider promoting it to a skill (user approval required)"

  # Shadow retirement mirror — an expired one needs either a confirmed deletion or a rollback decision
  local sh_dir="$PROJ/.claude/deprecated"
  if [ -d "$sh_dir" ]; then
    sec "Shadow retirement mirror"
    local today expired=0 sh_active=0 exp_list=""
    today=$(date +%Y-%m-%d)
    while IFS= read -r sf; do
      [ -z "$sf" ] && continue
      local exp="${sf##*.shadow-expires-}"
      case "$exp" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
          if [ "$exp" \< "$today" ]; then expired=$((expired+1)); exp_list="$exp_list $(basename "$sf")"
          else sh_active=$((sh_active+1)); fi ;;
        *) expired=$((expired+1)); exp_list="$exp_list $(basename "$sf")(malformed expiry date)" ;;
      esac
    done < <(find "$sh_dir" -name '*.shadow-expires-*' -type f 2>/dev/null)
    if [ "$expired" -gt 0 ]; then
      warn "${expired} expired shadows" "a decision is needed: confirm retirement (delete) or roll back (restore in place):$exp_list"
    else
      ok "${sh_active} shadows under observation · none expired"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════
# --inventory : per-area asset inventory (no verdicts)
#
# This is the **input** to /harness-evaluation's requested perspectives ①"per-area review" and ⑨"token cost". The evaluation
# skill does not count again — it judges what was counted here. Why no verdict (ok/bad) is issued: these numbers are
# observations, not budgets, and driving a threshold into an observation comes after repeated evidence accumulates (the E-07 discipline).
# ════════════════════════════════════════════════════════════════════
run_inventory() {
  printf "\n${C_D}orangekit doctor --inventory${C_0}  (plugin: %s)\n" "$PLUGIN_ROOT"
  local g="workflow.graph.json" hasjq=0
  command -v jq >/dev/null 2>&1 && [ -f "$g" ] && hasjq=1

  sec "skills (${C_D}lines=SKILL.md · desc=resident bytes · onCall=total .md in the directory · in/out=graph edges · docs=number of README+docs files mentioning it${C_0})"
  printf "  %-26s %5s %6s %-3s %8s %5s %4s  %s\n" "skill" "lines" "descB" "res" "onCallB" "in/out" "docs" "phase"
  local sd sn sl dv dmi ib eio dm ph
  for sd in skills/*/; do
    [ -f "$sd/SKILL.md" ] || continue
    sn=$(basename "$sd")
    sl=$(num "$(wc -l < "$sd/SKILL.md")")
    dv=$(num "$(awk '/^---$/{n++; next} n==1 && /^(name|description):/{p=1} n==1 && /^[a-z_-]+:/ && !/^(name|description):/{p=0} n==1 && p{print} n>=2{exit}' "$sd/SKILL.md" | wc -c | tr -d ' ')")
    dmi="○"; grep -q '^disable-model-invocation:[[:space:]]*true' "$sd/SKILL.md" 2>/dev/null && dmi="—"
    ib=$(num "$(find "$sd" -name '*.md' -print0 2>/dev/null | xargs -0 cat 2>/dev/null | wc -c | tr -d ' ')")
    eio="?"; ph=""
    if [ "$hasjq" -eq 1 ]; then
      eio=$(jq -r --arg n "$sn" '"\([.edges[]|select(.to==$n)]|length)/\([.edges[]|select(.from==$n)]|length)"' "$g" 2>/dev/null)
      ph=$(jq -r --arg n "$sn" '[.nodes[]|select(.id==$n)|.phase[]?]|join(",")' "$g" 2>/dev/null)
    fi
    dm=$(num "$(grep -lF -- "$sn" README.md docs/*.md 2>/dev/null | wc -l | tr -d ' ')")
    printf "  %-26s %5s %6s %-3s %8s %5s %4s  %s\n" "$sn" "$sl" "$dv" "$dmi" "$ib" "$eio" "$dm" "$ph"
  done

  sec "rule cards (${C_D}paths=number of condition globs, 0=always · links=number of ../references references${C_0})"
  printf "  %-24s %5s %-8s %5s %5s\n" "card" "lines" "stamp" "paths" "links"
  local rc rl rs rp rk
  for rc in rules/*.md; do
    [ -f "$rc" ] || continue
    rl=$(num "$(wc -l < "$rc")")
    rs=$(grep -m1 -oE 'orangekit-rule-version: [0-9.]+' "$rc" | awk '{print $2}')
    rp=$(num "$(awk '/^---$/{n++; next} n==1 && /^[[:space:]]*- /{c++} END{print c+0}' "$rc")")
    rk=$(num "$(grep -oE '\.\./references/[A-Za-z0-9_./-]+\.md' "$rc" | sort -u | wc -l | tr -d ' ')")
    printf "  %-24s %5s %-8s %5s %5s\n" "$(basename "$rc")" "$rl" "${rs:-none}" "$rp" "$rk"
  done
  printf "  %-24s %5s\n" "total" "$(num "$(cat rules/*.md 2>/dev/null | wc -l | tr -d ' ')")"

  sec "hooks (${C_D}blocks=dblock/block call sites · fixtures=the fixtures/*.json fed to this script${C_0})"
  printf "  %-22s %5s %-24s %5s %6s\n" "script" "lines" "event" "blocks" "fixtures"
  if [ -f hooks/hooks.json ] && command -v jq >/dev/null 2>&1; then
    local hs hev hl hb hf
    while IFS=$'\t' read -r hs hev; do
      [ -f "$hs" ] || continue
      hl=$(num "$(wc -l < "$hs")")
      hb=$(num "$(grep -cE '^[[:space:]]*(&& |\|\| )?(dblock|block) "' "$hs")")
      hf=$(num "$(ls -1 scripts/fixtures/${hev%%|*}*.json 2>/dev/null | wc -l | tr -d ' ')")
      printf "  %-22s %5s %-24s %5s %6s\n" "$(basename "$hs")" "$hl" "$hev" "$hb" "$hf"
    done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[]?.hooks[]?.command
                    | capture("(?<f>scripts/[a-z0-9./-]+\\.sh)").f + "\t" + $e' hooks/hooks.json 2>/dev/null \
             | awk -F'\t' '{ if ($1 in ev) ev[$1]=ev[$1]"|"$2; else ev[$1]=$2 } END { for (k in ev) print k "\t" ev[k] }' | sort)
  fi
  printf "  %-22s %5s\n" "lib/common.sh" "$(num "$(wc -l < scripts/lib/common.sh 2>/dev/null)")"

  sec "agents (${C_D}descB=resident bytes · unlike the skill table, there is no non-resident switch${C_0})"
  local af adv
  for af in agents/*.md; do
    [ -f "$af" ] || continue
    # descB in the skill table counts only name+description. The **same formula** is used here — reading the two tables
    # side by side is the purpose of --inventory, so comparability comes first. The value that also adds `tools:`
    # is produced by --usage's "resident context cost" (that one aims to measure the actual render, so it includes it).
    adv=$(num "$(awk '/^---$/{n++; next} n==1 && /^(name|description):/{p=1} n==1 && /^[A-Za-z_-]+:/ && !/^(name|description):/{p=0} n==1 && p{print} n>=2{exit}' "$af" | wc -c | tr -d ' ')")
    printf "  %-16s %4s lines %6s descB  model=%-7s tools=%s\n" "$(basename "$af" .md)" "$(num "$(wc -l < "$af")")" \
      "$adv" \
      "$(grep -m1 -E '^model:' "$af" | sed 's/^model:[[:space:]]*//')" \
      "$(grep -m1 -E '^tools:' "$af" | sed 's/^tools:[[:space:]]*//')"
  done

  sec "axis guide packs (${C_D}verified=pack verification date · pkgs=number of packages used as the freshness baseline${C_0})"
  local pk pj
  for pk in guides/frontend/*/ guides/backend/*/ guides/app/*/; do
    [ -f "$pk/pack.json" ] || continue
    pj="$pk/pack.json"
    printf "  %-28s %3s files %6s lines  v%-7s verified=%s pkgs=%s\n" "${pk#guides/}" \
      "$(num "$(find "$pk" -type f | wc -l | tr -d ' ')")" \
      "$(num "$(find "$pk" -name '*.md' -print0 | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')")" \
      "$(jq -r '.packVersion // "?"' "$pj" 2>/dev/null)" "$(jq -r '.verified // "?"' "$pj" 2>/dev/null)" \
      "$(jq -r '(.pkgs // []) | length' "$pj" 2>/dev/null)"
  done
  printf "  seams: %s\n" "$({ ls -1d guides/seams/*/ 2>/dev/null || true; } | sed -E 's|.*/([^/]+)/$|\1|' | tr '\n' ' ')"

  sec "other assets"
  printf "  %-14s %3s files %6s lines\n" "references/" "$(num "$(find references -name '*.md' 2>/dev/null | wc -l | tr -d ' ')")" "$(num "$(find references -name '*.md' -print0 2>/dev/null | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  %-14s %3s files %6s lines\n" "templates/" "$(num "$(find templates -type f 2>/dev/null | wc -l | tr -d ' ')")" "$(num "$(find templates -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  %-14s %3s files\n" "presets/" "$(num "$(find presets -name '*.json' 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  %-14s %3s files\n" "fixtures/" "$(num "$(ls -1 scripts/fixtures/*.json 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  %-14s %3s files %6s lines\n" "docs/" "$(num "$(ls -1 docs/*.md 2>/dev/null | wc -l | tr -d ' ')")" "$(num "$(cat docs/*.md 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  %-14s %3s files %6s lines  (check scripts — the upkeep of the verdict machinery)\n" "scripts/*.sh" "$(num "$(ls -1 scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')")" "$(num "$(cat scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')")"
  printf "  ${C_D}the measurement of resident cost is --usage, and invocation traces come from --usage's skill invocation section — they are not counted here${C_0}\n"
}

# ════════════════════════════════════════════════════════════════════
MODE="${1:---default}"
case "$MODE" in
  --fast)      run_fast ;;
  --self-test) run_self_test ;;
  --graph)     run_graph ;;
  --usage)     run_usage ;;
  --lessons)   run_lessons ;;
  --consumer)  run_consumer ;;
  --inventory) run_inventory ;;
  --all)       run_fast; run_self_test; run_graph; run_consumer; run_usage; run_lessons; run_inventory ;;
  --default)   run_fast; run_graph ;;
  -h|--help)
    # Print the whole header comment. Hardcoding line numbers means the header gets truncated the moment it grows,
    # or the implementation leaks — `sed -n '2,24p'` was in fact printing 6 lines down to `set -uo pipefail` (evaluation v6 · E-36).
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit 0 ;;
  *) printf "unknown option: %s (see --help)\n" "$MODE" >&2; exit 2 ;;
esac

printf "\n${C_D}────────────────────────────────────────────${C_0}\n"
printf "  pass %s · ${C_Y}warn %s${C_0} · ${C_R}fail %s${C_0}\n\n" "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
