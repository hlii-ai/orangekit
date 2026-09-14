#!/bin/bash
# skills/health-check/scripts/build-parser.sh
# Structures build/lint/typecheck/test output as JSON.
# Saves tokens by consuming only a structured summary instead of putting the raw log (hundreds of lines) into context.
#
# Usage: build-parser.sh <build|lint|typecheck|test|sonar> [command...]
#   With no command given, reads techStack.commands.<mode> from ./orangekit.config.json.
#   If that is missing too, looks for a same-named script in package.json scripts.
#
# Output (JSON): { mode, command, success, exit_code, error_count, warning_count,
#               errors: [up to 40 structured lines], tail: [last 15 lines on failure] }
#
# sonar mode requires a SonarQube server (SONAR_HOST_URL · SONAR_TOKEN environment variables).
#   The token is taken from the environment only — writing it into config is blocked by the security-check hook.
#   If the server, token, or scanner is missing, or the analysis does not finish, it reports **undecidable (exit 2), not failure**:
#   { undecidable: true, reason: "..." }. So that a missing tool is not folded into an absence of defects.
#   Extra fields: severity_counts{blocker,critical,major,minor,info} · total (total issue count as counted by the server)
set -u

MODE="${1:-build}"; shift 2>/dev/null || true
CMD="${*:-}"

command -v jq >/dev/null 2>&1 || { printf '{"success":false,"error":"jq required"}\n'; exit 2; }

# ── undecidable — means the check could not run, not that it passed ──
undecidable() {
  jq -n --arg r "$1" --arg cmd "${CMD:-}" \
    '{mode:"sonar", command:$cmd, success:false, exit_code:2, undecidable:true,
      reason:$r, error_count:0, warning_count:0, errors:[], tail:[]}'
  exit 2
}

# Command resolution: argument > orangekit.config.json > package.json scripts
if [ -z "$CMD" ] && [ -f orangekit.config.json ]; then
  CMD=$(jq -r ".techStack.commands.${MODE} // empty" orangekit.config.json 2>/dev/null)
fi
if [ -z "$CMD" ] && [ -f package.json ]; then
  if jq -e ".scripts.\"${MODE}\"" package.json >/dev/null 2>&1; then
    PM="npm"
    [ -f pnpm-lock.yaml ] && PM="pnpm"
    [ -f yarn.lock ] && PM="yarn"
    [ -f bun.lockb ] && PM="bun"
    CMD="$PM run $MODE"
  fi
fi
[ "$MODE" = "sonar" ] && [ -z "$CMD" ] && CMD="sonar-scanner"

if [ -z "$CMD" ]; then
  jq -n --arg m "$MODE" '{mode:$m, success:false, error:"no command given — provide it via orangekit.config.json techStack.commands or as an argument"}'
  exit 2
fi

