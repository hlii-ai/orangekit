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

INPUT=$(cat 2>/dev/null || printf '{}')
# shellcheck source=lib/common.sh
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/common.sh"

# A failed root resolution must not stop the security check — only the heartbeat is best-effort
ORANGEKIT_HOOK_NAME="security-check"
ORANGEKIT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || printf '')}"
[ -n "$ORANGEKIT_ROOT" ] && orangekit_heartbeat 0

TOOL_NAME=$(orangekit_field "$INPUT" '.tool_name')
FILE_PATH=$(orangekit_field "$INPUT" '.tool_input.file_path')
CONTENT=$(orangekit_field "$INPUT" '.tool_input.content')
NEW_STRING=$(orangekit_field "$INPUT" '.tool_input.new_string')

# Avoid self-reference when this hook itself is being handled (the pattern strings match themselves)
[[ "$FILE_PATH" =~ security-check\.sh$ ]] && exit 0

# ══════════════════════════════════════════════════════════════════════
# Summoning the UI direction review (does not block)
# ══════════════════════════════════════════════════════════════════════
#
# **A different axis** from the secret and destruction gates. Those two stop what must not happen now;
# this one summons "a judgement that can only be made now".
#
# The T1 card `.claude/rules/ui-design.md` loads when Claude **reads a matching file**.
# When existing UI is edited, neighbours get read, so it comes up. But on greenfield, where there is
# nothing to read — the moment a first screen is created — it does not. That one slot, where the
# direction decision matters most, was empty, and this branch fills only that.
#
# **It does not block.** Whether the review actually happened cannot be judged by a machine, and an
# undecidable verdict is not blocked (harness-change "a guard has three states").
#
# The conditions are narrowed to three. Firing on every edit makes the user turn the hook off, and a hook that is off reaches nothing:
#   ① Write only — Edit and MultiEdit are excluded. Editing an existing file is not a direction decision
#   ② UI file extension — judging by directory makes `app/` drag in a FastAPI backend as well
#   ③ New creation only — an overwrite is a file that already has a direction
# Test and story files are left out: same extension, but not the place where direction is set.
#
# Without jq, orangekit_emit_context quietly emits nothing. This is a notice, not a block,
# so that degradation is accepted — a missing jq does not stop the security check.
if [ "$TOOL_NAME" = "Write" ] \
   && [[ "$FILE_PATH" =~ \.(tsx|jsx|vue|svelte|css|scss)$ ]] \
   && [[ ! "$FILE_PATH" =~ \.(test|spec|stories)\. ]] \
   && [ ! -f "$FILE_PATH" ]; then
  orangekit_emit_context PreToolUse \
'This is a new UI file. If the direction is still being decided, pass the review in `.claude/rules/ui-design.md` first — avoid the 3 default clusters · one signature element · 2-pass review. If you are following a direction that is already set, carry on.'
fi

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

# First token of the command (leading environment variable assignments are skipped)
_first_tok() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk '{print $1; exit}'
}

# Is it an investigation/search command? Blocking `grep 'DROP TABLE' supabase/migrations/` is itself the false positive.
#
# The order of judgement matters. Filtering first on "if psql/supabase appears anywhere in the command it is not a read"
# mistakes **a name inside a path** (`supabase/migrations/`) for a client.
# So a read is established by the first token first, and the read verdict is reversed only when a client appears
# **in command position after a pipe** (`cat x.sql | psql`).
_readonly_cmd() {
  case "$(_first_tok "$1")" in
    grep|egrep|fgrep|rg|ag|cat|head|tail|less|more|ls|find|wc|awk|diff|jq|file|stat|which|echo|printf) ;;
    git) printf '%s' "$1" | grep -Eq '^[[:space:]]*git[[:space:]]+(log|diff|show|grep|blame|status|branch|remote|config|rev-parse|describe|ls-files)([^a-zA-Z-]|$)' || return 1 ;;
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
  printf '%s' "$1" \
    | grep -Eqi '(\$\(|`|[|;&])[[:space:]]*(sudo[[:space:]]+)?(npx[[:space:]]+)?(psql|mysql|mariadb|sqlite3|mongosh?|supabase|prisma|drizzle-kit|alembic|sqlcmd)([[:space:]]|$)'
}

