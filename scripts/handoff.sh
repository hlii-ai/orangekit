#!/bin/bash
# scripts/handoff.sh — PreCompact + SessionEnd
#
# Preserves the work state when the context is compacted or the session ends.
#
# v2's pre-compact-saver printed with a plain echo, but PreCompact stdout does not
# enter the context (only the three events SessionStart / UserPromptSubmit /
# UserPromptExpansion turn plain text into context).
# So it preserved nothing for 4 months, and that is why the user had to create
# 7 SESSION-HANDOFF files by hand.
#
# v3 emits additionalContext JSON, and on SessionEnd it also leaves a file.

INPUT=$(cat 2>/dev/null || printf '{}')
# shellcheck source=lib/common.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"
orangekit_begin "handoff" "$INPUT"

cd "$ORANGEKIT_ROOT" 2>/dev/null || exit 0

EVENT=$(orangekit_field "$INPUT" '.hook_event_name'); EVENT="${EVENT:-PreCompact}"

OUT=""
add() { OUT="${OUT}$1"$'\n'; }

# ── git state ─────────────────────────────────────────────────────────
if git rev-parse --git-dir >/dev/null 2>&1; then
  # A repo with 0 commits (right after git init): git log and rev-parse HEAD exit 128 →
  # the pipefail+ERR trap kills the whole hook and **all** of the handoff disappears.
  # The first session of a new project is exactly this state (session-brief already blocked the same trap).
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    HEADL=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-64)
  else
    BRANCH=$(git branch --show-current 2>/dev/null)
    HEADL="none (before the first commit)"
  fi
  add "## Work state preserved"
  add ""
  add "- branch \`${BRANCH:-?}\` · HEAD \`${HEADL:-none}\`"

  # One git status for both the list and the count (it used to run twice)
  ST=$(git status --porcelain 2>/dev/null || true)
  if [ -n "$ST" ]; then
    # Lines counted while reading (= wc -l of the porcelain, which ends every line with a newline); the first 12 are listed
    N=0; LIST=""
    while IFS= read -r l; do N=$((N + 1)); [ "$N" -le 12 ] && LIST+="$l"$'\n'; done <<< "$ST"
    add "- ${N} uncommitted:"
    while IFS= read -r l; do [ -n "$l" ] && add "  - \`${l}\`"; done <<< "${LIST%$'\n'}"
  fi
fi

# ── Open workspaces ───────────────────────────────────────────────────
if [ -d "$ORANGEKIT_ROOT/dev/active" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    NAME=$(basename "$d")
    add ""
    add "### In progress: ${NAME}"
    TF=$({ find "$d" -name '*task*' -type f 2>/dev/null || true; } | head -1)
    if [ -n "$TF" ] && [ -f "$TF" ]; then
      DONE=$(orangekit_num "$(grep -c '^[[:space:]]*- \[x\]' "$TF" 2>/dev/null || true)")
      TODO=$(orangekit_num "$(grep -c '^[[:space:]]*- \[ \]' "$TF" 2>/dev/null || true)")
      add "- progress ${DONE}/$((DONE+TODO))"
      if [ "$TODO" -gt 0 ]; then
        add "- remaining work:"
        # The last stage of a pipe runs in a subshell, so add() would only change a copy of OUT — process substitution keeps the loop in this shell
        while IFS= read -r t; do add "$t"; done < <({ grep '^[[:space:]]*- \[ \]' "$TF" 2>/dev/null || true; } | head -5 | sed 's/^[[:space:]]*- \[ \]/  -/')
      fi
      add "- file: \`${TF#$ORANGEKIT_ROOT/}\`"
    fi
  done < <({ find "$ORANGEKIT_ROOT/dev/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | head -3)
fi

[ -z "$OUT" ] && exit 0
add ""
add "> Refer to the files above and carry on with the work."

# ── On SessionEnd, a file is left as well ─────────────────────────────
if [ "$EVENT" = "SessionEnd" ]; then
  HD="$(orangekit_handoff_dir)"
  if mkdir -p "$HD" 2>/dev/null; then
    TS=$(date -u '+%Y%m%d-%H%M%S')
    printf '%s\n' "$OUT" > "$HD/${TS}.md" 2>/dev/null || true
    # Keep only the 10 most recent (prevents unbounded growth)
    # Rotate only the YYYYMMDD-HHMMSS.md files this hook writes — never delete a note someone placed by hand
    { ls -1t "$HD"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].md 2>/dev/null || true; } | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done
  fi
fi

orangekit_edge "build" "handoff"
orangekit_emit_context "$EVENT" "$OUT"
exit 0
