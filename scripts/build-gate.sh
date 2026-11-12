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

INPUT=$(< /dev/stdin) 2>/dev/null || INPUT='{}'   # $(< …) reads without a cat exec; unreadable stdin → {} as before
# shellcheck source=lib/common.sh
_OK_PY_LAZY=1   # never runs Python: skip win-compat's Windows python probes on every call
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"
# One jq for all three fields (and the heartbeat's timestamp) — read first, it has no side effect
orangekit_fields "$INPUT" STOP_ACTIVE '.stop_hook_active' TRANSCRIPT '.transcript_path' SESSION_ID '.session_id'
orangekit_begin "build-gate" "$INPUT"

cd "$ORANGEKIT_ROOT" 2>/dev/null || exit 0
orangekit_edge "build" "build-gate"   # automatic at Stop — records the traversal fact regardless of the verdict

# Infinite-loop prevention: if we are already continuing because of this hook, do not block again
[ "$STOP_ACTIVE" = "true" ] && exit 0

# ── 1. Were any source files changed in this session? ─────────────────
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# A snapshot line is `path<TAB>mtime<TAB>size` (common.sh · orangekit_worktree_snapshot).
# Comparing names alone drops **a source file that was already uncommitted at session start**
# out of the difference no matter how much it changed — the gate went silent on the most common path of all, resuming work.
BASELINE="$(orangekit_state_dir)/session-baseline.txt"
CURRENT=$(orangekit_worktree_snapshot)

if [ -z "$CURRENT" ]; then
  CHANGED=""   # a clean tree: both branches below would give "" (the one empty line they see is dropped by the `$( )`)
elif [ -f "$BASELINE" ]; then
  # The difference is taken on snapshot **lines**, then only the paths are extracted: newly dirtied files and
  # files that were already dirty but changed again this time both remain.
  CHANGED=$(comm -13 <(sort "$BASELINE") <(printf '%s\n' "$CURRENT" | sort) 2>/dev/null \
            | orangekit_snapshot_paths | sort -u)
else
  CHANGED=$(printf '%s\n' "$CURRENT" | orangekit_snapshot_paths | sort -u)
fi

# Source extensions only (config, docs and markdown excluded)
# dart is the Flutter app axis — leave it out and a session that only edited .dart passes with no verification
[ -z "$CHANGED" ] && exit 0   # = SRC_CHANGED empty below, without its three greps
SRC_CHANGED=$(grep <<<"$CHANGED" -E '\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|java|kt|swift|dart|rb|php|vue|svelte)$' \
  | grep -vE '\.(config|test|spec)\.' | grep -vE '^\s*$' || true)

[ -z "$SRC_CHANGED" ] && exit 0

# ── 1-b. Keep only what **this session** changed ──────────────────────
# The snapshot difference is "what changed in the working tree", not "what this session changed". When other sessions
# work in the same checkout their edits land in the difference, and the gate **blocked this session over files it never
# touched** (consumer report 2026-10-28 · three sessions in parallel). Keep only files this session left a trace on in the
# transcript — ⓐ the path of an Edit · Write · MultiEdit · NotebookEdit ⓑ a file a Bash command **writes**.
# ⓑ used to be "the file's name appears in the command", so a read (`cat b/index.tsx` · `git diff` · `grep --include=index.tsx`)
# or a same-named file in another directory counted, and the gate blocked over another session's edit (consumer report B10).
# Now each segment's write targets are taken — redirections · tee · cp/mv/install/ln destination · rm/touch/truncate · sed -i ·
# git checkout/restore/mv/rm — and resolved against the call's cwd (the transcript records it per entry) plus any `cd` before
# them. Read-only commands count for nothing. **Conservative where it cannot tell**: a command it does not know (a codemod, a
# formatter, `python - <<EOF`) or a target it cannot resolve (`$VAR`, a glob) falls back to the old name match, and with no
# cwd a relative target matches as a path suffix — an unclear case counts as this session's, so a real edit is never missed.
# Known limit: a generator that changes files without naming them in the command is not counted.
# A transcript that cannot be read is undecidable — do not block (the three-state rule below).
{ [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] && command -v jq >/dev/null 2>&1; } || exit 0

