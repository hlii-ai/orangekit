#!/bin/bash
# Exercise the real shim under a simulated Windows shell, with observable fake interpreters.
# No native Windows behavior is claimed: CI must still cover real Python/jq executables.
R=$(cd "${1:?plugin root}" && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
realjq=$(type -P jq)
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: $2 != $3"; fi; }
mkdir -p "$T/bin"
for name in python3 python py; do
  cat > "$T/bin/$name" <<'PY'
#!/bin/bash
name=${0##*/}
printf '%s\n' "$name" >> "$WIN_TEST_LOG"
[ "$name" = "$WIN_TEST_WORKS" ] || exit 49
if [ "$name" = py ]; then [ "${1:-}" = -3 ] || exit 8; shift; fi
case "$*" in *sys.version_info*) exit 0 ;; esac
[ "${PYTHONUTF8:-}" = 1 ] && [ "${PYTHONIOENCODING:-}" = utf-8 ] || exit 9
[ "${1:-}" = --fail ] && exit 7
printf '42\r\n'
PY
  chmod +x "$T/bin/$name"
done
cat > "$T/bin/jq" <<'JQ'
#!/bin/bash
[ -z "${WIN_TEST_REAL_JQ:-}" ] || exec "$WIN_TEST_REAL_JQ" "$@"
[ "${1:-}" = --fail ] && exit 9
printf 'jq-output\r\n'
JQ
chmod +x "$T/bin/jq"
for works in python3 python py none; do
  for lazy in 0 1; do
    : > "$T/log"
    output=$(WIN_TEST_LOG="$T/log" WIN_TEST_WORKS="$works" OSTYPE=msys PATH="$T/bin:$PATH" \
      bash -c '
        [ "$2" = 1 ] && _OK_PY_LAZY=1
        source "$1/scripts/lib/win-compat.sh"
        echo "startup=$(wc -l < "$WIN_TEST_LOG" | tr -d " ")"
        if [ "$WIN_TEST_WORKS" != none ]; then
          python3; python3
          rc=0; python3 --fail || rc=$?; echo "python-rc=$rc"
        fi
        jq
        rc=0; jq --fail || rc=$?; echo "jq-rc=$rc"
      ' _ "$R" "$lazy" 2>&1)
    n=3; case "$works" in python3) n=1 ;; python) n=2 ;; esac
    startup=$n; [ "$lazy" = 1 ] && startup=0
    expected="startup=$startup"
    if [ "$works" != none ]; then expected="$expected"$'\n42\n42\npython-rc=7'; fi
    expected="$expected"$'\njq-output\njq-rc=9'
    check "$works lazy=$lazy output, CRLF, UTF-8 and exit status" "$output" "$expected"
    calls=$n; [ "$works" != none ] && calls=$((n+3))
    [ "$works" = none ] && [ "$lazy" = 1 ] && calls=0
    check "$works lazy=$lazy resolves at most once in the parent shell" "$(wc -l < "$T/log" | tr -d ' ')" "$calls"
  done
done
mkdir -p "$T/project"
(cd "$T/project" && git init -q)
for hook in security-check build-gate; do
  : > "$T/log"
  rc=0
  printf '%s' '{"session_id":"shim","tool_name":"Bash","tool_input":{"command":"ls"},"hook_event_name":"Stop","stop_hook_active":false}' \
    | WIN_TEST_LOG="$T/log" WIN_TEST_WORKS=python WIN_TEST_REAL_JQ="$realjq" OSTYPE=msys PATH="$T/bin:$PATH" \
      CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$T/project" ORANGEKIT_STATE_DIR="$T/state" \
      bash "$R/scripts/$hook.sh" > "$T/hook-o" 2> "$T/hook-e" || rc=$?
  check "$hook simulated Windows exits successfully" "$rc" 0
  check "$hook simulated Windows starts no Python" "$(wc -l < "$T/log" | tr -d ' ')" 0
done
for platform in darwin linux-gnu; do
  output=$(OSTYPE="$platform" bash -c '
    before=$(declare -F); settings="${PYTHONUTF8+x}:${PYTHONUTF8:-}:${PYTHONIOENCODING+x}:${PYTHONIOENCODING:-}"
    source "$1/scripts/lib/win-compat.sh"
    [ "$before" = "$(declare -F)" ] && [ "$settings" = "${PYTHONUTF8+x}:${PYTHONUTF8:-}:${PYTHONIOENCODING+x}:${PYTHONIOENCODING:-}" ] && echo untouched
  ' _ "$R" 2>&1)
  check "$platform defines no functions or Python settings" "$output" untouched
done
echo "pass $pass fail $fail"
[ "$fail" = 0 ]
