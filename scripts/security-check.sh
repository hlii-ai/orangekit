#!/bin/bash
# scripts/security-check.sh — PreToolUse (Edit|Write|MultiEdit|Bash)
#
# The last line of defense that blocks obvious hardcoded secrets.
#
# In v2 this was **the only hook that worked** out of 11. The reason is clear —
# it does not need to know any path, so it was unaffected by the wrong root computation.
# v3 keeps that property: the verdict needs no project root.
#
# Only exact patterns are used. A false positive makes the user turn the hook off,
# and then the blocking power is 0.

# `--owning <path>…` — not the hook but a lookup mode: prints, one per line, the rule cards and skills the gate would require before the first write to that path.
# The planning stage (dev-docs-generator) uses it to fill in "Read first" for each slice — it must be the **same judgement** as the gate, so no copy is kept.
# `--scratch-db new|url|psql|drop|list <name>` — not the hook but the **dedicated path for scratch verification DBs** (see "Scratch-DB path" below).
# $(< …) reads stdin without a cat exec; unreadable stdin → {} as before
case "${1:-}" in --owning|--scratch-db) INPUT='{}' ;; *) INPUT=$(< /dev/stdin) 2>/dev/null || INPUT='{}' ;; esac
# shellcheck source=lib/common.sh
_OK_PY_LAZY=1   # never runs Python: skip win-compat's Windows python probes on every call
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"

# A failed root resolution must not stop the security check — only the heartbeat is best-effort
ORANGEKIT_HOOK_NAME="security-check"
# Through orangekit_slashes like every path from Claude Code — on Windows CLAUDE_PROJECT_DIR is C:\…, and a root left in that
# form never prefixes a normalized C:/… file path (the knowledge gate then found no owner: fail-open)
orangekit_slashes_v ORANGEKIT_ROOT "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '')}"

# Every field this hook reads, with one jq call (one per field used to cost a fork and an exec each, on every tool call)
orangekit_fields "$INPUT" TOOL_NAME '.tool_name' FILE_PATH '.tool_input.file_path' CONTENT '.tool_input.content' \
  NEW_STRING '.tool_input.new_string' F_CMD '.tool_input.command' F_TP '.transcript_path' F_SID '.session_id' F_CWD '.cwd'
orangekit_slashes_v FILE_PATH "$FILE_PATH"   # C:\…\a.ts → C:/…/a.ts (Windows)
# The heartbeat comes right after the field read, which also gives it its timestamp (no `date` exec)
[ -n "$ORANGEKIT_ROOT" ] && [ "${1:-}" != "--owning" ] && [ "${1:-}" != "--scratch-db" ] && orangekit_heartbeat 0

# Avoid self-reference when this hook itself is being handled (the pattern strings match themselves)
[[ "$FILE_PATH" =~ security-check\.sh$ ]] && exit 0