# Does a heredoc feed a DB client — then the body is not data but **SQL that will be executed**.
_feeds_db_client() {
  case "$(_first_tok "$1")" in
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
    { if (inhd) { l=$0; if (dash) sub(/^[ \t]+/,"",l); if (l==delim) inhd=0; else if (keep) print; next }
      if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
        # A `<<<` herestring is not a heredoc — if the preceding character is `<`, skip it
        if (RSTART==1 || substr($0,RSTART-1,1) != "<") {
          t=substr($0,RSTART,RLENGTH); dash=(substr(t,1,3)=="<<-")
          sub(/^<<-?[ \t]*/,"",t); gsub(/[\047"]/,"",t); delim=t; inhd=1
          keep=feeds_db($0) } }
      print }'
}

# A command that **writes** text to a file is not the execution of destruction.
# `cat > 0003_drop_legacy.sql <<'EOF' ... EOF` **authors** a migration, it does not
# execute one, and the same string shows up when writing fixtures, docs and tests.
# (The secret check runs the other way — writing a secret is itself the exposure, so that path stays watched.
#  In fact, while this gate was being built, the command writing its own fixture got blocked. That is why this function exists.)
# The verdict is not made from the heredoc alone: `psql <<'SQL'` is a heredoc but it is execution.
_authoring_cmd() {
  case "$(_first_tok "$1")" in
    cat|tee|printf|echo) printf '%s' "$1" | grep -Eq '(>|<<)' && return 0 ;;
  esac
  return 1
}

# A commit message, a PR title or a tag annotation **does not execute** SQL — DDL vocabulary in an argument is description.
# Measured (evaluation v6 · E-22): `git commit -m "fix: drop table legacy_users"` and
# `gh pr create --title "…drop table…"` were blocked with exit 2. A false positive that blocks a commit is the fastest way to make
# the user turn the hook off. The exemption is judged by **the first token** (not by string containment),
# and it is not granted when a DB client follows a pipe.
_message_cmd() {
  case "$(_first_tok "$1")" in
    git) printf '%s' "$1" | grep -Eq '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+(commit|tag|notes|merge|revert|stash)([^a-zA-Z-]|$)' || return 1 ;;
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
_segments() { printf '%s\n' "$1" | awk '{ gsub(/;|&&|\|\|/, "\n"); print }'; }

# Is it a **single command that runs** this hook or doctor? Used only for the self-reference exemption of the secret scan.
# It used to exempt on containment of the string `*doctor.sh*`, which skipped the whole destruction gate —
# `bash scripts/doctor.sh --help; psql -c "DROP TABLE users"` was exit 0 (evaluation v6 · E-21).
# The exemption is judged by the first token, and is not granted when another command follows (`;` `&&` `||` `&`).
_self_ref_cmd() {
  printf '%s' "$1" | grep -Eq '(;|&&|\|\||&[[:space:]]|&$)' && return 1
  local t1 t2
  t1=$(_first_tok "$1")
  t2=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' | awk '{print $2; exit}')
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
  c=$(printf '%s' "$1" | sed -E 's/[0-9]*>{1,2}[[:space:]]*\/dev\/null//g; s/&>[[:space:]]*\/dev\/null//g; s/[0-9]*>&[0-9]+//g')
  printf '%s' "$c" | grep -Eq '(^|[^0-9A-Za-z_])(tee|dd)([^0-9A-Za-z_]|$)' && return 0
  printf '%s' "$c" | grep -Eq '(^|[^-<>=])>{1,2}[[:space:]]*[^=&[:space:]]' && return 0
  return 1
}

