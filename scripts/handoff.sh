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

  MODIFIED=$({ git status --porcelain 2>/dev/null || true; } | head -12)
  if [ -n "$MODIFIED" ]; then
    N=$(orangekit_num "$(git status --porcelain 2>/dev/null | wc -l)")
    add "- ${N} uncommitted:"
    while IFS= read -r l; do [ -n "$l" ] && add "  - \`${l}\`"; done <<< "$MODIFIED"
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
      DONE=$(orangekit_num "$(grep -c '^\s*- \[x\]' "$TF" 2>/dev/null || true)")
      TODO=$(orangekit_num "$(grep -c '^\s*- \[ \]' "$TF" 2>/dev/null || true)")
      add "- progress ${DONE}/$((DONE+TODO))"
      if [ "$TODO" -gt 0 ]; then
        add "- remaining work:"
        { grep '^\s*- \[ \]' "$TF" 2>/dev/null || true; } | head -5 | sed 's/^\s*- \[ \]/  -/' | while IFS= read -r t; do
          printf '%s\n' "$t"
        done | while IFS= read -r t; do add "$t"; done
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
    { ls -1t "$HD"/*.md 2>/dev/null || true; } | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done
  fi
fi

orangekit_edge "build" "handoff"
orangekit_emit_context "$EVENT" "$OUT"
exit 0