# ══════════════════════════════════════════════════════════════════════
# Prior-knowledge gate — load the rule card · skill that owns a path before writing to it
# ══════════════════════════════════════════════════════════════════════
#
# **A different axis** from the secret and destruction gates. Those two stop what must not happen now;
# this one stops "a judgement that can only be made now" from being made without the rule or procedure.
#
# Root cause: an agent finishes its judgement **in its head** and goes straight to writing the artifact (the file). Whether to call a rule or skill
# is the model's discretion, so the sentence "call X when Y" was never hung on the execution path.
#   - a `paths:` card loads when a matching file is **read** (platform-contract §3). At the moment a new file is first
#     written, or edited through Bash, there is no read, so no card comes up
#   - a skill is chosen by the model from its description. The P3 · P4 instructions in the routing card are only sentences
# Measured (benchmark B3 = 1.7.0, 3 runs): the data-modeling card reached before the first table was written 1/3 · in a fresh session 0/3,
# `/test-driven-development` called 0/9 (stages 1·2·4) in a repo that had a test runner, Bash file writes 25~43 per run in stage 1.
# A non-blocking notice arrived **after** the file was saved and could not change the design (only an omission-reason comment, 3/3).
#
# So a deterministic checkpoint goes at the **boundary of the artifact** — it checks through the transcript whether the knowledge that owns the path
# entered this session (since the last compaction), and if not, sends that write back once (exit 2).
#   Owning knowledge ① rule card: `paths:` of the project's `.claude/rules/*.md` (the card declares it itself)
#                    ② skill: `beforeWrite` of a skill node in `workflow.graph.json` (the graph declares it, doctor verifies it)
#   Write            a new file from Write · the target of a Bash redirection · `tee` · `sed -i`. Bash does not force a Read,
#                    so a card is required for edits to existing files too. A skill is required only for new files
#   Entered          card: a Read (to the end — not if `limit` is shorter than the card) · `cat` · a Read of a file at that card's path
#                    (= native load). Skill: a Skill tool call · the user's `/skill` command
# **Each item blocks only once per session** — a subagent reads in its own transcript, which may not show in the main record,
# and blocking twice on the same item would loop forever. From the second time it is a notice.
# **Undecidable** (no transcript · jq · root) does not block and only emits a notice (harness-change "three states").
# Known limit — a file written by a script (python · node) has a target that cannot be read from the command, so it is not caught.
_globs_ere() {   # stdin: one glob per line → ERE `^(…|…)$` (empty string if none)
  sed -E -e 's/[].+^$()|\\[]/\\&/g' -e 's#\*\*/#@DS@#g' -e 's#\*\*#@DD@#g' -e 's#\*#[^/]*#g' -e 's#\?#[^/]#g' \
         -e 's#@DS@#(.*/)?#g' -e 's#@DD@#.*#g' -e 's#\{([^}]*)\}#(\1)#g' \
  | sed -E -e ':a' -e 's#\(([^()|\\]*),#(\1|#' -e 'ta' \
  | paste -sd '|' - | sed -E 's#^(.+)$#^(\1)$#'
}
_card_re() {   # $1 card → the ERE of its `paths:`. Empty string if there is no paths (always loaded)
  awk 'NR==1 && $0!="---" {exit} NR==1 {next} /^---[[:space:]]*$/ {exit}
       /^[[:space:]]*-[[:space:]]/ {sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/["\047]/,""); print}' "$1" 2>/dev/null | _globs_ere
}
_session_reads() {   # $1 transcript → since the last compaction, "R<TAB>path<TAB>limit" · "B<TAB>command" · "S<TAB>skill"
  # From the shared transcript index (common.sh): the K lines are what this function's own jq pass printed, line for line —
  # including the `fromjson?` tolerance of a line jq cannot parse (a lone surrogate `\ud83d`, a truncated last line: consumer report N1).
  # Only the appended tail of the transcript is parsed (consumer report B7 · E3: ~2 s per call on a 230 MB transcript).
  # The old pass exited with jq's status, and this hook died with it, when the last transcript line made the program fail
  # (an unreadable transcript: 2); that status is kept so the verdict stays the same.
  local m c kc kv
  orangekit_transcript_index "$1" "$F_SID" || return
  awk 'substr($0, 1, 2) == "K\t" { l = substr($0, 3); if (l == "C") { n = 0; next } a[++n] = l }
       END { for (i = 1; i <= n; i++) print a[i] }' "$ORANGEKIT_TI"
  IFS=' ' read -r m c kc kv _ < "$ORANGEKIT_TI" || true
  [ "$kv" != 1 ] || return 5
}
_has_test_runner() {   # routing P4's "a repo that has a test runner"
  local r="$ORANGEKIT_ROOT" t
  if [ -f "$r/package.json" ] && command -v jq >/dev/null 2>&1; then
    t=$(jq -r '.scripts.test // empty' "$r/package.json" 2>/dev/null || true)   # an invalid package.json is "no runner", not a hook error
    [ -n "$t" ] && [[ "$t" != *"no test specified"* ]] && return 0
  fi
  for t in pytest.ini conftest.py go.mod Cargo.toml; do [ -f "$r/$t" ] && return 0; done
  [ -f "$r/pyproject.toml" ] && grep -q 'pytest' "$r/pyproject.toml" 2>/dev/null && return 0
  ls "$r"/vitest.config.* "$r"/jest.config.* >/dev/null 2>&1 && return 0
  return 1
}
_bash_targets() {   # $1 command → the file paths it writes (one per line). Heredoc bodies · /dev/* · variable or substitution paths are left out
  local t
  t=$(printf '%s\n' "$1" | awk '
      hd != "" { x=$0; sub(/^[\t ]+/, "", x); if (x == hd) hd = ""; next }
      { print
        if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
          hd = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*["\047]?/, "", hd) } }' \
      | sed -E 's/[0-9]*>{1,2}[[:space:]]*\/dev\/null//g; s/&>[[:space:]]*\/dev\/null//g; s/[0-9]*>&[0-9]+//g')
  { grep <<<"$t" -oE '(^|[^-<>=0-9A-Za-z_])>{1,2}[[:space:]]*[^[:space:];&|<>()]+' | sed -E 's/^.?>{1,2}[[:space:]]*//' || true
    grep <<<"$t" -oE '(^|[;&|[:space:]])tee([[:space:]]+-a)?[[:space:]]+[^-[:space:];&|<>()][^[:space:];&|<>()]*' | awk '{print $NF}' || true
    grep <<<"$t" -oE "(^|[;&|[:space:]])sed[[:space:]]+(-[A-Za-z]*i[^[:space:]]*|--in-place[^[:space:]]*)([[:space:]]+(''|\"\"))?([[:space:]]+-e)?[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:]]+)[[:space:]]+[^-[:space:];&|<>()][^[:space:];&|<>()]*" | awk '{print $NF}' || true
  } | sed -E "s/^[\"']//; s/[\"']$//" | { grep -vE '^(/dev/|&)|[$`~*]' || true; } | sort -u
}
_gate_rel() {   # $1 path (absolute or relative) $2 base directory → the project-relative path, or an empty string if outside
  local p="$1"
  case "$p" in /*|[A-Za-z]:/*) ;; *) p="${2:-$ORANGEKIT_ROOT}/${p#./}" ;; esac   # C:/… is absolute too (Windows)
  case "$p" in "$ORANGEKIT_ROOT"/*) printf '%s' "${p#"$ORANGEKIT_ROOT"/}" ;; esac
}
_norm_v() {   # $1 variable  $2 absolute path → the path with `.` and `..` segments folded, no fork
  local s segs=() out=() lead=""
  case "$2" in [A-Za-z]:/*) lead=${2%%/*} ;; esac
  IFS=/ read -r -d '' -a segs <<<"${2#"$lead"}" || true   # read, not `for s in $p`: a `*` in a segment must not glob
  [ ${#segs[@]} -gt 0 ] && segs[${#segs[@]}-1]=${segs[${#segs[@]}-1]%$'\n'}   # the here-string's trailing newline
  for s in ${segs[@]+"${segs[@]}"}; do
    case "$s" in ''|.) ;; ..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;; *) out+=("$s") ;; esac
  done
  local IFS=/; printf -v "$1" '%s/%s' "$lead" "${out[*]-}"
}
_cd_base_v() {   # $1 variable  $2 command text before a target  $3 start directory → the directory after its last `cd`/`pushd`;
  # returns 1 when that `cd` cannot be followed (no argument · `-` · `~` · a variable or substitution) — skip rather than guess (B12)
  local w base="$3" next=0 arg words=()
  read -r -d '' -a words <<<"${2//[;&|()]/ ; }" || true   # read, not `for w in $cmd`: no glob expansion
  for w in ${words[@]+"${words[@]}"}; do
    if [ "$next" = 1 ]; then
      next=0; [ "$w" = ";" ] && return 1
      arg=${w#[\"\']}; arg=${arg%[\"\']}
      case "$arg" in -|*[\$\`~]*) return 1 ;; esac
      orangekit_slashes_v arg "$arg"
      case "$arg" in /*|[A-Za-z]:/*) base=$arg ;; *) base="$base/$arg" ;; esac
    elif [ "$w" = cd ] || [ "$w" = pushd ]; then next=1; fi
  done
  [ "$next" = 1 ] && return 1
  printf -v "$1" '%s' "$base"
}
# The owner table — every card's and skill node's path ERE, built **once per hook call** by one pass over all cards and one jq
# over the graph. It used to be re-derived per card and per skill node for every write target (~7 processes a card, ~10 a node:
# 122 processes for one owned Write with 11 cards). The transformations are _card_re's and _globs_ere's, unchanged; the
# table is used only for plain input (every card readable, every skill id/when/glob a one-line string, the graph a list of
# objects). Anything else leaves _OT_STATE=slow and _owners_of takes its per-card path below — the old code, unchanged.
_OT_STATE=""; _OT_CN=(); _OT_CR=(); _OT_SN=(); _OT_SW=(); _OT_SR=(); _OT_SU=()
_globs_lines() {   # stdin: globs in groups, each ended by a line "\001" → one ERE per group, exactly what _globs_ere prints for it
  sed -E -e 's/[].+^$()|\\[]/\\&/g' -e 's#\*\*/#@DS@#g' -e 's#\*\*#@DD@#g' -e 's#\*#[^/]*#g' -e 's#\?#[^/]#g' \
         -e 's#@DS@#(.*/)?#g' -e 's#@DD@#.*#g' -e 's#\{([^}]*)\}#(\1)#g' \
  | sed -E -e ':a' -e 's#\(([^()|\\]*),#(\1|#' -e 'ta' \
  | awk '$0 == "\001" { print j; j = ""; f = 0; next } { j = j (f++ ? "|" : "") $0 }' \
  | sed -E 's#^(.+)$#^(\1)$#'
}
_owner_table() {
  [ -z "$_OT_STATE" ] || return 0
  _OT_STATE=slow
  [ -n "$ORANGEKIT_ROOT" ] || return 0
  local c k=0 nc=0 ns=0 sk="" out line graph
  local -a files=() lines=() sn=() sw=()
  if [ -d "$ORANGEKIT_ROOT/.claude/rules" ]; then
    for c in "$ORANGEKIT_ROOT"/.claude/rules/*.md; do
      [ -f "$c" ] || continue
      [ -r "$c" ] || return 0
      [ -s "$c" ] && files+=("$c")   # an empty card has no `paths:` — _card_re gives "" and the card is skipped
    done
  fi
  graph="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/workflow.graph.json"
  if [ -f "$graph" ] && command -v jq >/dev/null 2>&1; then
    sk=$(jq -r 'if (.nodes | type) != "array" or any(.nodes[]; type != "object") then "OKSLOW" else
          . as $g | [.nodes[] | select(.kind=="skill" and .beforeWrite)] as $sk
          | if any($sk[]; (.id | type) != "string" or .id == "" or (.id | test("[\t\n]"))
                         or ((.beforeWrite.when // "") | type) != "string" or ((.beforeWrite.when // "") | test("[\t\n]"))) then "OKSLOW"
            else [$sk[] | .id as $n | {n: $n, w: (.beforeWrite.when // ""),
                   p: [$g.nodes[] | select(.id == $n) | .beforeWrite.paths[]?], u: [$g.nodes[] | select(.id == $n) | .beforeWrite.unless[]?]}] as $x
              | if any($x[]; any((.p + .u)[]; type != "string" or test("[\n\u0000\u0001\u0002]"))) then "OKSLOW"
                else ($x[] | "\(.n)\t\(.w)"), "\u0002", ($x[] | (.p[], "\u0001", .u[], "\u0001")) end end end' "$graph" 2>/dev/null) || return 0
    [ "$sk" != OKSLOW ] || return 0
    while IFS= read -r line; do
      [ "$line" = $'\002' ] && break
      [ -n "$line" ] || continue
      sn[ns]=${line%%$'\t'*}; sw[ns]=${line#*$'\t'}; ns=$((ns + 1))
    done <<< "$sk"
    case "$sk" in *$'\002'*) sk=${sk#*$'\002'}; sk=${sk#$'\n'} ;; *) sk="" ;; esac
  fi
  [ ${#files[@]} -gt 0 ] || [ "$ns" -gt 0 ] || { _OT_STATE=fast; return 0; }
  out=$({ if [ ${#files[@]} -gt 0 ]; then
            awk 'FNR == 1 { if (NR > 1) print "\001"; d = ($0 != "---"); next }
                 d { next }
                 /^---[[:space:]]*$/ { d = 1; next }
                 /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/["\047]/,""); print }
                 END { if (NR > 0) print "\001" }' "${files[@]}"
          fi
          [ -z "$sk" ] || printf '%s\n' "$sk"; } | _globs_lines; printf '@@end\n') || return 0
  while IFS= read -r line; do lines[k]=$line; k=$((k + 1)); done <<< "$out"
  [ "$k" -eq $(( ${#files[@]} + 2 * ns + 1 )) ] && [ "${lines[k - 1]}" = "@@end" ] || return 0
  k=0
  while [ "$k" -lt ${#files[@]} ]; do
    if [ -n "${lines[k]}" ]; then _OT_CN[nc]=${files[k]##*/}; _OT_CR[nc]=${lines[k]}; nc=$((nc + 1)); fi
    k=$((k + 1))
  done
  c=0
  while [ "$c" -lt "$ns" ]; do
    _OT_SN[c]=${sn[c]}; _OT_SW[c]=${sw[c]}; _OT_SR[c]=${lines[k]}; _OT_SU[c]=${lines[k + 1]}
    k=$((k + 2)); c=$((c + 1))
  done
  _OT_STATE=fast
}
_owners_of() {   # $1 project-relative path  $2 1=new file 0=existing → lines of "card<TAB>name<TAB>ERE" · "skill<TAB>name<TAB>"
  local rel="$1" isnew="$2" c re n un when
  [ -n "$rel" ] && [ -n "$ORANGEKIT_ROOT" ] || return 0
  if [ "$_OT_STATE" = fast ]; then
    c=0
    while [ "$c" -lt ${#_OT_CN[@]} ]; do
      re=${_OT_CR[c]}; [[ "$rel" =~ $re ]] && printf 'card\t%s\t%s\n' "${_OT_CN[c]}" "$re"
      c=$((c + 1))
    done
    if [ "$isnew" = 1 ]; then
      c=0
      while [ "$c" -lt ${#_OT_SN[@]} ]; do
        n=${_OT_SN[c]}; when=${_OT_SW[c]}; re=${_OT_SR[c]}; un=${_OT_SU[c]}; c=$((c + 1))
        [ -n "$re" ] && [[ "$rel" =~ $re ]] || continue
        [ -n "$un" ] && [[ "$rel" =~ $un ]] && continue
        [ "$when" = "test-runner" ] && ! _has_test_runner && continue
        printf 'skill\t%s\t\n' "$n"
      done
    fi
    return 0
  fi
  if [ -d "$ORANGEKIT_ROOT/.claude/rules" ]; then
    for c in "$ORANGEKIT_ROOT"/.claude/rules/*.md; do
      [ -f "$c" ] || continue
      re=$(_card_re "$c"); [ -n "$re" ] || continue
      [[ "$rel" =~ $re ]] && printf 'card\t%s\t%s\n' "${c##*/}" "$re"
    done
  fi
  local graph="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/workflow.graph.json"
  if [ "$isnew" = 1 ] && [ -f "$graph" ] && command -v jq >/dev/null 2>&1; then
    while IFS=$'\t' read -r n when; do
      [ -n "$n" ] || continue
      re=$(jq -r --arg n "$n" '.nodes[] | select(.id==$n) | .beforeWrite.paths[]?' "$graph" | _globs_ere)
      un=$(jq -r --arg n "$n" '.nodes[] | select(.id==$n) | .beforeWrite.unless[]?' "$graph" | _globs_ere)
      [ -n "$re" ] && [[ "$rel" =~ $re ]] || continue
      [ -n "$un" ] && [[ "$rel" =~ $un ]] && continue
      [ "$when" = "test-runner" ] && ! _has_test_runner && continue
      printf 'skill\t%s\t\n' "$n"
    done < <(jq -r '.nodes[]? | select(.kind=="skill" and .beforeWrite) | "\(.id)\t\(.beforeWrite.when // "")"' "$graph" 2>/dev/null)
  fi
  return 0
}
# = `printf '%s' "$2" | tr -cd 'A-Za-z0-9._-'` into the variable $1 — without the fork when there is nothing to delete (a UUID)
_clean_sid() {
  case "$2" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) eval "$1=\$(printf '%s' \"\$2\" | tr -cd 'A-Za-z0-9._-')" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}
KG_NOTES=""
_kg_note() { KG_NOTES+="${KG_NOTES:+$'\n\n'}$1"; }   # collect, do not print one JSON per target — hook stdout must be a single JSON object
_kg_flush() { [ -z "$KG_NOTES" ] || orangekit_emit_context PreToolUse "$KG_NOTES"; KG_NOTES=""; }
_knowledge_gate() {   # $1 project-relative path  $2 1=new file 0=existing  → exit 2 if it blocks
  local rel="$1" isnew="$2" n re names=() kinds=() res=() unread=() again=() undec=() _k _v _l seen _ok _on _or
  _owner_table
  while IFS=$'\t' read -r _ok _on _or; do
    [ -n "$_ok" ] || continue
    kinds+=("$_ok"); names+=("$_on"); res+=("$_or")
  done < <(_owners_of "$rel" "$isnew")
  [ ${#names[@]} -gt 0 ] || return 0
  local tp sid state list
  tp=$F_TP; _clean_sid sid "$F_SID"
  # Undecidable — no transcript · no jq · or the time budget is spent (an advisory gate must not run the hook into its 15 s timeout)
  if [ -z "$tp" ] || [ ! -f "$tp" ] || ! command -v jq >/dev/null 2>&1 || [ "$SECONDS" -ge "$KG_DEADLINE" ]; then
    list=$(for i in "${!names[@]}"; do [ "${kinds[$i]}" = card ] && printf '  - Read .claude/rules/%s\n' "${names[$i]}" || printf '  - skill /%s\n' "${names[$i]}"; done)
    _kg_note "Load these before writing \`$rel\` (it cannot be determined whether they were loaded in this session, so this does not block):
$list"
    return 0
  fi
  # Read the transcript once per hook call — re-reading it for every write target costs ~2 s per target in a long session (consumer report B7)
  if [ -z "${KG_READS_DONE:-}" ]; then KG_READS=$(_session_reads "$tp"); KG_READS_DONE=1; fi
  local reads=$KG_READS
  state="$(orangekit_state_dir)/knowledge-gate.${sid:-nosession}"
  for i in "${!names[@]}"; do
    n=${names[$i]}; re=${res[$i]}; seen=0
    # Whether a card or skill was loaded does not depend on the target — judge each once per hook call. Re-judging it per target
    # walked every Read/Bash/Skill line once per card per target: 1,800 calls · 3 cards · 8 targets took 19 s (B7 residual)
    case "$KG_SEEN" in
      *"|${kinds[$i]}:$n=1|"*) continue ;;
      *"|${kinds[$i]}:$n=0|"*) ;;
      *)
    while IFS=$'\t' read -r _k _v _l; do
      [ "$SECONDS" -lt "$KG_DEADLINE" ] || { seen=2; break; }   # budget spent mid-scan → undecidable for this item
      if [ "${kinds[$i]}" = skill ]; then
        [ "$_k" = S ] && { [ "$_v" = "$n" ] || [[ "$_v" == *:"$n" ]]; } && { seen=1; break; }
        continue
      fi
      case "$_v" in [A-Za-z]:\\*) _v=${_v//\\//} ;; esac   # a Windows Read path, same form as ORANGEKIT_ROOT
      case "$_k" in
        R) if [[ "$_v" == */.claude/rules/"$n" ]]; then
             if [ -z "$_l" ] || [ "$(orangekit_num "$_l")" -ge "$(orangekit_count_lines "$_v")" ]; then seen=1; break; fi
             continue
           fi
           _v=${_v#"$ORANGEKIT_ROOT"/}
           [[ "$_v" != /* ]] && [[ "$_v" =~ $re ]] && { seen=1; break; } ;;
        B) [[ "$_v" =~ (^|[\;\&\|[:space:]])cat[[:space:]][^\;\&\|]*\.claude/rules/${n//./\\.} ]] && { seen=1; break; } ;;
      esac
    done <<< "$reads"
    [ "$seen" -eq 2 ] || KG_SEEN="$KG_SEEN|${kinds[$i]}:$n=$seen|" ;;
    esac
    [ "$seen" -eq 2 ] && { undec+=("$i"); continue; }
    [ "$seen" -eq 1 ] && continue
    if [ -f "$state" ] && grep -qxF "${kinds[$i]}:$n" "$state"; then again+=("$i"); else unread+=("$i"); fi
  done
  if [ ${#unread[@]} -gt 0 ]; then
    mkdir -p "$(dirname "$state")" 2>/dev/null && for i in "${unread[@]}"; do printf '%s:%s\n' "${kinds[$i]}" "${names[$i]}"; done >> "$state"
    printf '⏸ Load these first: `%s` is subject to the rules and procedures below, but they have not been loaded in this session yet.\n' "$rel" >&2
    for i in "${unread[@]}"; do
      if [ "${kinds[$i]}" = card ]; then printf '  - Read to the end with the Read tool: .claude/rules/%s\n' "${names[$i]}" >&2
      else printf '  - Call with the Skill tool: /%s\n' "${names[$i]}" >&2; fi
    done
    printf '\nA rule card loads only when a file is *read*, and a skill applies only when it is *called* — writing from judgement in your head alone skips both.\n' >&2
    printf 'Load the items above, then redo this work to that standard. (Each item stops you only once per session)\n' >&2
    printf 'To avoid this stop next time: read the cards listed under "Read first" in the plan (tasks.md) slice when you start the slice.\n' >&2
    exit 2
  fi
  if [ ${#again[@]} -gt 0 ]; then
    list=$(for i in "${again[@]}"; do printf '  - %s\n' "${names[$i]}"; done)
    _kg_note "You are writing \`$rel\` with rules or skills still not loaded — this was announced once in this session, so it does not block:
$list"
  fi
  if [ ${#undec[@]} -gt 0 ]; then
    list=$(for i in "${undec[@]}"; do [ "${kinds[$i]}" = card ] && printf '  - Read .claude/rules/%s\n' "${names[$i]}" || printf '  - skill /%s\n' "${names[$i]}"; done)
    _kg_note "Load these before writing \`$rel\` (it cannot be determined whether they were loaded in this session, so this does not block):
$list"
  fi
  return 0
}
if [ "${1:-}" = "--owning" ]; then
  shift
  [ -n "$ORANGEKIT_ROOT" ] || { printf 'cannot determine: the project root was not found\n' >&2; exit 0; }
  _owner_table
  for _op in "$@"; do
    _orel=$(_gate_rel "$_op" "$PWD")
    [ -n "$_orel" ] || continue
    _oe=1; [ -e "$ORANGEKIT_ROOT/$_orel" ] && _oe=0
    _owners_of "$_orel" "$_oe" | awk -F'\t' -v p="$_orel" '{ if ($1 == "card") print p "\tRead .claude/rules/" $2; else print p "\t/" $2 }'
  done
  exit 0
fi
# **Runs last** (`_kg_done`), after the secret scan and the destructive gate. It is advisory and the slowest part of the hook
# (a transcript pass), and it used to run first: a long transcript ran the hook into its 15 s timeout, or one unparseable
# transcript line killed it, and a `DROP TABLE` or a hardcoded key in the same call was never judged (consumer report B7 · N1).
# A blocking gate must never depend on an advisory one finishing.
KG_SEEN=""; case "${ORANGEKIT_KG_BUDGET:-8}" in ''|*[!0123456789]*) KG_DEADLINE=$((SECONDS + $(orangekit_num "${ORANGEKIT_KG_BUDGET:-8}"))) ;; *) _kgb=${ORANGEKIT_KG_BUDGET:-8}; KG_DEADLINE=$((SECONDS + ${_kgb:0:18})) ;; esac   # = orangekit_num for plain digits, without its fork   # seconds of the 15 s hook timeout, counted from hook start; past it → undecidable notice
_kg_run() {
  if [ "$TOOL_NAME" = "Write" ] && [ -n "$FILE_PATH" ] && [ ! -e "$FILE_PATH" ]; then
    _knowledge_gate "$(_gate_rel "$FILE_PATH" "$ORANGEKIT_ROOT")" 1
    _kg_flush
  fi
  # _bash_targets finds a target only after a `>`, `tee` or `sed` — the text it strips first always holds a `>` itself, so a
  # command with none of the three has no target, and the ~10 processes of the extraction are skipped
  case "$F_CMD" in *'>'*|*tee*|*sed*) ;; *) return 0 ;; esac
  if [ "$TOOL_NAME" = "Bash" ] && [ -n "$ORANGEKIT_ROOT" ]; then
    local _gcwd _gcmd _gt _gabs _gbase
    # cwd in the same form as ORANGEKIT_ROOT — on Windows it arrives as C:\… and a target under it never matched the root (S1)
    orangekit_slashes_v _gcwd "$F_CWD"; _gcmd=$F_CMD
    while IFS= read -r _gt; do
      [ -n "$_gt" ] || continue
      # a relative target resolves against the last `cd` before it in the same command, not the session cwd (B12)
      case "$_gt" in
        /*|[A-Za-z]:/*) _gabs=$_gt ;;
        *) _cd_base_v _gbase "${_gcmd%%"$_gt"*}" "${_gcwd:-$ORANGEKIT_ROOT}" || continue
           _norm_v _gabs "$_gbase/${_gt#./}" ;;
      esac
      if [ -e "$_gabs" ]; then _knowledge_gate "$(_gate_rel "$_gabs")" 0; else _knowledge_gate "$(_gate_rel "$_gabs")" 1; fi
    done < <(_bash_targets "$_gcmd")
    _kg_flush
  fi
  return 0
}
_kg_done() { _kg_run; exit 0; }   # every "nothing to block" exit below goes through here

# ══════════════════════════════════════════════════════════════════════
# Destructive command gate
# ══════════════════════════════════════════════════════════════════════
#
# **A different axis** from the secret check. Secrets look at "a value is on the wrong side";
# this gate looks at "something irreversible is about to happen".
# Reversibility classification (T0) judges by the **edit path**, so destruction that touches no file at all,
# like `DROP TABLE`, is fundamentally beyond its reach — that blind spot is what this is.
#
# A block (exit 2) is **only for what is effectively irreversible**. `rm -rf` · `reset --hard` ·
# `clean -fdx` stay as warnings: a false positive makes the user turn the hook off, and a hook that is off
# blocks nothing. If the same item produces 2 or more false positives, do not widen the rule —
# **narrow the condition, or demote that item to a warning** (the false-positive discipline in rules/lessons.md).
#
# **Three states.** When the target branch of a force push cannot be determined (outside a repo · detached · 0 commits)
# it does not block: it reports "undecidable" explicitly and lets it through.
#
# Known limit — when the destructive statement sits **inside a file**, as in `cat x.sql | psql`, it does not appear
# in the command string and is not caught. The hook only blocks the common paths; the rest is handled by
# reversibility classification and user confirmation. Growing the regex to widen this limit grows false positives first.

dblock() {   # $1 what  $2 impact  $3 safe alternative
  printf '❌ Blocked: %s\n\n' "$1" >&2
  printf 'Impact: %s\n' "$2" >&2
  printf 'Safe alternative: %s\n\n' "$3" >&2
  printf 'If this command is really needed, present the impact and the rollback procedure to the user and get confirmation first.\n' >&2
  exit 2
}
dwarn() { printf '⚠️  %s\n     %s\n' "$1" "$2" >&2; }

# ── Process budget: the same verdicts with fewer forks ───────────────
# Every Bash call runs this gate, and on Windows each fork + exec costs ~30–50 ms (CI: 2.5–3.1 s per call on Git Bash, 20× Linux).
# The helpers below skip work only where the skipped step **provably** returns its "nothing" answer, and only for _plain text:
# pure ASCII with no \001, at most 1 KB. Anything else takes the old path — macOS awk aborts on invalid UTF-8 (a crash the verdict
# depends on), GNU `grep -i` folds non-ASCII letters (ſ matches s), the awk helpers split records on \001, and bash 3.2's
# ${x//…/…} is quadratic (an 8 KB heredoc took 22 s), so a long command keeps its single awk/grep.
_plain() { [ "${#1}" -le 1024 ] || return 1; local LC_ALL=C; case "$1" in *[![:ascii:]]*|*$'\001'*) return 1 ;; esac; return 0; }
# = `grep <<<"$2" -Eq "$1"`; for one-line _plain text the same ERE in bash (C locale, so ranges are ASCII): one exec less
_grepq() {
  case "$2" in *$'\n'*) ;; *) if _plain "$2"; then local LC_ALL=C; [[ "$2" =~ $1 ]]; return; fi ;; esac
  grep <<<"$2" -Eq "$1"
}
_noquotes() { local LC_ALL=C; _NQ=${1//\"/}; _NQ=${_NQ//\'/}; }   # _plain text with every " and ' removed → _NQ

# First token of the command (leading environment variable assignments are skipped) → _FT_OUT, memoised on the last input
# (three judgements per segment ask for it). For _plain text the same rule in bash: line 1, leading space stripped, then every
# `NAME=value␠` prefix (sed's `(…=[^[:space:]]*[[:space:]]+)*` can only end at the first space after the `=`), then up to the first
# space or tab (awk's `$1`). Other text: the original sed | awk
_FT_IN=""; _FT_OUT=""; _FT_SET=""
_first_tok_v() {
  [ "$_FT_SET" = 1 ] && [ "$_FT_IN" = "$1" ] && return 0
  local l
  if _plain "$1"; then
    l=${1%%$'\n'*}
    l=${l#"${l%%[![:space:]]*}"}
    while [[ "$l" =~ ^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]*[[:space:]]+ ]]; do l=${l:${#BASH_REMATCH[0]}}; done
    _FT_OUT=${l%%[$' \t']*}
  else
    _FT_OUT=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk 'NR == 1 {print $1}')
  fi
  _FT_IN=$1; _FT_SET=1
}
_first_tok() { _first_tok_v "$1"; printf '%s' "$_FT_OUT"; }

# Is it an investigation/search command? Blocking `grep 'DROP TABLE' supabase/migrations/` is itself the false positive.
#
# The order of judgement matters. Filtering first on "if psql/supabase appears anywhere in the command it is not a read"
# mistakes **a name inside a path** (`supabase/migrations/`) for a client.
# So a read is established by the first token first, and the read verdict is reversed only when a client appears
# **in command position after a pipe** (`cat x.sql | psql`).
_readonly_cmd() {
  _first_tok_v "$1"
  case "$_FT_OUT" in
    grep|egrep|fgrep|rg|ag|cat|head|tail|less|more|ls|find|wc|awk|diff|jq|file|stat|which|echo|printf) ;;
    git) _grepq '^[[:space:]]*git[[:space:]]+(log|diff|show|grep|blame|status|branch|remote|config|rev-parse|describe|ls-files)([^a-zA-Z-]|$)' "$1" || return 1 ;;
    *) return 1 ;;
  esac
  # Does a read command flow into a destructive executor — then it is not a read
  _pipes_to_db_client "$1" && return 1
  return 0
}

# Does a DB client appear in **command position**? A name inside a path (`supabase/migrations/`) is not counted,
# so only what follows a pipe, a separator, or **a command substitution** is looked at. Three places use it (_readonly_cmd · _feeds_db_client ·
# _message_cmd) — a copy gets fixed on one side only, and that divergence has already become a defect in this file once.
#
# **A command substitution (`$(…)` · backtick) is command position.** Its absence made the E-22 commit-message false-positive repair
# exempt the execution path too — measured (this round): `git commit -m "$(psql -d app -c "DROP TABLE users")"` and
# `gh pr create --body "$(psql …)"` passed with exit 0, while the same input against the previous version gave
# exit 2. That is, it was a **regression** created by a false-positive repair. `$(` is a place the shell must execute, so
# there is no room to confuse it with description — a bare `(`, on the other hand, is not included: prose parentheses such as
# `git commit -m "docs: (psql) explanation"` would be mistaken for execution and become a new false positive. Narrow the hole in the exemption without adding false positives.
_pipes_to_db_client() {
  # Command position needs one of `$(` ` | ; & and a client name in some ASCII casing — without them the grep cannot match
  _plain "$1" && case "$1" in *'$('*|*'`'*|*'|'*|*';'*|*'&'*) ;; *) return 1 ;; esac
  _plain "$1" && case "$1" in *[Pp][Ss][Qq][Ll]*|*[Mm][Yy][Ss][Qq][Ll]*|*[Mm][Aa][Rr][Ii][Aa][Dd][Bb]*|*[Ss][Qq][Ll][Ii][Tt][Ee]3*|*[Mm][Oo][Nn][Gg][Oo]*|\
                              *[Ss][Uu][Pp][Aa][Bb][Aa][Ss][Ee]*|*[Pp][Rr][Ii][Ss][Mm][Aa]*|*[Dd][Rr][Ii][Zz][Zz][Ll][Ee]-[Kk][Ii][Tt]*|\
                              *[Aa][Ll][Ee][Mm][Bb][Ii][Cc]*|*[Ss][Qq][Ll][Cc][Mm][Dd]*) ;; *) return 1 ;; esac
  grep <<<"$1" -Eqi '(\$\(|`|[|;&])[[:space:]]*(sudo[[:space:]]+)?(npx[[:space:]]+)?(psql|mysql|mariadb|sqlite3|mongosh?|supabase|prisma|drizzle-kit|alembic|sqlcmd)([[:space:]]|$)'
}

# Does a heredoc feed a DB client — then the body is not data but **SQL that will be executed**.
_feeds_db_client() {
  _first_tok_v "$1"
  case "$_FT_OUT" in
    psql|mysql|mariadb|sqlite3|mongo|mongosh|supabase|prisma|drizzle-kit|alembic|sqlcmd) return 0 ;;
  esac
  _pipes_to_db_client "$1"
}

# A heredoc body is **data, not a command** — a payload flowing into a file or an interpreter.
# So it is stripped **before** the destruction verdict. Only the body is stripped; a command outside the heredoc
# (`... PY && psql -c '...'`) is still judged.
#
# How it arose (measured 2026-09-08): a `python3 - <<'PY' ... PY` that writes a destructive DDL name into a document
# as an example was blocked. `_authoring_cmd` **already held the right judgement** — "a command that writes is not an
# execution" — but that verdict had been narrowed to `cat|tee|printf|echo` alone.
# The cause runs two layers deep — ⓐ **enumerating authoring tools is guaranteed to fall behind** (python · node · perl ·
# ruby · sed -i · jq > file …) ⓑ and more deeply, the gate was **reading the payload, not the command.**
# ⓑ is the real cause, so that is what is fixed here. Growing the tool list only postpones ⓐ.
#
# **A heredoc handed to a DB client is not stripped** — `psql <<'SQL'` is a heredoc but it is execution.
# That verdict is made from **the line that opens the heredoc** alone (which is why `feeds_db` in the awk below is not
# a copy of _pipes_to_db_client — it is a different question, "what receives the heredoc", and it does not take the command-substitution extension:
# `$(psql <<'SQL')` is not a line that opens a heredoc). Searching the whole command for `; psql` mistakes a string inside a heredoc body
# written to a file (a test matrix, an example in a document) for execution — measured (evaluation v6 · E-44):
# `cat > matrix.sh <<'EOF' … 'x; psql -c "DROP TABLE t"' … EOF` was blocked with exit 2.
_strip_heredoc_bodies() {
  printf '%s' "$1" | awk '
    function feeds_db(line) {
      return (line ~ /^[ \t]*([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*(sudo[ \t]+)?(npx[ \t]+)?(psql|mysql|mariadb|sqlite3|mongo|mongosh|supabase|prisma|drizzle-kit|alembic|sqlcmd)([ \t]|$)/ \
           || line ~ /[|;&][ \t]*(sudo[ \t]+)?(npx[ \t]+)?(psql|mysql|mariadb|sqlite3|mongo|mongosh|supabase|prisma|drizzle-kit|alembic|sqlcmd)([ \t]|$)/)
    }
    # What receives the heredoc is **the segment containing `<<`, not the whole line**. Looking at the whole line, in
    # `psql … -c "select …"; python3 - <<EOF` the psql in the earlier segment leaves the python body
    # as SQL — measured (benchmark B2/run1 step 1): the string `BEFORE TRUNCATE ON point_entries` in a python body that edits
    # a migration was blocked as TRUNCATE. Split on `;` `&&` `||` outside quotes
    # (a pipe is not split — `cat <<EOF | psql` is a heredoc going into psql).
    function seg_of(line, st, ln,    i, c, q, s, e) {
      q=""; s=1
      for (i=1; i<st; i++) { c=substr(line,i,1)
        if (q!="") { if (c==q) q=""; continue }
        if (c=="\047" || c=="\"") { q=c; continue }
        if (c==";") s=i+1
        else if ((c=="&" || c=="|") && substr(line,i+1,1)==c) { s=i+2; i++ } }
      e=length(line); q=""
      for (i=st+ln; i<=length(line); i++) { c=substr(line,i,1)
        if (q!="") { if (c==q) q=""; continue }
        if (c=="\047" || c=="\"") { q=c; continue }
        if (c==";" || ((c=="&" || c=="|") && substr(line,i+1,1)==c)) { e=i-1; break } }
      return substr(line, s, e-s+1)
    }
    { if (inhd) { l=$0; if (dash) sub(/^[ \t]+/,"",l); if (l==delim) inhd=0; else if (keep) print; next }
      if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        # A `<<<` herestring is not a heredoc — if the preceding character is `<`, skip it
        if (RSTART==1 || substr($0,RSTART-1,1) != "<") {
          t=substr($0,RSTART,RLENGTH); dash=(substr(t,1,3)=="<<-")
          sub(/^<<-?[ \t]*/,"",t); gsub(/[\047"]/,"",t); delim=t; inhd=1
          keep=feeds_db(seg_of($0, RSTART, RLENGTH)) } }
      print }'
}

# A command that **writes** text to a file is not the execution of destruction.
# `cat > 0003_drop_legacy.sql <<'EOF' ... EOF` **authors** a migration, it does not
# execute one, and the same string shows up when writing fixtures, docs and tests.
# (The secret check runs the other way — writing a secret is itself the exposure, so that path stays watched.
#  In fact, while this gate was being built, the command writing its own fixture got blocked. That is why this function exists.)
# The verdict is not made from the heredoc alone: `psql <<'SQL'` is a heredoc but it is execution.
_authoring_cmd() {
  _first_tok_v "$1"
  case "$_FT_OUT" in
    cat|tee|printf|echo) if _plain "$1"; then case "$1" in *'>'*|*'<<'*) return 0 ;; esac
                         else grep <<<"$1" -Eq '(>|<<)' && return 0; fi ;;
  esac
  return 1
}

# A commit message, a PR title or a tag annotation **does not execute** SQL — DDL vocabulary in an argument is description.
# Measured (evaluation v6 · E-22): `git commit -m "fix: drop table legacy_users"` and
# `gh pr create --title "…drop table…"` were blocked with exit 2. A false positive that blocks a commit is the fastest way to make
# the user turn the hook off. The exemption is judged by **the first token** (not by string containment),
# and it is not granted when a DB client follows a pipe.
_message_cmd() {
  _first_tok_v "$1"
  case "$_FT_OUT" in
    git) _grepq '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+(commit|tag|notes|merge|revert|stash)([^a-zA-Z-]|$)' "$1" || return 1 ;;
    gh|glab) ;;
    *) return 1 ;;
  esac
  _pipes_to_db_client "$1" && return 1
  return 0
}

