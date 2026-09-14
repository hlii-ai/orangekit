#!/bin/bash
# scripts/lib/common.sh — orangekit-product shared hook substrate
#
# Every hook sources this file. The purpose is not convenience but **eliminating silent failure**.
#
# In v2, 8 hooks sat dead for 4 months without emitting a single signal. Three causes:
#   1. The root path was computed relative to BASH_SOURCE → points outside the repo once shipped as a plugin
#   2. The `|| echo 0` fallback put 2 lines where 1 belonged, collapsing integer comparison
#   3. Output used JSON fields the event does not support → silently ignored
#
# This file blocks those three with orangekit_root / orangekit_num / orangekit_emit respectively.

# Already loaded — do not run again
[ -n "${ORANGEKIT_COMMON_LOADED:-}" ] && return 0
ORANGEKIT_COMMON_LOADED=1

set -Eeuo pipefail

# ── ERR trap: a failure is not passed over quietly ────────────────────
# Emits to stderr, but the exit code follows each hook's own policy.
orangekit_on_err() {
  local code=$? line=${1:-?}
  printf '[orangekit:%s] ERROR line %s (exit %s)\n' "${ORANGEKIT_HOOK_NAME:-unknown}" "$line" "$code" >&2
  orangekit_heartbeat "$code"
  exit "$code"
}
trap 'orangekit_on_err $LINENO' ERR

# ── Project root resolution ───────────────────────────────────────────
# Priority: CLAUDE_PROJECT_DIR → stdin .cwd → git toplevel → fail
# **Does not guess.** If it cannot be found, block with exit 2 (anti-goal 1).
#
# Usage: ORANGEKIT_ROOT=$(orangekit_root "$INPUT")
orangekit_root() {
  local input="${1:-}" root=""

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"; return 0
  fi

  if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
    root=$(printf '%s' "$input" | jq -r '.cwd // .workspace_dir // empty' 2>/dev/null || true)
    if [ -n "$root" ] && [ -d "$root" ]; then
      printf '%s' "$root"; return 0
    fi
  fi

  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$root" ] && [ -d "$root" ]; then
    printf '%s' "$root"; return 0
  fi

  printf '[orangekit:%s] FATAL: cannot determine the project root.\n' "${ORANGEKIT_HOOK_NAME:-unknown}" >&2
  printf '  Tried: CLAUDE_PROJECT_DIR → stdin.cwd → git rev-parse --show-toplevel\n' >&2
  printf '  Aborting rather than guessing. (anti-goal 1: no guard that can fail silently)\n' >&2
  exit 2
}

# ── Number normalization ──────────────────────────────────────────────
# macOS `wc -l` prepends whitespace, and when a pipe fails `|| echo 0` appends to the
# existing output, producing multiple lines such as "0\n0". Both break integer comparison.
# Always guarantees a single integer. Empty or unparseable becomes 0.
orangekit_num() {
  local v="${1:-}"
  v=$(printf '%s' "$v" | tr -d '[:space:]' | head -c 18)
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# Counts a file's lines safely (0 if it does not exist)
orangekit_count_lines() {
  [ -f "${1:-}" ] || { printf '0'; return 0; }
  orangekit_num "$(wc -l < "$1" 2>/dev/null || printf '0')"
}

# ── Valid JSON output per event ───────────────────────────────────────
# Claude Code supports different fields for each event. Output carrying an unsupported field is
# silently ignored — the reason v2's stop-guard never blocked even once.
#
#   SessionStart / UserPromptSubmit : plain stdout becomes the context as-is
#   PreCompact / SessionEnd / Stop  : additionalContext (JSON) required
#   Stop                            : decision/reason unsupported. Use continue/systemMessage
#   PreToolUse                      : hookSpecificOutput supported
#
# Usage: orangekit_emit_context <event> "<text>"
orangekit_emit_context() {
  local event="${1:-}" text="${2:-}"
  [ -z "$text" ] && return 0

  case "$event" in
    SessionStart|UserPromptSubmit|UserPromptExpansion)
      # Only these three events take plain stdout as context
      printf '%s\n' "$text"
      ;;
    PreCompact|SessionEnd|Stop|SubagentStop|PostToolUse|PostToolBatch)
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg c "$text" '{additionalContext: $c}'
      else
        printf '{"additionalContext":%s}\n' "$(orangekit_json_escape "$text")"
      fi
      ;;
    PreToolUse)
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg e "$event" --arg c "$text" \
          '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}'
      fi
      ;;
    *)
      printf '[orangekit] unknown event: %s\n' "$event" >&2
      return 1
      ;;
  esac
}

