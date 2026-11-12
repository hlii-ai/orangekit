#!/bin/bash
# harness/skills/pack-refresh/scripts/pack-refresh.sh — raise an axis pack to a newer major only after it is proven
#
# pack.json `pkgs` is not "what to install". It is "the majors this pack's code was verified on". Raising it without
# re-verifying makes the stamp lie: the guide still shows the old API and a consumer gets code that does not compile.
# So the bump is gated mechanically, not by an instruction:
#
#   pack-refresh.sh --check [pack-dir...]         which packs have a newer major (guide-freshness · needs the network)
#   pack-refresh.sh --verify <pack-dir>           guide-gate --pack + pack-smoke --pack --online. On a pass, records the
#                                                 pack's content hash outside the tree (.git/pack-refresh/)
#   pack-refresh.sh --bump <pack-dir> <x.y.z>     raises packVersion · verified · the stamps of the changed files —
#                                                 refused unless the content is exactly what --verify passed
#   pack-refresh.sh --self-test                   proves --bump refuses unverified and since-changed content
#
# Exit codes: 0 = ok · 1 = stale majors found / verify failed / bump refused · 2 = usage or asset error

set -uo pipefail   # no -e: a failed check is reported, not a reason to stop half-way

# Windows shims — a COPY of orangekit-product's scripts/lib/win-compat.sh (this plugin ships without scripts/).
# doctor --default compares it with the canonical file; change both together.
# ── Windows (Git Bash · MSYS · Cygwin): resolve Python, strip CRLF
# `python3` is often the Microsoft Store alias — on PATH, but it opens the Store (exit 9009) instead of running — while a
# python.org install answers to `python` or `py -3`. Native jq.exe and python.exe also end every line with CRLF, and the
# trailing \r broke comparisons silently. Only on a Windows shell; macOS and Linux are untouched.
case "${OSTYPE:-}" in
  msys*|cygwin*|win*)
    # Python on Windows writes stdout in the console code page (cp1252): a message holding ≠ or → raised UnicodeEncodeError,
    # the check died and its FAIL never printed — guide-gate passed bad stack cards on windows-latest (CI run 6)
    export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
    # The probes start up to three Windows processes (an interpreter ~0.1 s each). A hook that never runs Python sets _OK_PY_LAZY
    # before sourcing (security-check and build-gate, on every tool call) and skips them; python3 then resolves on its first call.
    # Everything else resolves here, once, as before — an answer first found inside $( ) would not reach the parent shell, and
    # a loop of `$(… | python3 …)` would probe again every time. Nothing found → the plain python3 on PATH, as before
    _ok_py_resolve() {
      local _ok_c; _OK_PY=""
      for _ok_c in python3 python "py -3"; do
        # an `if` condition: a failing probe must not trip the caller's `set -e` (common.sh) when it runs on a first call
        if command $_ok_c -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then _OK_PY=$_ok_c; break; fi
      done
      return 0
    }
    python3() {
      # first call (lazy): in a trap-free $( ) — the caller's ERR trap (common.sh) fires on a failing probe even inside an `if` on bash 3.2
      [ -n "${_OK_PY+x}" ] || _OK_PY=$(trap - ERR; _ok_py_resolve; printf '%s' "$_OK_PY")
      [ -n "$_OK_PY" ] || { command python3 "$@"; return; }
      command $_OK_PY "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"
    }
    [ -n "${_OK_PY_LAZY:-}" ] || { _ok_py_resolve; [ -n "$_OK_PY" ] || unset -f python3; }   # as before: no Python, no function
    command -v jq >/dev/null 2>&1 && jq() { command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; } ;;
esac

