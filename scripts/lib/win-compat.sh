#!/bin/bash
# scripts/lib/win-compat.sh — Windows shims, sourced by hooks (through common.sh), doctor, the installers and skill scripts.
# Safe for checkers: no `set` options, no traps, no output. On macOS and Linux it defines nothing.
# The orangekit-harness plugin ships without scripts/, so its scripts carry a copy that doctor compares with this file.

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