# Splits the command into **segments** (`;` `&&` `||` newline). In `git commit -m "…drop table…" && psql -c
# "DROP TABLE t"` the first half is description and the second is execution — as one string the two cannot be separated,
# so exempting leaks the second and not exempting makes the first a false positive. Judging per segment separates them.
# A pipe (`|`) does not split — `cat x.sql | psql` has to stay one segment for _pipes_to_db_client to see it.
_segments_v() { local LC_ALL=C t=${1//;/$'\n'}; t=${t//&&/$'\n'}; _SEGS=${t//||/$'\n'}; }   # _plain text → _SEGS (printf '%s\n' of it = _segments)
_segments() {
  # _plain text: the same three replacements in bash (the separators share no character, so one after another = awk's single gsub)
  if _plain "$1"; then _segments_v "$1"; printf '%s\n' "$_SEGS"; return 0; fi
  printf '%s\n' "$1" | awk '{ gsub(/;|&&|\|\|/, "\n"); print }'
}

# Is it a **single command that runs** this hook or doctor? Used only for the self-reference exemption of the secret scan.
# It used to exempt on containment of the string `*doctor.sh*`, which skipped the whole destruction gate —
# `bash scripts/doctor.sh --help; psql -c "DROP TABLE users"` was exit 0 (evaluation v6 · E-21).
# The exemption is judged by the first token, and is not granted when another command follows (`;` `&&` `||` `&`).
_self_ref_cmd() {
  # Both tokens it compares are substrings of the command — without either file name in it, the answer is no
  case "$1" in *doctor.sh*|*security-check.sh*) ;; *) _plain "$1" && return 1 ;; esac
  grep <<<"$1" -Eq '(;|&&|\|\||&[[:space:]]|&$)' && return 1
  local t1 t2
  t1=$(_first_tok "$1")
  t2=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk 'NR == 1 {print $2}')
  case "$t1" in
    */doctor.sh|*/security-check.sh|doctor.sh|security-check.sh) return 0 ;;
    bash|sh) case "$t2" in */doctor.sh|*/security-check.sh|doctor.sh|security-check.sh) return 0 ;; esac ;;
  esac
  return 1
}

# Is it a command that **writes to a file** — only these enter the secret scan.
# Treating every `>` as a write pulls `rg 'AKIA…' . 2>/dev/null` (a read-only investigation) into the scan and
# blocks it (evaluation v6 · E-23). Discarding or duplicating stderr/stdout (`2>/dev/null` `>&2` `&>/dev/null`),
# an arrow (`->`) and a comparison (`>=`) are not writes.
_writes_file() {
  local c
  # Both greps need `tee`, `dd` or a `>`; the sed only removes text that holds a `>` — without the three, no write
  _plain "$1" && case "$1" in *'>'*|*tee*|*dd*) ;; *) return 1 ;; esac
  c=$(printf '%s' "$1" | sed -E 's/[0-9]*>{1,2}[[:space:]]*\/dev\/null//g; s/&>[[:space:]]*\/dev\/null//g; s/[0-9]*>&[0-9]+//g')
  grep <<<"$c" -Eq '(^|[^0-9A-Za-z_])(tee|dd)([^0-9A-Za-z_]|$)' && return 0
  grep <<<"$c" -Eq '(^|[^-<>=])>{1,2}[[:space:]]*[^=&[:space:]]' && return 0
  return 1
}

# ── Scratch-DB drop exemption — only when proven ─────────────────────
#
# Blocking `DROP DATABASE` regardless of the name made commands that delete **scratch DBs the agent created for verification**
# get blocked over and over — measured (benchmark B2, 6 runs): all 17 DB blocks were scratch DBs. 13 were
# the re-create-in-the-same-command form (`DROP DATABASE IF EXISTS app_fresh` + `CREATE DATABASE
# app_fresh` — running the migrations from scratch on an empty DB to verify), and 4 were cleanup of a DB created earlier.
# The blocked agent went around it by creating a new one with a timestamp on the name, and only DBs that could not be deleted piled up —
# 0 protection, only friction left. The real danger (deleting a project DB or a system DB) was not a single case.
#
# **The exemption is given only when both are proven** (the same discipline as the `.env` exemption below — if undecidable, no
# exemption is given and today's block stands. It does not newly block; it just does not grant a new exception):
#   ① the target is not the project DB — it is absent from the connection URLs and `PGDATABASE`-style values in the environment variables and the
#      project root `.env*`, and it is not a system DB either. **If none can be found it is undecidable** → no exemption
#   ② the target is a DB the agent created — the same command runs `CREATE DATABASE <the same name>`,
#      or it is a name created in a command this hook let through earlier (`<state>/created-dbs`)
# Why ② cannot stand in for ①: resetting a dev DB (`DROP … app; CREATE … app`) satisfies ② but is
# the same thing as `prisma migrate reset`, so it is blocked. Why ① cannot stand in for ②: it is common for one local Postgres to hold
# several projects' DBs, and someone else's project DB satisfies ①.
# If the name is a variable or a substitution, it is judged **by expanding it to a value within the same command** (`_expand_shell_literals`: literal loops · assignments). If it cannot be expanded it is undecidable → no exemption.
# `DROP TABLE` is exempted not by name proof but only by **measurement** (`_scratch_tables_ok`). `DROP SCHEMA` is not exempted.
# Known limit — a name for which a `CREATE DATABASE` was attempted on a DB that already existed (and is absent from the project config) and **failed**
# is recorded too. The hook runs before execution (PreToolUse), so it does not know whether it succeeded.
_SYS_DBS=" postgres template0 template1 mysql information_schema performance_schema sys "

