#!/bin/bash
# scripts/session-brief.sh — SessionStart
#
# It does two things:
#   1. Prints the T0 operating contract (plugin-owned → updated automatically, the project cannot change it)
#   2. Session brief — HEAD, uncommitted files, open workspaces, **hook liveness**
#
# Replaces v2's session-start-validator. That hook computed the root wrongly, so integer comparison
# broke and it ended at exit 0, and its only surviving output was a recommendation for
# /harness-evaluation, which the user had forbidden.
#
# SessionStart is one of the three events where plain stdout becomes the context as-is.

# Private detached entry point: the supervisor reaps both jobs. Each job owns a process group;
# disable job control inside it so jq/sleep stay in that group. A stalled build and all its
# children are killed after 20 s (below SessionStart's 30 s timeout), then its private file is removed.
# No hook pipes survive: the caller redirects all three descriptors before starting nohup.
if [ "${1:-}" = --warm-transcript ]; then
  set -m
  (
    set +m
    _OK_PY_LAZY=1
    source "$2/scripts/lib/common.sh"
    CLAUDE_PROJECT_DIR=$3 ORANGEKIT_STATE_DIR=$4
    ORANGEKIT_ROOT=$(orangekit_root '')
    orangekit_transcript_index "$5" "$6" || exit 0
  ) &
  warm_pid=$!
  # Windows: a native launcher (Chocolatey's jq.exe shim) starts the real jq.exe outside the MSYS process group, where the group
  # kill cannot reach it (CI run 9: one busy jq.exe survived). So each other member of the worker's group has its Windows tree
  # ended first. Not the worker itself: an MSYS exec leaves no Windows parent behind, so its tree does not reach jq, and once it
  # is gone the supervisor cancels this timer before the group kill (CI run 10). Only with taskkill and a member's Windows pid;
  # a failure is ignored and the group kill runs either way
  ( set +m; sleep 20
    case "${OSTYPE:-}" in msys*|cygwin*)
      if command -v taskkill >/dev/null 2>&1; then
        for d in /proc/[0-9]*; do
          [ "${d##*/}" != "$warm_pid" ] && read -r g 2>/dev/null < "$d/pgid" && [ "$g" = "$warm_pid" ] \
            && read -r w 2>/dev/null < "$d/winpid" && [ -n "$w" ] \
            && { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill /F /T /PID "$w" >/dev/null 2>&1 || true; }
        done
      fi ;;
    esac
    kill -KILL -- "-$warm_pid" 2>/dev/null || true ) &
  warm_timer=$!
  wait "$warm_pid" 2>/dev/null || true
  kill -KILL -- "-$warm_timer" 2>/dev/null || true
  wait "$warm_timer" 2>/dev/null || true
  warm_sid=${6//[^A-Za-z0-9._-]/}
  rm -f "$4/transcript-index.${warm_sid:-nosession}.$$" 2>/dev/null
  exit 0
fi

INPUT=$(cat 2>/dev/null || printf '{}')
# shellcheck source=lib/common.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"
orangekit_begin "session-brief" "$INPUT"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Warm resumed transcripts without delaying the briefing. The normal index writer keeps its
# atomic temp+rename protocol; a racing gate reads a complete cache or builds its own copy.
orangekit_fields "$INPUT" WARM_TRANSCRIPT '.transcript_path' WARM_SESSION '.session_id'
orangekit_slashes_v WARM_TRANSCRIPT "$WARM_TRANSCRIPT"
if [ -r "$WARM_TRANSCRIPT" ] && command -v jq >/dev/null 2>&1 && command -v nohup >/dev/null 2>&1; then
  set -m   # the supervisor must also survive cancellation of the hook's process group
  nohup bash "$PLUGIN_ROOT/scripts/session-brief.sh" --warm-transcript "$PLUGIN_ROOT" "$ORANGEKIT_ROOT" \
    "$(orangekit_state_dir)" "$WARM_TRANSCRIPT" "$WARM_SESSION" </dev/null >/dev/null 2>&1 &
  set +m
fi

# ── 1. T0 operating contract ──────────────────────────────────────────
# The project decides the response language — T0's {{RESPONSE_LANGUAGE}} is substituted here.
# This is where putting T0 in hook output earns its keep: as a file the language would be fixed,
# but as output a different value per project is injected every session.
#
# **Never emit an empty value.** If the placeholder survives, `{{RESPONSE_LANGUAGE}}` leaks into
# the context every session as-is, and the model reads it as a language name.
orangekit_response_language() {
  local cfg="$ORANGEKIT_ROOT/orangekit.config.json" code="" label="" blk=""

  if [ -f "$cfg" ]; then
    if command -v jq >/dev/null 2>&1; then
      code=$(jq -r '.project.language // empty' "$cfg" 2>/dev/null || true)
      label=$(jq -r '.project.languageLabel // empty' "$cfg" 2>/dev/null || true)
    else
      # This file has four "language" keys — project · techStack · frontend · backend.
      # A naive grep -m1 picks the stack language (TypeScript) as the response language depending on key order.
      # Search only after narrowing the range to the project block.
      blk=$({ sed -n '/"project"[[:space:]]*:/,/^[[:space:]]*}/p' "$cfg" 2>/dev/null || true; })
      code=$({ grep <<<"$blk" -m1 -oE '"language"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null || true; } \
              | sed -E 's/.*"([^"]*)"$/\1/')
      label=$({ grep <<<"$blk" -m1 -oE '"languageLabel"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null || true; } \
              | sed -E 's/.*"([^"]*)"$/\1/')
    fi
  fi

  # "Other" is free input, and this value goes straight into a sed substitution expression and into a T0 line.
  # **It is discarded whole, not truncated or filtered** — the debris of filtering (`s/x/y/` fragments) and
  # a multibyte character cut on a byte boundary make the T0 sentence unreadable. A value outside the normal
  # range is not a language name, so falling through to the next candidate is always better.
  orangekit_safe_label() {
    local v="${1:-}" clean=""
    [ -z "$v" ] && { printf ''; return 0; }
    [ "${#v}" -gt 60 ] && { printf ''; return 0; }
    clean=$(printf '%s' "$v" | tr -d '|&/\\$`<>{}"'"'"'[:cntrl:]' 2>/dev/null || true)
    [ "$clean" = "$v" ] && printf '%s' "$v" || printf ''
  }

  label=$(orangekit_safe_label "${label:-}")
  code=$(orangekit_safe_label "${code:-}")

  # Label priority: languageLabel → endonym of a known code → raw code → default
  if [ -z "$label" ]; then
    case "$code" in
      ko) label="한국어" ;;
      en) label="English" ;;
      id) label="Bahasa Indonesia" ;;
      vi) label="Tiếng Việt" ;;
      ja) label="日本語" ;;
      zh) label="中文" ;;
      # Other — when init left only the code. Accepted only when it has the shape of a language tag
      [A-Za-z][A-Za-z]|[A-Za-z][A-Za-z][A-Za-z]|[A-Za-z][A-Za-z]-[A-Za-z0-9]*) label="$code" ;;
      *) label="" ;;
    esac
  fi

  # Default for an unconfigured project. Right after installation there is no way to know which language
  # the user speaks, so follow the language the user writes in — pinning Korean blocks foreign users until init.
  [ -z "$label" ] && label="the language the user writes in"
  printf '%s' "$label"
}

