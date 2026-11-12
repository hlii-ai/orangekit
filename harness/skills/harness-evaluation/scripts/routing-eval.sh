#!/bin/bash
# routing-eval.sh — measure the routing accuracy of skill descriptions (P2 firing accuracy)
#
# Gives the full set of resident descriptions + competing built-ins (assets/routing-competitors.tsv) as a list, and
# asks each user utterance, in an isolated `claude -p`, "which ONE skill would you call first (or NONE)?"
# Unlike skill-creator's run_eval, which looks at one skill alone, this exposes **mis-calls between neighbors**.
# Descriptions are read from SKILL.md at run time — compare before/after an improvement by git state.
#
#   routing-eval.sh --cases <file.jsonl> [--out <dir>] [--model sonnet] [--jobs 8] [--runs 1]
#   routing-eval.sh --self-test     prove scoring and normalization with a fake claude (no network)
#   routing-eval.sh --help
#
# Case format (JSONL): {"id":"pr-prep-1","query":"…","expect":["pr-prep"],"kind":"pos|near|neg"}
#   expect values: plugin skill name · builtin:code-review · builtin:security-review ·
#              simplify · init · skill-creator · diagram-design · run · loop · none
#
# Exit codes: 0 = measured, 1 = some calls failed (no response), 2 = cannot run (no claude/jq · bad argument)

set -uo pipefail   # no -e: one call's failure must not stop the whole measurement

# Windows shims — a COPY of orangekit-product's scripts/lib/win-compat.sh (this plugin ships without scripts/).
# doctor --default compares it with the canonical file; change both together.
# ── Windows (Git Bash · MSYS · Cygwin): resolve Python, strip CRLF
# `python3` is often the Microsoft Store alias — on PATH, but it opens the Store (exit 9009) instead of running — while a
# python.org install answers to `python` or `py -3`. Native jq.exe and python.exe also end every line with CRLF, and the
# trailing \r broke comparisons silently. Only on a Windows shell; macOS and Linux are untouched.
case "${OSTYPE:-}" in
  msys*|cygwin*|win*)
    # Python on Windows writes stdout in the console code page (cp1252): a message holding ≠ or → raised UnicodeEncodeError,
    # the check died and its FAIL never printed — guide-gate passed bad stack cards on windows-latest (CI run 6)
    export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
    # The probes start up to three Windows processes (an interpreter ~0.1 s each). A hook that never runs Python sets _OK_PY_LAZY
    # before sourcing (security-check and build-gate, on every tool call) and skips them; python3 then resolves on its first call.
    # Everything else resolves here, once, as before — an answer first found inside $( ) would not reach the parent shell, and
    # a loop of `$(… | python3 …)` would probe again every time. Nothing found → the plain python3 on PATH, as before
    _ok_py_resolve() {
      local _ok_c; _OK_PY=""
      for _ok_c in python3 python "py -3"; do
        # an `if` condition: a failing probe must not trip the caller's `set -e` (common.sh) when it runs on a first call
        if command $_ok_c -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then _OK_PY=$_ok_c; break; fi
      done
      return 0
    }
    python3() {
      # first call (lazy): in a trap-free $( ) — the caller's ERR trap (common.sh) fires on a failing probe even inside an `if` on bash 3.2
      [ -n "${_OK_PY+x}" ] || _OK_PY=$(trap - ERR; _ok_py_resolve; printf '%s' "$_OK_PY")
      [ -n "$_OK_PY" ] || { command python3 "$@"; return; }
      command $_OK_PY "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"
    }
    [ -n "${_OK_PY_LAZY:-}" ] || { _ok_py_resolve; [ -n "$_OK_PY" ] || unset -f python3; }   # as before: no Python, no function
    command -v jq >/dev/null 2>&1 && jq() { command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; } ;;
esac

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$SKILL_DIR/../../.." && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

CASES="" OUT="" MODEL="sonnet" JOBS=8 RUNS=1 SELFTEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cases) CASES="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not installed — brew install jq" >&2; exit 2; }

