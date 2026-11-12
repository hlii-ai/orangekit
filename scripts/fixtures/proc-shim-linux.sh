#!/bin/bash
# proc-shim proof — meaningful only on Linux procps (doctor --self-test runs it directly on a procps host, otherwise in containers).
# Usage: bash proc-shim-linux.sh <plugin root>
# Each case runs like Claude Code does: the whole command sits on a `bash -c` command line. The control (no wrapper) must really die —
# that is what lets this test tell "the wrapper saved it" apart.
SHIM=${1:?plugin root}/bin
pass=0 fail=0
target() { (exec -a "node server.mjs" sleep 300) >/dev/null 2>&1 & echo $!; }
# A killed target is a zombie until its new parent reaps it, and kill -0 succeeds on a zombie. In a container PID 1 reaps
# asynchronously, so checking right after the kill read "still alive" at random (flaky on Ubuntu 22.04: a different case
# failed on each run). A zombie counts as dead, and a target expected dead gets up to 2s to go
alive() { kill -0 "$1" 2>/dev/null || return 1; [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" = Z ] && return 1; return 0; }
check() { # name, expect_after(1/0), expect_target_dead(1/0), out, rc, tpid
  local ok=1 i=0
  case "$4" in *AFTER*) a=1 ;; *) a=0 ;; esac
  if [ "$3" = 1 ]; then while alive "$6" && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done; fi
  alive "$6" && d=0 || d=1
  [ "$a" = "$2" ] && [ "$d" = "$3" ] || ok=0
  if [ $ok = 1 ]; then pass=$((pass+1)); echo "ok   $1 (rc=$5)"; else fail=$((fail+1)); echo "FAIL $1 (after=$a dead=$d rc=$5) :: $4"; fi
  kill "$6" 2>/dev/null; wait "$6" 2>/dev/null
}
run_case() { # name, path_mode(shim|plain), expect_after, expect_dead, command
  local t out rc
  t=$(target); sleep 0.3
  if [ "$2" = shim ]; then out=$(PATH="$SHIM:$PATH" bash -c "$5" 2>&1); rc=$?
  else out=$(bash -c "$5" 2>&1); rc=$?; fi
  check "$1" "$3" "$4" "$out" "$rc" "$t"
}
cd /tmp
run_case "control: plain pkill -f kills its own shell"  plain 0 1 'pkill -f "node server.mjs"; echo AFTER'
run_case "pkill -f"                                     shim 1 1 'pkill -f "node server.mjs"; echo AFTER'
run_case "pkill -9 -f"                                  shim 1 1 'pkill -9 -f "node server.mjs"; echo AFTER'
run_case "pkill --signal KILL -f"                       shim 1 1 'pkill --signal KILL -f "node server.mjs"; echo AFTER'
run_case "kill \$(pgrep -f)"                            shim 1 1 'kill $(pgrep -f "node server.mjs"); echo AFTER'
run_case "pgrep -f | xargs kill"                        shim 1 1 'pgrep -f "node server.mjs" | xargs kill; echo AFTER'
run_case "for loop pgrep -f; kill"                      shim 1 1 'for p in $(pgrep -f "node server.mjs"); do kill $p; done; echo AFTER'
run_case "guarded loop (cwd check)"                     shim 1 1 'for p in $(pgrep -f "node server.mjs"); do [ "$(readlink /proc/$p/cwd)" = /tmp ] && kill $p; done; echo AFTER'
run_case "pids variable"                                shim 1 1 'P=$(pgrep -f "node server.mjs"); kill $P; echo AFTER'
run_case "heredoc script run right away"                shim 1 1 'cat > /tmp/r.sh <<EOF
pkill -f "node server.mjs"
EOF
bash /tmp/r.sh; echo AFTER'
run_case "while read loop"                              shim 1 1 'pgrep -f "node server.mjs" | while read p; do kill $p; done; echo AFTER'