FAIL=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_D=""; C_0=""; }
# doctor.sh's conventions are copied (not sourced — lib/common.sh's set -e and ERR trap conflict with running every check)
ok()  { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad() { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec() { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }

# The repo is the one you are working in, not where this script sits — an installed orangekit-harness holds only harness/
REPO="${PACK_REFRESH_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
GATE="${PACK_REFRESH_GATE:-$REPO/skills/stack-guide-generator/scripts/guide-gate.sh}"
SMOKE="${PACK_REFRESH_SMOKE:-$REPO/skills/stack-guide-generator/scripts/pack-smoke.sh}"
FRESH="$REPO/scripts/guide-freshness.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# sha256sum ships with Linux and recent macOS; older macOS has only `shasum -a 256` (same digest, same output shape)
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
# Every file of the pack, in a fixed order, hashed together — what was verified is exactly what gets bumped
pack_hash() {
  (cd "$1" && find . -type f ! -name '*.bak' | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) \
    | _sha256 | cut -d' ' -f1
}
# The record lives in .git — never committed, never shipped to consumers
record_file() {
  local gd; gd=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/pack-refresh/%s' "$gd" "$(printf '%s' "$1" | sed 's#.*guides/##; s#/*$##; s#/#__#g')"
}

do_check() {
  [ $# -gt 0 ] || set -- "$REPO"/guides/frontend/*/ "$REPO"/guides/app/*/ "$REPO"/guides/backend/*/
  bash "$FRESH" --pack "$@"
}

do_verify() {
  local P="${1:-}" rec code
  [ -f "$P/pack.json" ] || { printf 'not a pack directory: %s\n' "$P" >&2; exit 2; }
  rec=$(record_file "$P") || { printf 'no git repository at %s — nowhere to record the verification\n' "$REPO" >&2; exit 2; }
  rm -f "$rec"
  sec "verify $P"
  code=0; bash "$GATE" --pack "$P" || code=$?
  [ "$code" -eq 0 ] && ok "guide-gate --pack passed" || bad "guide-gate --pack failed (exit $code)" "fix the guide code, then verify again"
  code=0; bash "$SMOKE" --pack "$P" --online || code=$?
  [ "$code" -eq 0 ] && ok "pack-smoke --pack --online passed" || bad "pack-smoke --pack --online failed (exit $code)" "the new major does not typecheck or run — fix it, then verify again"
  if [ "$FAIL" -eq 0 ]; then
    mkdir -p "$(dirname "$rec")" && pack_hash "$P" > "$rec"
    ok "verified content recorded — --bump is allowed for exactly this content"
  fi
}

do_bump() {
  local P="${1:-}" V="${2:-}" rec today pkgs id changed f
  [ -f "$P/pack.json" ] || { printf 'not a pack directory: %s\n' "$P" >&2; exit 2; }
  # Digits and two dots only — the value goes into sed replacements (a glob let `1.2.3/x` or `1.2.3&` through)
  printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { printf 'version must look like x.y.z: %s\n' "$V" >&2; exit 2; }
  rec=$(record_file "$P") || { printf 'no git repository at %s\n' "$REPO" >&2; exit 2; }
  sec "bump $P → $V"
  if [ ! -f "$rec" ]; then
    bad "refused: this pack was not verified" "run --verify first — pack.json changes only after the new major is proven"; return
  fi
  if [ "$(cat "$rec")" != "$(pack_hash "$P")" ]; then
    bad "refused: the pack changed after it was verified" "run --verify again on the current content"; return
  fi
  today=$(date -u +%Y-%m-%d)
  pkgs=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("pkgs") or []))' "$P/pack.json" | tr -d '\r') \
    || { bad "refused: could not read pkgs from pack.json (python3)" "the PACK.md stamp would be written with no packages"; return; }
  [ -n "$pkgs" ] || { bad "refused: pack.json has no pkgs" "the PACK.md stamp records the verified majors — it cannot be empty"; return; }
  id=$(printf '%s' "$P" | sed 's#.*guides/##; s#/*$##')
  # Stamps follow the files that changed since the last commit, plus PACK.md, whose stamp carries the pkgs
  changed=$( { git -C "$REPO" diff --name-only HEAD -- "$P" 2>/dev/null; git -C "$REPO" ls-files --others --exclude-standard -- "$P" 2>/dev/null; } \
             | sed "s#^#$REPO/#" | grep '\.md$' || true)
  changed=$(printf '%s\n%s\n' "$changed" "$P/PACK.md" | sed 's#//*#/#g' | sort -u)
  sed -i.bak -E "s/(\"packVersion\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1$V\"/; s/(\"verified\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1$today\"/" "$P/pack.json" && rm -f "$P/pack.json.bak"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    head -1 "$f" | grep -q "^<!-- orangekit-pack: $id v" || continue
    if head -1 "$f" | grep -q ' verified '; then
      sed -i.bak -E "1s#^<!-- orangekit-pack: $id v[^ ]+ verified [^ ]+ .* -->#<!-- orangekit-pack: $id v$V verified $today $pkgs -->#" "$f"
    else
      sed -i.bak -E "1s#^<!-- orangekit-pack: $id v[^ ]+#<!-- orangekit-pack: $id v$V#" "$f"
    fi
    rm -f "$f.bak"
  done <<< "$changed"
  rm -f "$rec"   # one verification buys one bump
  ok "packVersion $V · verified $today · stamps of changed files updated"
}

self_test() {
  local t p out
  t=$(mktemp -d 2>/dev/null) || { printf 'no temp directory\n' >&2; exit 2; }
  p="$t/guides/frontend/fx"
  mkdir -p "$p/resources"
  printf '{\n  "packVersion": "1.0.0",\n  "verified": "2020-01-01",\n  "pkgs": ["fx@2"]\n}\n' > "$p/pack.json"
  printf '<!-- orangekit-pack: frontend/fx v1.0.0 verified 2020-01-01 fx@1 -->\n# pack\n' > "$p/PACK.md"
  printf '<!-- orangekit-pack: frontend/fx v1.0.0 -->\n# a\n' > "$p/resources/a.md"
  git -C "$t" init -q && git -C "$t" add -A && git -C "$t" -c user.email=t@t -c user.name=t commit -qm base
  printf '<!-- orangekit-pack: frontend/fx v1.0.0 -->\n# a, new major API\n' > "$p/resources/a.md"
  printf '#!/bin/bash\nexit 0\n' > "$t/pass.sh"; printf '#!/bin/bash\nexit 1\n' > "$t/fail.sh"
  run() { PACK_REFRESH_REPO="$t" PACK_REFRESH_GATE="$t/$1" PACK_REFRESH_SMOKE="$t/$1" bash "${BASH_SOURCE[0]}" "${@:2}" 2>&1; }

  sec "self-test: the bump is gated by verification"
  out=$(run pass.sh --bump "$p" 1.1.0)
  case "$out" in *"not verified"*) ok "an unverified pack is refused" ;; *) bad "an unverified pack was bumped" "$out" ;; esac
  grep -q '"1.0.0"' "$p/pack.json" && ok "  …and pack.json is untouched" || bad "pack.json changed although the bump was refused"

  out=$(run fail.sh --verify "$p")
  case "$out" in *"failed (exit 1)"*) ok "a failing gate is reported" ;; *) bad "a failing gate was not reported" "$out" ;; esac
  out=$(run pass.sh --bump "$p" 1.1.0)
  case "$out" in *"not verified"*) ok "  …and a failed verification does not allow the bump" ;; *) bad "a failed verification allowed the bump" "$out" ;; esac

  run pass.sh --verify "$p" >/dev/null
  printf '# edited after verify\n' >> "$p/resources/a.md"
  out=$(run pass.sh --bump "$p" 1.1.0)
  case "$out" in *"changed after it was verified"*) ok "content changed after verification is refused" ;; *) bad "content changed after verification was bumped" "$out" ;; esac

  run pass.sh --verify "$p" >/dev/null
  out=$(run pass.sh --bump "$p" 1.1.0)
  if grep -q '"packVersion": "1.1.0"' "$p/pack.json" && head -1 "$p/PACK.md" | grep -q 'v1.1.0 verified .* fx@2 -->' \
     && head -1 "$p/resources/a.md" | grep -q 'v1.1.0 -->'; then
    ok "verified content is bumped: packVersion, PACK.md stamp with the new pkgs, the changed resource's stamp"
  else
    bad "the bump did not update pack.json and the stamps" "$out"
  fi
  out=$(run pass.sh --bump "$p" '1.2.3&x' 2>&1); local vrc=$?
  [ "$vrc" -eq 2 ] && ok "a version with sed metacharacters (1.2.3&x) is refused (exit 2)" || bad "a malformed version reached sed (exit $vrc)"
  out=$(run pass.sh --bump "$p" 1.2.0)
  case "$out" in *"not verified"*) ok "one verification allows one bump" ;; *) bad "a second bump went through on the old verification" "$out" ;; esac
  rm -rf "$t"
}

case "${1:-}" in --self-test|-h|--help|"") ;; *)
  [ -d "${REPO:-}/guides" ] \
    || { printf 'run this from the orangekit source repo (no guides/ under %s)\n' "${REPO:-the current directory}" >&2; exit 2; } ;;
esac
case "${1:-}" in
  --check)     shift; do_check "$@"; exit $? ;;
  --verify)    shift; do_verify "$@" ;;
  --bump)      shift; do_bump "$@" ;;
  --self-test) self_test ;;
  -h|--help)   usage; exit 0 ;;
  *)           usage >&2; exit 2 ;;
esac
printf "\n  pass %s · fail %s\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