# The target names after `create|drop database` in a text (lowercase, one per line). Variables and substitutions are emitted as they are
_db_targets() {   # $1 text  $2 create|drop
  printf '%s' "$1" | awk -v verb="$2" -v q="'" '
    { s = tolower($0); gsub(/\\/, "", s)
      while (match(s, verb "[ \t]+database[ \t]+")) {
        s = substr(s, RSTART + RLENGTH)
        sub(/^if[ \t]+(not[ \t]+)?exists[ \t]+/, "", s)
        t = s; sub(/^["`]/, "", t)
        if (match(t, "^[^ \t\"`;,)" q "]+")) print substr(t, 1, RLENGTH) } }'
}

# The DB names the project uses — environment variables + the project root `.env*`. The path of a connection URL and the value of a name key
_project_db_names() {
  local f
  { env 2>/dev/null
    # If there is no `.env*` at all, the glob is left literally — ending with `[ -f ] && cat` makes the loop
    # return 1, the function fails under pipefail and the ERR trap fires (when the connection URL is only in an environment variable, as in the benchmark)
    for f in "${ORANGEKIT_ROOT:-.}"/.env*; do [ -f "$f" ] || continue; cat "$f" 2>/dev/null || true; done
  } | awk -v q="'" '
    { line = $0; sub(/^[ \t]*export[ \t]+/, "", line)
      eq = index(line, "="); if (!eq) next
      k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
      gsub("^[ \t\"" q "]+|[ \t\"" q "]+$", "", v)
      if (v ~ /^(postgres(ql)?|mysql|mariadb)(\+[a-z0-9]+)?:\/\//) {
        if (sub(/^[^:]+:\/\/[^\/]*\//, "", v)) { sub(/[?#].*$/, "", v); if (v != "") print tolower(v) }
      } else if (k ~ /^[ \t]*(PGDATABASE|POSTGRES_DB|MYSQL_DATABASE|DB_NAME|DB_DATABASE|DATABASE_NAME)[ \t]*$/ && v != "") print tolower(v) }' \
    | sort -u
}

_created_dbs_file() { [ -n "${ORANGEKIT_ROOT:-}" ] && printf '%s/created-dbs' "$(orangekit_state_dir)"; }

# ── Expand the names the shell computes into values before judging (root cause ① of the residual false positives) ──
# The hook sees the **characters** of a command, but a DB name is a **value** the shell computes. The `$d` in `for d in ot_final ot_work; do … "DROP DATABASE IF
# EXISTS $d"; done` is not a name as characters — left unexpanded it becomes "unknown" and collapses into a block (benchmark B3 run5: it was a scratch DB the
# previous command created, blocked only because it was a loop variable). Nothing is executed — **only characters are substituted**, and only the two forms that can be expanded safely:
#   ① `for V in w1 w2; do BODY; done` — if every word is a literal, BODY is unrolled once per word
#   ② `V=value` — if the value is a literal, or contains a piece that **changes on every run** (`$(date …)` `$$` `$RANDOM` `$(uuidgen)`
#      — timestamp, random number, PID), the value is put into later `$V`. That piece is replaced with the marker `@@u@@` — a name that cannot equal a DB that already existed
# Any other value (`$(cat x)` · another variable · a glob · a nested loop) is left unexpanded → what the judgment below blocks is the same as today.
_expand_shell_literals() {
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" }
    function isword(w) { return (w ~ /^[A-Za-z0-9_.@-]+$/) }
    function subst(b, v, w,   out, i, lv) {
      out = ""; lv = length(v)
      while ((i = index(b, "$")) > 0) {
        out = out substr(b, 1, i - 1); b = substr(b, i)
        if (substr(b, 1, lv + 3) == "${" v "}") { out = out w; b = substr(b, lv + 4) }
        else if (substr(b, 1, lv + 1) == "$" v && substr(b, lv + 2, 1) !~ /[A-Za-z0-9_]/) { out = out w; b = substr(b, lv + 2) }
        else { out = out "$"; b = substr(b, 2) }
      }
      return out b
    }
    function expand_loops(s,   out, orig, rest, body, after, v, ws, n, words, i, ok, consumed) {
      out = ""
      while (match(s, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+[^;$`|&<>()\n]+;[ \t]*do[ \t]+/)) {
        out = out substr(s, 1, RSTART - 1); orig = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
        if (!match(rest, /;[ \t]*done|\n[ \t]*done/)) { out = out orig; s = rest; continue }
        consumed = substr(rest, 1, RSTART + RLENGTH - 1); body = substr(rest, 1, RSTART - 1); after = substr(rest, RSTART + RLENGTH)
        v = orig; sub(/^for[ \t]+/, "", v); sub(/[ \t].*$/, "", v)
        ws = orig; sub(/^for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+/, "", ws); sub(/;[ \t]*do[ \t]+$/, "", ws); gsub(/^[ \t]+|[ \t]+$/, "", ws)
        n = split(ws, words, /[ \t]+/); ok = (n > 0 && n <= 32)
        for (i = 1; i <= n; i++) if (!isword(words[i])) ok = 0
        if (!ok || index(body, "for ") > 0) { out = out orig consumed; s = after; continue }
        for (i = 1; i <= n; i++) out = out subst(body, v, words[i]) "; "
        s = after
      }
      return out s
    }
    # ③ A `f() { BODY; }` definition and calls like `f w1 w2` — at each call, expand `$1`…`$9` in BODY to the literal arguments and delete the definition itself.
    #    Benchmark B4 run5: the `$1` in `mk() { psql … "DROP DATABASE IF EXISTS $1" -c "CREATE DATABASE $1 TEMPLATE x"; }; mk rev_a`
    #    is not a name as characters, so it was blocked. If an argument is not a literal or the definition is nested, it is not expanded (the same judgement as today)
    function expand_funcs(s,   out, nm, body, i, L, c, q, depth, st, rest, defs, n, k, args, nargs, j, b, cand, pre, ok) {
      n = 0
      while (match(s, /(^|[\n;&|( \t])(function[ \t]+)?[A-Za-z_][A-Za-z0-9_-]*[ \t]*\(\)[ \t]*\{/)) {
        pre = substr(s, 1, RSTART - 1); cand = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
        nm = cand; sub(/^[\n;&|( \t]/, "", nm); sub(/^function[ \t]+/, "", nm); sub(/[ \t]*\(\)[ \t]*\{$/, "", nm)
        L = length(rest); q = ""; depth = 1
        for (i = 1; i <= L; i++) {
          c = substr(rest, i, 1)
          if (q != "") { if (c == q) q = ""; continue }
          if (c == "\"" || c == "\047") { q = c; continue }
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth == 0) break }
        }
        if (depth != 0) { out = out pre cand; s = rest; continue }
        body = substr(rest, 1, i - 1)
        if (body ~ /\(\)[ \t]*\{/) { out = out pre cand body "}"; s = substr(rest, i + 1); continue }
        defs[++n] = nm; dbody[nm] = body; dtext[n] = cand body "}"; bad[nm] = 0
        out = out pre " @@fn" n "@@ "; s = substr(rest, i + 1)
      }
      s = out s
      if (n == 0) return s
      for (k = 1; k <= n; k++) {
        nm = defs[k]; out = ""
        while (match(s, "(^|[\n;&|( \t])" nm "([ \t]+[^\n;&|<>()]*)?([\n;&|)]|$)")) {
          pre = substr(s, 1, RSTART - 1); cand = substr(s, RSTART, RLENGTH); rest = substr(s, RSTART + RLENGTH)
          c = substr(cand, 1, 1); if (c ~ /[\n;&|( \t]/) { pre = pre c; cand = substr(cand, 2) }
          j = substr(cand, length(cand), 1); if (j ~ /[\n;&|)]/) { rest = j rest; cand = substr(cand, 1, length(cand) - 1) }
          args = cand; sub("^" nm "[ \t]*", "", args); gsub(/^[ \t]+|[ \t]+$/, "", args)
          nargs = (args == "") ? 0 : split(args, a, /[ \t]+/); ok = (nargs <= 9)
          for (j = 1; j <= nargs; j++) { gsub(/^["\047]|["\047]$/, "", a[j]); if (!isword(a[j])) ok = 0 }
          if (!ok) { bad[nm] = 1; out = out pre cand; s = rest; continue }
          b = dbody[nm]
          for (j = 1; j <= 9; j++) b = subst(b, j, (j <= nargs) ? a[j] : "")
          out = out pre "{ " b " ; }"; s = rest
        }
        s = out s
      }
      # If even one call could not be expanded, the definition is put back as it was — the `$1` in that body stays unresolved and is judged as today
      for (k = 1; k <= n; k++) { j = index(s, "@@fn" k "@@"); if (j) s = substr(s, 1, j - 1) (bad[defs[k]] ? dtext[k] : ":") substr(s, j + length("@@fn" k "@@")) }
      return s
    }
    function uniq(val,   t) {
      t = val
      gsub(/\$\((date|uuidgen|mktemp|shuf)[^)]*\)/, "@@u@@", t)
      gsub(/\$\$|\$RANDOM|\$\{RANDOM\}|\$EPOCHSECONDS|\$SECONDS/, "@@u@@", t)
      if (t ~ /[$`]/ || t !~ /^[A-Za-z0-9_.@-]+$/) return ""
      return t
    }
    function expand_assign(s,   out, pre, tail, nm, i, L, c, q, depth, raw, val, res, rest, head, remain) {
      out = ""
      while (match(s, /(^|[;&|\n \t])(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        pre = substr(s, 1, RSTART + RLENGTH - 1)
        nm = substr(s, RSTART, RLENGTH); sub(/^[;&|\n \t]/, "", nm); sub(/^export[ \t]+/, "", nm); sub(/=$/, "", nm)
        tail = substr(s, RSTART + RLENGTH)
        i = 1; q = ""; depth = 0; L = length(tail)
        while (i <= L) {
          c = substr(tail, i, 1)
          if (c == "$" && substr(tail, i + 1, 1) == "(") { depth++; i += 2; continue }
          if (depth > 0) { if (c == "(") depth++; else if (c == ")") depth--; i++; continue }
          if (q == "") {
            if (c == "\"" || c == "\047") { q = c; i++; continue }
            if (c ~ /[ \t\n;&|]/) break
          } else if (c == q) { q = ""; i++; continue }
          i++
        }
        raw = substr(tail, 1, i - 1); rest = substr(tail, i)
        val = raw; gsub(/"/, "", val); gsub(/\047/, "", val)
        res = uniq(val)
        if (res != "") {
          if (match(rest, "(^|[;&|\n \t])(export[ \t]+)?" nm "=")) { head = substr(rest, 1, RSTART - 1); remain = substr(rest, RSTART) }
          else { head = rest; remain = "" }
          rest = subst(head, nm, res) remain
        }
        out = out pre raw; s = rest
      }
      return out s
    }
    { printf "%s", expand_assign(expand_loops(expand_funcs($0))) }'
}

# A loop word that comes from a file — `for d in $(sort -u /tmp/scratchdb); do … DROP DATABASE $d …` (benchmark B5 run6: every scratch DB was written
# to a file as it was created, then all of them were dropped at the end). The hook **can read** that file before execution, so only when it is a regular file at an absolute path,
# every word is name-shaped (32 or fewer), and this command does not write to that file, it is rewritten to `for d in w1 w2; do` and handed to the loop unrolling above.
# If it cannot be read it is left as is → undecidable → blocked as today. The unrolled names still go through exemption ① and ② unchanged.
_inline_listed_files() {
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0; out = ""
    while (match(s, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+"?\$\((cat|sort|sort[ \t]+-u|uniq|<)[ \t]*\/[A-Za-z0-9_.\/-]+[ \t]*\)"?[ \t]*;/)) {
      hdr = substr(s, RSTART, RLENGTH); out = out substr(s, 1, RSTART - 1); s = substr(s, RSTART + RLENGTH)
      f = hdr; sub(/^[^\/]*/, "", f); sub(/[ \t]*\)"?[ \t]*;$/, "", f)
      v = hdr; sub(/^for[ \t]+/, "", v); sub(/[ \t].*$/, "", v)
      ok = (f !~ /\.\./); n = 0; delete seen; words = ""
      if (ok && (out s) ~ ("(>|tee[ \t]+(-a[ \t]+)?)[ \t]*" f "([^A-Za-z0-9_./-]|$)")) ok = 0
      while (ok && (r = (getline line < f)) > 0) {
        m = split(line, w, /[ \t\r\n]+/)   # RS is \001, so getline reads the whole file at once
        for (i = 1; i <= m; i++) {
          if (w[i] == "") continue
          if (w[i] !~ /^[A-Za-z0-9_.@-]+$/) { ok = 0; break }
          if (!(w[i] in seen)) { seen[w[i]] = 1; words = words " " w[i]; n++ }
        }
      }
      if (r < 0) ok = 0
      close(f)
      if (ok && n > 0 && n <= 32) out = out "for " v " in" words ";"
      else out = out hdr
    }
    printf "%s", out s }'
}

# Does it match a recorded creation name — exactly equal, or matching the fixed part of a name recorded with a piece that changes on every run (`@@u@@`)
# (`SCR="ot_scratch_$(date +%s)"; … CREATE DATABASE $SCR` → recorded `ot_scratch_@@u@@` ↔ at drop time, `ot_scratch_1730300000` read from the file).
# If the fixed part is under 3 characters anything would match, so it is not accepted
_created_has() {   # $1 name  $2 records (one per line)
  grep <<<"$2" -qxF -- "$1" && return 0
  local p pre suf
  while IFS= read -r p; do
    case "$p" in *'@@u@@'*) ;; *) continue ;; esac
    pre=${p%%@@u@@*}; suf=${p#*@@u@@}
    case "$suf" in *'@@u@@'*) continue ;; esac
    [ $(( ${#pre} + ${#suf} )) -ge 3 ] || continue
    case "$1" in "$pre"*"$suf") ;; *) continue ;; esac
    local mid=${1#"$pre"}; mid=${mid%"$suf"}
    [ -n "$mid" ] && grep <<<"$mid" -Eq '^[a-z0-9_-]+$' && return 0
  done <<< "$2"
  return 1
}

# ── Exemption judgment for DROP — names by proof, tables by measurement (an exemption opens only when proven) ──
# DATABASE: not the project DB (environment variables · `.env*`) + created by the agent (a CREATE in the same command, or recorded) or a name unique to each run
# 0 = every DROP DATABASE in this segment is proven to be the deletion of a scratch DB. 1 = not so, or undecidable
_scratch_dbs_ok() {   # $1 segment  $2 DB names created in the executing segments of the same command
  local targets proj="" created n f
  targets=$(_db_targets "$1" drop); [ -z "$targets" ] && return 1
  created="$2"
  f=$(_created_dbs_file) && [ -f "$f" ] && created="$created
$(cat "$f" 2>/dev/null)"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    case "$n" in *'@@u@@'*) continue ;; esac     # a name that changes on every run: it cannot be a DB that already existed
    case "$n" in *'$'*|*'('*|*'{'*|*'`'*) return 1 ;; esac
    case "$_SYS_DBS" in *" $n "*) return 1 ;; esac
    [ -z "$proj" ] && { proj=$(_project_db_names); [ -z "$proj" ] && return 1; }
    grep <<<"$proj" -qxF -- "$n" && return 1
    _created_has "$n" "$created" || return 1
  done <<< "$targets"
  return 0
}

# TABLE (root cause ②): a table has no name proof such as "it is not in the project config". So we **measure** —
# whether there is data the deletion would destroy is knowable from a read-only query, not a guess (the principle of not collapsing undecidable into a block, solved by measurement).
# The hook sees it before execution, so a "table that does not exist yet" is a scratch table this command will create (benchmark B3 run5: `tmp_probe`, created to test the migration runner
# and dropped in the same command · run6: a defensive `DROP TABLE IF EXISTS phase1_snapshot_check` of a name that never existed).
# Exemption conditions — only when **all** are proven: ① the name is an unquoted literal ② that psql points at the project DB (an explicit `"$DATABASE_URL"`, a value in the environment variables) and the same command does not change the connection environment
# ③ a read-only query answers within 3 seconds: absent → pass · present and **has no rows** (and no CASCADE) → pass · has rows → block
# ④ DROP SCHEMA is not exempted. No psql · connection failure · timeout · another DB · an existing table with CASCADE → undecidable → blocked as today.
# The connection URL used for measuring is read **only from the hook's environment variables**. If it is only in `.env*`, the command's shell does not know that value (`$DATABASE_URL` is empty and
# psql uses the default connection), so the DB the hook measured and the DB the command will run against differ — with no proof that the measured target = the executed target, no exemption is granted.
_project_db_url() {
  [ -n "${DATABASE_URL:-}" ] || return 1
  printf '%s' "$DATABASE_URL"
}

# Does this psql call point at the project DB — the connection argument must be exactly one `"$DATABASE_URL"` or none, and there must be no connection flags such as -d/-h/-p/-U
_psql_targets_project_db() (   # $1 segment containing psql — subshell: keeps an expected-to-fail grep from firing the ERR trap
  trap - ERR; set +e
  local t urlform cnt
  case "$1" in *psql*) ;; *) return 1 ;; esac
  t=${1#*psql}; t=${t%%|*}
  urlform='"\$DATABASE_URL"|\$DATABASE_URL|"\$\{DATABASE_URL\}"|\$\{DATABASE_URL\}'
  # Segment splitting also cuts at a `;` inside quotes (`-c "DROP TABLE t; DELETE …"`) — a fragment with no closing quote is also treated as a -c argument
  t=$(printf ' %s ' "$t" | sed -E "s/[[:space:]]-[A-Za-z]*[cf][[:space:]]+(\"[^\"]*(\"|\$)|'[^']*('|\$))/ /g; s/<<-?[[:space:]]*['\"]?[A-Za-z_]+['\"]?/ /g; s/[0-9]*>&?[^[:space:]]*/ /g; s/<[^[:space:]]*/ /g")
  cnt=$(grep <<<"$t" -oE "$urlform" | wc -l | tr -d ' ')
  [ "${cnt:-0}" -eq 1 ] || return 1      # a psql with no connection argument connects with the PG* defaults — no proof it is the project DB
  t=$(printf '%s' "$t" | sed -E "s/($urlform)/ /")
  grep <<<"$t" -Eq '^[[:space:]]*(-[qXAt1]+([[:space:]]+|$)|-v[[:space:]]+[A-Za-z_]+=[^[:space:]]*([[:space:]]+|$)|--quiet([[:space:]]+|$))*[[:space:]]*$'
)

# The target names of DROP TABLE (one per line). If the same statement has CASCADE, a `@@cascade@@` line is emitted first
_table_targets() {
  printf '%s' "$1" | awk -v q="'" '
    { s = tolower($0)
      while (match(s, /drop[ \t]+table[ \t]+(if[ \t]+exists[ \t]+)?/)) {
        s = substr(s, RSTART + RLENGTH); stmt = s
        if (match(stmt, "[;\"`" q "]")) stmt = substr(stmt, 1, RSTART - 1)
        if (stmt ~ /cascade/) print "@@cascade@@"
        sub(/[ \t]+(cascade|restrict).*$/, "", stmt)
        n = split(stmt, parts, /[ \t]*,[ \t]*/)
        for (i = 1; i <= n; i++) { t = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", t); print t }
      } }'
}

# Read-only measurement: absent | empty | rows (returns 1 when it cannot measure) — subshell: a psql failure is an expected result, so it must not fire the ERR trap
_probe_table() (   # $1 lowercase literal name (schema.table allowed)
  trap - ERR; set +e
  local url out
  url=$(_project_db_url) || return 1
  case "$url" in *'$'*|*'`'*|*"'"*|*'"'*) return 1 ;; esac
  command -v psql >/dev/null 2>&1 || return 1
  out=$(PGCONNECT_TIMEOUT=3 PGOPTIONS='-c statement_timeout=3000 -c lock_timeout=1000' \
        psql "$url" -X -A -t -q -v ON_ERROR_STOP=1 -c "SELECT to_regclass('$1') IS NOT NULL" 2>/dev/null) || return 1
  case "$out" in f) printf 'absent'; return 0 ;; t) ;; *) return 1 ;; esac
  # If row-level security (RLS) applies to this role, the table looks "empty" even when it has rows (S1 audit F2, 1.8.0) — if the measurement cannot see all of the target, it cannot be judged
  out=$(PGCONNECT_TIMEOUT=3 PGOPTIONS='-c statement_timeout=3000 -c lock_timeout=1000' \
        psql "$url" -X -A -t -q -v ON_ERROR_STOP=1 -c "SELECT c.relrowsecurity AND NOT (r.rolsuper OR r.rolbypassrls OR (c.relowner = r.oid AND NOT c.relforcerowsecurity)) FROM pg_class c, pg_roles r WHERE c.oid = to_regclass('$1') AND r.rolname = current_user" 2>/dev/null) || return 1
  [ "$out" = f ] || return 1
  out=$(PGCONNECT_TIMEOUT=3 PGOPTIONS='-c statement_timeout=3000 -c lock_timeout=1000' \
        psql "$url" -X -A -t -q -v ON_ERROR_STOP=1 -c "SELECT EXISTS (SELECT 1 FROM $1 LIMIT 1)" 2>/dev/null) || return 1
  case "$out" in f) printf 'empty' ;; t) printf 'rows' ;; *) return 1 ;; esac
)

# Does the same command change the connection environment — `DATABASE_URL=… psql "$DATABASE_URL"` · `export DATABASE_URL=…` · `PGHOST=… psql` · `unset DATABASE_URL`.
# If so, `"$DATABASE_URL"` is not the DB the hook measured (the measured target and the executed target diverge) → undecidable
_command_redefines_db_env() {
  grep <<<"${_GATE_CMD:-}" -Eq '(^|[^A-Za-z0-9_])(DATABASE_URL|PGHOST|PGHOSTADDR|PGPORT|PGDATABASE|PGUSER|PGSERVICE|PGSERVICEFILE|PGPASSFILE|PGOPTIONS)=|unset[[:space:]]+(DATABASE_URL|PG[A-Z]+)'
}

_scratch_tables_ok() {   # $1 segment
  local t cascade=0 any=0 st
  _command_redefines_db_env && return 1
  _psql_targets_project_db "$1" || return 1
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    if [ "$t" = "@@cascade@@" ]; then cascade=1; continue; fi
    case "$t" in *'"'*) return 1 ;; esac
    t=$(printf '%s' "$t" | tr 'A-Z' 'a-z')
    grep <<<"$t" -Eq '^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?$' || return 1
    case "$t" in pg_*|information_schema.*|pg_catalog.*) return 1 ;; esac
    st=$(_probe_table "$t" || printf '@@undecided@@')   # a failed measurement is received as a value — so a failure inside a command substitution does not fire the ERR trap
    [ "$st" = "@@undecided@@" ] && return 1
    case "$st" in
      absent) ;;                               # nothing to delete — or a scratch table this command will create
      empty) [ "$cascade" = 0 ] || return 1 ;; # even when empty, CASCADE deletes the dependent objects with it
      *) return 1 ;;                           # it has rows
    esac
    any=1
  done < <(_table_targets "$1")
  [ "$any" = 1 ]
}

# All DROPs in one segment — DATABASE by name proof, TABLE by measurement, SCHEMA never exempt. When the three are mixed, all must pass
_drop_exempt() {   # $1 segment  $2 DB names created in the same command
  grep <<<"$1" -Eqi '(^|[^a-z_])drop[[:space:]]+schema([^a-z_]|$)' && return 1
  if grep <<<"$1" -Eqi '(^|[^a-z_])drop[[:space:]]+database([^a-z_]|$)'; then _scratch_dbs_ok "$1" "$2" || return 1; fi
  if grep <<<"$1" -Eqi '(^|[^a-z_])drop[[:space:]]+table([^a-z_]|$)'; then _scratch_tables_ok "$1" || return 1; fi
  return 0
}

# Records the DB names that commands we let through created (the "created earlier" basis for ②). Capped
_record_created_dbs() {   # $1 names (one per line)
  local f n
  f=$(_created_dbs_file) || return 0
  [ -z "$1" ] && return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  grep <<<"$1" -v '[$({`]' >> "$f" 2>/dev/null || true
  n=$(orangekit_num "$(wc -l < "$f" 2>/dev/null)")
  if [ "$n" -gt 400 ]; then
    tail -200 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null || rm -f "$f.tmp"
  fi
  return 0
}

# ── Shell functions that create DBs — record the DB created by a call even when the definition is in another command (an env file that gets sourced) ──────────
# Benchmark B4 run5: a function was put in a file with `cat > env.sh <<EOF … mk() { … CREATE DATABASE $1 …; } … EOF`, and later commands created
# scratch DBs with `. env.sh; mk rev_rb`. The hook did not know that call creates a DB, so nothing was recorded, and the final cleanup (`for d in rev_*; … DROP DATABASE $d`) was blocked.
# The definition is looked for in the **raw text, heredoc bodies included** (a definition written to a file is still a definition). Only the function name is recorded, and a name created by that call
# still goes through exemption ① (not a project or system DB) as before — creating a project DB through a function does not exempt it.
_created_db_fns_file() { [ -n "${ORANGEKIT_ROOT:-}" ] && printf '%s/created-db-fns' "$(orangekit_state_dir)"; }
_db_creator_fns_in() (   # $1 raw text → names of the functions that create a DB from their first argument
  trap - ERR; set +e
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0
    while (match(s, /(function[ \t]+)?[A-Za-z_][A-Za-z0-9_-]*[ \t]*\(\)[ \t]*\{[^}]*\}/)) {
      d = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (tolower(d) ~ /create[ \t]+database[ \t]+(if[ \t]+not[ \t]+exists[ \t]+)?["\047]?\$\{?1/ || d ~ /createdb[^}]*\$\{?1/) {
        n = d; sub(/^function[ \t]+/, "", n); sub(/[ \t]*\(\).*$/, "", n); print n } } }'
)
_db_creates_via_fns() (   # $1 executable segment → names created by calling a recorded creator function with a literal argument
  trap - ERR; set +e
  local f fns fn
  f=$(_created_db_fns_file) && [ -f "$f" ] || return 0
  fns=$(sort -u "$f" 2>/dev/null)
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    grep <<<"$1" -oE "(^|[[:space:];&|(])$fn[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*" | awk '{print tolower($NF)}' || true
  done <<< "$fns"
)
_record_db_creator_fns() {   # $1 raw text
  # Both finders match only a `name() {…}` definition — without a `()` there is nothing to record
  _plain "$1" && case "$1" in *'()'*) ;; *) return 0 ;; esac
  local f n; f=$(_created_db_fns_file) || return 0
  n=$(_db_creator_fns_in "$1")
  [ -n "$n" ] && { mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$n" >> "$f" 2>/dev/null || true; }
  f=$(_url_fns_file) || return 0
  n=$(_url_fns_in "$1"); [ -n "$n" ] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$n" >> "$f" 2>/dev/null || true
  return 0
}

