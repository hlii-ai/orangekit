#!/bin/bash
# scripts/track-skill.sh — PostToolUse (Skill)
#
# Records skill invocations. Without this, "culling unused skills" is forever possible only by
# guesswork — the reason the v2 audit had to treat "the output directory is empty" as evidence of use.
#
# Anti-goal 8: do not cull without measuring.
#
# How it differs from v2's three PostToolUse trackers:
#   - reacts only to a Skill call, not to every tool call
#   - no full /tmp scan (what those hooks did on every single call)
#   - the consumer really exists (doctor --usage)

INPUT=$(cat 2>/dev/null || printf '{}')
# shellcheck source=lib/common.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"

ORANGEKIT_HOOK_NAME="track-skill"
ORANGEKIT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '')}"
[ -z "$ORANGEKIT_ROOT" ] && exit 0

# The heartbeat is **the first action** (the same placement as security-check.sh). Placed after the early exit below,
# "this hook ran" would depend on whether .skill exists, and the liveness metric would report a hook that really ran
# as "never executed". That the hook ran and that there was a skill to record are different things.
orangekit_heartbeat 0

SKILL=$(orangekit_field "$INPUT" '.tool_input.skill')
[ -z "$SKILL" ] && exit 0

DIR="$(orangekit_state_dir)"
mkdir -p "$DIR" 2>/dev/null || exit 0
printf '%s|%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SKILL" >> "$DIR/skilluse.log" 2>/dev/null || true
orangekit_edge "build" "track-skill"   # an edge the graph declares as instrumented:true — with no emission the 'not executed' warning stays forever

# Rotation (prevents unbounded growth)
N=$(orangekit_count_lines "$DIR/skilluse.log")
if [ "$N" -gt 5000 ]; then
  tail -2500 "$DIR/skilluse.log" > "$DIR/skilluse.log.tmp" 2>/dev/null \
    && mv "$DIR/skilluse.log.tmp" "$DIR/skilluse.log" 2>/dev/null || true
fi

exit 0