# ── sonar mode — run the scanner → wait for the CE task → query issues via the Web API ──
# The other modes' paths do not pass through here.
if [ "$MODE" = "sonar" ]; then
  command -v curl >/dev/null 2>&1 || undecidable "curl not installed — cannot query the SonarQube Web API"
  command -v "${CMD%% *}" >/dev/null 2>&1 || undecidable "${CMD%% *} not installed — cannot run static analysis"
  [ -n "${SONAR_HOST_URL:-}" ] || undecidable "SONAR_HOST_URL not set — analysis server unknown"
  [ -n "${SONAR_TOKEN:-}" ]    || undecidable "SONAR_TOKEN not set — cannot authenticate to the Web API (the token is taken from the environment only)"

  HOST="${SONAR_HOST_URL%/}"
  curl -sf -m 10 -u "$SONAR_TOKEN:" "$HOST/api/system/status" >/dev/null 2>&1 \
    || undecidable "no response from the SonarQube server ($HOST) — not running, or the token is not valid"

  SOUT=$(eval "$CMD" 2>&1); SCODE=$?
  if [ "$SCODE" -ne 0 ]; then
    undecidable "sonar-scanner failed (exit $SCODE) — $(printf '%s\n' "$SOUT" | tail -3 | tr '\n' ' ')"
  fi

  TASKFILE=".scannerwork/report-task.txt"
  [ -f "$TASKFILE" ] || undecidable "$TASKFILE missing — the scanner did not upload the analysis"
  CE_ID=$(grep -E '^ceTaskId=' "$TASKFILE" | cut -d= -f2-)
  PKEY=$(grep -E '^projectKey=' "$TASKFILE" | cut -d= -f2-)
  [ -n "$CE_ID" ] && [ -n "$PKEY" ] || undecidable "could not read ceTaskId·projectKey from report-task.txt"

  # CE task polling — capped at 60s. Never build a wait that has neither a predicate nor a counter.
  STATUS=""; ELAPSED=0
  while [ "$ELAPSED" -lt 60 ]; do
    STATUS=$(curl -sf -m 10 -u "$SONAR_TOKEN:" "$HOST/api/ce/task?id=$CE_ID" 2>/dev/null \
             | jq -r '.task.status // empty')
    case "$STATUS" in
      SUCCESS) break;;
      FAILED|CANCELED) undecidable "server-side analysis $STATUS — no result";;
    esac
    sleep 5; ELAPSED=$((ELAPSED + 5))
  done
  [ "$STATUS" = "SUCCESS" ] || undecidable "server-side analysis did not finish within 60s (last status: ${STATUS:-no response})"

  ISSUES=$(curl -sf -m 30 -u "$SONAR_TOKEN:" \
    "$HOST/api/issues/search?componentKeys=$PKEY&resolved=false&ps=100" 2>/dev/null) \
    || undecidable "issue query failed — $HOST/api/issues/search"

  # SonarQube 10+ may give only impacts[].severity (HIGH/MEDIUM/LOW) instead of severity — normalize it.
  printf '%s' "$ISSUES" | jq \
    --arg cmd "$CMD" \
    'def sev: (.severity // (.impacts // [] | .[0].severity // "MAJOR"))
              | if . == "HIGH" then "CRITICAL" elif . == "MEDIUM" then "MAJOR"
                elif . == "LOW" then "MINOR" else . end;
     (.issues // []) as $all
     | ($all | map(sev)) as $sevs
     | {mode:"sonar", command:$cmd,
        exit_code:0,
        error_count:   ($sevs | map(select(. == "BLOCKER" or . == "CRITICAL")) | length),
        warning_count: ($sevs | map(select(. == "MAJOR")) | length),
        severity_counts: {
          blocker:  ($sevs | map(select(. == "BLOCKER"))  | length),
          critical: ($sevs | map(select(. == "CRITICAL")) | length),
          major:    ($sevs | map(select(. == "MAJOR"))    | length),
          minor:    ($sevs | map(select(. == "MINOR"))    | length),
          info:     ($sevs | map(select(. == "INFO"))     | length)
        },
        total: (.paging.total // ($all | length)),
        errors: ($all | map("\(sev) \(.component // "?"):\(.line // 0) — \(.message // "") [\(.rule // "?")]")
                      | .[0:40]),
        tail: []}
     | .success = (.error_count == 0)'
  exit 0
fi

OUT=$(eval "$CMD" 2>&1); CODE=$?

# Extract error/warning lines — TS (file(l,c): error TSxxxx), ESLint (error/warning),
# Python (File "...", Error:), Rust (error[Exxx]), generic (any line containing error)
ERR_LINES=$(printf '%s\n' "$OUT" | grep -nE \
  '(: error TS[0-9]+|: warning|[[:space:]]error[[:space:]]|^Error|error\[|ERROR|FAILED|✕|✗|Traceback|File "|SyntaxError|TypeError|AssertionError)' \
  | head -40)
# grep -c prints "0" even when there are no matches (it merely exits 1). The '|| echo 0'
# fallback prints 0 twice and breaks the JSON — the §1.1 idiom of v2's silent failure. Only strip whitespace.
ERR_COUNT=$(printf '%s\n' "$OUT" | grep -cE '(: error TS[0-9]+|[[:space:]]error[[:space:]]|^Error|error\[|ERROR|FAILED)' | tr -d '[:space:]')
WARN_COUNT=$(printf '%s\n' "$OUT" | grep -cE '(: warning|[[:space:]]warning[[:space:]]|WARN)' | tr -d '[:space:]')
case "$ERR_COUNT" in ''|*[!0-9]*) ERR_COUNT=0;; esac
case "$WARN_COUNT" in ''|*[!0-9]*) WARN_COUNT=0;; esac

SUCCESS=false; [ "$CODE" -eq 0 ] && SUCCESS=true

TAIL_JSON="[]"
if [ "$CODE" -ne 0 ]; then
  TAIL_JSON=$(printf '%s\n' "$OUT" | tail -15 | jq -R . | jq -s .)
fi

printf '%s\n' "$ERR_LINES" | jq -R . | jq -s \
  --arg mode "$MODE" --arg cmd "$CMD" \
  --argjson success "$SUCCESS" --argjson code "$CODE" \
  --argjson ec "$ERR_COUNT" --argjson wc "$WARN_COUNT" \
  --argjson tail "$TAIL_JSON" \
  '{mode:$mode, command:$cmd, success:$success, exit_code:$code,
    error_count:$ec, warning_count:$wc,
    errors:(map(select(length>0))), tail:$tail}'
exit 0