CONTRACT="$PLUGIN_ROOT/templates/operating-contract.md"
if [ -f "$CONTRACT" ]; then
  RESP_LANG=$(orangekit_response_language)
  # Removes whole HTML comment blocks (deleting only '^<!--' leaks the body of a multi-line comment)
  sed '/<!--/,/-->/d' "$CONTRACT" | sed '/./,$!d' \
    | sed "s|{{RESPONSE_LANGUAGE}}|${RESP_LANG}|g"
else
  printf '[orangekit] warning: operating contract file missing (%s)\n' "$CONTRACT"
fi

# ── 2. Session brief ──────────────────────────────────────────────────
printf '\n## Session brief\n\n'

cd "$ORANGEKIT_ROOT" 2>/dev/null || true

if git rev-parse --git-dir >/dev/null 2>&1; then
  # A repo with 0 commits (just after init): git log/rev-parse HEAD exits 128 → the pipefail+ERR trap
  # kills the whole hook and the brief is lost entirely. Check that HEAD exists first.
  if git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    HEAD_LINE=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-72)
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  else
    HEAD_LINE="none (before the first commit)"
    BRANCH=$(git branch --show-current 2>/dev/null)
  fi
  DIRTY=$(orangekit_num "$(git status --porcelain 2>/dev/null | wc -l)")
  printf -- '- branch `%s` · HEAD `%s`\n' "${BRANCH:-?}" "${HEAD_LINE:-none}"
  if [ "$DIRTY" -gt 0 ]; then
    printf -- '- %s uncommitted files\n' "$DIRTY"
  fi
  # Snapshot at session start — the baseline build-gate uses to tell "what changed this session".
  # The format (path+mtime+size) and the computation are held solely by common.sh's orangekit_worktree_snapshot —
  # rewriting the pipeline here would diverge from the copy on the build-gate side.
  mkdir -p "$(orangekit_state_dir)" 2>/dev/null || true
  orangekit_worktree_snapshot > "$(orangekit_state_dir)/session-baseline.txt" 2>/dev/null || true
  # build-gate's UI render notice fires once per session. The marker is opened here —
  # a warning that never turns off teaches people to ignore it.
  rm -f "$(orangekit_state_dir)/ui-notice.stamp" 2>/dev/null || true
fi