# Stop-family block. Not decision/reason but continue:false + systemMessage.
orangekit_emit_block() {
  local event="${1:-}" reason="${2:-}"
  case "$event" in
    Stop|SubagentStop)
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg r "$reason" '{continue:false, systemMessage:$r}'
      else
        printf '{"continue":false,"systemMessage":%s}\n' "$(orangekit_json_escape "$reason")"
      fi
      ;;
    *)
      printf '[orangekit] the %s event does not support orangekit_emit_block\n' "$event" >&2
      return 1
      ;;
  esac
}

# Stop-family **non-blocking** notice. Shows an undecidable verdict or a note to the user without stopping progress.
# Why it is separate from blocking (orangekit_emit_block): folding an undecidable verdict into a block makes it a false positive,
# and false positives make people turn the hook off, which drops its blocking power to 0.
orangekit_emit_notice() {
  local event="${1:-}" msg="${2:-}"
  [ -z "$msg" ] && return 0
  case "$event" in
    Stop|SubagentStop|PostToolUse|PostToolBatch|PreCompact|SessionEnd)
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg m "$msg" '{systemMessage:$m}'
      else
        printf '{"systemMessage":%s}\n' "$(orangekit_json_escape "$msg")"
      fi
      ;;
    *)
      printf '[orangekit] the %s event does not support orangekit_emit_notice\n' "$event" >&2
      return 1
      ;;
  esac
}

orangekit_json_escape() {
  printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk 'BEGIN{printf "\""} {printf "%s%s", sep, $0; sep="\\n"} END{printf "\""}'
}

# ── Where instrumentation is recorded ─────────────────────────────────
# The default is the project's `.claude/.orangekit`. There is exactly one reason `ORANGEKIT_STATE_DIR`
# can override it: **doctor --self-test must not write into the log it is measuring.**
# Fixture injection sets CLAUDE_PROJECT_DIR to the repo so the hook sees a real project
# (that is what differs from --consumer), and as a side effect the heartbeat and edge records
# got mixed in with real-use records. Then "which path actually executes" is no longer a measurement
# but a self-assertion (evaluation v3 · E-09).
orangekit_state_dir() {
  printf '%s' "${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}"
}

# Where handoff artifacts go. Overridable for the same reason as `orangekit_state_dir` —
# when --self-test injects PreCompact/SessionEnd fixtures, handoff writes into the **real**
# dev/handoff/, and rotation (keep the latest 10) pushed out real restore material.
# Isolating only the state log and missing this one left the repair half-done (evaluation v5 · E-13).
orangekit_handoff_dir() {
  printf '%s' "${ORANGEKIT_HANDOFF_DIR:-${ORANGEKIT_ROOT:-.}/dev/handoff}"
}

# ── Worktree snapshot ─────────────────────────────────────────────────
# session-brief creates it at session start and build-gate compares against it at Stop.
#
# **It must not hold file names alone.** A set of names carries "is it dirty" and fails to carry
# "did it change". So a source file that was already uncommitted at session start dropped out of
# `comm -13` no matter how much it was edited, and the build gate went silent entirely — on the
# most common path of all, resuming earlier work, the gate's blocking power was 0.
#
# Line format: `<path><TAB><mtime><TAB><size>`. A content hash is more accurate but spawns one
# process per file — mtime+size ends in a single `stat` and there is effectively no case of
# "edited but not caught".
#
# **The two hooks do not each compute it.** This bug happened because the generator and the
# comparator were two copies of the same pipeline. With a single copy there is nowhere to diverge.
#
# For a deleted file `stat` fails — put `-` in place of an empty value to **keep the line.**
# Skipping it makes a "deleted then restored" case look unchanged.
orangekit_worktree_snapshot() {
  local f st
  git status --porcelain 2>/dev/null | sed -E 's/^.{3}//; s/^.* -> //' | sort -u   | while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -e "$f" ]; then
        st=$(stat -f '%m	%z' "$f" 2>/dev/null || stat -c '%Y	%s' "$f" 2>/dev/null || printf -- '-	-')
      else
        st=$(printf -- '-	-')
      fi
      printf '%s	%s
' "$f" "$st"
    done
}