# output parity with the real binaries (ancestors excluded)
t=$(target); sleep 0.3
o1=$(PATH="$SHIM:$PATH" bash -c 'pgrep -f "node server.mjs"'); [ "$o1" = "$t" ] && { pass=$((pass+1)); echo "ok   pgrep lists only the target"; } || { fail=$((fail+1)); echo "FAIL pgrep list: [$o1] want [$t]"; }
o2=$(PATH="$SHIM:$PATH" bash -c 'pgrep -c -f "node server.mjs"'); [ "$o2" = 1 ] && { pass=$((pass+1)); echo "ok   pgrep -c = 1"; } || { fail=$((fail+1)); echo "FAIL pgrep -c: [$o2]"; }
o3=$(PATH="$SHIM:$PATH" bash -c 'pgrep -fl "node server.mjs"'); [ "$o3" = "$t sleep" ] && { pass=$((pass+1)); echo "ok   pgrep -fl"; } || { fail=$((fail+1)); echo "FAIL pgrep -fl: [$o3]"; }
o4=$(PATH="$SHIM:$PATH" bash -c 'pgrep -a -f "node server.mjs"'); [ "$o4" = "$t node server.mjs 300" ] && { pass=$((pass+1)); echo "ok   pgrep -a"; } || { fail=$((fail+1)); echo "FAIL pgrep -a: [$o4]"; }
t2=$(target); sleep 0.3
o5=$(PATH="$SHIM:$PATH" bash -c 'pgrep -n -f "node server.mjs"'); [ "$o5" = "$t2" ] && { pass=$((pass+1)); echo "ok   pgrep -n = newest"; } || { fail=$((fail+1)); echo "FAIL pgrep -n: [$o5] want $t2"; }
o6=$(PATH="$SHIM:$PATH" bash -c 'pgrep -o -f "node server.mjs"'); [ "$o6" = "$t" ] && { pass=$((pass+1)); echo "ok   pgrep -o = oldest"; } || { fail=$((fail+1)); echo "FAIL pgrep -o: [$o6] want $t"; }
o7=$(PATH="$SHIM:$PATH" bash -c 'pgrep -d, -f "node server.mjs"'); [ "$o7" = "$t,$t2" ] && { pass=$((pass+1)); echo "ok   pgrep -d,"; } || { fail=$((fail+1)); echo "FAIL pgrep -d: [$o7] want $t,$t2"; }
o8=$(PATH="$SHIM:$PATH" bash -c 'pkill -e -f "node server.mjs"'); case "$o8" in *"killed (pid $t)"*"killed (pid $t2)"*) pass=$((pass+1)); echo "ok   pkill -e";; *) fail=$((fail+1)); echo "FAIL pkill -e: [$o8]";; esac
wait 2>/dev/null
PATH="$SHIM:$PATH" bash -c 'pgrep -f "no-such-proc-xyz"'; r=$?; [ $r = 1 ] && { pass=$((pass+1)); echo "ok   no match exit 1"; } || { fail=$((fail+1)); echo "FAIL no match rc=$r"; }
PATH="$SHIM:$PATH" bash -c 'pkill -f "no-such-proc-xyz"'; r=$?; [ $r = 1 ] && { pass=$((pass+1)); echo "ok   pkill no match exit 1"; } || { fail=$((fail+1)); echo "FAIL pkill no match rc=$r"; }
PATH="$SHIM:$PATH" bash -c 'pgrep --bogus x' 2>/dev/null; r=$?; [ $r = 2 ] && { pass=$((pass+1)); echo "ok   bad option exit 2"; } || { fail=$((fail+1)); echo "FAIL bad option rc=$r"; }
v=$(PATH="$SHIM:$PATH" bash -c 'pkill --version'); case "$v" in *procps*) pass=$((pass+1)); echo "ok   --version passes through";; *) fail=$((fail+1)); echo "FAIL version [$v]";; esac
echo "pass $pass · fail $fail"
[ $fail = 0 ]