# Linux procps pkill/pgrep do not leave their own ancestor shells out, so `pkill -f PAT` also kills the shell running the command.
# Put the bin/ wrappers (which leave ancestors out) at the **front** of this session's Bash PATH — the plugin bin/ is appended at
# the end of PATH and hidden by the originals (measured), so prepend it through CLAUDE_ENV_FILE. Not procps (macOS · BSD) → leave it alone.
# With the marker present, security-check stops guessing self-kill from the command text — the cause is gone.
# The marker is **per session** and holds the wrapper directory: one marker per project would let a parallel session that could not
# install the wrappers switch the check off too, and a plugin update mid-session that deletes the old cache (the wrappers) would leave
# only the marker behind — security-check re-checks the wrappers in that directory
PS_SID=$(orangekit_field "$INPUT" '.session_id' | tr -cd 'A-Za-z0-9._-')
PS_DIR="$(orangekit_state_dir)/proc-shim"
mkdir -p "$PS_DIR" 2>/dev/null || true
find "$PS_DIR" -type f -mtime +7 -delete 2>/dev/null || true
[ -n "$PS_SID" ] && rm -f "$PS_DIR/$PS_SID" 2>/dev/null || true
PK_VER=$(pkill --version 2>&1 || true)   # macOS/BSD exit 2 on --version — caught inside so the ERR trap is not touched
case "$PK_VER" in *procps*)
  if [ -n "$PS_SID" ] && [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -x "$PLUGIN_ROOT/bin/pkill" ] && [ -x "$PLUGIN_ROOT/bin/pgrep" ]; then
    printf 'export PATH="%s/bin:$PATH"\n' "$PLUGIN_ROOT" >> "$CLAUDE_ENV_FILE" 2>/dev/null \
      && printf '%s\n' "$PLUGIN_ROOT/bin" > "$PS_DIR/$PS_SID"
  fi ;;
esac

# Open workspaces
if [ -d "$ORANGEKIT_ROOT/dev/active" ]; then
  OPEN=$({ find "$ORANGEKIT_ROOT/dev/active" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true; } | head -5)
  if [ -n "$OPEN" ]; then
    printf -- '- open work: '
    printf '%s\n' "$OPEN" | while IFS= read -r d; do printf '`%s` ' "$(basename "$d")"; done   # without a trailing newline, read drops the last workspace
    printf '\n'
    # The next slice's "Read first" — after a new session or a compaction, the cards read earlier are not in this session. An instruction to read them at the start of a slice
    # did not make anyone read them again (benchmark B5: stage 4, a new session, had a bundle and still 5 send-backs). The briefing puts that line in front of the first write
    printf '%s\n' "$OPEN" | while IFS= read -r d; do
      tf="$d/tasks.md"; [ -f "$tf" ] || continue
      awk -v ws="$(basename "$d")" '
        /^### / { if (pending) exit; head = $0; sub(/^### +/, "", head); rf = ""; pending = 0; done = ($0 ~ /✅/); next }
        head != "" && !done && /^- (먼저 읽을 것|Read first):/ { rf = $0; sub(/^- (먼저 읽을 것|Read first):[ \t]*/, "", rf) }
        head != "" && !done && /^- \[ \]/ { pending = 1 }
        END { if (pending && rf != "") printf "- next slice `%s` (%s) — read first, before the first write: %s\n", head, ws, rf }' "$tf" 2>/dev/null || true
    done
  fi
fi