# Shell functions that build a connection URL — `psql "$(UU rev_rb)"` after `UU() { echo $DATABASE_URL | sed "s#/[^/]*\$#/$1#"; }` (benchmark B4 run5).
# Put a probe name in the body's `$1` and record the function only when `_url_db_name` returns **that name** — a function that discards its argument is not recorded.
_url_fns_file() { [ -n "${ORANGEKIT_ROOT:-}" ] && printf '%s/url-fns' "$(orangekit_state_dir)"; }
_url_fns_in() (   # $1 raw text → names of the functions that replace only the DB name of DATABASE_URL with their first argument
  trap - ERR; set +e
  local nm body
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0
    while (match(s, /(function[ \t]+)?[A-Za-z_][A-Za-z0-9_-]*[ \t]*\(\)[ \t]*\{[^}]*\}/)) {
      d = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (d !~ /DATABASE_URL/ || d !~ /\$\{?1/) continue
      n = d; sub(/^function[ \t]+/, "", n); sub(/[ \t]*\(\).*$/, "", n)
      b = d; sub(/^[^{]*\{/, "", b); sub(/\}$/, "", b); gsub(/\n/, " ", b)
      printf "%s\t%s\n", n, b } }' | while IFS=$'\t' read -r nm body; do
    body=$(printf '%s' "$body" | sed 's/\${1}/zzorangekitprobe/g; s/\$1/zzorangekitprobe/g; s/;[[:space:]]*$//')
    [ "$(_url_db_name "$body")" = zzorangekitprobe ] && printf '%s\n' "$nm"
  done
  true
)

# ── Work inside a psql attached to a scratch DB — exempt the deletes and DML (root cause ③ of the residual false positives) ──────────────
# Benchmark B4 run6: `MIG=$(echo "$DATABASE_URL" | sed 's#/app$#/migtest#'); psql "$MIG" <<SQL … DROP TABLE …` · run6 stage 4:
# `S="${DATABASE_URL%/*}/scratch_0014"; … psql "$S" -qc "DELETE FROM challenges"` · B2: `export DATABASE_URL="$BASE/rev_scratch3"; psql
# "$DATABASE_URL" <<EOF … truncate …`. All of them are work inside a **scratch DB the same command created**, but the hook did not know which DB that psql attached to, so it
# took it for project-DB work and blocked it. Resolve the connection string **through assignments in the same command** to get the target DB name, and if that name is proven a scratch DB
# (the same proof as `_scratch_dbs_ok` — not a project or system DB, and a name this command created or one that was recorded), exempt the deletes and DML of that psql.
# A connection that cannot be resolved (another variable · a command substitution · -h to another host) is judged as before — a new exemption opens only when it is proven.
_scratch_db_ok() {   # $1 name  $2 names created in the same command → 0 = proven a scratch DB
  _scratch_dbs_ok "DROP DATABASE $1" "$2"
}
_url_db_name() (   # $1 assigned value → if it is DATABASE_URL with only the DB name changed, that name (lowercase)
  trap - ERR; set +e
  grep <<<"$1" -qE 'DATABASE_URL|@@base@@' || return 1
  printf '%s' "$1" | sed -nE 's#.*/([A-Za-z_][A-Za-z0-9_]*)[#|"'"'"')]*[[:space:]]*$#\1#p' | tr 'A-Z' 'a-z' | head -1
)
_psql_conn_db() (   # $1 psql segment  $2 "VAR=db" lines → the DB name that psql attaches to (if it resolves)
  trap - ERR; set +e
  local t v
  case "$1" in *psql*) ;; *) return 1 ;; esac
  t=${1#*psql}
  grep <<<"$t" -Eq '(^|[[:space:]])-(h|-host|p|-port|U|-username)([[:space:]=]|$)' && return 1
  v=$(grep <<<"$t" -oE '(^|[[:space:]])-d[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | awk '{print tolower($NF)}' | head -1)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v=$(grep <<<"$t" -oE '^[[:space:]]*"?\$\([A-Za-z_][A-Za-z0-9_-]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\)' | head -1)
  if [ -n "$v" ]; then
    local fn arg f
    fn=$(printf '%s' "$v" | sed -E 's/^[[:space:]]*"?\$\(([A-Za-z_][A-Za-z0-9_-]*).*/\1/'); arg=$(printf '%s' "$v" | sed -E 's/.*[[:space:]]([A-Za-z_][A-Za-z0-9_]*)\)$/\1/')
    f=$(_url_fns_file) && [ -f "$f" ] && grep -qxF -- "$fn" "$f" && { printf '%s' "$arg" | tr 'A-Z' 'a-z'; return 0; }
    return 1
  fi
  v=$(grep <<<"$t" -oE '"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(/[A-Za-z_][A-Za-z0-9_]*)?"?' | head -1 | tr -d '"{}')
  [ -n "$v" ] || return 1
  case "$v" in
    */*) printf '%s' "${v##*/}" | tr 'A-Z' 'a-z'; return 0 ;;
  esac
  v=${v#\$}
  printf '%s\n' "$2" | awk -F= -v k="$v" '$1==k && $2!="@@base@@" && $2!="@@url@@" {d=$2} END {if (d!="") {print d; exit 0} exit 1}'
)
_assigns_of() (   # $1 segment → the leading assignments "VAR<TAB>value" (the value with its quotes)
  trap - ERR; set +e
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]+//' \
    | grep -oE '^((export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|\$\([^)]*\)|[^[:space:];&|]+)[[:space:]]*)+' \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|\$\([^)]*\)|[^[:space:];&|]+)' | sed -E 's/=/\t/' || true
)
_sed_base_of() (   # $1 assignment value → X when it strips only the last path piece of X, as in `$(echo "$X" | sed 's#/[^/]*$##')`
  trap - ERR; set +e
  local v re cut
  v=$(printf '%s' "$1" | tr -d '[:space:]')
  cut='\[\^/\][*+]\$'
  re='^"?\$\((echo|printf'"'"'%s'"'"'|printf"%s")"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\|sed(-E|-r)?'"'"'s(#/'"$cut"'##|@/'"$cut"'@@|,/'"$cut"',,|:/'"$cut"'::)'"'"'\)"?$'
  [[ "$v" =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}"
  return 0
)
_conn_update() (   # $1 assignment lines (VAR<TAB>value)  $2 the map so far ("VAR=db" · "VAR=@@base@@") → the new map. An assignment that does not resolve removes that variable
  trap - ERR; set +e
  local map="$2" var val db b
  while IFS=$'\t' read -r var val; do
    [ -n "$var" ] || continue
    map=$(printf '%s\n' "$map" | awk -F= -v k="$var" '$1!=k')
    if grep <<<"$val" -Eq '^"?\$\{?DATABASE_URL\}?"?$'; then map="$map
$var=@@url@@"; continue; fi
    b=$(printf '%s' "$val" | sed -nE 's/^"?\$\{([A-Za-z_][A-Za-z0-9_]*)%\/[^}]*\}"?$/\1/p')
    # The same thing done with sed — `$(echo "$DATABASE_URL" | sed 's#/[^/]*$##')` (benchmark B5 run5: `"$B/rv_rollback"` appended to this base address could not be resolved, so it was blocked)
    [ -z "$b" ] && b=$(_sed_base_of "$val")
    if [ "$b" = DATABASE_URL ] || { [ -n "$b" ] && grep <<<"$map" -qxF -- "$b=@@url@@"; }; then map="$map
$var=@@base@@"; continue; fi
    for b in $(printf '%s\n' "$map" | awk -F= '$2=="@@base@@" {print $1}'); do
      val=$(printf '%s' "$val" | sed "s#\\\$$b\([^A-Za-z0-9_]\)#@@base@@\1#g; s#\\\${$b}#@@base@@#g")
    done
    db=$(_url_db_name "$val" || true)
    [ -n "$db" ] && map="$map
$var=$db"
  done <<< "$1"
  printf '%s' "$map"
)
# ── Scratch-DB path — proof by **record**, not by the characters of the command ──────────────────────────────
# The exemptions above (a CREATE in the same command · a recorded name · resolving assignments, loops and functions) prove "scratch DB" from the **characters** of the command.
# A shell can write the same thing in endlessly different syntax, so proof by characters never closes — every round blocked a new form (B2 re-generating the same command → B3 loop variable →
# B4 shell function → B5 sed base address · list file). So there is **one path that always passes**:
#   `security-check.sh --scratch-db new <name> [--template <DB>]`  creates a DB with the reserved prefix, records it in project state, and prints the connection URL
#   `… --scratch-db psql <name> [psql args…]`                       attaches to that DB (deletes and DML included — it runs only inside that DB)
#   `… --scratch-db url <name>` · `drop <name>|--all [--force]` · `list`
# This mode makes the safety judgement itself, **from the record and the DB name** (prefix + in the record + not a project or system DB). The hook only has to recognise
# a segment whose first token is this mode (`_scratch_cmd`), so the form closes to one. When it cannot decide (no DATABASE_URL · no psql) it does not create anything and says why.
_SCRATCH_PREFIX="orangekit_scratch_"
_SCRATCH_SELF="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/security-check.sh"
_SCRATCH_HINT="If it is a scratch DB for verification, use the dedicated path — it always passes: bash \"$_SCRATCH_SELF\" --scratch-db new <name> [--template <DB>] → --scratch-db psql <name> -c \"…\" → --scratch-db drop <name>"
_scratch_registry() { [ -n "${ORANGEKIT_ROOT:-}" ] && printf '%s/scratch-dbs' "$(orangekit_state_dir)"; }
_scratch_url() {   # $1 DB name → DATABASE_URL with only the DB name replaced (the query string is kept)
  printf '%s' "$DATABASE_URL" | sed -E "s#^([a-z0-9+]+://[^/]*)/[^?]*#\1/$1#"
}
_scratch_cmd() {   # $1 segment → is it a segment that runs this mode? (judged by the first token)
  local t1 rest
  # t1 is a piece of the segment with its quotes removed, so without this file's path in the quote-stripped segment it cannot match
  _plain "$1" && { _noquotes "$1"; case "$_NQ" in *"$_SCRATCH_SELF"*) ;; *) return 1 ;; esac; }
  t1=$(_first_tok "$1")
  rest=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  case "$t1" in bash|sh) rest=${rest#* }; t1=$(_first_tok "$rest") ;; esac
  t1=${t1//\"/}; t1=${t1//\'/}
  # Only when it is **this plugin's own file** — so a same-named file the agent made (`./security-check.sh`) cannot earn the exemption
  [ "$t1" = "$_SCRATCH_SELF" ] || return 1
  rest=${rest#*security-check.sh}; rest=${rest#\"}; rest=${rest#\'}
  [[ "$rest" =~ ^[[:space:]]+--scratch-db([[:space:]]|$) ]]
}
if [ "${1:-}" = "--scratch-db" ]; then
  set +e; trap - ERR
  _sub=${2:-}; _nm=${3:-}; _reg=$(_scratch_registry)
  _say() { printf '%s\n' "$*" >&2; }
  [ -n "$_sub" ] || { _say "Usage: --scratch-db new|url|psql|drop|list <name>"; exit 2; }
  [ -n "$_reg" ] || { _say "Undecidable: the project root was not found, so no record can be kept — not creating a scratch DB"; exit 2; }
  [ -n "${DATABASE_URL:-}" ] || { _say "Undecidable: DATABASE_URL is not set, so it is unknown which server to create on — not creating"; exit 2; }
  command -v psql >/dev/null 2>&1 || { _say "Undecidable: psql is not installed"; exit 2; }
  _full() { printf '%s%s' "$_SCRATCH_PREFIX" "$1"; }
  _known() { [ -f "$_reg" ] && grep -qxF -- "$1" "$_reg"; }
  _valid() { [[ "$1" =~ ^[a-z][a-z0-9_]{0,39}$ ]]; }
  case "$_sub" in
    list) [ -f "$_reg" ] && cat "$_reg"; exit 0 ;;
    new)
      _valid "$_nm" || { _say "The name must start with a lowercase letter and be [a-z0-9_], at most 40 characters"; exit 2; }
      _db=$(_full "$_nm"); _tpl=""
      if [ "${4:-}" = "--template" ]; then
        _tpl=${5:-}; [[ "$_tpl" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { _say "The --template name is not valid"; exit 2; }
      fi
      grep <<<"$(_project_db_names)" -qxF -- "$_db" && { _say "Not creating — same name as a project DB: $_db"; exit 2; }
      psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$_db\"${_tpl:+ TEMPLATE \"$_tpl\"}" >&2 || exit 1
      mkdir -p "$(dirname "$_reg")" && { _known "$_db" || printf '%s\n' "$_db" >> "$_reg"; }
      _scratch_url "$_db"; printf '\n'; exit 0 ;;
    url|psql)
      _db=$(_full "$_nm"); _known "$_db" || { _say "Not a recorded scratch DB: $_db — run --scratch-db new $_nm first"; exit 2; }
      [ "$_sub" = url ] && { _scratch_url "$_db"; printf '\n'; exit 0; }
      shift 3; exec psql "$(_scratch_url "$_db")" "$@" ;;
    drop)
      _force=""; for _a in "$@"; do [ "$_a" = --force ] && _force=" WITH (FORCE)"; done
      if [ "$_nm" = --all ]; then _list=$([ -f "$_reg" ] && cat "$_reg"); else _list=$(_full "$_nm"); _known "$_list" || { _say "Not dropping a scratch DB that is not in the record: $_list"; exit 2; }; fi
      _rc=0
      while IFS= read -r _db; do
        [ -n "$_db" ] || continue
        case "$_db" in "$_SCRATCH_PREFIX"*) ;; *) _say "Not dropping a name without the prefix: $_db"; _rc=2; continue ;; esac
        grep <<<"$(_project_db_names)" -qxF -- "$_db" && { _say "Not dropping a project DB: $_db"; _rc=2; continue; }
        if psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$_db\"$_force" >&2; then
          grep -vxF -- "$_db" "$_reg" > "$_reg.tmp" 2>/dev/null; mv "$_reg.tmp" "$_reg"; printf 'dropped %s\n' "$_db"
        else _rc=1; fi
      done <<< "$_list"
      exit "$_rc" ;;
    *) _say "Unknown subcommand: $_sub"; exit 2 ;;
  esac
fi