# Extracts only the path from a snapshot line (before the TAB). Safe even if the path contains spaces.
orangekit_snapshot_paths() { cut -f1; }

# ── Heartbeat ─────────────────────────────────────────────────────────
# Every hook records its own execution as its first action. Another component (session-brief)
# reads this log and reports dead hooks. A component does not vouch for itself (P1).
orangekit_heartbeat() {
  local code="${1:-0}" dir
  [ -z "${ORANGEKIT_ROOT:-}" ] && return 0
  dir="$(orangekit_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s|%s|%s|%s\n' \
    "${ORANGEKIT_HOOK_NAME:-unknown}" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${ORANGEKIT_ROOT}" \
    "$code" >> "$dir/hookrun.log" 2>/dev/null || true

  # Rotation: above 2000 lines, keep the most recent 1000 (prevents unbounded growth).
  #
  # **Invariant: rotation never erases any component's last piece of evidence.**
  # A plain tail makes this log lie — security-check fires on Edit/Write/MultiEdit/Bash alike,
  # takes 97% of the lines, and pushes every other hook's history out of the window. Then
  # session-brief **reports a hook that really ran as "never executed"** (track-skill measured:
  # 7 lines remained in skilluse.log while they had evaporated from hookrun.log). What the metric measured
  # was not "has it ever run" but "did it run recently enough to survive rotation".
  #
  # Only the names being pushed out of the window are picked, and their single last line is kept along with them. Global dedup is not used
  # because the same hook running twice in the same second is normal, and erasing that would distort the line
  # count. The cost falls only at rotation time (once every 2000 lines); the cost per hook call is 0.
  local n; n=$(orangekit_count_lines "$dir/hookrun.log")
  if [ "$n" -gt 2000 ]; then
    awk -F'|' -v keep=1000 '
      # Only rows with NF>=4 and a non-empty name count as carry candidates — this stops a corrupted row from a partial write
      # from being carried forever as the last evidence at every rotation (a normal writer writes 4 fields).
      # Note: this awk program sits inside shell single quotes. Do not use a single quote in the comments either.
      { rows[NR] = $0; if (NF >= 4 && $1 != "") last[$1] = NR }
      END {
        start = NR - keep + 1; if (start < 1) start = 1
        for (k in last) if (last[k] < start) print rows[last[k]]
        for (i = start; i <= NR; i++) print rows[i]
      }
    ' "$dir/hookrun.log" > "$dir/hookrun.log.tmp" 2>/dev/null \
      && mv "$dir/hookrun.log.tmp" "$dir/hookrun.log" 2>/dev/null || true
  fi
}

# ── Graph edge instrumentation ────────────────────────────────────────
# Makes which path actually executes measurable (Graph Engineering G2).
orangekit_edge() {
  local from="${1:-}" to="${2:-}" dir
  [ -z "${ORANGEKIT_ROOT:-}" ] && return 0
  dir="$(orangekit_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s|%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$from" "$to" \
    >> "$dir/graph.log" 2>/dev/null || true
  # Rotation — only this log had no ceiling (evaluation v6 · E-28). It is the heaviest writer (security-check emits on every
  # tool call) yet its two sibling logs rotated and this one alone accumulated without bound. An append carries a ceiling with it
  # (code-change "when you write code that appends, put the rotation/ceiling in with it" — the harness is no exception).
  local n; n=$(orangekit_num "$(wc -l < "$dir/graph.log" 2>/dev/null)")
  if [ "$n" -gt 5000 ]; then
    tail -2500 "$dir/graph.log" > "$dir/graph.log.tmp" 2>/dev/null \
      && mv "$dir/graph.log.tmp" "$dir/graph.log" 2>/dev/null || rm -f "$dir/graph.log.tmp"
  fi
}

# ── Hook initialization ───────────────────────────────────────────────
# Usage:
#   INPUT=$(cat 2>/dev/null || echo '{}')
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#   orangekit_begin "session-brief" "$INPUT"
orangekit_begin() {
  ORANGEKIT_HOOK_NAME="${1:-unknown}"
  local input="${2:-}"
  ORANGEKIT_ROOT=$(orangekit_root "$input")
  export ORANGEKIT_HOOK_NAME ORANGEKIT_ROOT
  orangekit_heartbeat 0
}

# Extract a field from stdin JSON (empty string if jq is absent)
orangekit_field() {
  local input="${1:-}" path="${2:-}"
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$input" | jq -r "$path // empty" 2>/dev/null || printf ''
}