# Resident listing — skills with disable-model-invocation: true are left out, since their description is not resident.
build_listing() {
  local root prefix sm fm name desc
  for pair in "skills:orangekit-product" "marketing/skills:orangekit-marketing"; do
    root="${pair%%:*}"; prefix="${pair##*:}"
    for sm in "$REPO/$root"/*/SKILL.md; do
      [ -f "$sm" ] || continue
      fm=$(awk '/^---$/{n++; if(n==2) exit; next} n==1' "$sm")
      printf '%s\n' "$fm" | grep -q '^disable-model-invocation:[[:space:]]*true' && continue
      name=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)
      desc=$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//; s/\\"/"/g')
      printf -- '- %s:%s: %s\n' "$prefix" "$name" "$desc"
    done
  done
  while IFS="$(printf '\t')" read -r name desc; do
    [ -n "$name" ] && printf -- '- %s: %s\n' "$name" "$desc"
  done < "$SKILL_DIR/assets/routing-competitors.tsv"
}

# Answer normalization — strip the plugin prefix; an unprefixed code-review or security-review is the built-in
# (the plugin's security-review appears in the listing only as orangekit-product:security-review).
normalize() {
  local a; a=$(printf '%s' "$1" | tr -d '`*"' | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*\/\{0,1\}//; s/[[:space:]].*$//; s/[.,]$//')
  case "$a" in
    orangekit-product:*|orangekit-marketing:*) printf '%s' "${a#*:}" ;;
    code-review|security-review) printf 'builtin:%s' "$a" ;;
    ''|none|no) printf 'none' ;;
    *) printf '%s' "$a" ;;
  esac
}

ask_one() {   # $1=id $2=run  — the query is re-read from the case file (avoids xargs argument-quoting problems)
  local id="$1" run="$2" q ans
  q=$(jq -r --arg id "$id" 'select(.id==$id) | .query' "$CASES")
  ans=$("$CLAUDE_BIN" -p "$q" --system-prompt-file "$OUT/system.txt" --tools "" --setting-sources "" \
          --strict-mcp-config --no-session-persistence --model "$MODEL" 2>/dev/null \
        | awk 'NF{l=$0} END{print l}')
  printf '%s' "$ans" > "$OUT/raw/$id.$run.txt"
}
export -f ask_one

score() {
  local f id run raw got
  : > "$OUT/results.jsonl"
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r .id)
    run=1
    while [ "$run" -le "$RUNS" ]; do
      f="$OUT/raw/$id.$run.txt"
      raw=$(cat "$f" 2>/dev/null || true)
      if [ -z "$raw" ]; then got="ERROR"; else got=$(normalize "$raw"); fi
      printf '%s' "$line" | jq -c --arg got "$got" --arg raw "$raw" --argjson run "$run" \
        '{id, kind, expect, query, run:$run, got:$got, raw:$raw, pass:(.expect|index($got)!=null)}' >> "$OUT/results.jsonl"
      run=$((run+1))
    done
  done < "$CASES"
}

report() {
  local r="$OUT/results.jsonl"
  jq -rs '
    def pct(a;b): if b==0 then "-" else ((a*1000/b|floor)/10|tostring)+"%" end;
    (map(select(.pass))|length) as $p | length as $n |
    "Total \($p)/\($n) = \(pct($p;$n))  (errors \(map(select(.got=="ERROR"))|length))",
    (group_by(.kind)[] | "  \(.[0].kind)\t\(map(select(.pass))|length)/\(length) = \(pct(map(select(.pass))|length; length))"),
    "",
    "By expected skill (pos+near):",
    (map(select(.kind!="neg")) | group_by(.expect[0])[] |
       "  \(.[0].expect[0])\t\(map(select(.pass))|length)/\(length)"),
    "",
    "Wrong answers (expected → actual):",
    (map(select(.pass|not))[] | "  [\(.kind)] \(.id): \(.expect|join("|")) → \(.got)  « \(.query) »")
  ' "$r" | tee "$OUT/summary.txt"
}

run_eval() {
  [ -f "$CASES" ] || { echo "case file not found: $CASES" >&2; exit 2; }
  jq -c . "$CASES" >/dev/null 2>&1 || { echo "case file is not JSONL: $CASES" >&2; exit 2; }
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "FAIL claude CLI not found — cannot measure" >&2; exit 2; }
  [ -n "$OUT" ] || OUT="$(mktemp -d)/routing-eval"
  mkdir -p "$OUT/raw"
  {
    cat <<'EOF'
You are Claude Code, an AI coding assistant working in a user's software project. You have a Skill tool. The skills available to it are listed below as `- name: description`. Invoke a skill when the user's request matches what it does; otherwise you handle the request directly without any skill.

For the user's message, decide which ONE skill you would invoke first, or NONE if you would not invoke any skill. Reply with exactly the skill name as listed, or NONE, and nothing else.

<available_skills>
EOF
    build_listing
    echo "</available_skills>"
  } > "$OUT/system.txt"
  export CASES OUT MODEL CLAUDE_BIN
  local run=1 ids; ids=$(jq -r .id "$CASES")
  while [ "$run" -le "$RUNS" ]; do
    printf '%s\n' "$ids" | xargs -P "$JOBS" -I{} bash -c 'ask_one "$1" "$2"' _ {} "$run"
    run=$((run+1))
  done
  score
  echo "Results: $OUT/results.jsonl"
  report
  grep -q '"got":"ERROR"' "$OUT/results.jsonl" && return 1
  return 0
}

self_test() {
  local T; T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  # Fake claude: returns the query string as the answer → each case is its own mock response
  cat > "$T/claude" <<'EOF'
#!/bin/bash
printf 'thinking...\n%s\n' "$2"
EOF
  chmod +x "$T/claude"
  cat > "$T/cases.jsonl" <<'EOF'
{"id":"a","query":"orangekit-product:pr-prep","expect":["pr-prep"],"kind":"pos"}
{"id":"b","query":"security-review","expect":["builtin:security-review"],"kind":"near"}
{"id":"c","query":"orangekit-product:security-review","expect":["builtin:security-review"],"kind":"near"}
{"id":"d","query":"NONE","expect":["none"],"kind":"neg"}
{"id":"e","query":"`orangekit-marketing:seo-strategy`","expect":["seo-strategy"],"kind":"pos"}
EOF
  local out rc fails=0
  out=$(CLAUDE_BIN="$T/claude" bash "$0" --cases "$T/cases.jsonl" --out "$T/o" --jobs 2 2>&1); rc=$?
  # Expected: a·b·d·e pass, c fails (the plugin's security-review must be told apart from the built-in) → 4/5
  printf '%s\n' "$out" | grep -q 'Total 4/5' || { echo "FAIL score is not 4/5"; fails=1; }
  printf '%s\n' "$out" | grep -q 'c: builtin:security-review → security-review' \
    || { echo "FAIL wrong answer c was not caught for the intended reason (plugin vs built-in confusion)"; fails=1; }
  [ "$rc" -eq 0 ] || { echo "FAIL exit code $rc (expected 0)"; fails=1; }
  # No response counts as ERROR and exits 1
  printf '#!/bin/bash\nexit 0\n' > "$T/claude"
  CLAUDE_BIN="$T/claude" bash "$0" --cases "$T/cases.jsonl" --out "$T/o2" --jobs 2 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL no response but exit code $rc (expected 1)"; fails=1; }
  # Is the real listing non-empty — with 0 resident skills the measurement is meaningless
  local n; n=$(grep -c '^- orangekit-' "$T/o/system.txt")
  [ "$n" -ge 10 ] || { echo "FAIL resident skill listing has ${n} entries"; fails=1; }
  grep -q 'orangekit-product:orangekit-init' "$T/o/system.txt" && { echo "FAIL a manual-only skill got into the listing"; fails=1; }
  [ "$fails" -eq 0 ] && echo "PASS routing-eval self-test (score 4/5 · wrong-answer reason · no-response exit 1 · ${n} listed · manual-only excluded)"
  return "$fails"
}

if [ "$SELFTEST" -eq 1 ]; then self_test; exit $?; fi
[ -n "$CASES" ] || { usage >&2; exit 2; }
run_eval; exit $?
