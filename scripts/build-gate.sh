#!/bin/bash
# scripts/build-gate.sh — Stop
#
# Blocks an attempt to finish after editing source code without running the build/tests.
#
# There were two reasons v2's stop-guard never blocked even once:
#   1. It emitted {"decision":"block","reason":...} — the Stop event does not support that field.
#      The only supported fields are additionalContext / continue / systemMessage.
#   2. `tail -200 transcript | grep -qE "(build|test)"` — the word "test" appearing
#      anywhere in the conversation was enough to pass.
#
# v3 (1) emits continue:false + systemMessage and
#     (2) parses the transcript JSONL and looks only at actual Bash tool calls.

INPUT=$(cat 2>/dev/null || printf '{}')
# shellcheck source=lib/common.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"
orangekit_begin "build-gate" "$INPUT"

cd "$ORANGEKIT_ROOT" 2>/dev/null || exit 0
orangekit_edge "build" "build-gate"   # automatic at Stop — records the traversal fact regardless of the verdict

# Infinite-loop prevention: if we are already continuing because of this hook, do not block again
STOP_ACTIVE=$(orangekit_field "$INPUT" '.stop_hook_active')
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(orangekit_field "$INPUT" '.transcript_path')

# ── 1. Were any source files changed in this session? ─────────────────
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# A snapshot line is `path<TAB>mtime<TAB>size` (common.sh · orangekit_worktree_snapshot).
# Comparing names alone drops **a source file that was already uncommitted at session start**
# out of the difference no matter how much it changed — the gate went silent on the most common path of all, resuming work.
BASELINE="$(orangekit_state_dir)/session-baseline.txt"
CURRENT=$(orangekit_worktree_snapshot)

if [ -f "$BASELINE" ]; then
  # The difference is taken on snapshot **lines**, then only the paths are extracted: newly dirtied files and
  # files that were already dirty but changed again this time both remain.
  CHANGED=$(comm -13 <(sort "$BASELINE") <(printf '%s\n' "$CURRENT" | sort) 2>/dev/null \
            | orangekit_snapshot_paths | sort -u)
else
  CHANGED=$(printf '%s\n' "$CURRENT" | orangekit_snapshot_paths | sort -u)
fi

# Source extensions only (config, docs and markdown excluded)
SRC_CHANGED=$(printf '%s\n' "$CHANGED" | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|swift|rb|php|vue|svelte)$' \
  | grep -vE '\.(config|test|spec)\.' | grep -vE '^\s*$' || true)

[ -z "$SRC_CHANGED" ] && exit 0

SRC_COUNT=$(orangekit_num "$(printf '%s\n' "$SRC_CHANGED" | grep -c . || printf '0')")
[ "$SRC_COUNT" -eq 0 ] && exit 0

# ── 2. Did the build/tests actually run? ──────────────────────────────
# Extracts only the command of Bash tool calls from the transcript JSONL and judges on that.
#
# **The verdict has three states. "Undecidable" must not be folded into "did not run".**
# jq is not in a default macOS install. Folding it would block every session that did run the build,
# and then the user turns the hook off and its blocking power becomes 0 (the principle security-check.sh wrote down).
# Same discipline as guide-freshness.sh --offline: an undecided verdict is reported explicitly, never asserted.
UNDECIDABLE=""
if ! command -v jq >/dev/null 2>&1; then
  UNDECIDABLE="jq not installed"
