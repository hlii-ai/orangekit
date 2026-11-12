#!/bin/bash
# Process budget per hook call — the guard against the per-call cost creeping back.
# On Windows (Git Bash) every external process costs ~15–30 ms: MSYS2 emulates fork, and each jq · awk · grep · sed · date pays it.
# CI run 7 measured 2.5–3.7 s per security-check call there, with 73–137 processes per call; the same calls now start 1–3.
# A PATH shim logs every exec of a common tool while one hook call runs on a fixed input, and the count must stay within budget.
# Budgets = the measured count + 2. A Windows shell adds win-compat's start-up (python probes) and one `tr` per jq — 6 more there.
# Usage: bash proc-budget.sh <plugin root>     Exit: 0 = every call within budget · 1 = over budget (or the shim could not be built)
R=$(cd "${1:?plugin root}" && pwd)
T=$(mktemp -d 2>/dev/null) || { echo "FAIL cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
extra=2; case "${OSTYPE:-}" in msys*|cygwin*|win*) extra=8 ;; esac
pass=0 fail=0

# the shim: one wrapper per tool the hooks call, logging its name, then running the real one
mkdir -p "$T/shim"
for c in jq awk gawk mawk sed grep egrep tr head tail wc date mkdir cat sort comm cut paste git stat dirname basename find mv rm \
         env pkill pgrep ls xargs od uname tee mktemp cp sleep psql sh python3 python py cygpath perl; do
  real=$(PATH="$PATH" type -P "$c" 2>/dev/null) || continue
  printf '#!/bin/sh\necho %s >> "$OKPB_LOG"\nexec "%s" "$@"\n' "$c" "$real" > "$T/shim/$c"; chmod +x "$T/shim/$c"
done
[ -x "$T/shim/jq" ] && [ -x "$T/shim/git" ] || { echo "skip process budget — jq or git not installed"; exit 0; }

P="$T/p"; mkdir -p "$P/.claude/rules" "$P/src"
printf -- '---\npaths:\n  - "migrations/**"\n---\n# data card\n' > "$P/.claude/rules/data.md"
echo 'export const a = 1' > "$P/src/a.ts"
(cd "$P" && git init -q && git add -A && git -c user.email=t@x -c user.name=t commit -qm i) >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' > "$T/t.jsonl"
pl() { MSYS_NO_PATHCONV=1 jq -nc --arg t "$1" --argjson i "$2" --arg tp "$T/t.jsonl" --arg c "$P" '{session_id:"pb",transcript_path:$tp,cwd:$c,tool_name:$t,tool_input:$i}'; }

run() {   # name  budget  script  payload
  local log="$T/log.$1" n
  : > "$log"; rm -rf "$T/st"; mkdir -p "$T/st"
  printf '%s' "$4" | (cd "$P" && OKPB_LOG="$log" PATH="$T/shim:$PATH" CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" \
    ORANGEKIT_STATE_DIR="$T/st" bash "$R/scripts/$3" >/dev/null 2>&1)
  n=$(grep -c . "$log" 2>/dev/null); n=${n:-0}
  if [ "$n" -le $(( $2 + extra )) ]; then pass=$((pass+1)); echo "ok   $1: $n processes (budget $(( $2 + extra )))"
  else fail=$((fail+1)); echo "FAIL $1: $n processes, budget $(( $2 + extra )) — $(sort "$log" | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')"; fi
}
run "security-check Bash ls"                1 security-check.sh "$(pl Bash '{"command":"ls"}')"
run "security-check Bash git status"        2 security-check.sh "$(pl Bash '{"command":"git status"}')"
run "security-check Bash with pipes"        2 security-check.sh "$(pl Bash '{"command":"cd x && npx vitest run | tail; git status | head"}')"
EDIT=$(MSYS_NO_PATHCONV=1 jq -nc --arg f "$P/src/a.ts" '{file_path:$f, old_string:"1", new_string:"2"}')
WRITE=$(MSYS_NO_PATHCONV=1 jq -nc --arg f "$P/src/a.ts" '{file_path:$f, content:"export const a = 2"}')
run "security-check Edit"                   2 security-check.sh "$(pl Edit "$EDIT")"
run "security-check Write (existing file)"  2 security-check.sh "$(pl Write "$WRITE")"
run "build-gate Stop, clean tree"           3 build-gate.sh "$(MSYS_NO_PATHCONV=1 jq -nc --arg tp "$T/t.jsonl" --arg c "$P" '{session_id:"pb",transcript_path:$tp,cwd:$c,hook_event_name:"Stop",stop_hook_active:false}')"
echo "pass $pass fail $fail"
[ "$fail" -eq 0 ]