# The PAT of `pkill -f PAT` · `kill $(pgrep -f PAT)` · `pgrep -f PAT | xargs kill` (one per line). Emits only quote-stripped literals,
# and skips options that take a value (-u root and the like). A pattern anchored with `^` or `$` cannot match the shell's command line (which has `bash -c …` in front), so it is not emitted
_self_kill_patterns() (
  trap - ERR; set +e
  printf '%s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0; n = 0; L = length(s); cur = ""; q = ""; inw = 0
    for (i = 1; i <= L; i++) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = ""; else cur = cur c; continue }
      if (c == "\"" || c == "\047") { q = c; inw = 1; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { if (inw) { t[++n] = cur; cur = ""; inw = 0 } t[++n] = "$("; i++; continue }
      if (c ~ /[ \t\n]/) { if (inw) { t[++n] = cur; cur = ""; inw = 0 } continue }
      if (c ~ /[;&|()]/) { if (inw) { t[++n] = cur; cur = ""; inw = 0 } t[++n] = c; continue }
      cur = cur c; inw = 1
    }
    if (inw) t[++n] = cur
    for (i = 1; i <= n; i++) {
      if (t[i] != "pkill" && t[i] != "pgrep") continue
      cmd = t[i]; full = 0; j = i + 1
      while (j <= n && t[j] ~ /^-/) {
        if (t[j] == "--") { j++; break }
        if (t[j] == "--full") full = 1
        else if (t[j] ~ /^--(signal|pidfile|uid|euid|group|pgroup|parent|session|terminal|ns)$/) j++
        else if (t[j] ~ /^-[A-Za-z0-9]+$/) { if (t[j] ~ /f/) full = 1; if (t[j] ~ /[gGPstuUF]$/) j++ }
        j++
      }
      if (!full || j > n || t[j] ~ /^([;&|()]|\$\()$/) continue
      pat = t[j]
      if (pat ~ /^\^/ || pat ~ /\$$/ || pat == "") continue
      if (cmd == "pgrep") {
        killed = 0
        if (i > 1 && t[i - 1] == "$(") for (k = i - 2; k >= 1 && t[k] !~ /^[;&|]$/; k--) if (t[k] == "kill") killed = 1
        for (k = j + 1; k <= n && t[k] !~ /^[;&]$/; k++) if (t[k] == "|") { for (m = k + 1; m <= n && t[m] !~ /^[;&|]$/; m++) if (t[m] == "kill") killed = 1; break }
        if (!killed) continue
      }
      print pat
    } }'
)
# A command handed to a shell with -c runs exactly as if typed, but the gate saw it as one quoted argument:
# `bash -c "git push --force origin main"` read the push target as `main"` and passed (exit 0), as did sh/zsh -c, -lc and
# /bin/bash -c. Replace each `<shell> [-flags] -c '<payload>'` with its payload (\" \\ \$ \` unescaped in a double-quoted one),
# up to 4 levels deep, so the segments below see the real commands. An unterminated quote is left as it was.
_unwrap_shell_c() (   # $1 command → the same text with every shell -c payload inlined
  trap - ERR; set +e
  printf ' %s' "$1" | awk 'BEGIN { RS = "\001" } {
    s = $0
    for (pass = 0; pass < 4; pass++) {
      out = ""; changed = 0
      while (match(s, /[^A-Za-z0-9_.\/-]([A-Za-z0-9_.-]*\/)*(bash|sh|zsh|dash|ksh)([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*c[A-Za-z]*[ \t]+["\047]/)) {
        q = substr(s, RSTART + RLENGTH - 1, 1); pre = substr(s, 1, RSTART); rest = substr(s, RSTART + RLENGTH)
        p = ""; i = 1; n = length(rest); closed = 0
        while (i <= n) {
          ch = substr(rest, i, 1)
          if (q == "\"" && ch == "\\" && i < n && substr(rest, i + 1, 1) ~ /["\\$`]/) { p = p substr(rest, i + 1, 1); i += 2; continue }
          if (ch == q) { closed = 1; break }
          p = p ch; i++
        }
        if (!closed) { out = out substr(s, 1, RSTART + RLENGTH - 1); s = rest; continue }
        out = out pre " " p " "; s = substr(rest, i + 1); changed = 1
      }
      s = out s
      if (!changed) break
    }
    printf "%s", substr(s, 2)
  }'
)
# A command is judged by **what runs**, not by its characters. The checks below used to read the text, and every shell shape that moves
# a word out of command position — or a command into a place the text does not show — went through (measured 2026-11-08, 121 of 419 matrix
# cases on 1.14.1, the same on upstream): `eval "git push --force origin main"`, `echo main | xargs git push --force origin`, `git -c x=y push …`,
# `git -C . push …`, `( git push … )`, `"main"` in quotes, `refs/heads/main`, a second push after a feature-branch push, a git alias, and a script
# written then run (`printf … > p.sh && bash p.sh`, `bash <<EOF`, `| sh`) or already on disk (`bash danger.sh`).
# One quote-aware pass turns the command into its **simple commands**, one per line: `mark<US>cmd<US>arg…` (US = \037, quotes removed,
# the command word lowercased to its basename). On the way it
#   · drops leading assignments and keywords, and the wrappers sudo · doas · env · command · exec · nohup · setsid · time · nice · ionice · timeout · stdbuf · npx · bunx
#   · re-parses what a shell would run again: eval's words, a `<shell> -c` payload, `$( )` · backticks · `<( )`, `$VAR` as the command when VAR holds
#     a literal from the same command, `xargs CMD` with the words a literal `echo`/`printf`/`cat FILE` feeds it, and a git alias (`-c alias.x=…` ·
#     `git config alias.x …` in the same command — a `!` alias is a shell command)
#   · strips git's global options before the subcommand (`-c k=v` · `-C dir` · `--git-dir` · `--work-tree` · `--no-pager` · `-p` · `--bare` …)
#   · reads the body of a script that runs — `bash|sh|zsh|dash|ksh FILE` · `source|. FILE` · `./FILE` · `bash < FILE` · `cat FILE | bash` · `| bash`
#     · `bash <<EOF` — from what the same command wrote to it (`echo|printf … > F` · `cat > F <<EOF` · `tee F`), else from disk (64 KB cap, a path
#     run directly only with a shell shebang or a .sh name). It is parsed the same way, so only its command-position lines count: a test script
#     that carries `"git push --force origin main"` as a quoted argument is data, not a push
# mark 1 = it came through a path the text checks cannot see (a wrapper, xargs, a script body, a shell's stdin); the SQL checks take only those lines.
# Undecidable, left as today (comment, not guess): a value computed at run time (`$CMD` from `$(…)` · `read`), a script fetched at run time (`curl … | sh`),
# a script over the cap, a non-shell interpreter (`python x.py`), an npm/pnpm script body, an alias set in an earlier command and stored in git config.
# A final `@@ok` line proves the pass finished — the caller fails closed without it.
_simple_cmds() (   # $1 command  $2 directory relative script paths resolve against
  trap - ERR; set +e
  printf '%s' "$1" | awk -v cwd="${2:-$PWD}" -v home="${HOME:-}" 'BEGIN { RS = "\001"; CAP = 65536; BUDGET = 262144; US = "\037"; CWD = cwd }
    function base(w) { sub(/.*\//, "", w); w = tolower(w); sub(/\.exe$/, "", w); return w }
    function qj(dep, a, b,   s, i, w) { s = ""; for (i = a; i <= b; i++) { w = W[dep, i]; gsub(/\047/, "\047\\\047\047", w); s = s " \047" w "\047" } return s }
    function pj(dep, a, b,   s, i) { s = ""; for (i = a; i <= b; i++) s = s (i > a ? " " : "") W[dep, i]; return s }
    function norm(p) {
      if (p == "") return ""
      if (substr(p, 1, 2) == "~/") p = home substr(p, 2)
      if (p !~ /^\// && p !~ /^[A-Za-z]:\//) p = CWD "/" p
      while (sub(/\/\.\//, "/", p)) ; sub(/\/\.$/, "", p)
      return p
    }
    function unesc(t) { gsub(/\\n/, "\n", t); gsub(/\\t/, "\t", t); return t }
    function disk(p, direct,   c, r, q, ok) {   # p normalised → content, "" when not a regular file · over the cap · (run directly) not a shell script
      # One sh call answers what awk cannot: getline on a directory is a fatal i/o error in BSD awk, and the size must be known before reading
      q = p; gsub(/\047/, "\047\\\047\047", q); q = "\047" q "\047"; ok = ""
      c = "f=" q "; [ -f \"$f\" ] && [ -r \"$f\" ] && [ \"$(wc -c < \"$f\")\" -le " CAP " ] && " \
          (direct ? "{ case \"$f\" in *.sh|*.bash|*.zsh|*.ksh) ;; *) head -n 1 \"$f\" | grep -Eq \"^#!.*[/ ]((ba|z|da|k)?sh)([[:space:]]|$)\" ;; esac; } && " : "") "echo y"
      c | getline ok; close(c)
      if (ok !~ /^y/) return ""   # RS is \001, so the line keeps its newline
      c = ""; r = (getline c < p); close(p)
      if (r < 0 || BUDGET < length(c)) return ""
      BUDGET -= length(c); return c
    }
    function resolve(p, direct,   k) {   # a script path → its content: what this command wrote there, else the file
      if (p == "" || p ~ /[$`*?]/) return ""
      k = norm(p)
      if (k in WR) return WR[k]
      return disk(k, direct)
    }
    function stdin_text(t) { return (substr(t, 1, 1) == "\001") ? resolve(substr(t, 2), 0) : t }
    function write_to(f, app, text,   k) { if (f == "" || f ~ /[$`]/ || f ~ /^\/dev\//) return; k = norm(f); WR[k] = (app ? ((k in WR) ? WR[k] : disk(k, 0)) : "") text }
    function emit(mark, name, dep, a, b, extra,   s, i, w) {
      s = mark US name
      for (i = a; i <= b; i++) { w = W[dep, i]; gsub(/[\n\r]/, " ", w); s = s US w }
      if (extra != "") { gsub(/[\n\r]/, " ", extra); s = s US extra }
      print s
    }
    function addword(dep, w,   r) {
      r = RED[dep]; RED[dep] = ""
      if (r == "") { W[dep, ++N[dep]] = w; return }
      if (r == ">" || r == ">>") { OUTF[dep] = w; OUTA[dep] = (r == ">>"); return }
      if (r == "<") { INF[dep] = w; return }
      if (r == "<<<") { HS[dep] = w; return }
      if (r == "<<" || r == "<<-") { HDN[dep]++; HDD[dep, HDN[dep]] = w; HDT[dep, HDN[dep]] = (r == "<<-"); HDK[dep, HDN[dep]] = "?"; return }
    }
    function closepar(s, i,   L, c, q, d) {   # i = first char after "(" → index of the matching ")"
      L = length(s); q = ""; d = 1
      for (; i <= L; i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == "\\" && q == "\"") i++; else if (c == q) q = ""; continue }
        if (c == "\\") { i++; continue }
        if (c == "\047" || c == "\"") q = c
        else if (c == "(") d++
        else if (c == ")") { if (--d == 0) return i }
      }
      return L + 1
    }
    function closetick(s, i,   L, c) { L = length(s); for (; i <= L; i++) { c = substr(s, i, 1); if (c == "\\") i++; else if (c == "`") return i } return L + 1 }
    function heredocs(s, i, dep,   L, k, body, ln, c, cmp) {
      L = length(s)
      for (k = 1; k <= HDN[dep]; k++) {
        body = ""
        while (i <= L) {
          ln = ""; while (i <= L && (c = substr(s, i, 1)) != "\n") { ln = ln c; i++ } i++
          cmp = ln; if (HDT[dep, k]) sub(/^\t+/, "", cmp)
          if (cmp == HDD[dep, k]) break
          body = body ln "\n"
        }
        if (HDK[dep, k] == "shell") parse(body, 1, dep + 1)
        else if (HDK[dep, k] == "write") write_to(HDF[dep, k], HDA[dep, k], body)
        else if (HDK[dep, k] == "db") { gsub(/[\n\r]/, " ", body); print HDL[dep, k] US body }
      }
      HDN[dep] = 0
      return i
    }
    function parse(s, mark, dep,   i, L, c, d, q, cur, inw, e, body, sep) {
      if (dep > 8) return
      L = length(s); i = 1; q = ""; cur = ""; inw = 0
      N[dep] = 0; RED[dep] = ""; OUTF[dep] = ""; OUTA[dep] = 0; INF[dep] = ""; HS[dep] = ""; HDN[dep] = 0; PIPEIN[dep] = ""
      while (i <= L) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == q) q = ""; else cur = cur c; i++; continue }
        if (q == "\"") {
          if (c == "\\" && i < L) { d = substr(s, i + 1, 1); if (d ~ /["\\$`]/) { cur = cur d; i += 2; continue } if (d == "\n") { i += 2; continue } }
          else if (c == "\"") { q = ""; i++; continue }
          else if (c == "$" && substr(s, i + 1, 1) == "(") { e = closepar(s, i + 2); body = substr(s, i + 2, e - i - 2); parse(body, mark, dep + 1); cur = cur "$(" body ")"; i = e + 1; continue }
          else if (c == "`") { e = closetick(s, i + 1); body = substr(s, i + 1, e - i - 1); parse(body, mark, dep + 1); cur = cur "`" body "`"; i = e + 1; continue }
          cur = cur c; i++; continue
        }
        if (c == "\\") { d = substr(s, i + 1, 1); if (d != "\n" && d != "") { cur = cur d; inw = 1 } i += 2; continue }
        if (c == "\047" || c == "\"") { q = c; inw = 1; i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == "\047") { q = "\047"; inw = 1; i += 2; continue }
        if ((c == "$" || c == "<" || c == ">") && substr(s, i + 1, 1) == "(") {
          e = closepar(s, i + 2); body = substr(s, i + 2, e - i - 2); parse(body, mark, dep + 1); cur = cur c "(" body ")"; inw = 1; i = e + 1; continue
        }
        if (c == "`") { e = closetick(s, i + 1); body = substr(s, i + 1, e - i - 1); parse(body, mark, dep + 1); cur = cur "`" body "`"; inw = 1; i = e + 1; continue }
        if (c == " " || c == "\t" || c == "\r") { if (inw) { addword(dep, cur); cur = ""; inw = 0 } i++; continue }
        if (c == "#" && !inw) { while (i <= L && substr(s, i, 1) != "\n") i++; continue }
        if (c == ">" || c == "<" || (c == "&" && substr(s, i + 1, 1) == ">")) {
          if (inw && cur ~ /^[0-9]+$/) { cur = ""; inw = 0 } else if (inw) { addword(dep, cur); cur = ""; inw = 0 }
          if (c == "&") { i++; c = ">" }
          if (substr(s, i, 3) == "<<<") { RED[dep] = "<<<"; i += 3; continue }
          if (substr(s, i, 2) == "<<") { RED[dep] = "<<"; i += 2; if (substr(s, i, 1) == "-") { RED[dep] = "<<-"; i++ } continue }
          RED[dep] = c; i++
          if (c == ">" && substr(s, i, 1) == ">") { RED[dep] = ">>"; i++ }
          if (substr(s, i, 1) == "|") i++
          if (substr(s, i, 1) == "&") { RED[dep] = "dup"; i++ }
          continue
        }
        if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")") {
          if (inw) { addword(dep, cur); cur = ""; inw = 0 }
          sep = c
          if (c == "|" && substr(s, i + 1, 1) == "|") { sep = "||"; i++ }
          else if (c == "|" && substr(s, i + 1, 1) == "&") i++
          else if (c == "&" && substr(s, i + 1, 1) == "&") { sep = "&&"; i++ }
          else if (c == ";" && substr(s, i + 1, 1) == ";") i++
          endcmd(mark, dep, sep); i++
          if (c == "\n" && HDN[dep] > 0) i = heredocs(s, i, dep)
          continue
        }
        cur = cur c; inw = 1; i++
      }
      if (inw) addword(dep, cur)
      endcmd(mark, dep, "")
      if (HDN[dep] > 0) heredocs("", 1, dep)
    }
    function endcmd(mark, dep, sep,   n, k, j, b, w, stdin, wrapped, nm, v, R, items, ni, it, t, content, x, sk) {
      n = N[dep]; stdin = PIPEIN[dep]; PIPEIN[dep] = ""; wrapped = 0; k = 1
      if (HS[dep] != "") stdin = HS[dep]
      if (INF[dep] != "") stdin = "\001" INF[dep]
      # leading assignments — a literal one is remembered for `$VAR` as a command word
      while (k <= n && W[dep, k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        nm = W[dep, k]; v = nm; sub(/=.*/, "", nm); sub(/^[^=]*=/, "", v)
        if (v !~ /[$`]/) VAR[nm] = v; else delete VAR[nm]
        k++
      }
      while (k <= n && W[dep, k] ~ /^(if|then|else|elif|do|while|until|!|\{|\}|fi|done|esac)$/) k++
      if (k <= n && W[dep, k] ~ /^(for|case|select|function|in)$/) k = n + 1
      for (;;) {   # wrappers — the command they run is the next word after their own options
        if (k > n) break
        b = base(W[dep, k])
        if (b == "sudo" || b == "doas") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] == "--") { k++; break } if (W[dep, k] ~ /^(-[ugCDhprtUT]|--(user|group|chdir|host|prompt|role|type|other-user|close-from))$/) k++; k++ } while (k <= n && W[dep, k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) k++ }
        else if (b == "env") {
          k++
          while (k <= n && (W[dep, k] ~ /^-/ || W[dep, k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
            if (W[dep, k] ~ /^(-S|--split-string)$/) { parse(W[dep, k + 1] qj(dep, k + 2, n), 1, dep + 1); k = n + 1; break }
            if (W[dep, k] == "--") { k++; break }
            if (W[dep, k] ~ /^(-u|-C|--unset|--chdir)$/) k++
            k++
          }
        }
        else if (b == "command") { k++; if (W[dep, k] ~ /^-[vV]/) k = n + 1; else if (W[dep, k] == "-p") k++ }
        else if (b == "exec") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] == "-a") k++; k++ } }
        else if (b ~ /^(nohup|setsid|time|chronic|unbuffer|caffeinate)$/) { k++; while (k <= n && W[dep, k] ~ /^-/) k++ }
        else if (b == "nice" || b == "ionice") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] ~ /^(-[ncpt]|--adjustment|--class|--classdata)$/) k++; k++ } }
        else if (b == "timeout") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] ~ /^(-[sk]|--signal|--kill-after)$/) k++; k++ } k++ }
        else if (b == "stdbuf") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] ~ /^-[ioe]$/ || W[dep, k] ~ /^--(input|output|error)$/) k++; k++ } }
        else if (b == "npx" || b == "bunx") { k++; while (k <= n && W[dep, k] ~ /^-/) { if (W[dep, k] ~ /^(-p|--package)$/) k++; k++ } }
        else if ((b == "pnpm" || b == "yarn") && W[dep, k + 1] ~ /^(exec|dlx)$/) k += 2
        else break
        wrapped = 1
      }
      if (k <= n) {
        b = base(W[dep, k]); mark = (mark || wrapped) ? 1 : 0
        if (W[dep, k] ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) {   # `$CMD` — re-parsed when CMD holds a literal set in this command
          nm = W[dep, k]; gsub(/[${}]/, "", nm)
          if (nm in VAR) parse(VAR[nm] qj(dep, k + 1, n), 1, dep + 1)
        }
        else if (b == "eval") parse(pj(dep, k + 1, n), mark, dep + 1)
        else if (b ~ /^(ba|z|da|k)?sh$/) {
          j = k + 1; sk = 0
          while (j <= n && W[dep, j] ~ /^[-+]/) {
            if (W[dep, j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) { parse(W[dep, j + 1], mark, dep + 1); sk = 1; break }
            if (W[dep, j] ~ /^-[A-Za-z]*n/) { sk = 1; break }
            if (W[dep, j] ~ /^([-+]o|--rcfile|--init-file)$/) j++
            j++
          }
          if (!sk) {
            if (j <= n) parse(resolve(W[dep, j], 0), 1, dep + 1)
            else if (HDN[dep] > 0 && HDK[dep, HDN[dep]] == "?") HDK[dep, HDN[dep]] = "shell"
            else if (stdin != "") parse(stdin_text(stdin), 1, dep + 1)
          }
        }
        else if (b == "source" || b == ".") { if (k < n) parse(resolve(W[dep, k + 1], 0), 1, dep + 1) }
        else if (b == "xargs") {
          j = k + 1; R = ""
          while (j <= n && W[dep, j] ~ /^-/) {
            w = W[dep, j]
            if (w == "--") { j++; break }
            if (w == "-I") { R = W[dep, j + 1]; j += 2; continue }
            if (w ~ /^-I./) { R = substr(w, 3); j++; continue }
            if (w ~ /^-i/) { R = (length(w) > 2) ? substr(w, 3) : "{}"; j++; continue }
            if (w ~ /^-[nLPsdEa]$/ || w ~ /^--(max-args|max-lines|max-procs|max-chars|delimiter|eof|arg-file|process-slot-var)$/) j++
            j++
          }
          content = (stdin == "") ? "" : stdin_text(stdin)
          ni = split(content, items, /[ \t\r\n]+/); t = ""; it = ""
          for (x = 1; x <= ni; x++) if (items[x] != "") { if (it == "") it = items[x]; t = t " " items[x] }
          if (j > n) { W[dep, j] = "echo"; n = j }
          if (R != "") { for (x = j; x <= n; x++) if (it != "") gsub(R == "{}" ? "\\{\\}" : R, it, W[dep, x]); parse(qj(dep, j, n), 1, dep + 1) }
          else parse(qj(dep, j, n) t, 1, dep + 1)
        }
        else if (b == "git") {
          j = k + 1
          while (j <= n && W[dep, j] ~ /^-/) {
            w = W[dep, j]
            if (w == "-c") { v = W[dep, j + 1]; if (v ~ /^alias\.[^=]+=/) { nm = v; sub(/^alias\./, "", nm); sub(/=.*/, "", nm); sub(/^[^=]*=/, "", v); AL[nm] = v } j += 2; continue }
            if (w ~ /^(-C|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--exec-path|--list-cmds)$/) j++
            j++
          }
          w = W[dep, j]
          if (w == "config") for (x = j + 1; x < n; x++) if (W[dep, x] ~ /^alias\./) { nm = W[dep, x]; sub(/^alias\./, "", nm); AL[nm] = W[dep, x + 1]; break }
          if (w in AL && ALD < 8) {
            ALD++; v = AL[w]
            if (substr(v, 1, 1) == "!") parse(substr(v, 2) qj(dep, j + 1, n), mark, dep + 1)
            else parse("git " v qj(dep, j + 1, n), mark, dep + 1)
            ALD--
          } else emit(mark, "git", dep, j, n, "")
        }
        else {
          if (b == "cd" || b == "pushd") { if (k < n && W[dep, k + 1] !~ /[$`]/ && W[dep, k + 1] != "-") CWD = norm(W[dep, k + 1]) }
          content = ""
          if (b == "echo") { j = k + 1; while (j <= n && W[dep, j] ~ /^-[neE]+$/) j++; content = unesc(pj(dep, j, n)) "\n" }
          else if (b == "printf" && W[dep, k + 1] != "-v") { content = unesc(W[dep, k + 1]); for (x = k + 2; x <= n; x++) content = content "\n" W[dep, x]; content = content "\n" }
          if ((b == "echo" || b == "printf") && OUTF[dep] != "") write_to(OUTF[dep], OUTA[dep], content)
          if (b == "cat" || b == "tee") {
            t = OUTF[dep]; x = OUTA[dep]
            if (b == "tee") { for (j = k + 1; j <= n; j++) if (W[dep, j] == "-a") x = 1; else if (W[dep, j] !~ /^-/) { t = W[dep, j]; break } }
            if (t != "" && HDN[dep] > 0 && HDK[dep, HDN[dep]] == "?") { HDK[dep, HDN[dep]] = "write"; HDF[dep, HDN[dep]] = t; HDA[dep, HDN[dep]] = x }
            else if (t != "" && stdin != "" && k == n) write_to(t, x, stdin_text(stdin))
            if (b == "cat" && k + 1 == n && OUTF[dep] == "") content = "\001" W[dep, n]
          }
          if (b ~ /^(psql|mysql|mariadb|sqlite3|mongo|mongosh|sqlcmd)$/ && HDN[dep] > 0 && HDK[dep, HDN[dep]] == "?") {
            HDK[dep, HDN[dep]] = "db"; HDL[dep, HDN[dep]] = mark US b; for (x = k + 1; x <= n; x++) HDL[dep, HDN[dep]] = HDL[dep, HDN[dep]] US W[dep, x]; gsub(/[\n\r]/, " ", HDL[dep, HDN[dep]])
          }
          else emit(mark, b, dep, k + 1, n, (b ~ /^(psql|mysql|mariadb|sqlite3|mongo|mongosh|sqlcmd)$/ && stdin != "" && substr(stdin, 1, 1) != "\001") ? stdin : "")
          if (W[dep, k] ~ /\// && b != "cd" && b != "pushd") parse(resolve(W[dep, k], 1), 1, dep + 1)
          if (sep == "|") PIPEIN[dep] = content
        }
      }
      for (x = 1; x <= HDN[dep]; x++) if (HDK[dep, x] == "?") HDK[dep, x] = ""
      N[dep] = 0; RED[dep] = ""; OUTF[dep] = ""; OUTA[dep] = 0; INF[dep] = ""; HS[dep] = ""
    }
    { parse($0, 0, 0) } END { print "@@ok" }'
)
# Can the tokenizer's output change a verdict? It is read for three things only: git/rm lines (GITX · the push checks), DB-client
# lines reached through a wrapper (SQLX), and its end marker. It reads a file only for a shell, `source`/`.`, a command word with a
# `/`, an input redirect, xargs, or `$VAR`/`$( )`/backticks as a command. So for _plain text with none of those characters, none
# of those words and no git/rm/client name in any casing — checked with quotes removed, since the tokenizer joins quoted pieces,
# and with no backslash, which it also removes — every line it can print is some other command, and it prints "@@ok".
_sc_cannot_matter() {
  _plain "$1" || return 1
  case "$1" in *[/\\\<\`\$=]*|*for*|*'()'*) return 1 ;; esac
  _noquotes "$1"
  case "$_NQ" in
    .|.[[:space:]]*|*[[:space:]\;\&\|\(].|*[[:space:]\;\&\|\(].[[:space:]\;\&\|\(\)]*|.[\;\&\|\(\)]*) return 1 ;;
    *[Ss][Hh]*|*[Ss][Oo][Uu][Rr][Cc][Ee]*|*[Xx][Aa][Rr][Gg][Ss]*|*[Ee][Vv][Aa][Ll]*|*[Ee][Nn][Vv]*|*[Gg][Ii][Tt]*|*[Rr][Mm]*) return 1 ;;
    *[Pp][Ss][Qq][Ll]*|*[Mm][Yy][Ss][Qq][Ll]*|*[Mm][Aa][Rr][Ii][Aa][Dd][Bb]*|*[Ss][Qq][Ll][Ii][Tt][Ee]*|*[Mm][Oo][Nn][Gg][Oo]*) return 1 ;;
    *[Ss][Qq][Ll][Cc][Mm][Dd]*|*[Ss][Uu][Pp][Aa][Bb][Aa][Ss][Ee]*|*[Pp][Rr][Ii][Ss][Mm][Aa]*|*[Dd][Rr][Ii][Zz][Zz][Ll][Ee]*|*[Aa][Ll][Ee][Mm][Bb][Ii][Cc]*) return 1 ;;
  esac
  return 0
}
destructive_gate() {
  # Judged after stripping the heredoc body (= data). The secret check **does not strip** —
  # the axis is the opposite: writing a secret is itself the exposure, so the body is exactly what is judged.
  _record_db_creator_fns "$1"
  local DCMD _xin="" _xout=""
  if _plain "$1"; then
    # The same four passes, each run only when its input holds what it rewrites (a heredoc `<<` · a `<shell> -c '…'` · a `for` ·
    # an assignment, loop or function) — otherwise it would print its input unchanged. A skipped `$( )` still drops trailing newlines
    DCMD=$1
    case "$DCMD" in *'<<'*) DCMD=$(_strip_heredoc_bodies "$DCMD") || true ;; esac
    while [[ "$DCMD" == *$'\n' ]]; do DCMD=${DCMD%$'\n'}; done
    case "$DCMD" in *sh*-*c*[\"\']*) DCMD=$(_unwrap_shell_c "$DCMD") || true ;; esac
    case "$DCMD" in *for*) DCMD=$(_inline_listed_files "$DCMD") || true ;; esac
    if ! _plain "$DCMD"; then _xin=$DCMD; DCMD=$(_expand_shell_literals "$DCMD"); _xout=$DCMD
    else case "$DCMD" in *=*|*for*|*'()'*) _xin=$DCMD; DCMD=$(_expand_shell_literals "$DCMD"); _xout=$DCMD ;; esac; fi
  else
    DCMD=$(_expand_shell_literals "$(_inline_listed_files "$(_unwrap_shell_c "$(_strip_heredoc_bodies "$1")")")")
  fi
  _GATE_CMD="$DCMD"
  # What runs, one simple command per line (see _simple_cmds). The literal expansion runs on the raw command — the tokenizer needs the
  # heredoc bodies (a script written with `cat > p.sh <<EOF` · `bash <<EOF`). $PWD = the session cwd the hook runs in (also what `git rev-parse` below reads)
  local SC SQLX="" GITX="" _l
  local -a _w
  # The literal expansion only changes text with an assignment, a loop or a function — skipped otherwise (one awk less on most commands)
  # The literal expansion of the raw command was often just computed for DCMD from the very same text — then it is reused
  # (CI run 7: the tokenizer commit made every Bash call ~20% slower on Windows, two awk passes over one string among it)
  if _sc_cannot_matter "$1"; then SC="@@ok"
  else case "$1" in
    *=*|*for*|*'()'*) if [ -n "$_xin" ] && [ "$_xin" = "$1" ]; then SC=$(_simple_cmds "$_xout" "$PWD") || SC=""
                      else SC=$(_simple_cmds "$(_expand_shell_literals "$1")" "$PWD") || SC=""; fi ;;
    *) SC=$(_simple_cmds "$1" "$PWD") || SC="" ;;
  esac; fi   # a failed pass is caught below, not by the ERR trap (whose exit code would be awk's)
  # Never fail open: without the end marker the pass died part-way and anything after that point was not seen.
  # Not a dblock title — it is a hook failure, not a pattern, so it stays out of the block-reason count the manual quotes
  if [ "${SC##*$'\n'}" != "@@ok" ] && [ "$SC" != "@@ok" ]; then
    printf '❌ Blocked: the command could not be parsed for the destructive-command check\n\nImpact: a force push, DROP or reset inside it would go unchecked.\n' >&2
    printf 'Safe alternative: split it into simpler commands, or run the parts separately.\n' >&2
    exit 2
  fi
  while IFS=$'\037' read -r -a _w; do
    [ "${#_w[@]}" -ge 2 ] || continue
    _l="${_w[*]:1}"
    case "${_w[1]}" in
      git|rm) GITX+="$_l"$'\n' ;;
      psql|mysql|mariadb|sqlite3|mongo|mongosh|sqlcmd|supabase|prisma|drizzle-kit|alembic) [ "${_w[0]}" = 1 ] && SQLX+="$_l"$'\n' ;;
    esac
  done <<< "$SC"
  local target="" _D _DP=0
  dhas() { grep <<<"$_D" -Eqi -e "$1"; }
  # A necessary keyword of the next dhas pattern (a glob, letters in both cases). For _plain text a case-insensitive grep can only
  # match where the keyword stands in some ASCII casing, so its absence answers "no" without the grep. Other text: always "maybe"
  _dk() { [ "$_DP" = 1 ] || return 0; local k; for k in "$@"; do case "$_D" in $k) return 0 ;; esac; done; return 1; }

  # ── Data destruction (SQL · migration tools) — judged per segment ───
  # A segment that is neither an investigation command, an authoring command, nor a message command = something meant to run
  local seg created_here="" _i _a _b _pn _none="" _fns=0
  local -a _segs=() _ex=()
  _exec_seg() {
    # A letter or digit is never [:space:] — only a segment without one needs the tr
    case "$1" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) ;; *) [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ] && return 1 ;; esac
    _readonly_cmd "$1" && return 1
    _authoring_cmd "$1" && return 1
    _message_cmd "$1" && return 1
    return 0
  }
  # The DBs the same command creates — gathered only from executing segments. A `CREATE DATABASE` string written to a file is not
  # a creation. Gathered first so that it is visible even when the DROP is in an earlier segment than the CREATE (`DROP … && CREATE …`)
  # Both loops below read the same segment list — it is read once, and whether a segment executes is judged once
  if [ -z "$SQLX" ] && _plain "$DCMD"; then   # the same lines _segments prints, read without the process substitution's fork
    _segments_v "$DCMD"; while IFS= read -r seg; do _segs+=("$seg"); done <<< "$_SEGS"
  else while IFS= read -r seg; do _segs+=("$seg"); done < <(_segments "$DCMD"; printf '%s' "$SQLX"); fi
  # _db_creates_via_fns has nothing to find unless a creator function was recorded (this call may just have recorded one, above)
  [ -n "${ORANGEKIT_ROOT:-}" ] && [ -f "${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}/created-db-fns" ] && _fns=1   # = _created_db_fns_file
  _i=0
  while [ "$_i" -lt ${#_segs[@]} ]; do
    seg=${_segs[_i]}; _ex[_i]=0; _i=$((_i + 1))
    _exec_seg "$seg" || continue
    _ex[_i - 1]=1
    # `create … database` is matched on the lowercased text with backslashes removed — no "create" in any casing, nothing to find
    _a=""; _b=""
    if _plain "$seg"; then case "$seg" in *[Cc]*[Rr]*[Ee]*[Aa]*[Tt]*[Ee]*) _a=$(_db_targets "$seg" create) || true ;; esac
    else _a=$(_db_targets "$seg" create) || true; fi
    [ "$_fns" = 0 ] || _b=$(_db_creates_via_fns "$seg")
    created_here="$created_here$_a
$_b
"
  done
  # Connection map — in segment order. A standalone assignment (`S=…` · `export DATABASE_URL=…`) carries forward, while an assignment before a command (`DATABASE_URL=… npm …`) applies to that command only
  local cmap="" segmap scratch_seg hd_delim="" a_lines
  _i=0
  while [ "$_i" -lt ${#_segs[@]} ]; do
    seg=${_segs[_i]}; _i=$((_i + 1))
    if [ -n "$hd_delim" ]; then   # a heredoc body going into a scratch-DB psql — it runs only inside that scratch DB
      [ "$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')" = "$hd_delim" ] && hd_delim=""
      continue
    fi
    # An assignment needs a `=`; with none, _conn_update would print the map back unchanged
    if _plain "$seg"; then case "$seg" in *=*) a_lines=$(_assigns_of "$seg") ;; *) a_lines="" ;; esac
    else a_lines=$(_assigns_of "$seg"); fi
    if [ -n "$a_lines" ]; then segmap=$(_conn_update "$a_lines" "$cmap"); else segmap=$cmap; fi
    if [ -n "$a_lines" ] && [ -z "$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*((export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|\$\([^)]*\)|[^[:space:];&|]+)[[:space:]]*)+//' | tr -d '[:space:]')" ]; then
      cmap="$segmap"
    fi
    [ "${_ex[_i - 1]}" = 1 ] || continue
    _D="$seg"; _DP=0; _plain "$seg" && _DP=1
    scratch_seg=0
    # _psql_conn_db answers "@@none@@" at once without a psql in the segment; that answer's proof depends only on this call's
    # state (created_here is complete, the records are written at the end), so it is computed once, not per segment
    case "$seg" in *psql*) _pn=$(_psql_conn_db "$seg" "$segmap" || printf '@@none@@') ;; *) _pn=@@none@@ ;; esac
    if [ "$_pn" = @@none@@ ] && [ -z "$_none" ]; then
      # "@@none@@" can only be proven a scratch DB by a record holding "@@" (an exact line, or a name with a per-run piece) —
      # none in this command and no record file means no; the steps it skips only read (and in this `if` cannot fail the hook)
      _none=1
      case "$created_here" in *@@*) _none="" ;; esac
      [ -n "${ORANGEKIT_ROOT:-}" ] && [ -f "${ORANGEKIT_STATE_DIR:-${ORANGEKIT_ROOT:-.}/.claude/.orangekit}/created-dbs" ] && _none=""
      if [ -z "$_none" ]; then if _scratch_db_ok "@@none@@" "$created_here"; then _none=0; else _none=1; fi; fi
    fi
    if _scratch_cmd "$seg" || { [ "$_pn" = @@none@@ ] && [ "$_none" = 0 ]; } || { [ "$_pn" != @@none@@ ] && _scratch_db_ok "$_pn" "$created_here"; }; then
      scratch_seg=1
      if grep <<<"$seg" -Eq '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*'; then
        hd_delim=$(grep <<<"$seg" -oE '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*' | head -1 | sed -E "s/^<<-?[[:space:]]*['\"]?//")
      fi
    fi
    if [ "$scratch_seg" = 1 ]; then
      # Work inside a scratch DB is exempt — but a DROP DATABASE that deletes a **different** DB from inside it still goes through the name proof
      dhas '(^|[^a-z_])drop[[:space:]]+database([^a-z_]|$)' && ! _scratch_dbs_ok "$seg" "$created_here" \
        && dblock "DROP of a table/database/schema via DDL" "That object and every row inside it disappears. Without a backup there is no recovery" \
                  "$_SCRATCH_HINT"
      continue
    fi

    _dk '*[Dd][Rr][Oo][Pp]*' && dhas '(^|[^a-z_])drop[[:space:]]+(table|database|schema)([^a-z_]|$)' \
      && ! _drop_exempt "$seg" "$created_here" \
      && dblock "DROP of a table/database/schema via DDL" \
                "That object and every row inside it disappears. Without a backup there is no recovery" \
                "Take a backup first (pg_dump or similar), run it inside a transaction, check the result, then commit. $_SCRATCH_HINT. The project DB (the connection URL in environment variables · .env*) and system DBs are still blocked"

    # coreutils `truncate -s 0 file` carries a dash, so it does not match
    _dk '*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*' && dhas '(^|[^a-z_])truncate[[:space:]]+(table[[:space:]]+)?["a-z_]' \
      && dblock "TRUNCATE — emptying an entire table" \
                "Every row is deleted and a rollback or recovery is usually impossible (triggers are skipped too)" \
                "Narrow the range with DELETE ... WHERE, or run it after a backup. $_SCRATCH_HINT"

    # DELETE without WHERE — only when the table name is followed directly by `;` or the end (no match when WHERE is present)
    _dk '*[Dd][Ee][Ll][Ee][Tt][Ee]*' && dhas '(^|[^a-z_])delete[[:space:]]+from[[:space:]]+["a-z_][a-z0-9_."]*[[:space:]]*(;|$)' \
      && dblock "DELETE FROM without WHERE" \
                "Every row in the target table is deleted" \
                "Narrow the range with a WHERE clause, and first check the number of affected rows with SELECT COUNT(*) on the same condition. $_SCRATCH_HINT"

    _dk '*[Ss][Uu][Pp][Aa][Bb][Aa][Ss][Ee]*' && dhas 'supabase[[:space:]]+db[[:space:]]+reset' \
      && dblock "supabase db reset — resetting the local DB" \
                "Schema and data are all deleted and migrations are reapplied from scratch. Data outside the seed disappears" \
                "To revert only one specific migration, write a new revert migration instead"

    _dk '*[Pp][Rr][Ii][Ss][Mm][Aa]*' && dhas 'prisma[[:space:]]+migrate[[:space:]]+reset|prisma[[:space:]]+db[[:space:]]+push[^|;&]*--force-reset' \
      && dblock "prisma schema reset" \
                "Drops the database and recreates it. All existing data disappears" \
                "Create an incremental migration with prisma migrate dev"

    _dk '*[Aa][Ll][Ee][Mm][Bb][Ii][Cc]*' '*[Dd][Rr][Ii][Zz][Zz][Ll][Ee]-[Kk][Ii][Tt]*' && dhas 'alembic[[:space:]]+downgrade[[:space:]]+base|drizzle-kit[[:space:]]+drop' \
      && dblock "reverting every migration" \
                "Every migration is un-applied and the schema and data disappear" \
                "Specify a single revision to revert to (alembic downgrade -1)"

    # An UPDATE without WHERE can be reverted, but it silently changes every row — warning
    _dk '*[Uu][Pp][Dd][Aa][Tt][Ee]*' && dhas '(^|[^a-z_])update[[:space:]]+["a-z_][a-z0-9_."]*[[:space:]]+set[^;]*(;|$)' \
      && ! dhas '(^|[^a-z_])where([^a-z_]|$)' \
      && dwarn "UPDATE without WHERE — every row in the table changes" "Check that the range is narrowed with a WHERE clause"
  done   # segments: _segments "$DCMD" + SQLX, the SQL that reaches a client only through a wrapper · xargs · a script (mark 1)

  # Below looks at the whole command — a git command completes within a segment and this vocabulary never turns up in a descriptive argument
  _D="$DCMD"$'\n'"$GITX"   # + git/rm as they run: global options stripped, eval · xargs · alias · script bodies resolved
  _DP=0; _plain "$_D" && _DP=1

  # ── git history destruction ─────────────────────────────────────────
  _dk '*[Ff][Ii][Ll][Tt][Ee][Rr]-*' '*--[Mm][Ii][Rr][Rr][Oo][Rr]*' && dhas 'git[[:space:]]+filter-branch|git[[:space:]]+filter-repo|git[[:space:]]+push[^|;&]*--mirror' \
    && dblock "git history rewrite / mirror push" \
              "Every commit hash changes and everyone else's clone goes out of sync. Remote history cannot be undone" \
              "If a rewrite is truly necessary, announce it to the team first, leave a backup branch and tag, then proceed"

  # ── Force push · remote branch deletion — judged by the target branch (three states) ───
  # Looking only at `--force` lets three forms that do the same thing through — the `+main` refspec (the original form of a force push),
  # `--delete main` and `:main` (remote branch deletion). Isolated injection confirmed all three exited 0 (evaluation v9 · E-61).
  # All four are one question: "does this change the remote history of a shared branch without other people's consent". The verdict rules
  # (target branch · pass when undecidable) stay as they are and **only the entrance** is widened.
  # Judged on every `git push` that runs (_simple_cmds), not on the first one the text shows: a feature-branch push in front used to hide
  # `&& git push --force origin main`, and quotes · `)` · `refs/heads/` around the branch name made the target read as another word.
  local pmode pforce pdel pall plead pskip pn a r
  local -a prefs
  while IFS=$'\037' read -r -a _w; do
    [ "${_w[1]:-}" = git ] && [ "${_w[2]:-}" = push ] || continue
    pforce=0; pdel=0; pall=0; plead=0; pskip=0; pn=0; prefs=()
    for a in "${_w[@]:3}"; do
      [ "$pskip" = 1 ] && { pskip=0; continue; }
      case "$a" in
        --force-with-lease*|--force-if-includes) plead=1 ;;
        --force) pforce=1 ;;
        --delete) pdel=1 ;;
        --all|--branches) pall=1 ;;
        -o|--push-option|--repo|--receive-pack|--exec) pskip=1 ;;
        --*) ;;
        -*) case "$a" in *f*) pforce=1 ;; esac; case "$a" in *d*) pdel=1 ;; esac ;;   # a short-option cluster: -uf · -fd
        *) pn=$((pn + 1)); [ "$pn" -ge 2 ] && prefs+=("$a") ;;   # the first word is the remote, the rest are refspecs
      esac
    done
    [ "$plead" = 1 ] && pforce=0   # --force-with-lease is the safe form (a `+ref` is still forced below)
    [ "${#prefs[@]}" -eq 0 ] && prefs=("")
    for r in "${prefs[@]}"; do
      pmode=""; [ "$pforce" = 1 ] && pmode="force"
      case "$r" in +*) pmode="force"; r="${r#+}" ;; esac
      case "$r" in :*) pmode="delete" ;; esac
      [ "$pdel" = 1 ] && pmode="delete"
      [ -n "$pmode" ] || continue
      # The destination of `src:dst` is the target; `refs/heads/main` is main
      target="${r##*:}"; target="${target#refs/heads/}"
      [ "$pall" = 1 ] && [ -z "$r" ] && target="every branch (--all)"
      # No refspec, HEAD, @ or the current-branch substitution = the current branch. HEAD is checked for existence first so that rev-parse does not
      # die with exit 128 in a repo with 0 commits — if it is absent, it is left undecidable.
      case "$target" in ""|HEAD|@|'$(git branch --show-current)'|'$(git rev-parse --abbrev-ref HEAD)'|'`git branch --show-current`')
        target=""
        git rev-parse -q --verify HEAD >/dev/null 2>&1 && target=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '') ;;
      esac
      case "$target" in *'$'*|*'`'*) target="" ;; esac   # a value computed at run time — undecidable, as before
      case "$target" in
        main|master|develop|development|release|release/*|prod|production|stage|staging|"every branch (--all)")
          if [ "$pmode" = "delete" ]; then
            dblock "remote deletion of a shared branch ($target)" \
                   "The branch disappears from the remote, cutting other people's tracking branches and open PRs. Without a local copy there is no recovery" \
                   "Check whether it is merged first, and do the deletion from the UI, through the host's branch protection rules"
          fi
          dblock "force push to a shared branch ($target)" \
                 "It overwrites remote history and commits other people pushed can disappear. Recovery requires their local copy" \
                 "git push --force-with-lease — it is refused when someone else's commits are there. Revert commits that are already public instead" ;;
        ""|HEAD)
          printf '⚠️  Undecidable: cannot confirm the target branch of the force push/delete\n' >&2
          printf '     (outside a repo · detached HEAD · 0 commits · a name computed at run time). Not blocking, letting it through —\n' >&2
          printf '     check for yourself whether the target is a shared branch, and use --force-with-lease.\n' >&2 ;;
        *)
          [ "$pmode" = "force" ] && dwarn "force push to a feature branch ($target)" "If the branch is shared, use --force-with-lease" ;;
      esac
    done
  done <<< "$SC"

  # ── A process kill that kills its own shell — sent back before execution ────────────
  # `pkill -f PAT` (or `kill $(pgrep -f PAT)`) searches the whole command line for PAT, and the command line of the shell running this command also contains PAT
  # literally, so it **kills its own shell too** — the commands after it never run and the call ends with exit 143/144. Measured (benchmark run4~6): it repeated in every tool
  # (baseline 7 · Superpowers 10 · gstack 6 · OrangeKit 1.11.0 16 times), and the same failure more than 3 times was recorded as "stuck".
  # Judged only when certain — the pattern reads as a quoted literal and **that pattern actually matches the characters of this command**. A `[s]erver.mjs` form does not match, so it passes.
  # Only Linux procps pkill and pgrep kill their own shell — the BSD/macOS versions exclude their own ancestor processes by default (measured: macOS survives and
  # a procps-ng 4.0.2 container gets exit 143). It does not happen anywhere else, so it is not blocked
  local kp kflat kprocps=0 ksid kbin=""
  # _self_kill_patterns only reports a word that is `pkill` or `pgrep` once quotes are removed — none, nothing to judge
  _plain "$DCMD" && { _noquotes "$DCMD"; case "$_NQ" in *pkill*|*pgrep*) ;; *) kprocps=skip ;; esac; }
  [ "$kprocps" = skip ] || {
  { pkill --version 2>&1 || true; } | grep -q procps && kprocps=1
  # If session start put the ancestor-excluding wrappers at the front of **this session's** PATH (per-session marker) and those wrappers
  # still exist, the shell does not die — do not guess and block. Other sessions' markers are not read (parallel sessions), and a marker
  # whose wrappers are gone (plugin update mid-session) falls back to the text check
  _clean_sid ksid "$F_SID"
  [ -n "$ksid" ] && kbin=$(head -1 "$(orangekit_state_dir)/proc-shim/$ksid" 2>/dev/null || true)
  [ -n "$kbin" ] && [ -x "$kbin/pkill" ] && [ -x "$kbin/pgrep" ] && kprocps=0
  kflat=$(printf '%s' "$1" | tr '\n' ' ')   # A shell command line is one string — aligned with grep's line-by-line judgement
  if [ "$kprocps" = 1 ]; then while IFS= read -r kp; do
    [ -n "$kp" ] || continue
    if grep <<<"$kflat" -Eq -- "$kp" 2>/dev/null; then
      printf '❌ Blocked: this command kills its own shell — `%s`\n\n' "$kp" >&2
      printf 'Impact: `pkill -f` and `pgrep -f` search the whole command line, and the command line of the shell running this command also contains this pattern, so it is terminated along with the target. The commands after it do not run and the call ends with exit 143/144.\n' >&2
      printf 'Fixed form: wrap the first character of the pattern in brackets — `pkill -f "%s"` (as a regex it finds the same process but does not match the characters of this command). If you know the PID, `kill <PID>` is the surest.\n' \
        "$(printf '%s' "$kp" | sed -E 's/^([A-Za-z0-9])/[\1]/')" >&2
      exit 2
    fi
  done < <(_self_kill_patterns "$DCMD"); fi
  }

  # ── Recoverable, but silently lost — warning only ───────────────────
  if _dk '*[Rr][Mm]*' && dhas '(^|[^a-z_])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)*-?[a-zA-Z]*[fF]' \
     && ! dhas '(node_modules|/dist|/build|\.next|\.turbo|\.cache|/tmp/|coverage)'; then
    dwarn "rm -rf — deleted files do not go through the trash" "Check the target path again. If the file is tracked, first see whether git can bring it back"
  fi
  _dk '*[Rr][Ee][Ss][Ee][Tt]*' && dhas 'git[[:space:]]+reset[^|;&]*--hard' \
    && dwarn "git reset --hard — uncommitted changes disappear" "Keep them first with git stash or git diff > patch"
  _dk '*[Cc][Ll][Ee][Aa][Nn]*' && dhas 'git[[:space:]]+clean[^|;&]*-[a-z]*[fd]' \
    && dwarn "git clean — untracked files are deleted" "Check the targets first with git clean -n"

  # Record the DBs created by a command that passed this gate — a later cleanup (`DROP DATABASE`) proves ② with them
  case "$created_here" in *[!$'\n']*) _record_created_dbs "$(grep <<<"$created_here" -v '^$' || true)" ;; esac   # only newlines: nothing to record
  return 0
}

# Edit/Write are not the only paths by which the model writes a file. When it writes with a Bash heredoc or a redirection,
# secret blocking becomes **0** if the matcher is only Edit|Write|MultiEdit — the gate's effective
# coverage then depends on tool choice (evaluation v5 · E-20).
# The edge is recorded **before the verdict**. Placed after the block() calls below, the moment a block happened
# that line was never reached, so --usage traversal counted only the success path —
# the very event the hook exists for was the least visible in the instrumentation (same discipline as the heartbeat).
[ -n "$ORANGEKIT_ROOT" ] && orangekit_edge "build" "security-check"

case "$TOOL_NAME" in
  Edit|Write|MultiEdit)
    TEXT="${CONTENT}${NEW_STRING}"
    ;;
  Bash)
    CMD=$F_CMD
    # A destructive command is irreversible **even when it writes no file**. It is looked at before the write filter below,
    # and **no command is exempt** — while the self-reference exemption still reached this far,
    # `…doctor.sh…; psql -c "DROP TABLE"` passed through whole (evaluation v6 · E-21).
    destructive_gate "$CMD"
    # Self-reference avoidance applies **only to the secret scan**, and only to a **single command** that runs this hook or doctor —
    # both carry the pattern strings themselves in their body, so a self-check command gets blocked by itself.
    _self_ref_cmd "$CMD" && _kg_done
    # Looks **only at commands that write a file**. Scanning read commands too would falsely block
    # investigation and inspection commands (`grep 'AKIA[0-9A-Z]{16}' ...`), and a false positive makes the
    # user turn the hook off, and a hook that is off blocks nothing.
    _writes_file "$CMD" || _kg_done
    TEXT="$CMD"
    ;;
  *) _kg_done ;;
esac
[ -z "$TEXT" ] && _kg_done

block() {
  printf '❌ Blocked: %s\n\n' "$1" >&2
  printf '%s\n\n' "$2" >&2
  # The guidance has to point at **a path that is actually possible**. The old wording said "move it to .env.local"
  # while writing to that very file was blocked too, so it pointed at the one place that was impossible.
  if [ "${ENV_NOT_IGNORED:-0}" = "1" ]; then
    printf 'This file is not in .gitignore — add it first. Then you can write here.\n' >&2
  else
    printf 'The right way: move it into a gitignored .env file (writing there is allowed).\n' >&2
  fi
  exit 2
}
warn() { printf '⚠️  %s\n%s\n' "$1" "$2" >&2; }

# -e is required: a pattern starting with '-', such as a PEM header, is mistaken by grep for an option
# A here-string is required: in `printf | grep -q`, when grep stops at its first match printf dies of SIGPIPE, and under
# pipefail that 141 reads as "no match". A secret near the **top** of a Write larger than the pipe buffer (~64KB) went
# through (consumer report). Every `grep <<<"$x"` in this file is there for the same reason.
has()  { grep <<<"$TEXT" -Eq  -e "$1"; }
hasi() { grep <<<"$TEXT" -Eqi -e "$1"; }
# One grep for the literal every secret pattern below must contain (AKIA · gh?_ · sk_ (also in _sk_) · sk- · AIza · sb_secret_ ·
# the JWT header · -----BEGIN · "service_account" · dangerouslySetInnerHTML · kakao). It runs case-insensitively — a superset of
# each case-sensitive pattern's literal, and the same matching as the KakaoPay `hasi` — so on a miss every `hass`/`hassi` is false
# without its own grep (each one re-wrote the whole text to a here-string temp file: 17 × 300 KB for one large Write).
# The negative zod check keeps its own grep
_SEC_ANY=1
hass() { [ "$_SEC_ANY" = 1 ] && has "$1"; }
hassi() { [ "$_SEC_ANY" = 1 ] && hasi "$1"; }

# ── .env exemption — only when proven ─────────────────────────────────
#
# The **legitimate destination** of a secret is a gitignored .env file. But this hook had only one path
# condition, package.json, so it was blocking writes there too — the block message guided the user to
# "move it to .env.local" while blocking writes to that very file, a contradiction, and
# "register the key as an environment variable", **the most common normal task**, was impossible.
#
# **The exemption is granted only when proven.** When undecidable (no git · outside a repo · untracked) no
# exemption is given and it falls through to the checks below, so today's behavior is preserved exactly —
# this relaxation never makes anything worse than today, and opens only when proven.
# That is why it does not conflict with "an undecidable verdict is not folded into a block": it does not add a new
# block, it **withholds a new exception**, and the existing blocks stay as they are.
#
# `.gitignore` is not scanned as text — that misses nested .gitignore files, negation patterns (`!`) and the global
# exclude. `git check-ignore` holds the authoritative answer.
# It moves into the directory the file is in and asks about the basename: the same result comes out whether
# file_path is absolute or relative, and git resolves the parent .gitignore hierarchy itself.
#
# **A Bash heredoc (`cat > .env.local <<EOF`) is not exempted.** On that path file_path is
# empty, and the target path cannot be parsed reliably out of a shell command string.
# (destructive_gate carries the same limit — see the "destructive statement inside a file" comment above.)
case "$TOOL_NAME" in
  Edit|Write|MultiEdit)
    # ${FILE_PATH##*/} is basename's answer unless the path ends in "/" (basename strips that first) — only then the fork
    case "$FILE_PATH" in */) _base=$(basename -- "$FILE_PATH") ;; *) _base=${FILE_PATH##*/} ;; esac
    if [[ "$_base" =~ ^\.env(\..+)?$ ]]; then
      if ( cd "$(dirname -- "$FILE_PATH")" 2>/dev/null \
           && git check-ignore -q -- "$(basename -- "$FILE_PATH")" 2>/dev/null ); then
        printf '🔐 Writing a secret to %s — the file is ignored by .gitignore, so it will not be committed.\n' "$FILE_PATH" >&2
        _kg_done
      fi
      # Not ignored, or undecidable. No exemption: it falls through to the checks below, but a mark is left so that
      # block()'s guidance branches to "add it to .gitignore".
      ENV_NOT_IGNORED=1
    fi
    ;;
esac

# ── Blocked: obvious secrets ──────────────────────────────────────────
grep <<<"$TEXT" -Eqi -e 'AKIA|gh[pousr]_|sk_|sk-|AIza|sb_secret_|eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9|-----BEGIN|"service_account"|dangerouslySetInnerHTML|kakao' || _SEC_ANY=0

hass 'AKIA[0-9A-Z]{16}' \
  && block "hardcoded AWS Access Key ID" "pattern: AKIA + 16 uppercase letters/digits"

hass 'ghp_[a-zA-Z0-9]{36}' \
  && block "hardcoded GitHub Personal Access Token" "pattern: ghp_ + 36 characters"

hass 'gh[pousr]_[A-Za-z0-9]{36,}' \
  && block "hardcoded GitHub token" "pattern: gho_/ghu_/ghs_/ghr_"

hass 'sk_(live|test)_[a-zA-Z0-9]{24,}' \
  && block "hardcoded Stripe Secret Key" "pattern: sk_live_ or sk_test_"

hass '(test|live)_sk_[a-zA-Z0-9]{20,}' \
  && block "hardcoded TossPayments Secret Key" "pattern: test_sk_ or live_sk_"

# KakaoPay — a secret named in the rules that was missing from the v2 check
hassi 'kakao.{0,20}(secret_?key|admin_?key)[[:space:]]*[:=][[:space:]]*['"'"'"][^'"'"'"]{16,}' \
  && block "hardcoded KakaoPay secret" "secretKey/adminKey belong in server environment variables only"

hass 'sk-proj-[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded OpenAI API Key" "pattern: sk-proj-"

hass 'sk-ant-[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded Anthropic API Key" "pattern: sk-ant-"

hass 'AIza[0-9A-Za-z_-]{35}' \
  && block "hardcoded Google API Key" "pattern: AIza + 35 characters"

# Supabase new key scheme (sb_secret_ / sb_publishable_)
hass 'sb_secret_[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded Supabase Secret Key" "sb_secret_ keys are server-only. Never expose one to the client"

# Supabase legacy JWT key
if hass 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.[a-zA-Z0-9_-]{40,}\.[a-zA-Z0-9_-]+'; then
  if hasi 'service_?role'; then
    block "hardcoded Supabase Service Role Key" "service_role bypasses RLS. Never expose it to the client"
  elif ! hasi 'anon|publishable'; then
    block "suspected hardcoded Supabase JWT key" "Possibly service_role. If it is anon, use a NEXT_PUBLIC_ environment variable"
  else
    warn "Supabase Anon Key detected" "It may be public, but using an environment variable is recommended"
  fi
fi

# has() already uses grep -e, so the call site must not add '--'.
# Adding it makes '--' the pattern argument and falsely blocks all code containing '--' (i--, count--).
hass '-----BEGIN[[:space:]]+(RSA|EC|DSA|OPENSSH|PGP)?[[:space:]]*PRIVATE KEY-----' \
  && block "hardcoded Private Key" "PEM-format private key"

if hass '"type"[[:space:]]*:[[:space:]]*"service_account"' && has '"private_key"[[:space:]]*:'; then
  block "hardcoded GCP Service Account JSON" "Use a GOOGLE_APPLICATION_CREDENTIALS path instead"
fi

# A secret in package.json
if [[ "$FILE_PATH" =~ package\.json$ ]] && hass '(AKIA|ghp_|sk_live_|sk_test_|sb_secret_)'; then
  block "secret inside package.json" "It is exposed on npm run"
fi

# ── Warnings (not blocked) ────────────────────────────────────────────

# Missing input validation in an API Route / Server Action
if [ "$TOOL_NAME" = "Write" ] \
   && [[ "$FILE_PATH" =~ (api/.+\.(ts|js)|/actions\.(ts|js))$ ]] \
   && ! has "(from ['\"]zod['\"]|z\.(object|string|number|array|enum|union))" \
   && ! has "(valibot|yup|joi|superstruct|arktype|typia)"; then
  warn "No schema validation detected in the API Route/Server Action: $FILE_PATH" \
       "Validate every external input with a schema (zod or similar)"
fi

# XSS — dangerouslySetInnerHTML warns when no sanitize accompanies it (not blocked:
# an existing sanitize import in the same file may not be visible in this diff)
if hass 'dangerouslySetInnerHTML' && ! hasi 'dompurify|sanitize'; then
  warn "dangerouslySetInnerHTML detected: $FILE_PATH" \
       "Sanitize it with DOMPurify or similar, or replace it with text rendering"
fi

# Direct .env edit
if [[ "$FILE_PATH" =~ \.env$ ]] || [[ "$FILE_PATH" =~ \.env\.(local|production)$ ]]; then
  warn ".env file modified: $FILE_PATH" "Check whether it is covered by .gitignore (.env.example is OK)"
fi

_kg_done