elif [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
  UNDECIDABLE="transcript cannot be read"
fi

if [ -n "$UNDECIDABLE" ]; then
  orangekit_emit_notice "Stop" "$(printf '%s source files changed, but whether the build/tests ran **cannot be determined** (%s).\n\nNot blocking — check it yourself. Installing jq makes this gate work again.' \
    "$SRC_COUNT" "$UNDECIDABLE")" 2>/dev/null || true
  exit 0
fi

# Recognition works on **the first token of a segment** — the same discipline as security-check's exemptions.
# The old one-line regex was wrong in both directions (evaluation v9 · E-60): it counted `echo npm run build` and `grep 'pnpm build'`
# as runs (v2 stop-guard's failure had survived, merely narrowed), while it failed to recognize the very
# `pytest` (bare command) the fastapi preset prescribes, plus `python -m pytest` · `tsc --noEmit` · `jest`, and so **blocked a session
# that had run its own prescription.** A false-positive block makes the user turn the hook off, and a hook that is off blocks nothing.
#
# Three categories: ① the verifier is itself the command (pytest · jest · tsc · make …) ② verification vocabulary follows
# a runner (npm run build · python -m pytest · npx tsc · uv run pytest …) ③ a subcommand of a language tool
# (cargo test · go vet …). A segment carrying install vocabulary (install, add) is excluded from ② —
# `python -m pip install pytest` is not verification. Known limit: if a line of a heredoc **body** in a file
# starts with a verifier name it is counted as a run — the inherent boundary of judging from command text alone.
_verification_ran() {
  jq -r 'select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use" and .name=="Bash") | .input.command // empty' \
     "$TRANSCRIPT" 2>/dev/null \
  | awk '
    function head(s) {
      sub(/^[ \t]+/, "", s)
      while (match(s, /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/)) s = substr(s, RLENGTH + 1)
      while (match(s, /^(time|env|nice|sudo|command)[ \t]+/)) s = substr(s, RLENGTH + 1)
      if (match(s, /^timeout[ \t]+[0-9]+[a-z]?[ \t]+/)) s = substr(s, RLENGTH + 1)
      if (match(s, /^(bash|sh|zsh)[ \t]+-c[ \t]+["\047]?/)) s = substr(s, RLENGTH + 1)
      return s
    }
    { n = split($0, seg, /;|&&|\|\|/)
      for (i = 1; i <= n; i++) {
        s = head(seg[i]); split(s, w, /[ \t]+/); t = w[1]; sub(/.*\//, "", t)
        if (t ~ /^(pytest|jest|vitest|mocha|tsc|vue-tsc|ruff|mypy|pyright|eslint|biome|tox|nox|gradlew|gradle|mvnw|mvn|make)$/) { found = 1; exit }
        if (s ~ /(^|[ \t])(install|add|i)([ \t]|$)/) continue
        if (t ~ /^(pnpm|npm|yarn|bun|npx|bunx|uv|poetry|pipx|python|python3|py|deno)$/ \
            && s ~ /[ \t][a-z:_-]*(build|test|typecheck|check|lint|pytest|unittest|jest|vitest|mocha|tsc|ruff|mypy|clippy)[a-z:_-]*([ \t"\047]|$)/) { found = 1; exit }
        if (t ~ /^(cargo|go|dotnet|swift)$/ && s ~ /^[a-z0-9.\/-]+[ \t]+(build|test|check|clippy|vet)([ \t]|$)/) { found = 1; exit }
      } }
    END { exit found ? 0 : 1 }'
}
BUILD_RAN=0
_verification_ran && BUILD_RAN=1

# ── 2-a. A UI file is not finished when the build passes (notice, not a block) ───
# tsc passes a blank screen and a screen whose console explodes alike. So this **notifies** here.
# Why it does not block: false positives arise in environments with no headless browser and on component edits that need no server,
# and repeated false positives make the user turn the hook off (the principle in security-check.sh).
_ui_render_notice() {
  local ui_changed ui_count stamp
  ui_changed=$(printf '%s\n' "$SRC_CHANGED" | grep -E '\.(tsx|jsx|vue|svelte)$' || true)
  [ -z "$ui_changed" ] && return 0
  ui_count=$(orangekit_num "$(printf '%s\n' "$ui_changed" | grep -c . || printf '0')")
  [ "$ui_count" -eq 0 ] && return 0

  stamp="$(orangekit_state_dir)/ui-notice.stamp"
  [ -f "$stamp" ] && return 0   # once per session (session-brief clears it each session)

  # A trace that the render was checked — a probe or browser-automation Bash call, or a built-in /run skill call.
  # Not the presence of a string but **an actual tool call** (the lesson of v2's stop-guard).
  if jq -r 'select(.type=="assistant") | .message.content[]?
            | select(.type=="tool_use")
            | if .name=="Bash" then (.input.command // empty)
              elif .name=="Skill" then (.input.skill // empty)
              else empty end' "$TRANSCRIPT" 2>/dev/null \
     | grep -qiE '(ui-probe|playwright|puppeteer|chromium|(^|:)run$)'; then
    return 0
  fi

  : > "$stamp" 2>/dev/null || true
  orangekit_emit_notice "Stop" "$(printf '%s UI files changed this session and the build passed, but **there is no trace that the render was checked.**\n\n%s\n\nBring it up with the built-in `/run`, then point the `ui-ux-design` skill ui-probe at that URL.\nA passing typecheck is not evidence that a screen appears — this does not block, so skip it if you do not need it.' \
    "$ui_count" "$(printf '%s\n' "$ui_changed" | head -3 | sed 's/^/  - /')")" 2>/dev/null || true
  return 0
}

if [ "$BUILD_RAN" -eq 1 ]; then
  _ui_render_notice
  exit 0
fi

# ── 3. Block ──────────────────────────────────────────────────────────
# Reads the real commands out of config and gives specific guidance
CFG="${ORANGEKIT_CONFIG_PATH:-$ORANGEKIT_ROOT/orangekit.config.json}"
BUILD_CMD=""; TEST_CMD=""
if [ -f "$CFG" ] && command -v jq >/dev/null 2>&1; then
  BUILD_CMD=$(jq -r '.techStack.commands.build // empty' "$CFG" 2>/dev/null || printf '')
  TEST_CMD=$(jq -r '.techStack.commands.test // empty' "$CFG" 2>/dev/null || printf '')
fi
HINT="build and test"
[ -n "$BUILD_CMD" ] && HINT="$BUILD_CMD"
[ -n "$BUILD_CMD" ] && [ -n "$TEST_CMD" ] && HINT="$BUILD_CMD && $TEST_CMD"

FILES=$(printf '%s\n' "$SRC_CHANGED" | head -5 | sed 's/^/  - /')
MORE=""
[ "$SRC_COUNT" -gt 5 ] && MORE=$(printf '\n  ... and %s more' "$((SRC_COUNT-5))")

orangekit_edge "build-gate" "build"   # block → re-enter build
orangekit_emit_block "Stop" "$(printf '%s source files changed this session but the build/tests were not run.\n\n%s%s\n\nRun: %s\n\n(written ≠ working — verification is part of the same action)' \
  "$SRC_COUNT" "$FILES" "$MORE" "$HINT")"
exit 0