destructive_gate() {
  # Judged after stripping the heredoc body (= data). The secret check **does not strip** —
  # the axis is the opposite: writing a secret is itself the exposure, so the body is exactly what is judged.
  local DCMD; DCMD=$(_strip_heredoc_bodies "$1")
  local target="" _D
  dhas() { printf '%s' "$_D" | grep -Eqi -e "$1"; }

  # ── Data destruction (SQL · migration tools) — judged per segment ───
  # A segment that is neither an investigation command, an authoring command, nor a message command = something meant to run
  local seg
  while IFS= read -r seg; do
    [ -z "$(printf '%s' "$seg" | tr -d '[:space:]')" ] && continue
    _readonly_cmd "$seg" && continue
    _authoring_cmd "$seg" && continue
    _message_cmd "$seg" && continue
    _D="$seg"

    dhas '(^|[^a-z_])drop[[:space:]]+(table|database|schema)([^a-z_]|$)' \
      && dblock "DROP of a table/database/schema via DDL" \
                "That object and every row inside it disappears. Without a backup there is no recovery" \
                "Take a backup first (pg_dump or similar), run it inside a transaction, check the result, then commit"

    # coreutils `truncate -s 0 file` carries a dash, so it does not match
    dhas '(^|[^a-z_])truncate[[:space:]]+(table[[:space:]]+)?["a-z_]' \
      && dblock "TRUNCATE — emptying an entire table" \
                "Every row is deleted and a rollback or recovery is usually impossible (triggers are skipped too)" \
                "Narrow the range with DELETE ... WHERE, or run it after a backup"

    # DELETE without WHERE — only when the table name is followed directly by `;` or the end (no match when WHERE is present)
    dhas '(^|[^a-z_])delete[[:space:]]+from[[:space:]]+["a-z_][a-z0-9_."]*[[:space:]]*(;|$)' \
      && dblock "DELETE FROM without WHERE" \
                "Every row in the target table is deleted" \
                "Narrow the range with a WHERE clause, and first check the number of affected rows with SELECT COUNT(*) on the same condition"

    dhas 'supabase[[:space:]]+db[[:space:]]+reset' \
      && dblock "supabase db reset — resetting the local DB" \
                "Schema and data are all deleted and migrations are reapplied from scratch. Data outside the seed disappears" \
                "To revert only one specific migration, write a new revert migration instead"

    dhas 'prisma[[:space:]]+migrate[[:space:]]+reset|prisma[[:space:]]+db[[:space:]]+push[^|;&]*--force-reset' \
      && dblock "prisma schema reset" \
                "Drops the database and recreates it. All existing data disappears" \
                "Create an incremental migration with prisma migrate dev"

    dhas 'alembic[[:space:]]+downgrade[[:space:]]+base|drizzle-kit[[:space:]]+drop' \
      && dblock "reverting every migration" \
                "Every migration is un-applied and the schema and data disappear" \
                "Specify a single revision to revert to (alembic downgrade -1)"

    # An UPDATE without WHERE can be reverted, but it silently changes every row — warning
    dhas '(^|[^a-z_])update[[:space:]]+["a-z_][a-z0-9_."]*[[:space:]]+set[^;]*(;|$)' \
      && ! dhas '(^|[^a-z_])where([^a-z_]|$)' \
      && dwarn "UPDATE without WHERE — every row in the table changes" "Check that the range is narrowed with a WHERE clause"
  done < <(_segments "$DCMD")

  # Below looks at the whole command — a git command completes within a segment and this vocabulary never turns up in a descriptive argument
  _D="$DCMD"

  # ── git history destruction ─────────────────────────────────────────
  dhas 'git[[:space:]]+filter-branch|git[[:space:]]+filter-repo|git[[:space:]]+push[^|;&]*--mirror' \
    && dblock "git history rewrite / mirror push" \
              "Every commit hash changes and everyone else's clone goes out of sync. Remote history cannot be undone" \
              "If a rewrite is truly necessary, announce it to the team first, leave a backup branch and tag, then proceed"

  # ── Force push · remote branch deletion — judged by the target branch (three states) ───
  # Looking only at `--force` lets three forms that do the same thing through — the `+main` refspec (the original form of a force push),
  # `--delete main` and `:main` (remote branch deletion). Isolated injection confirmed all three exited 0 (evaluation v9 · E-61).
  # All four are one question: "does this change the remote history of a shared branch without other people's consent". The verdict rules
  # (target branch · pass when undecidable) stay as they are and **only the entrance** is widened.
  local pushseg="" pmode=""
  if dhas 'git[[:space:]]+push'; then
    pushseg=$(printf '%s' "$DCMD" | tr ';|&' '\n' | grep -E 'git[[:space:]]+push' | head -1)
    if printf '%s' "$pushseg" | grep -Eq -- '(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))' \
       && ! printf '%s' "$pushseg" | grep -q -- '--force-with-lease'; then
      pmode="force"
    elif printf '%s' "$pushseg" | grep -Eq '[[:space:]]\+[A-Za-z0-9_./:-]+'; then
      pmode="force"
    elif printf '%s' "$pushseg" | grep -Eq -- '(^|[[:space:]])(--delete|-d)([[:space:]]|$)|[[:space:]]:[A-Za-z0-9_./-]+([[:space:]]|$)'; then
      pmode="delete"
    fi
  fi
  if [ -n "$pmode" ]; then
    # The last non-flag token of an explicit refspec is taken as the target (the `+` of `+main` and the `src:` of `src:dst` are stripped)
    target=$(printf '%s' "$pushseg" \
             | awk '{n=0; for(i=1;i<=NF;i++) if($i !~ /^-/) t[++n]=$i; if(n>=4) print t[n]}')
    target="${target#+}"; target="${target##*:}"
    # With no refspec it is the current branch. HEAD is checked for existence first so that rev-parse does not
    # die with exit 128 in a repo with 0 commits — if it is absent, it is left undecidable.
    if [ -z "$target" ] && git rev-parse -q --verify HEAD >/dev/null 2>&1; then
      target=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')
    fi
    case "$target" in
      main|master|develop|development|release|release/*|prod|production|stage|staging)
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
        printf '     (outside a repo · detached HEAD · 0 commits). Not blocking, letting it through —\n' >&2
        printf '     check for yourself whether the target is a shared branch, and use --force-with-lease.\n' >&2 ;;
      *)
        [ "$pmode" = "force" ] && dwarn "force push to a feature branch ($target)" "If the branch is shared, use --force-with-lease" ;;
    esac
  fi

  # ── Recoverable, but silently lost — warning only ───────────────────
  if dhas '(^|[^a-z_])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+)*-?[a-zA-Z]*[fF]' \
     && ! dhas '(node_modules|/dist|/build|\.next|\.turbo|\.cache|/tmp/|coverage)'; then
    dwarn "rm -rf — deleted files do not go through the trash" "Check the target path again. If the file is tracked, first see whether git can bring it back"
  fi
  dhas 'git[[:space:]]+reset[^|;&]*--hard' \
    && dwarn "git reset --hard — uncommitted changes disappear" "Keep them first with git stash or git diff > patch"
  dhas 'git[[:space:]]+clean[^|;&]*-[a-z]*[fd]' \
    && dwarn "git clean — untracked files are deleted" "Check the targets first with git clean -n"

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
    CMD=$(orangekit_field "$INPUT" '.tool_input.command')
    # A destructive command is irreversible **even when it writes no file**. It is looked at before the write filter below,
    # and **no command is exempt** — while the self-reference exemption still reached this far,
    # `…doctor.sh…; psql -c "DROP TABLE"` passed through whole (evaluation v6 · E-21).
    destructive_gate "$CMD"
    # Self-reference avoidance applies **only to the secret scan**, and only to a **single command** that runs this hook or doctor —
    # both carry the pattern strings themselves in their body, so a self-check command gets blocked by itself.
    _self_ref_cmd "$CMD" && exit 0
    # Looks **only at commands that write a file**. Scanning read commands too would falsely block
    # investigation and inspection commands (`grep 'AKIA[0-9A-Z]{16}' ...`), and a false positive makes the
    # user turn the hook off, and a hook that is off blocks nothing.
    _writes_file "$CMD" || exit 0
    TEXT="$CMD"
    ;;
  *) exit 0 ;;
esac
[ -z "$TEXT" ] && exit 0

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
has()  { printf '%s' "$TEXT" | grep -Eq  -e "$1"; }
hasi() { printf '%s' "$TEXT" | grep -Eqi -e "$1"; }

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
    if [[ "$(basename -- "$FILE_PATH")" =~ ^\.env(\..+)?$ ]]; then
      if ( cd "$(dirname -- "$FILE_PATH")" 2>/dev/null \
           && git check-ignore -q -- "$(basename -- "$FILE_PATH")" 2>/dev/null ); then
        printf '🔐 Writing a secret to %s — the file is ignored by .gitignore, so it will not be committed.\n' "$FILE_PATH" >&2
        exit 0
      fi
      # Not ignored, or undecidable. No exemption: it falls through to the checks below, but a mark is left so that
      # block()'s guidance branches to "add it to .gitignore".
      ENV_NOT_IGNORED=1
    fi
    ;;
esac

# ── Blocked: obvious secrets ──────────────────────────────────────────

has 'AKIA[0-9A-Z]{16}' \
  && block "hardcoded AWS Access Key ID" "pattern: AKIA + 16 uppercase letters/digits"

has 'ghp_[a-zA-Z0-9]{36}' \
  && block "hardcoded GitHub Personal Access Token" "pattern: ghp_ + 36 characters"

has 'gh[pousr]_[A-Za-z0-9]{36,}' \
  && block "hardcoded GitHub token" "pattern: gho_/ghu_/ghs_/ghr_"

has 'sk_(live|test)_[a-zA-Z0-9]{24,}' \
  && block "hardcoded Stripe Secret Key" "pattern: sk_live_ or sk_test_"

has '(test|live)_sk_[a-zA-Z0-9]{20,}' \
  && block "hardcoded TossPayments Secret Key" "pattern: test_sk_ or live_sk_"

# KakaoPay — a secret named in the rules that was missing from the v2 check
hasi 'kakao.{0,20}(secret_?key|admin_?key)[[:space:]]*[:=][[:space:]]*['"'"'"][^'"'"'"]{16,}' \
  && block "hardcoded KakaoPay secret" "secretKey/adminKey belong in server environment variables only"

has 'sk-proj-[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded OpenAI API Key" "pattern: sk-proj-"

has 'sk-ant-[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded Anthropic API Key" "pattern: sk-ant-"

has 'AIza[0-9A-Za-z_-]{35}' \
  && block "hardcoded Google API Key" "pattern: AIza + 35 characters"

# Supabase new key scheme (sb_secret_ / sb_publishable_)
has 'sb_secret_[a-zA-Z0-9_-]{20,}' \
  && block "hardcoded Supabase Secret Key" "sb_secret_ keys are server-only. Never expose one to the client"

# Supabase legacy JWT key
if has 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.[a-zA-Z0-9_-]{40,}\.[a-zA-Z0-9_-]+'; then
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
has '-----BEGIN[[:space:]]+(RSA|EC|DSA|OPENSSH|PGP)?[[:space:]]*PRIVATE KEY-----' \
  && block "hardcoded Private Key" "PEM-format private key"

if has '"type"[[:space:]]*:[[:space:]]*"service_account"' && has '"private_key"[[:space:]]*:'; then
  block "hardcoded GCP Service Account JSON" "Use a GOOGLE_APPLICATION_CREDENTIALS path instead"
fi

# A secret in package.json
if [[ "$FILE_PATH" =~ package\.json$ ]] && has '(AKIA|ghp_|sk_live_|sk_test_|sb_secret_)'; then
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
if has 'dangerouslySetInnerHTML' && ! hasi 'dompurify|sanitize'; then
  warn "dangerouslySetInnerHTML detected: $FILE_PATH" \
       "Sanitize it with DOMPurify or similar, or replace it with text rendering"
fi

# Direct .env edit
if [[ "$FILE_PATH" =~ \.env$ ]] || [[ "$FILE_PATH" =~ \.env\.(local|production)$ ]]; then
  warn ".env file modified: $FILE_PATH" "Check whether it is covered by .gitignore (.env.example is OK)"
fi

exit 0
