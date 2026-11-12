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

# ── Windows (Git Bash · MSYS · Cygwin) ───────────────────────────────
# winget installs jq into its package directory and only new shells see the PATH change, so a just-installed jq
# stayed invisible to every hook until Claude Code restarted. Look there before treating jq as missing
orangekit_winget_jq_dir() { # $1=LOCALAPPDATA → the directory holding jq.exe (empty when there is none)
  [ -n "${1:-}" ] || return 0
  local la f; la=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1")
  for f in "$la"/Microsoft/WinGet/Links/jq.exe "$la"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe; do
    if [ -f "$f" ]; then dirname "$f"; return 0; fi
  done
  return 0
}
if ! command -v jq >/dev/null 2>&1; then
  _okjq=$(orangekit_winget_jq_dir "${LOCALAPPDATA:-}")
  [ -z "$_okjq" ] || PATH="$_okjq:$PATH"
  unset _okjq
fi
# Windows shims (Python resolution, CRLF stripping) — one canonical file, see its header
# shellcheck source=win-compat.sh
# No `$(cd "$(dirname …)" && pwd)`: two forks and a dirname exec on every hook call cost most on Windows, and a relative path sources the same file
case "${BASH_SOURCE[0]}" in */*) . "${BASH_SOURCE[0]%/*}/win-compat.sh" ;; *) . ./win-compat.sh ;; esac

# ── ERR trap: a failure is not passed over quietly ────────────────────
# Emits to stderr, but the exit code follows each hook's own policy.
orangekit_on_err() {
  local code=$? line=${1:-?} cmd=${BASH_COMMAND:-}
  printf '[orangekit:%s] ERROR line %s (exit %s)\n' "${ORANGEKIT_HOOK_NAME:-unknown}" "$line" "$code" >&2
  # The exit code alone could not be fixed from — the 5th field keeps the line and the failing command
  orangekit_heartbeat "$code" "line $line: ${cmd:0:160}"
  exit "$code"
}
trap 'orangekit_on_err $LINENO' ERR

# ── Project root resolution ───────────────────────────────────────────
# Priority: CLAUDE_PROJECT_DIR → stdin .cwd → git toplevel → fail
# **Does not guess.** If it cannot be found, block with exit 2 (anti-goal 1).
#
# Usage: ORANGEKIT_ROOT=$(orangekit_root "$INPUT")
# ── Windows paths (Git Bash) ──────────────────────────────────────────
# Claude Code on Windows hands hooks Windows-form paths (C:\Users\me\proj\src\a.ts — CLAUDE_PROJECT_DIR, cwd, file_path,
# transcript entries), git for Windows prints C:/Users/me/proj, and every comparison in the hooks splits on "/" — so a
# prefix strip or a `paths:` glob silently missed. Git Bash opens C:/… as is, so turning backslashes into slashes at the
# boundary makes both sides meet without changing what the path opens. Only a drive-letter path, or any path on a
# Windows shell, is rewritten: on macOS/Linux a backslash is a legal file-name character and stays.
# A Git Bash path (/c/Users/…) is the same file as C:/Users/…, but once a value has passed through a native program (jq.exe,
# python.exe) one side is /c/… and the other C:/…, and a prefix strip never matches — so on a Windows shell /x/… becomes X:/….
orangekit_slashes() { local _oks; orangekit_slashes_v _oks "${1:-}"; printf '%s' "$_oks"; }  # $1 path → printed with / separators
orangekit_slashes_v() {  # $1 variable  $2 path → the same result in the variable, without the fork of `$(orangekit_slashes …)`
  local p="${2:-}" d
  case "$p" in
    [A-Za-z]:\\*|[A-Za-z]:/*) p=${p//\\//} ;;
    *) case "${OSTYPE:-}" in
         msys*|cygwin*|win*)
           p=${p//\\//}
           case "$p" in
             /[A-Za-z]|/[A-Za-z]/*)
               d=""; command -v cygpath >/dev/null 2>&1 && d=$(cygpath -m "$p" 2>/dev/null || true)   # guarded: a failure inside $( ) trips the ERR trap
               if [ -n "$d" ]; then p=$d; else d=$(printf '%s' "${p:1:1}" | tr '[:lower:]' '[:upper:]'); p="$d:/${p:3}"; fi ;;
           esac ;;
       esac ;;
  esac
  while [[ "$p" == *$'\n' ]]; do p=${p%$'\n'}; done   # what `$(orangekit_slashes …)` dropped
  printf -v "$1" '%s' "$p"
}

# Is version $1 newer than $2 (x.y.z, numeric per part)? Same rule as ver_gt in the installers, which do not source this file
orangekit_ver_gt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 } exit 1 }'; }

orangekit_root() {
  local input="${1:-}" root=""

  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    orangekit_slashes "$CLAUDE_PROJECT_DIR"; return 0
  fi

  if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
    root=$(printf '%s' "$input" | jq -r '.cwd // .workspace_dir // empty' 2>/dev/null || true)
    if [ -n "$root" ] && [ -d "$root" ]; then
      orangekit_slashes "$root"; return 0
    fi
  fi

  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$root" ] && [ -d "$root" ]; then
    orangekit_slashes "$root"; return 0
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
  # Already 1–18 plain digits: the pipeline below would return it unchanged — skip its fork and two execs
  case "$v" in ''|*[!0123456789]*) ;; *) [ "${#v}" -le 18 ] && { printf '%s' "$v"; return 0; } ;; esac
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
  local list f i n=0 st="" ok=0 tab=$'\t'
  local -a ex=() isx=() val=()
  # The path list as before (porcelain · rename target · sort -u) — a failing git status still fails this function, as the pipeline did
  # git status first on its own: a clean tree (the common Stop) needs no sed and no sort. Its output fed back through printf is
  # the same lines the pipe carried (porcelain ends every line with a newline)
  list=$(git status --porcelain 2>/dev/null) || return
  [ -n "$list" ] || return 0
  list=$(printf '%s\n' "$list" | sed -E 's/^.{3}//; s/^.* -> //' | sort -u) || return
  [ -n "$list" ] || return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ -e "$f" ]; then isx[n]=1; ex+=("$f"); else isx[n]=0; fi
    n=$((n + 1))
  done <<< "$list"
  # **One** `stat` for every existing path instead of one per file (597 dirty files took 1.06 s; one fork per file is what Windows pays most for).
  # GNU form first: GNU stat (Linux · Git Bash) reads -f as "file system status", prints a multi-line block for the
  # file and exits 1 over the '%m' operand — the fallback then appended the real value to that block, so every line
  # of the snapshot carried free-block counts that change by the second. BSD stat rejects -c with nothing on stdout.
  # The batch is used only when it printed exactly one `mtime<TAB>size` line per path; anything else (a path stat reads as an
  # option, a file gone in between, an unknown stat) falls back to the per-file loop, which is the old behaviour line for line
  if [ ${#ex[@]} -gt 0 ]; then
    case "${OSTYPE:-}" in
      darwin*|*bsd*) st=$(stat -f '%m	%z' "${ex[@]}" 2>/dev/null) || st=$(stat -c '%Y	%s' "${ex[@]}" 2>/dev/null) || st="" ;;
      *) st=$(stat -c '%Y	%s' "${ex[@]}" 2>/dev/null) || st=$(stat -f '%m	%z' "${ex[@]}" 2>/dev/null) || st="" ;;
    esac
    i=0
    while IFS= read -r f; do
      [[ "$f" =~ ^[0123456789]+$tab[0123456789]+$ ]] || { i=-1; break; }
      val[i]=$f; i=$((i + 1))
    done <<< "$st"
    [ "$i" -eq ${#ex[@]} ] && ok=1
  else
    ok=1
  fi
  i=0; n=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "${isx[n]}" = 1 ]; then
      if [ "$ok" = 1 ]; then st=${val[i]}; i=$((i + 1))
      else st=$(stat -c '%Y	%s' "$f" 2>/dev/null || stat -f '%m	%z' "$f" 2>/dev/null || printf -- '-	-'); fi
    else
      st=$(printf -- '-	-')
    fi
    n=$((n + 1))
    printf '%s	%s
' "$f" "$st"
  done <<< "$list"
}

# Extracts only the path from a snapshot line (before the TAB). Safe even if the path contains spaces.
orangekit_snapshot_paths() { cut -f1; }

# ── Heartbeat ─────────────────────────────────────────────────────────
# Every hook records its own execution as its first action. Another component (session-brief)
# reads this log and reports dead hooks. A component does not vouch for itself (P1).
# One `date` per hook call, shared by the heartbeat and the edge line (a fork + exec each, which Windows pays for most)
_orangekit_now() { [ -n "${_OK_NOW:-}" ] || _OK_NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true); }

orangekit_heartbeat() {
  local code="${1:-0}" detail="${2:-}" dir
  [ -z "${ORANGEKIT_ROOT:-}" ] && return 0
  dir=${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}   # = orangekit_state_dir, without the subshell
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  _orangekit_now
  # A '|' or newline inside the detail would split the row, so both become '/'. Readers use fields 1–4 only; 5 is optional
  detail=${detail//[|$'\n'$'\r']//}
  printf '%s|%s|%s|%s%s\n' \
    "${ORANGEKIT_HOOK_NAME:-unknown}" \
    "$_OK_NOW" \
    "${ORANGEKIT_ROOT}" \
    "$code" "${detail:+|$detail}" >> "$dir/hookrun.log" 2>/dev/null || true
}

# ── Graph edge instrumentation ────────────────────────────────────────
# Makes which path actually executes measurable (Graph Engineering G2).
orangekit_edge() {
  local from="${1:-}" to="${2:-}" dir
  [ -z "${ORANGEKIT_ROOT:-}" ] && return 0
  dir=${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  _orangekit_now
  printf '%s|%s|%s\n' "$_OK_NOW" "$from" "$to" \
    >> "$dir/graph.log" 2>/dev/null || true
}

# ── Log rotation — run by session-brief, not on every hook call ──────
# Both checks used to run inside every heartbeat and edge: a `wc -l` and a number normalisation each, on every tool call,
# to act once in 2000 lines (consumer report E10). session-brief runs at every start, resume and compaction, so a log
# still stays bounded; a session that never restarts grows by one short line per hook call until the next one.
#
# hookrun.log — above 2000 lines, keep the most recent 1000.
# **Invariant: rotation never erases any component's last piece of evidence.**
# A plain tail makes this log lie — security-check fires on Edit/Write/MultiEdit/Bash alike,
# takes 97% of the lines, and pushes every other hook's history out of the window. Then
# session-brief **reports a hook that really ran as "never executed"** (track-skill measured:
# 7 lines remained in skilluse.log while they had evaporated from hookrun.log). What the metric measured
# was not "has it ever run" but "did it run recently enough to survive rotation".
#
# Only the names being pushed out of the window are picked, and their single last line is kept along with them. Global dedup is not used
# because the same hook running twice in the same second is normal, and erasing that would distort the line count.
#
# graph.log — the only log that once had no ceiling (evaluation v6 · E-28): above 5000 lines, keep the last 2500.
# An append carries a ceiling with it (code-change "when you write code that appends, put the rotation/ceiling in with it").
orangekit_rotate_logs() {
  local dir n
  dir=${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}
  n=$(orangekit_count_lines "$dir/hookrun.log")
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
  n=$(orangekit_count_lines "$dir/graph.log")   # 0 without a graph.log yet — session-brief can run before any edge was written
  if [ "$n" -gt 5000 ]; then
    tail -2500 "$dir/graph.log" > "$dir/graph.log.tmp" 2>/dev/null \
      && mv "$dir/graph.log.tmp" "$dir/graph.log" 2>/dev/null || rm -f "$dir/graph.log.tmp"
  fi
  return 0
}

# Hook failures since the previous session started: "<hook> (exit N: line M: command)" per line, newest last.
# An all-time list never cleared once the cause was fixed — a warning that cannot be turned off teaches people to
# ignore it. Counting from the second-to-last session-brief row means the current session's own row does not hide
# the previous session's failures. A log rotated past that row is read whole.
orangekit_recent_failures() { # $1=hookrun.log
  [ -f "${1:-}" ] || return 0
  awk -F'|' '
    { name[NR] = $1; code[NR] = $4; det[NR] = $5; if ($1 == "session-brief") { prev = cur; cur = NR } }
    END { for (i = prev + 1; i <= NR; i++) if (code[i] != "" && code[i] != "0")
            printf "%s (exit %s%s)\n", name[i], code[i], (det[i] != "" ? ": " det[i] : "") }
  ' "$1" 2>/dev/null || true
}

# ── Hook initialization ───────────────────────────────────────────────
# Usage:
#   INPUT=$(cat 2>/dev/null || echo '{}')
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#   orangekit_begin "session-brief" "$INPUT"
orangekit_begin() {
  ORANGEKIT_HOOK_NAME="${1:-unknown}"
  local input="${2:-}"
  # orangekit_root's first answer, without the subshell (a fork costs as much as an exec on Windows); every other case as before
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then orangekit_slashes_v ORANGEKIT_ROOT "$CLAUDE_PROJECT_DIR"
  else ORANGEKIT_ROOT=$(orangekit_root "$input"); fi
  export ORANGEKIT_HOOK_NAME ORANGEKIT_ROOT
  orangekit_heartbeat 0
}

# Extract a field from stdin JSON (empty string if jq is absent)
orangekit_field() {
  local input="${1:-}" path="${2:-}"
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$input" | jq -r "$path // empty" 2>/dev/null || printf ''
}

# jq helpers shared by orangekit_fields and the transcript index — what `jq -r` prints for one value, as a string
# (a string as is; anything else as jq's indented JSON), and what `$( )` makes of a printed value (NULs and trailing newlines dropped)
_OK_JQ_DEFS='
def okpretty($i): if type == "object" then (if length == 0 then "{}" else "{\n" + ([to_entries[] | $i + "  " + (.key | tojson) + ": " + (.value | okpretty($i + "  "))] | join(",\n")) + "\n" + $i + "}" end)
  elif type == "array" then (if length == 0 then "[]" else "[\n" + ([.[] | $i + "  " + okpretty($i + "  ")] | join(",\n")) + "\n" + $i + "]" end)
  else tojson end;
def okraw: if type == "string" then . else okpretty("") end;
def okchomp: (split("\u0000") | join("")) | until(endswith("\n") | not; .[:-1]);'

# Several fields of the hook's stdin JSON with **one** jq call — one jq per field cost a fork and an exec each, on every tool call.
# Each variable gets exactly what `VAR=$(orangekit_field "$INPUT" PATH)` gives. Anything but one parseable JSON document
# (no jq, invalid JSON, several documents) takes the per-field path, so those inputs read exactly as before.
# Usage: orangekit_fields "$INPUT" VAR '.path' [VAR '.path' …]   (VAR names are the caller's, never a variable of this function)
orangekit_fields() {
  local _okin="${1:-}" _okprog="" _okout="" _okdocs=0; shift
  local -a _okargs=("$@")
  if command -v jq >/dev/null 2>&1; then
    while [ $# -ge 2 ]; do
      _okprog+="${_okprog:+, }\"$1=\" + ([try ($2 // empty) catch empty | okraw] | join(\"\\n\") | okchomp | @sh)"
      shift 2
    done
    # + the heartbeat's timestamp: jq `now|todate` prints exactly `date -u +%Y-%m-%dT%H:%M:%SZ` — one exec fewer per hook call
    _okout=$(jq -r <<< "$_okin" "$_OK_JQ_DEFS $_okprog, \"_okdocs=\$((_okdocs + 1))\", \"_OK_NOW=\${_OK_NOW:-\" + (now | todate | @sh) + \"}\"" 2>/dev/null) || _okout=""   # here-string: no forked printf; the newline it adds is JSON whitespace
    [ -n "$_okout" ] && eval "$_okout"
  fi
  [ "$_okdocs" = 1 ] && return 0
  set -- "${_okargs[@]}"
  while [ $# -ge 2 ]; do eval "$1=\$(orangekit_field \"\$_okin\" \"\$2\")"; shift 2; done
  return 0
}

# ── Transcript index — one shared, incremental pass ───────────────────
# security-check (knowledge gate) and build-gate (three passes) each parsed the whole transcript with their own jq program,
# on every call: a 230 MB transcript took ~1 s per pass, and build-gate made three (consumer report B7 · E3).
# One jq program now carries **each of those programs verbatim** and writes their output lines, tagged with which reader
# they belong to (K knowledge gate · T files touched · V verification commands · U render traces), so every reader still sees
# byte for byte what its own pass printed. The result is cached in the state dir per session, with the byte offset reached,
# and the next call parses only the appended tail (a 2 MB tail: 0.04 s).
#
# Cache file: `OKTI1 <committed offset> <kerr committed> <kerr view> <data bytes> <inode> <transcript>|<first line>|`, the committed lines,
# a line `P`, then the lines of a last transcript line that may still be half written (re-parsed by the next call).
# It is trusted only when all of these hold — anything else is a full re-read, never an empty view:
#   · same transcript path, same inode, same first line (a replaced file starts over)
#   · the byte before the committed offset is a newline (the tail starts on a line boundary; a shrunk file fails this too)
#   · the cache file is still the one whose header was read (another hook replacing it in between: start over), and its
#     committed lines still have the byte length the header recorded (a truncated or padded cache: start over)
#   · the read ends on a newline — then the size stat saw is committed; a half-written last line commits nothing new (this view
#     has its lines, the next call re-reads them). Byte counts are never taken from jq: jq 1.7 `-R` turns a UTF-8 character that
#     straddles its 4,095-byte read into U+FFFD (17 lines of one 242 MB transcript), the old passes included — the views keep that,
#     but a length jq reports is not the file's
# Concurrency: every call writes its own private file and reads only that; it is published by rename at exit. Two hooks at
# once each see a complete view, and whichever renames last wins — an older cache only means a longer tail next time.
# "kerr": the old knowledge-gate pass died with jq's status when the **last** transcript line made its program fail, and the
# hook with it (`_session_reads` keeps that behaviour); the flag says whether that line did.
_OK_TI_PROG='
def tag($t): $t + "\t" + (split("\n") | join("\n" + $t + "\t"));
def kg: if (.type=="system" and .subtype=="compact_boundary") then "C"
         elif .type=="assistant" then (.message.content[]? | select(.type=="tool_use")
           | if .name=="Read" then "R\t\(.input.file_path // "")\t\(.input.limit // "")"
             elif .name=="Bash" then "B\t\((.input.command // "") | gsub("\n";" "))"
             elif .name=="Skill" then "S\t\(.input.skill // "")"
             else empty end)
         elif .type=="user" then ((.message.content // "")
           | if type=="string" then . else ([.[]? | select(.type=="text") | .text] | join(" ")) end
           | [scan("<command-name>/?([^<]+)</command-name>")] | .[] | "S\t\(.[0])")
         else empty end;
def tc: select(.type=="assistant") | (.cwd // "") as $cwd | .message.content[]? | select(.type=="tool_use")
            | if (.name | test("^(Edit|Write|MultiEdit|NotebookEdit)$"))
                then "E\t" + (.input.file_path // .input.notebook_path // "")
              elif .name=="Bash" then "B\t" + $cwd + "\t" + ((.input.command // "") | gsub("\r"; "") | gsub("\n"; "\u001f"))
              else empty end;
def vr: select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use" and .name=="Bash") | .input.command // empty;
def ui: select(.type=="assistant") | .message.content[]?
            | select(.type=="tool_use")
            | if .name=="Bash" then (.input.command // empty)
              elif .name=="Skill" then (.input.skill // empty)
              else empty end;
# A line none of the four programs can print anything for is not parsed (fromjson is most of the cost): each prints only for an
# item whose type is "tool_use", a "compact_boundary" or a "<command-name>" text — strings that stand literally in the raw line
# unless it uses a \u escape, and such a line is always parsed. Its error flag (-1 here) is worked out only if it is the last line
def skip: (contains("\\u") | not) and (contains("\"tool_use\"") | not) and (contains("compact_boundary") | not) and (contains("command-name") | not);
def kerr: [fromjson?] as $d | if $d == [] then 0 elif ([$d[0] | try kg catch {okerr: 1}] | any(type == "object")) then 1 else 0 end;
def recs_full: [fromjson?] as $d
  | if $d == [] then {o: [], e: 0}
    else $d[0] as $j | [$j | try kg catch {okerr: 1}] as $k
      # tc · vr · ui all start with select(.type=="assistant"): on any other object they print nothing and cannot fail
      | {o: ([$k[] | strings | tag("K")]
             + (if ($j | type) == "object" and $j.type != "assistant" then [] else
                 [$j | try tc catch empty | tag("T")] + [$j | try vr catch empty | okraw | tag("V")]
                 + [$j | try ui catch empty | okraw | tag("U")] end)),
         e: (if ($k | any(type == "object")) then 1 else 0 end)}
    end;
def recs: if skip then {o: [], e: -1} else recs_full end;
(if $c > 0 then (try input catch "\u0000") else "" end) as $probe
| if $probe != "" then "OKTI-MISALIGNED"
  elif $old != "" and ($old | startswith($oh + "\n") | not) then "OKTI-RACED"
  elif ($old | ltrimstr($oh + "\n") | if . == "" or startswith("P\n") then 0 else (split("\nP\n")[0] | length + 1) end) != $dl
  then "OKTI-CORRUPT"
  else
    ($old | ltrimstr($oh + "\n") | if . == "" or startswith("P\n") then "" else split("\nP\n")[0] end) as $oc
    # The caller appends "\n@@E\n": the last input is that sentinel, and the one before it is "" exactly when the transcript
    # read ended with a newline (then that "" is the newline in front of the sentinel, not a transcript line)
    | reduce (inputs | [., . == "", recs]) as [$l, $z, $r] ({o: [], m: 0, pm: 0, n: 0, e: $kc, pe: $kc, ppe: $kc, z: false, pz: false, l: "", pl: "", ppl: ""};
        .pm = .m | .m = (.o | length) | .o += $r.o | .n += 1 | .ppe = .pe | .pe = .e | .e = $r.e | .pz = .z | .z = $z
        | .ppl = .pl | .pl = .l | .l = $l)
    | (if .e == -1 then .e = (.l | kerr) else . end) | (if .pe == -1 then .pe = (.pl | kerr) else . end)
    | (if .ppe == -1 then .ppe = (.ppl | kerr) else . end)
    # $nl -1: the input ends with the sentinel (a tail through a pipe). 1 / 0: a whole file read directly, ending / not ending
    # on a newline (the caller looked) — a pipe made jq twice as slow on a 100 MB file
    | if $nl == -1 and .n < 2 then "OKTI-MISALIGNED"   # the probe took the newline in front of the sentinel: nothing from the offset on
      else (if $nl == -1 then (if .pz then {c: $sz, k: .ppe, v: .ppe, cut: (.o | length)}   # read ended on a newline: commit up to the size stat saw
                               else {c: $c, k: $kc, v: .pe, cut: 0} end)                       # a half-written last line: nothing committed
            elif $nl == 1 then {c: $sz, k: .e, v: .e, cut: (.o | length)}
            else {c: $c, k: $kc, v: .e, cut: 0} end) as $cm
      | "OKTI1 \($cm.c) \($cm.k) \($cm.v) \($dl + ([.o[:$cm.cut][] | length + 1] | add // 0)) \($ino) \($key)",
        (if $oc != "" then $oc else empty end), .o[:$cm.cut][], "P", .o[$cm.cut:][]
      end
  end'
ORANGEKIT_TI=""; _OK_TI_PUB=""; _OK_TI_DEST=""
_orangekit_ti_publish() { [ -z "$_OK_TI_PUB" ] || mv -f "$_OK_TI_PUB" "$_OK_TI_DEST" 2>/dev/null || rm -f "$_OK_TI_PUB" 2>/dev/null || true; _OK_TI_PUB=""; }

# $1 transcript  $2 session id → ORANGEKIT_TI = a private file with the index of the whole transcript (header line first).
# Returns 2 when the transcript cannot be read (what `jq … "$transcript"` exited with), 1 when no file could be written.
orangekit_transcript_index() {
  local tp="${1:-}" sid="${2:-}" dir cache tmp st ino sz fp key magic c kc kv dl=0 hdl hino rest base=0 oh="" first
  ORANGEKIT_TI=""
  [ -r "$tp" ] || return 2
  command -v jq >/dev/null 2>&1 || return 1
  sid=${sid//[^A-Za-z0-9._-]/}
  dir=${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}
  cache="$dir/transcript-index.${sid:-nosession}"
  { [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; } && [ -w "$dir" ] && tmp="$cache.$$" || tmp=""
  case "${OSTYPE:-}" in
    darwin*|*bsd*) st=$(stat -f '%i %z' "$tp" 2>/dev/null || stat -c '%i %s' "$tp" 2>/dev/null || true) ;;
    *) st=$(stat -c '%i %s' "$tp" 2>/dev/null || stat -f '%i %z' "$tp" 2>/dev/null || true) ;;
  esac
  if [[ "$st" =~ ^[0-9]+\ [0-9]+$ ]] && [ -n "$tmp" ]; then
    ino=${st% *}; sz=${st#* }
    IFS= read -r -n 200 fp < "$tp" || true
    key="$tp|${fp//$'\r'/}|"
    if [ -f "$cache" ] && IFS=' ' read -r magic c kc kv hdl hino rest < "$cache" 2>/dev/null \
       && [ "$magic" = OKTI1 ] && [ "$hino" = "$ino" ] && [ "$rest" = "$key" ] && [[ "$hdl" =~ ^[0-9]+$ ]] \
       && [[ "$c" =~ ^[0-9]+$ ]] && [[ "$kc" =~ ^[01]$ ]] && [[ "$kv" =~ ^[01]$ ]] && [ "$c" -le "$sz" ]; then
      base=$c; dl=$hdl; oh="$magic $c $kc $kv $hdl $hino $rest"
    fi
  else
    # No usable size or no writable state dir: a full read into a temporary file that is not kept
    ino=0; sz=-1; key="-"; tmp=$(mktemp 2>/dev/null) || return 1
    _OK_TI_DEST=""
  fi
  _orangekit_ti_run() {   # $1 base → writes $tmp, prints nothing; the first line of $tmp says what happened
    if [ "$1" -gt 0 ]; then
      { tail -c +"$1" "$tp" 2>/dev/null; printf '\n@@E\n'; } | jq -nrR --rawfile old "$cache" --arg oh "$oh" --argjson c "$1" --argjson nl -1 \
        --argjson kc "${kc:-0}" --argjson dl "$dl" --argjson sz "$sz" --arg ino "$ino" --arg key "$key" "$_OK_JQ_DEFS $_OK_TI_PROG" > "$tmp" 2>/dev/null
    else
      local nl=0; [ -z "$(tail -c 1 "$tp" 2>/dev/null)" ] && nl=1   # `$( )` drops a final newline: empty = the file ends with one (or is empty)
      jq -nrR --arg old "" --arg oh "" --argjson c 0 --argjson kc 0 --argjson dl 0 --argjson nl "$nl" \
        --argjson sz "$sz" --arg ino "$ino" --arg key "$key" "$_OK_JQ_DEFS $_OK_TI_PROG" < "$tp" > "$tmp" 2>/dev/null
    fi
  }
  # A cache that does not line up (misaligned · replaced or damaged · jq failed) → the whole transcript again. A jq without
  # --rawfile (1.5) fails the cached read every time and takes this full read: correct, never faster
  first=""
  _orangekit_ti_run "$base" && IFS= read -r first < "$tmp" 2>/dev/null || true
  if [ "${first%% *}" != OKTI1 ] && [ "$base" -gt 0 ]; then
    base=0; dl=0; first=""; _orangekit_ti_run 0 && IFS= read -r first < "$tmp" 2>/dev/null || true
  fi
  [ "${first%% *}" = OKTI1 ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  ORANGEKIT_TI=$tmp
  if [ "$sz" -ge 0 ]; then
    _OK_TI_PUB=$tmp; _OK_TI_DEST=$cache
  else
    _OK_TI_PUB=$tmp; _OK_TI_DEST=""
  fi
  trap '_orangekit_ti_publish' EXIT
  return 0
}