# The three transcript passes below (files touched · verification commands · render traces) read **one** shared index
# (common.sh orangekit_transcript_index): it carries each pass's own jq program verbatim and is cached per session, so only
# the appended tail is parsed — three full jq passes cost ~3 s per turn on a 230 MB transcript (consumer report E3).
# Every pass reads line by line with `fromjson?`: one line jq cannot parse (a lone surrogate `\ud83d`, a truncated last line)
# stopped jq there, so every call after it was invisible — tests run later read as "not run" and blocked (consumer report N2).
# No index file could be written at all (no writable state dir and no temp dir): read as "transcript cannot be read" — do not block
orangekit_transcript_index "$TRANSCRIPT" "$SESSION_ID" || exit 0
_session_touched() {   # the T lines of the index = the old pass: "E<TAB>file" · "B<TAB>cwd<TAB>command (newlines as \037)"
  ORANGEKIT_SRC_LIST="$SRC_CHANGED" ORANGEKIT_ROOTS="$ORANGEKIT_ROOT
$(cd "$ORANGEKIT_ROOT" 2>/dev/null && pwd -P)" awk '
    substr($0, 1, 2) != "T\t" { next }
    { $0 = substr($0, 3) }
    # A bounded mention — look at the characters on both sides so `a.ts` does not match inside `data.tsx`
    function mention(s, p,    i, k, pre, post) {
      k = 0
      while ((i = index(substr(s, k + 1), p)) > 0) {
        k += i
        pre = (k > 1) ? substr(s, k - 1, 1) : ""
        post = substr(s, k + length(p), 1)
        if (pre !~ /[A-Za-z0-9_.-]/ && post !~ /[A-Za-z0-9_.-]/) return 1
      }
      return 0
    }
    # A mention of the bare file name only — when a directory is attached (`a/index.tsx`) it counts only if that path continues into
    # the path of this file. The fallback for commands and targets the write analysis below cannot judge.
    function endswith(s, t) { return length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
    function mention_base(s, base, full,    i, k, st, e, tok) {
      k = 0
      while ((i = index(substr(s, k + 1), base)) > 0) {
        k += i; e = k + length(base) - 1
        if (substr(s, e + 1, 1) ~ /[A-Za-z0-9_.-]/) continue
        st = k
        while (st > 1 && substr(s, st - 1, 1) ~ /[A-Za-z0-9_.\/~-]/) st--
        tok = substr(s, st, e - st + 1)
        if (tok == base) return 1                       # bare file name — loose, as before
        if (substr(s, k - 1, 1) != "/") continue        # part of another name (`data.tsx`)
        while (tok ~ /^(\.\.?\/)/) sub(/^\.\.?\//, "", tok)
        if (tok == full || endswith(full, "/" tok) || endswith(tok, "/" full)) return 1
      }
      return 0
    }
    # ── Bash: the files a command WRITES ──
    # Words, quote-aware. An operator is "\001op" (; | & ( ) && ||), a redirection "\002op" (> >> &> 2> < << <<<).
    function flush() { if (has || tok != "") T[++nt] = tok; tok = ""; has = 0 }
    function tokenize(s,   i, n, c, q, d) {
      nt = 0; tok = ""; has = 0; q = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\037") { if (q != "") tok = tok " "; else { flush(); T[++nt] = "\001;" }; continue }   # a newline (jq sent it as \037) ends a command
        if (q != "") {
          if (c == q) q = ""
          else if (q == "\"" && c == "\\" && i < n) { i++; tok = tok substr(s, i, 1) }
          else tok = tok c
          continue
        }
        if (c == "\"" || c == "\047") { q = c; has = 1; continue }
        if (c == "\\" && i < n) { i++; tok = tok substr(s, i, 1); has = 1; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (c == ">" || c == "<" || (c == "&" && substr(s, i + 1, 1) == ">")) {
          if (tok ~ /^[0-9]+$/) tok = ""             # the fd number of 2> is not a word
          flush(); d = c
          while (length(d) < 3 && substr(s, i + 1, 1) ~ /[<>&|]/) { i++; d = d substr(s, i, 1) }
          T[++nt] = "\002" d; continue
        }
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") {
          flush(); d = c
          if ((c == "|" || c == "&") && substr(s, i + 1, 1) == c) { i++; d = d c }
          T[++nt] = "\001" d; continue
        }
        tok = tok c; has = 1
      }
      flush()
    }
    function norm(p,   n, a, o, k, i, r) {
      if (p ~ /^[A-Za-z]:[\\\/]/) gsub(/\\/, "/", p)
      n = split(p, a, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] == ".") continue
        if (a[i] == "..") { if (k > 0) k--; continue }
        o[++k] = a[i]
      }
      r = ""; for (i = 1; i <= k; i++) r = r "/" o[i]
      if (k > 0 && o[1] ~ /^[A-Za-z]:$/) r = substr(r, 2)
      return r == "" ? "/" : r
    }
    # "?" unresolvable · "@rel" relative with no known cwd · otherwise an absolute normalized path
    function resolve(base, t) {
      if (t == "" || t ~ /[$`*?{]|\[/ || t ~ /^~/) return "?"
      if (t ~ /^\// || t ~ /^[A-Za-z]:[\\\/]/) return norm(t)
      if (base == "") { t = norm("/" t); return "@" substr(t, 2) }
      return norm(base "/" t)
    }
    function touches(r, wi,   k, rel) {
      if (substr(r, 1, 1) == "@") { r = substr(r, 2)
        return r == "" || r == wi || endswith(wi, "/" r) || index(wi, r "/") == 1 || index(wi, "/" r "/") > 0 }
      for (k = 1; k <= nr; k++) if (ROOTS[k] != "" && (r == ROOTS[k] || index(r, ROOTS[k] "/") == 1)) {
        rel = (r == ROOTS[k]) ? "" : substr(r, length(ROOTS[k]) + 2)
        return rel == "" || rel == wi || index(wi, rel "/") == 1          # the file, or a directory holding it
      }
      return endswith(r, "/" wi)                                          # outside both spellings of the root (an alias) — suffix
    }
    function count_mentions(s,   i) { for (i = 1; i <= n; i++) if (!hit[i] && (mention(s, w[i]) || mention_base(s, b[i], w[i]))) hit[i] = 1 }
    function count_target(t,   r, i) {
      r = resolve(cwd, t)
      if (r == "?") { unresolved = 1; return }
      for (i = 1; i <= n; i++) if (!hit[i] && touches(r, w[i])) hit[i] = 1
    }
    # One segment — tokens a..e. Words, redirect targets, then the command decides which words it writes.
    function judge(a, e,   i, d, nw, W, k, c, j, sc, inpl, nf, F, last, sub_, txt) {
      nw = 0; txt = ""; unresolved = 0
      for (i = a; i <= e; i++) {
        if (substr(T[i], 1, 1) == "\003") { txt = txt " " substr(T[i], 2); continue }   # heredoc body: text only
        txt = txt " " T[i]
        if (substr(T[i], 1, 1) == "\002") {
          d = substr(T[i], 2)
          if (i < e && d ~ />/ && d !~ /&$/) count_target(T[i + 1])      # > >> &> >| — the next word is written
          if (i < e) { i++; txt = txt " " T[i] }                            # < << <<< and >&2 — the next word is not
          continue
        }
        W[++nw] = T[i]
      }
      k = 1
      while (k <= nw && (W[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || W[k] ~ /^(sudo|env|time|nice|nohup|command|builtin|exec)$/)) k++
      c = (k <= nw) ? W[k] : ""; sub(/.*\//, "", c)
      if (c == "cd" || c == "pushd") {
        if (k < nw && W[k + 1] != "-") { j = resolve(cwd, W[k + 1]); cwd = (j == "?" || substr(j, 1, 1) == "@") ? "" : j } else cwd = ""
      } else if (c ~ /^(rm|rmdir|touch|truncate|unlink|tee|mv|shred)$/) {
        for (j = k + 1; j <= nw; j++) if (W[j] !~ /^-/) count_target(W[j])
      } else if (c ~ /^(cp|install|ln|rsync)$/) {
        last = ""; for (j = k + 1; j <= nw; j++) if (W[j] !~ /^-/) last = W[j]
        if (last != "") count_target(last)
      } else if (c == "sed" || c == "gsed") {
        inpl = 0; sc = 0; nf = 0
        for (j = k + 1; j <= nw; j++) {
          if (W[j] ~ /^-[A-Za-z]*i/ || W[j] ~ /^--in-place/) { inpl = 1; if (W[j] == "-i" && j < nw && W[j + 1] == "") j++; continue }
          if (W[j] ~ /^(-e|-f|--expression|--file)$/) { sc = 1; j++; continue }
          if (W[j] ~ /^-/) continue
          F[++nf] = W[j]
        }
        if (inpl) for (j = (sc ? 1 : 2); j <= nf; j++) count_target(F[j])
      } else if (c == "git") {
        j = k + 1; while (j <= nw && W[j] ~ /^-/) { if (W[j] == "-C") { unresolved = 1; break } j++ }
        sub_ = (j <= nw) ? W[j] : ""
        if (sub_ ~ /^(checkout|restore|mv|rm)$/) { for (j = j + 1; j <= nw; j++) if (W[j] !~ /^-/) count_target(W[j]) }
        else if (sub_ !~ /^(diff|log|show|status|blame|grep|ls-files|ls-tree|rev-parse|describe|shortlog|reflog|branch|remote|fetch|tag|add|commit|config|cat-file|show-ref|merge-base|worktree|push)$/) unresolved = 1
      } else if (c == "find") {
        for (j = k + 1; j <= nw; j++) if (W[j] ~ /^-(delete|exec|execdir|ok|okdir|fprint.*|fls)$/) unresolved = 1
      } else if (c == "awk" || c == "gawk") {
        for (j = k + 1; j <= nw; j++) if (W[j] ~ />/ || W[j] ~ /^-i/) unresolved = 1
      } else if (c !~ /^(cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|ls|wc|diff|cmp|file|stat|echo|printf|jq|yq|bat|tree|pwd|which|type|test|\[|true|false|sort|uniq|cut|tr|basename|dirname|realpath|readlink|nl|od|hexdump|xxd|strings|column|fold|printenv|date|sleep|mkdir|du|df|ps|kill|pgrep|lsof|open|code|man)$/ && c != "") unresolved = 1
      if (unresolved) count_mentions(txt)                                 # cannot tell what it writes — the old name match
    }
    BEGIN { n = split(ENVIRON["ORANGEKIT_SRC_LIST"], w, "\n")
            for (i = 1; i <= n; i++) { b[i] = w[i]; sub(/.*\//, "", b[i]) }
            nr = split(ENVIRON["ORANGEKIT_ROOTS"], ROOTS, "\n"); for (i = 1; i <= nr; i++) if (ROOTS[i] != "") ROOTS[i] = norm(ROOTS[i]) }
    # A Windows file_path (C:\…\src\a.ts) never ended in "/src/a.ts" — an Edit-only session was never blocked there (N3)
    /^E\t/ { p = substr($0, 3); if (p ~ /^[A-Za-z]:\\/) gsub(/\\/, "/", p)
             for (i = 1; i <= n; i++)
               if (!hit[i] && (p == w[i] || substr(p, length(p) - length(w[i])) == "/" w[i])) hit[i] = 1
             next }
    /^B\t/ { line = substr($0, 3); i = index(line, "\t")
             cwd = substr(line, 1, i - 1); cwd = (cwd == "") ? "" : norm(cwd)
             tokenize(substr(line, i + 1))
             # A heredoc body is data, not commands: keep it as text (the fallback still sees a path written by `python - <<EOF`)
             hd = ""; for (i = 1; i <= nt; i++) {
               if (hd != "") { if (T[i] == hd) hd = ""; T[i] = "\003" T[i]; continue }
               if (T[i] ~ /^\002<<-?$/ && i < nt) { hd = T[i + 1]; sub(/^-/, "", hd); i++ }   # <<-EOF tokenizes as << -EOF
             }
             s0 = 1
             for (i = 1; i <= nt + 1; i++) if (i > nt || substr(T[i], 1, 1) == "\001") { if (i > s0) judge(s0, i - 1); s0 = i + 1 }
             next }
    END { for (i = 1; i <= n; i++) if (hit[i]) print w[i] }' "$ORANGEKIT_TI"
}
SRC_CHANGED=$(_session_touched)
[ -z "$SRC_CHANGED" ] && exit 0

SRC_COUNT=$(orangekit_num "$(grep <<<"$SRC_CHANGED" -c . || printf '0')")
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
#
# The commands are the V lines of the transcript index — what the old `jq … | awk` pass fed this awk. awk now reads the file
# itself, so no writer can die of SIGPIPE when it exits early (that 141 under pipefail once read "ran" as "did not run" and
# blocked almost every turn of a long session — consumer report 2026-10-23~28).
_verification_ran() {
  awk '
    substr($0, 1, 2) != "V\t" { next }
    { $0 = substr($0, 3) }
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
        if (t ~ /^(pytest|jest|vitest|mocha|tsc|vue-tsc|ruff|mypy|pyright|eslint|biome|tox|nox|gradlew|gradle|mvnw|mvn|make|xcodebuild)$/) { found = 1; exit }
        if (s ~ /(^|[ \t])(install|add|i)([ \t]|$)/) continue
        if (t ~ /^(pnpm|npm|yarn|bun|npx|bunx|uv|poetry|pipx|python|python3|py|deno)$/ \
            && s ~ /[ \t][a-z:_-]*(build|test|typecheck|check|lint|pytest|unittest|jest|vitest|mocha|tsc|ruff|mypy|clippy)[a-z:_-]*([ \t"\047]|$)/) { found = 1; exit }
        if (t ~ /^(cargo|go|dotnet|swift)$/ && s ~ /^[a-z0-9.\/-]+[ \t]+(build|test|check|clippy|vet)([ \t]|$)/) { found = 1; exit }
        # App axis — flutter·dart count only when the subcommand is a verification (flutter pub get·flutter run are not)
        if (t ~ /^(flutter|dart)$/ && s ~ /^[a-z0-9.\/-]+[ \t]+(analyze|test|build)([ \t]|$)/) { found = 1; exit }
      } }
    END { exit found ? 0 : 1 }' "$ORANGEKIT_TI"
}
BUILD_RAN=0
_verification_ran && BUILD_RAN=1

# ── 2-a. A UI file is not finished when the build passes (notice, not a block) ───
# tsc passes a blank screen and a screen whose console explodes alike. So this **notifies** here.
# Why it does not block: false positives arise in environments with no headless browser and on component edits that need no server,
# and repeated false positives make the user turn the hook off (the principle in security-check.sh).
_ui_render_notice() {
  local ui_changed ui_count stamp
  ui_changed=$(grep <<<"$SRC_CHANGED" -E '\.(tsx|jsx|vue|svelte)$' || true)
  [ -z "$ui_changed" ] && return 0
  ui_count=$(orangekit_num "$(grep <<<"$ui_changed" -c . || printf '0')")
  [ "$ui_count" -eq 0 ] && return 0

  stamp="$(orangekit_state_dir)/ui-notice.stamp"
  [ -f "$stamp" ] && return 0   # once per session (session-brief clears it each session)

  # A trace that the render was checked — a probe or browser-automation Bash call, or a built-in /run skill call.
  # Not the presence of a string but **an actual tool call** (the lesson of v2's stop-guard).
  # The U lines of the transcript index (Bash commands and Skill names, as the old pass printed them), into the same grep
  if { awk 'substr($0, 1, 2) == "U\t" { print substr($0, 3) }' "$ORANGEKIT_TI" 2>/dev/null || true; } \
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
