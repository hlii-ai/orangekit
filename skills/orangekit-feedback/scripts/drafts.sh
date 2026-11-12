#!/bin/bash
# skills/orangekit-feedback/scripts/drafts.sh — the queue of bug reports session-brief drafts from orangekit hook errors
#
# session-brief writes one draft per new hook error into <project>/.claude/.orangekit/feedback-drafts/<id>.md and never
# drafts an error again once its file sits in sent/ or dismissed/. Moving a draft is this script's job, not an ad-hoc
# `mkdir`/`mv` by the model: Claude Code guards direct writes under .claude/, so the move stalled on a permission it
# could not get (measured in a real session — the draft stayed queued after "Dismiss").
#
#   drafts.sh list                         one line per queued draft: <id><TAB><title>
#   drafts.sh show <id>                    print one draft
#   drafts.sh mark <id> sent|dismissed     move it out of the queue
#   drafts.sh --self-test
#
# Ids are the numeric names session-brief gives (cksum of the error line) — anything else is refused, so a path
# cannot leave the drafts folder. Exit codes: 0 ok · 1 not found / nothing queued · 2 bad usage

set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
FD="${ORANGEKIT_STATE_DIR:-$ROOT/.claude/.orangekit}/feedback-drafts"

_id_ok() { case "${1:-}" in ''|*[!0-9]*) printf 'not a draft id: %s (digits only)\n' "${1:-}" >&2; return 1 ;; esac; return 0; }

cmd_list() {
  local f n=0
  for f in "$FD"/*.md; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "$(basename "$f" .md)" "$(sed -n '1s/^# //p' "$f")"; n=$((n+1))
  done
  [ "$n" -gt 0 ] || { printf 'no drafted reports in %s\n' "$FD" >&2; return 1; }
  return 0
}

cmd_show() {
  _id_ok "${1:-}" || return 2
  [ -f "$FD/$1.md" ] || { printf 'no queued draft %s\n' "$1" >&2; return 1; }
  cat "$FD/$1.md"
}

cmd_mark() {
  _id_ok "${1:-}" || return 2
  case "${2:-}" in sent|dismissed) ;; *) printf 'mark <id> sent|dismissed\n' >&2; return 2 ;; esac
  [ -f "$FD/$1.md" ] || { printf 'no queued draft %s\n' "$1" >&2; return 1; }
  mkdir -p "$FD/$2" && mv "$FD/$1.md" "$FD/$2/$1.md" || { printf 'could not move %s\n' "$1" >&2; return 1; }
  printf 'draft %s → %s/ (it will not be drafted again)\n' "$1" "$2"
}

self_test() {
  local t rc out pass=0 fail=0
  t=$(mktemp -d 2>/dev/null) || { echo 'no temp directory' >&2; return 2; }
  chk() { if [ "$1" = 0 ]; then pass=$((pass+1)); printf '  ✓ %s\n' "$2"; else fail=$((fail+1)); printf '  ✗ %s\n' "$2"; fi; }
  run() { ORANGEKIT_STATE_DIR="$t/state dir" bash "$0" "$@" 2>&1; }
  out=$(run list); rc=$?; chk "$([ "$rc" = 1 ] && echo 0 || echo 1)" "empty queue → exit 1"
  mkdir -p "$t/state dir/feedback-drafts"
  printf '# orangekit hook error: build-gate (exit 1)\n\nbody\n' > "$t/state dir/feedback-drafts/123.md"
  out=$(run list); rc=$?; chk "$([ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^123	orangekit hook error' && echo 0 || echo 1)" "list shows id and title"
  out=$(run show 123); chk "$(printf '%s' "$out" | grep -q '^body' && echo 0 || echo 1)" "show prints the draft"
  out=$(run show ../../etc/passwd); rc=$?; chk "$([ "$rc" = 2 ] && echo 0 || echo 1)" "a path instead of an id is refused (exit 2)"
  out=$(run mark 123 archived); rc=$?; chk "$([ "$rc" = 2 ] && echo 0 || echo 1)" "an unknown state is refused (exit 2)"
  out=$(run mark 123 dismissed); rc=$?
  chk "$([ "$rc" = 0 ] && [ -f "$t/state dir/feedback-drafts/dismissed/123.md" ] && [ ! -f "$t/state dir/feedback-drafts/123.md" ] && echo 0 || echo 1)" "mark dismissed moves it out of the queue"
  out=$(run mark 123 sent); rc=$?; chk "$([ "$rc" = 1 ] && echo 0 || echo 1)" "a draft no longer queued → exit 1"
  rm -rf "$t"
  printf '\n  pass %s · fail %s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  list)        cmd_list ;;
  show)        cmd_show "${2:-}" ;;
  mark)        cmd_mark "${2:-}" "${3:-}" ;;
  --self-test) self_test ;;
  -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" ;;
  *)           awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0" >&2; exit 2 ;;
esac