# ── 3. Hook liveness (P1: a component does not vouch for itself) ──────
HB="$(orangekit_state_dir)/hookrun.log"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
if [ -f "$HOOKS_JSON" ] && command -v jq >/dev/null 2>&1; then
  # The denominator is **the number of unique scripts**. The number of declaration entries must not be used — handoff.sh alone
  # is attached to two events, PreCompact and SessionEnd, which makes it structurally impossible for the numerator
  # (distinct script names in the log) to reach the denominator. It would become a warning that never turns off,
  # showing a shortfall every session, and teach people to ignore it (evaluation v5 · E-14).
  #
  # **The warning's denominator is narrower still — only hooks with no `matcher`.** That applies the same E-14 logic
  # one step further: a hook with a matcher has no chance to fire at all unless that tool is used.
  #   no matcher  → SessionStart · Stop · SessionEnd · PreCompact = fires unconditionally every session
  #   has matcher → PreToolUse(Edit|Write|Bash) · PostToolUse(Skill) = depends on user behavior
  # A user who never invokes a skill never runs track-skill.sh and stays at 4/5.
  # With the full count as the denominator, that user gets **a permanent warning with no way to fix it**.
  # doctor --usage's "live hooks N/M" uses the full count but is instrumentation that does not warn, so it stays as it is.
  EXPECTED=$(orangekit_num "$(jq -r '[.hooks|to_entries[].value[]?.hooks[]?.command
                  | capture("(?<f>[a-z0-9-]+)\\.sh").f] | unique | length' "$HOOKS_JSON" 2>/dev/null)")
  UNCOND=$({ jq -r '[.hooks|to_entries[].value[]? | select((.matcher // "") == "")
                  | .hooks[]?.command | capture("(?<f>[a-z0-9-]+)\\.sh").f] | unique | .[]' \
                  "$HOOKS_JSON" 2>/dev/null || true; })
  UN=$(orangekit_num "$(grep <<<"$UNCOND" -c . || true)")

  # **The number of unique hook names** left in the log. There is no time filter — the "within the last 7 days"
  # that used to be here was a condition not present in the code. The meaning is what the message says, "has it ever run",
  # and for that to hold, rotation must not erase a name's last evidence (the invariant of common.sh orangekit_heartbeat).
  #
  # There is no `[ -f "$HB" ]` branch — orangekit_begin on line 17 of this file creates the log before the
  # verdict, so "absent" was unreachable. The first session is judged **not by file absence but by
  # session-brief's own record count** (this session's is already in there).
  SEEN=$(orangekit_num "$(awk -F'|' '{print $1}' "$HB" 2>/dev/null | sort -u | wc -l)")
  SESSIONS=$(orangekit_num "$(awk -F'|' '$1=="session-brief"' "$HB" 2>/dev/null | wc -l)")
  FAILED=$(orangekit_recent_failures "$HB" | tail -5)

  # Unconditional hooks missing from the log
  UMISS=""
  for h in $UNCOND; do
    awk -F'|' -v n="$h" '$1==n {found=1} END{exit !found}' "$HB" 2>/dev/null || UMISS="$UMISS $h"
  done

  if [ "$SESSIONS" -le 1 ]; then
    # First session. No hook other than SessionStart had a chance to run — a warning here would make
    # "broken" the first thing a new user sees, and that is a false positive.
    printf -- '- first session — hook liveness is judged from the next session on (only SessionStart can fire now)\n'
  elif [ -n "$UMISS" ]; then
    printf -- '- ⚠️ hook liveness %s/%s — a hook that must fire every session has never run:%s. Check with `bash "%s/scripts/doctor.sh" --self-test`\n' \
      "$((UN - $(printf '%s\n' $UMISS | grep -c . || true)))" "$UN" "$UMISS" "$PLUGIN_ROOT"
    orangekit_edge "session-start" "doctor"
  elif [ "$SEEN" -lt "$EXPECTED" ]; then
    # Every unconditional hook is alive and only conditional ones have not fired — that is normal. No warning.
    printf -- '- hooks %s/%s OK (%s conditional ones fire when that tool is used)\n' "$UN" "$UN" "$((EXPECTED - SEEN))"
  else
    printf -- '- hooks %s/%s OK\n' "$SEEN" "$EXPECTED"
  fi
  if [ -n "$FAILED" ]; then
    printf -- '- ⚠️ orangekit hook errors since the last session (most recent %s):\n' "$(printf '%s\n' "$FAILED" | grep -c .)"
    printf '%s\n' "$FAILED" | sed 's/^/    - /'
    # Draft the report now, the way Claude Code drafts its own; it is reviewed and sent only on the user's word.
    # One draft per distinct error — one already drafted, sent or dismissed is not drafted again
    FD="$(orangekit_state_dir)/feedback-drafts"; FIRST=""
    mkdir -p "$FD" 2>/dev/null || true
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      sig=$(printf '%s' "$e" | cksum | cut -d' ' -f1)
      { [ -e "$FD/$sig.md" ] || [ -e "$FD/sent/$sig.md" ] || [ -e "$FD/dismissed/$sig.md" ]; } && continue
      printf '# orangekit hook error: %s\n\n**Kind:** bug (hook error, drafted at session start)\n\n### What happened\n%s\n\n### Expected\nThe hook exits 0.\n' \
        "$(printf '%s' "$e" | cut -c1-72)" "$e" > "$FD/$sig.md" 2>/dev/null && [ -z "$FIRST" ] && FIRST="$e"
    done <<< "$FAILED"
    ND=$(orangekit_num "$({ ls "$FD"/*.md 2>/dev/null || true; } | wc -l)")
    if [ "$ND" -gt 0 ]; then
      printf -- '- ✱ Bug report drafted: %s\n' "${FIRST:-$(sed -n '1s/^# //p' "$({ ls -t "$FD"/*.md 2>/dev/null || true; } | sed -n 1p)" 2>/dev/null)}"
      printf -- '    %s to review in .claude/.orangekit/feedback-drafts/ — offer it ONCE with AskUserQuestion ("Review & send" / "Not now"), never as a question at the end of a message. "Review & send" runs /orangekit-feedback: duplicate search, the full body, then File it / Edit / Dismiss\n' "$ND"
      orangekit_edge "session-start" "orangekit-feedback"
    fi
  fi
fi

# jq absent — functionality quietly degrades. The build gate falls to undecidable (does not block) and
# doctor --graph skips its verification. The user has to know that to decide whether to install it.
if ! command -v jq >/dev/null 2>&1; then
  printf -- '- ⚠️ `jq` not installed — the build gate is in an undecidable state and `doctor --graph` is skipped (`brew install jq`)\n'
fi

# ── 3.3 Plugin updates reaching the project — but the project pins the stack premise ───
# A project stacks code on the stack premise it started from. If the plugin pack has moved to next@16 patterns
# while this project is on 15, the update is not merely old, it is **wrong for this project**.
# Raising the version is the project's decision, taken when it raises its dependencies.
#
# So what is pinned is the "stack premise", not the "correctness of the guidance":
#   same pkgs major + pack version raised → a fix within the same premise (defect · security) → announce it
#   different pkgs major                  → the premise has moved → silence. The project decides
# Grounds: a prebuilt guide carried a privilege-escalation vulnerability for months. That was not a version
# problem but a defect, and it must reach the projects using that same stack.
PLUG_VER=$({ grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)

orangekit_majors() {  # stdin: "pkgs=a@1 b@2 ..." → sorted "a@1 b@2"
  # On no match (empty input included) grep exits 1 — pipefail plus the ERR trap kills the whole hook.
  # A guide with only resources assembled (no SKILL.md) is a normal intermediate state, and exactly then
  # the input is empty, so every later notice (unfinished work, rule cards) vanished. The || true guard is required.
  { grep -oE '[@A-Za-z0-9._/-]+@[0-9]+' 2>/dev/null || true; } | sort -u | tr '\n' ' '
}

if [ -n "${PLUG_VER:-}" ]; then
  FIXES=""; PINNED=""; CPIN=""
  for AJ in "$ORANGEKIT_ROOT"/.claude/skills/*/assembly.json; do
    [ -f "$AJ" ] || continue
    GD=$(dirname "$AJ"); GN=$(basename "$GD")
    PKV=$({ grep -m1 -oE '"packVersion"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$AJ" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    PACK=$({ grep -m1 -oE '"pack"[[:space:]]*:[[:space:]]*"[^"]+"' "$AJ" 2>/dev/null || true; } | sed -E 's/.*"([^"]+)"$/\1/')
    PJ="$PLUGIN_ROOT/guides/$PACK/pack.json"
    [ -f "$PJ" ] || continue
    # Compare the installed pack version with **the same pack's current packVersion** — compared with the plugin version
    # the numbering schemes differ, so it always differed and "there are guide fixes" showed every session for guides with nothing to fix
    CUR=$({ grep -m1 -oE '"packVersion"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$PJ" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -n "${PKV:-}" ] && [ "$PKV" = "${CUR:-}" ] && continue
    [ -n "${PKV:-}" ] && [ -n "${CUR:-}" ] && orangekit_ver_gt "$PKV" "$CUR" && continue   # newer than the plugin — kept, not a fix to apply
    # Wire contract move — install-guide.sh does not update this installed copy (contract pinning). Without the same
    # verdict here, it would recommend every session an update command that will be refused
    HAVEC=$({ grep -m1 -oE '"wireContract"[[:space:]]*:[[:space:]]*"[^"]*"' "$AJ" 2>/dev/null || true; } | sed -E 's/.*"([^"]*)"$/\1/')
    WANTC=$({ grep -m1 -oE '"wireContract"[[:space:]]*:[[:space:]]*"[^"]*"' "$PJ" 2>/dev/null || true; } | sed -E 's/.*"([^"]*)"$/\1/')
    # legacy (an installed copy from before the standard contract) diverges only when it is older than the pack whose wire
    # values really changed (wireContractSince) — the same verdict as contract_drift in install-guide.sh
    CDRIFT=0
    if [ -f "$GD/SKILL.md" ] && [ "${HAVEC:-legacy}" != "${WANTC:-legacy}" ]; then
      CDRIFT=1
      if [ -z "$HAVEC" ]; then
        SINCE=$({ grep -m1 -oE '"wireContractSince"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$PJ" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
        if [ -z "$SINCE" ]; then CDRIFT=0
        elif [ -n "${PKV:-}" ] && [ "$(printf '%s\n%s\n' "$PKV" "$SINCE" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$SINCE" ]; then CDRIFT=0
        fi
      fi
    fi
    if [ "$CDRIFT" -eq 1 ]; then
      CPIN="$CPIN $GN"; continue
    fi
    HAVE=$({ grep -m1 -oE 'pkgs=[^>]*' "$GD/SKILL.md" 2>/dev/null || true; } | orangekit_majors)
    WANT=$({ grep -oE '"[@A-Za-z0-9._/-]+@[0-9.]+"' "$PJ" 2>/dev/null | tr -d '"' || true; } | orangekit_majors)
    if [ -n "$HAVE" ] && [ -n "$WANT" ] && [ "$HAVE" != "$WANT" ]; then
      PINNED="$PINNED $GN"          # premise moved — the project decides
    else
      FIXES="$FIXES $GN(v$PKV)"     # a fix within the same premise — it has to reach
    fi
  done
  # The installer applies contract pinning to **the whole combination** — once one axis is caught, updates of the other
  # axes that have a seam are refused too. Recommending those axes separately as FIXES would recommend a refused command every session
  if [ -n "$CPIN" ] && [ -n "$FIXES" ]; then
    for F in $FIXES; do
      [ -f "$ORANGEKIT_ROOT/.claude/skills/${F%%(*}/SKILL.md" ] && CPIN="$CPIN ${F%%(*}"
    done
    FIXES=""
  fi
  [ -n "$FIXES" ] && printf -- '- There are guide fixes under the same stack premise (plugin v%s ↔ installed%s) — run `/orangekit-update`\n' \
    "$PLUG_VER" "$FIXES"
  [ -n "$PINNED" ] && printf -- '- %s: the plugin pack has moved to a different stack major — **not updating**. Move it across with `/stack-guide-generator` when you raise the dependency\n' \
    "$(printf '%s' "$PINNED" | sed 's/^ //')"
  [ -n "$CPIN" ] && printf -- '- %s: the plugin pack moved to the standard wire contract and diverges from the installed seam — **not updating**. For a prebuilt seam, add `--seam <combination>` to the update command; for a generated seam, move it across when you regenerate it with `/stack-guide-generator`\n' \
    "$(printf '%s' "$CPIN" | sed 's/^ //')"

  # The project raised a dependency major but the guide still teaches the old one — once code has piled up,
  # the baseline is **the major the project actually installed**, not the registry latest (stack-guide-generator Step 2-B).
  # In 0.x the minor acts as the major (same rule as guide-freshness.sh)
  if [ -f "$ORANGEKIT_ROOT/package.json" ] && command -v python3 >/dev/null 2>&1; then
    for AJ in "$ORANGEKIT_ROOT"/.claude/skills/*/assembly.json; do
      [ -f "$AJ" ] || continue
      GD=$(dirname "$AJ"); GN=$(basename "$GD")
      [ -f "$GD/SKILL.md" ] || continue
      DEPUP=$(python3 - "$GD/SKILL.md" "$ORANGEKIT_ROOT/package.json" 2>/dev/null <<'PYDEP' || true
import json, re, sys
def key(v):
    m = re.match(r'\D*(\d+)(?:\.(\d+))?', v or '')
    if not m: return None
    a, b = int(m.group(1)), int(m.group(2) or 0)
    return (0, b) if a == 0 else (a, 0)
def show(k): return f"0.{k[1]}" if k[0] == 0 else str(k[0])
txt = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'pkgs=([^>]*)', txt)
if not m: sys.exit(0)
have = {}
for spec in m.group(1).split():
    n, _, v = spec.rpartition('@')
    if n and v: have[n] = key(v)
pj = json.load(open(sys.argv[2], encoding='utf-8'))
deps = {**pj.get('devDependencies', {}), **pj.get('dependencies', {})}
out = []
for n, g in have.items():
    p = key(str(deps.get(n, '')).lstrip('^~>=< '))
    if g and p and p > g: out.append(f"{n} {show(g)}→{show(p)}")
print(' · '.join(out))
PYDEP
)
      [ -n "$DEPUP" ] && printf -- '- %s: the project raised a dependency version (guide version→project version: %s) — the guide is still written for the earlier version. Ask `/stack-guide-generator` for a refresh and it rewrites only the files where that package appears\n' "$GN" "$DEPUP"
    done
  fi

  # T1 rule cards have no stack premise (code-change discipline · reversibility · lessons) — the latest is always right
  #
  # **Look at non-installation first.** The drift loop below iterates .claude/rules/, so if the directory is
  # empty its body never runs once, and "never installed at all" passes silently.
  # Running install-rules is only an instruction in the orangekit-init skill, not a hook — if the model
  # skips Step 7 the rules never arrive. This is the only place that knows that.
  # On a glob miss ls exits 1 — the pipefail+ERR trap kills the whole hook.
  # It dies exactly when "0 rule cards", so it goes silent in the very situation it meant to report. The || true guard is mandatory.
  # RCOUNT counts **only the plugin card names present in the project**. Counting the whole directory lets project cards
  # (project-structure · code-conventions) and stack rule files (stack-*.md) fill the count and hide a missing T1 card
  t1_present() {
    local n=0 f
    for f in "$PLUGIN_ROOT"/rules/*.md; do
      if [ -f "$f" ] && [ -f "$ORANGEKIT_ROOT/.claude/rules/$(basename "$f")" ]; then n=$((n+1)); fi
    done
    printf '%s' "$n"
  }
  RCOUNT=$(orangekit_num "$(t1_present)")
  PCOUNT=$(orangekit_num "$({ ls -1 "$PLUGIN_ROOT"/rules/*.md 2>/dev/null || true; } | wc -l)")

  # Auto-install of what is missing — two boundaries are kept:
  #   ⓐ Only when orangekit.config.json exists. The plugin is installed globally, so without this gate it would write
  #     .claude/rules/ into every repo the user opens. config present = the mark that this project uses orangekit
  #   ⓑ --missing-only. For a file that already exists, not even the version is looked at — an automatic run must not
  #     silently overwrite a user's edits. Updates are only **reported** below and run by a person
  # Leaving installation to a skill instruction alone means the norms never arrive when the model skips Step 7.
  if [ -f "$ORANGEKIT_ROOT/orangekit.config.json" ] && [ "$RCOUNT" -lt "$PCOUNT" ]; then
    CLAUDE_PROJECT_DIR="$ORANGEKIT_ROOT" bash "$PLUGIN_ROOT/scripts/install-rules.sh" --missing-only --quiet 2>/dev/null || true
    RCOUNT=$(orangekit_num "$(t1_present)")
  fi

  # The not-installed warning uses the config gate too. An unconfigured project is already handled by the /orangekit-init nudge
  # in §3.5, so saying it again here would put two warning lines on a repo that does not use orangekit.
  if [ "$RCOUNT" -eq 0 ] && [ "$PCOUNT" -gt 0 ] && [ -f "$ORANGEKIT_ROOT/orangekit.config.json" ]; then
    printf -- '- ⚠️ T1 rule cards not installed (auto-install failed too) — run `bash "%s/scripts/install-rules.sh"` yourself. Work routing, reversibility and security norms are not reaching the session\n' "$PLUGIN_ROOT"
  else
    RDRIFT=0
    for RC in "$ORANGEKIT_ROOT"/.claude/rules/*.md; do
      [ -f "$RC" ] || continue
      SRC="$PLUGIN_ROOT/rules/$(basename "$RC")"; [ -f "$SRC" ] || continue
      SV=$({ grep -m1 -oE 'orangekit-rule-version: [0-9.]+' "$SRC" 2>/dev/null || true; } | awk '{print $2}')
      TV=$({ grep -m1 -oE 'orangekit-rule-version: [0-9.]+' "$RC"  2>/dev/null || true; } | awk '{print $2}')
      # Older only: a card newer than the plugin's is kept by install-rules.sh (no downgrade), so counting it nagged forever
      [ -n "${SV:-}" ] && [ -n "${TV:-}" ] && orangekit_ver_gt "$SV" "$TV" && RDRIFT=$((RDRIFT+1))
    done
    [ "$RDRIFT" -gt 0 ] && printf -- '- %s T1 rule cards are on an old version — `/orangekit-update` brings every plugin-installed file along (cards · references · stack cards · guides)\n' "$RDRIFT"
    # A new card appeared in the plugin but is absent from the project (the drift loop cannot catch this).
    # The config gate is mandatory — without it a repo that does not use orangekit gets a "0/8 cards" warning.
    [ "$RCOUNT" -lt "$PCOUNT" ] && [ -f "$ORANGEKIT_ROOT/orangekit.config.json" ] \
      && printf -- '- only %s/%s T1 rule cards installed — run `/orangekit-update`\n' "$RCOUNT" "$PCOUNT"
  fi
fi

# ── 3.4 Unfinished guide work (so 20 minutes do not vanish when a session dies) ───
# Guide generation runs outside init's critical path. When a session is cut off, this hook is the only thing
# that knows, so if it does not report here the work is silently lost.
GJ="$ORANGEKIT_ROOT/.orangekit/guide-job.json"
if [ -f "$GJ" ]; then
  GJ_STATUS=$({ grep -oE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' "$GJ" 2>/dev/null || true; } | sed -E 's/.*"([a-z]+)"$/\1/')
  GJ_COMBO=$({ grep -oE '"combo"[[:space:]]*:[[:space:]]*"[^"]*"' "$GJ" 2>/dev/null || true; } | sed -E 's/.*"([^"]*)"$/\1/')
  # The app axis is not in combo (web + backend) — append it so app-only work does not show up as `none+none`
  GJ_APP=$({ grep -oE '"app"[[:space:]]*:[[:space:]]*"[^"]*"' "$GJ" 2>/dev/null || true; } | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
  case "${GJ_APP:-none}" in none|undecided|"") ;; *) GJ_COMBO="${GJ_COMBO:-?} · app=$GJ_APP" ;; esac
  case "${GJ_STATUS:-}" in
    pending|running|interrupted)
      printf -- '- guide generation unfinished (`%s`, status %s) — carry on with `/stack-guide-generator`\n' \
        "${GJ_COMBO:-?}" "$GJ_STATUS"
      orangekit_edge "session-start" "stack-guide-generator" ;;
    failed)
      printf -- '- ⚠️ guide generation failed (`%s`) — check the reason in `.orangekit/guide-job.json` and retry `/stack-guide-generator`\n' \
        "${GJ_COMBO:-?}" ;;
  esac
fi

# Is the audit and repair workspace left over — the user does not know large temporary files (npm installs) remain on their disk.
# If generation is in progress (running · pending · interrupted) it is material to pick up, so just report it; otherwise say it can be deleted
SCR="$ORANGEKIT_ROOT/.orangekit/scratch"
if [ -d "$SCR" ]; then
  SCR_SIZE=$({ du -sh "$SCR" 2>/dev/null || true; } | awk '{print $1}')
  case "${GJ_STATUS:-}" in
    pending|running|interrupted)
      printf -- '- guide audit and repair workspace `.orangekit/scratch/` (%s) — deleted automatically when generation finishes\n' "${SCR_SIZE:-?}" ;;
    *)
      printf -- '- leftover guide workspace `.orangekit/scratch/` (%s) — not in use. Delete it with `rm -rf .orangekit/scratch`\n' "${SCR_SIZE:-?}" ;;
  esac
fi

# ── 3.5 Nudge for an unconfigured project (the earliest interactive contact after install) ───
if [ ! -f "$ORANGEKIT_ROOT/orangekit.config.json" ]; then
  printf -- '- unconfigured project — pick the tech stack (backend and DB included) with `/orangekit-init` and the stack rule files are installed (the detailed guide is optional)\n'
fi

# ── 3.6 Self-test entry point (a consumer project has no scripts/ — the absolute path is the only truth) ──
printf -- '- self-test: `bash "%s/scripts/doctor.sh"`\n' "$PLUGIN_ROOT"

# ── 4. Lesson promotion candidates (only when the threshold is reached) ───
LF="$ORANGEKIT_ROOT/docs/lessons.md"
if [ -f "$LF" ]; then
  # grep exits 1 on no match — the || true guards keep the pipefail+ERR trap from killing the hook
  # a false positive is a candidate for narrowing, not promotion (rules/lessons.md) — it is kept out of the promotion candidates and reported separately
  CAND=$({ grep -oE '\[category: [^]]+\]' "$LF" 2>/dev/null || true; } \
    | sed 's/\[category: //;s/\]//' | sort | uniq -c | sort -rn \
    | awk '$1>=3 && $2!="false-positive" {printf "%s(%s) ", $2, $1}')
  [ -n "$CAND" ] && printf -- '- lesson promotion candidates: %s→ `bash "%s/scripts/doctor.sh" --lessons`\n' "$CAND" "$PLUGIN_ROOT"
  FPN=$(orangekit_num "$({ grep -c '^## \[category: false-positive\]' "$LF" 2>/dev/null || true; })")
  [ "$FPN" -ge 2 ] && printf -- '- %s false positives recorded — `--lessons` aggregates the narrowing candidates per guard (narrow the condition, do not add a rule)\n' "$FPN"
  RCAND=$({ grep -oE '\[request: [^]]+\]' "$LF" 2>/dev/null || true; } \
    | sed 's/\[request: //;s/\]//' | sort | uniq -c | sort -rn \
    | awk '$1>=3 {printf "%s(%s) ", $2, $1}')
  [ -n "$RCAND" ] && printf -- '- repeated-request automation candidates: %s→ consider promoting to a skill (`--lessons`)\n' "$RCAND"
fi

# ── 5. Time since the last external-change check (the exploration stage of the self-evolution loop) ───
# No separate stamp file — the harness-evaluation report filenames are the ledger,
# and the mtime of the newest report is the last check time.
LATEST_HE=$({ ls -t "$ORANGEKIT_ROOT"/dev/docs/harness-evaluation/*.md 2>/dev/null || true; } | head -1)
if [ -n "$LATEST_HE" ]; then
  HE_MTIME=$(orangekit_num "$(stat -c %Y "$LATEST_HE" 2>/dev/null || stat -f %m "$LATEST_HE" 2>/dev/null || true)")   # GNU first (see orangekit_worktree_snapshot)
  NOW_TS=$(orangekit_num "$(date +%s)")
  if [ "$HE_MTIME" -gt 0 ] && [ "$NOW_TS" -gt "$HE_MTIME" ]; then
    HE_AGE=$(( (NOW_TS - HE_MTIME) / 86400 ))
    if [ "$HE_AGE" -ge 30 ]; then
      printf -- '- %s days since the last harness evaluation — `/harness-evaluation` recommended to check external change (native features · models)\n' "$HE_AGE"
      orangekit_edge "session-start" "harness-evaluation"
    fi
  fi
fi

# Log rotation moved here from every heartbeat/edge (common.sh orangekit_rotate_logs, consumer report E10) — after the
# liveness report above has read hookrun.log, so it still sees every row since the previous session. And the transcript
# indexes (common.sh orangekit_transcript_index) of sessions untouched for a week, plus private copies a killed hook left behind
orangekit_rotate_logs
find "$(orangekit_state_dir)" -maxdepth 1 -name 'transcript-index.*' -mtime +7 -delete 2>/dev/null || true

exit 0
