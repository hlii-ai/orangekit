#!/bin/bash
# Hook edge cases that a one-line JSON fixture cannot express — each needs a project, a transcript or a timing.
# doctor --self-test runs it; every case is a consumer-reported defect, and each one fails on the code before its fix.
#   N1  an unparseable transcript line killed security-check (exit 5) before the destructive and secret gates ran
#   N2  the same line hid every later call from build-gate → tests that ran read as "not run" (false block)
#   N3  a Windows file_path (C:\…) never matched in build-gate → an Edit-only session was never blocked
#   N5  an invalid package.json logged a fake hook error (ERR trap) on every new-file Write
#   N6  handoff used \s, which BSD sed (macOS) does not know → indented tasks were printed raw
#   E4  the advisory knowledge gate ran before the blocking gates (a block for the wrong reason, or none at all on a timeout)
#   B7  the knowledge gate re-judged every card for every write target — cost grew with targets × cards × tool calls
#   -c  `bash -c "git push --force …"` — the negative side (a feature branch through sh -c still passes)
#   D   destructive-command shapes (matrix 2026-11-08): eval · xargs · wrappers · git global options · git aliases · subshells · `$( )` ·
#       scripts written then run or already on disk · `| sh` · `bash <<EOF` — every block/warn row exits 0 on 2082bb1; the pass rows must stay allowed
# Usage: bash hook-edge-cases.sh <plugin root>     Exit: 0 = all pass · 1 = a case failed
R=$(cd "${1:?plugin root}" && pwd)
T=$(mktemp -d 2>/dev/null) || { echo "FAIL cannot create a temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
nok() { fail=$((fail+1)); echo "FAIL $1 :: $2"; }
KEY="AKI""AIOSFODNN7""EXAMPLE"   # AWS's published example key id, assembled at run time so no file carries it

proj() {   # $1 dir → a git repo with one rule card owning migrations/** and src/**
  mkdir -p "$1/.claude/rules" "$1/migrations" "$1/src" "$1/.st"
  (cd "$1" && git init -q && git -c user.email=t@x -c user.name=t commit -q --allow-empty -m init)
  printf -- '---\npaths:\n  - "migrations/**"\n---\n# data card\n' > "$1/.claude/rules/data.md"
}
# Payload JSON is built with Git Bash's argument path conversion off: /tmp/… handed to jq.exe came back as C:/Users/…/Temp/…
# while CLAUDE_PROJECT_DIR stayed /tmp/…, so no path was inside the project and E4's gate cases passed on windows-latest.
# Only the builders — a jq that READS a file by path needs the conversion (jq.exe cannot open /tmp/…)
jqb() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq "$@"; }
tu() { jqb -nc --arg n "$1" --argjson i "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:$i}]}}'; }
SURR='{"type":"user","message":{"content":[{"type":"tool_result","content":"build ok \ud83d"}]}}'   # lone surrogate: jq 1.7 rejects the line
TRUNC='{"type":"assistant","message":{"content":[{"type":"tool_u'                                 # a last line cut mid-write
sc() {   # $1 project  $2 payload JSON → stdout/stderr in $T/o $T/e, exit code in SC
  SC=0
  printf '%s' "$2" | (cd "$1" && CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$1" ORANGEKIT_STATE_DIR="$1/.st" \
    bash "$R/scripts/security-check.sh" >"$T/o" 2>"$T/e") || SC=$?
}
bg() {   # $1 project  $2 transcript → build-gate stdout in BG
  BG=$(printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s","transcript_path":"%s"}' "$1" "$2" \
    | (cd "$1" && CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$1" ORANGEKIT_STATE_DIR="$1/.st" bash "$R/scripts/build-gate.sh" 2>/dev/null))
}
write_in() { jqb -nc --arg s "$1" --arg t "$2" --arg f "$3" --arg c "$4" '{session_id:$s,transcript_path:$t,cwd:($f|sub("/[^/]*/[^/]*$";"")),tool_name:"Write",tool_input:{file_path:$f,content:$c}}'; }
bash_in() { jqb -nc --arg s "$1" --arg t "$2" --arg d "$3" --arg c "$4" '{session_id:$s,transcript_path:$t,cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'; }

# ── N1 · security-check with an unparseable transcript line ──────────────
P="$T/n1"; proj "$P"
{ tu Read "{\"file_path\":\"$P/.claude/rules/data.md\"}"; printf '%s\n%s' "$SURR" "$TRUNC"; } > "$T/n1-read.jsonl"
{ tu Bash '{"command":"ls"}'; printf '%s\n%s' "$SURR" "$TRUNC"; } > "$T/n1-none.jsonl"
sc "$P" "$(write_in n1a "$T/n1-read.jsonl" "$P/migrations/0002.sql" 'create table a (id int);')"
[ "$SC" = 0 ] && ! grep -q 'ERROR line' "$T/e" && ok "N1 card read before an unparseable line still counts (exit 0)" \
  || nok "N1 card read before an unparseable line" "exit $SC · $(head -1 "$T/e")"
sc "$P" "$(bash_in n1b "$T/n1-none.jsonl" "$P" 'echo x > migrations/a.sql && psql -c "DROP TABLE users"')"
[ "$SC" = 2 ] && grep -q 'DROP of a table' "$T/e" && ok "N1 DROP TABLE is blocked although the transcript has an unparseable line" \
  || nok "N1 DROP TABLE with an unparseable transcript line" "exit $SC (2 = blocked) · $(head -1 "$T/e")"
sc "$P" "$(write_in n1c "$T/n1-none.jsonl" "$P/migrations/0003.sql" "-- $KEY")"
[ "$SC" = 2 ] && grep -q 'AWS Access Key' "$T/e" && ok "N1 a hardcoded key is blocked although the transcript has an unparseable line" \
  || nok "N1 secret with an unparseable transcript line" "exit $SC (2 = blocked) · $(head -1 "$T/e")"

# ── E4 · blocking gates run before the knowledge gate ────────────────────
P="$T/e4"; proj "$P"; tu Bash '{"command":"ls"}' > "$T/e4.jsonl"
sc "$P" "$(write_in e4a "$T/e4.jsonl" "$P/migrations/0002.sql" "-- $KEY")"
[ "$SC" = 2 ] && grep -q 'AWS Access Key' "$T/e" && ok "E4 a secret is blocked as a secret, not sent back by the knowledge gate" \
  || nok "E4 secret in a file whose card is unread" "exit $SC · reason: $(grep -m1 -E 'Blocked|Load these' "$T/e")"
sc "$P" "$(bash_in e4b "$T/e4.jsonl" "$P" 'echo x > migrations/b.sql && psql -c "DROP TABLE users"')"
[ "$SC" = 2 ] && grep -q 'DROP of a table' "$T/e" && ok "E4 a DROP is blocked as a DROP, not sent back by the knowledge gate" \
  || nok "E4 DROP with an unread card" "exit $SC · reason: $(grep -m1 -E 'Blocked|Load these' "$T/e")"
sc "$P" "$(write_in e4c "$T/e4.jsonl" "$P/migrations/0004.sql" 'create table a (id int);')"
[ "$SC" = 2 ] && grep -q 'Load these first' "$T/e" && ok "E4 the knowledge gate still blocks a clean write once" \
  || nok "E4 knowledge gate after the reorder" "exit $SC · $(head -1 "$T/e")"
P="$T/e4t"; proj "$P"; tu Bash '{"command":"ls"}' > "$T/e4t.jsonl"
SC=0; write_in e4t "$T/e4t.jsonl" "$P/migrations/0002.sql" 'create table a (id int);' \
  | (cd "$P" && ORANGEKIT_KG_BUDGET=0 CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" \
     bash "$R/scripts/security-check.sh" >"$T/o" 2>"$T/e") || SC=$?
[ "$SC" = 0 ] && grep -q 'cannot be determined' "$T/o" && jq -e . "$T/o" >/dev/null 2>&1 \
  && ok "E4 a spent time budget falls back to the undecidable notice (one JSON, no block)" \
  || nok "E4 time budget" "exit $SC · stdout: $(head -c 120 "$T/o")"

# ── B7 · cost does not grow with write targets (transcript WITH tool calls) ──
P="$T/b7"; proj "$P"
for c in 1 2 3; do printf -- '---\npaths:\n  - "src/**"\n---\n# card %s\n' $c > "$P/.claude/rules/s$c.md"; printf 'card:s%s.md\n' $c >> "$P/.st/knowledge-gate.b7"; done
i=0; while [ $i -lt 300 ]; do
  tu Bash "{\"command\":\"cd apps/api && npx vitest run src/x$i.test.ts | tail -20\"}"; tu Read "{\"file_path\":\"/repo/apps/api/src/x$i.ts\"}"; i=$((i+1))
done > "$T/b7.jsonl"
ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo 0; }
targets() { local n=0 s=""; while [ $n -lt "$1" ]; do s="$s${s:+ && }echo x > src/f$n.ts"; n=$((n+1)); done; printf '%s' "$s"; }
a=$(ms); sc "$P" "$(bash_in b7 "$T/b7.jsonl" "$P" "$(targets 1)")"; c1=$SC; b=$(ms)
sc "$P" "$(bash_in b7 "$T/b7.jsonl" "$P" "$(targets 8)")"; c8=$SC; c=$(ms)
t1=$((b-a)); t8=$((c-b))
# Fixed: 8 targets ≈ 1.1–1.4× one target. Broken: ≈ 7×. The bound is 3× + 1 s so a slow, noisy runner cannot flake it; process
# creation on Windows (Git Bash) is slow and uneven enough that a ratio there measures the machine, not the hook
if [ "$a" = 0 ]; then echo "skip B7 timing — python3 unavailable for a millisecond clock"
elif case "${OSTYPE:-}" in msys*|cygwin*|win*) true ;; *) false ;; esac; then echo "skip B7 timing — not measured on a Windows shell (fork cost dominates; the cache logic is proven on macOS/Linux)"
elif [ "$c1" = 0 ] && [ "$c8" = 0 ] && [ "$t8" -lt $((t1*3 + 1000)) ]; then ok "B7 8 targets cost about one (1 target ${t1} ms · 8 targets ${t8} ms · 600 tool calls · 3 cards)"
else nok "B7 cost grows with write targets" "1 target ${t1} ms (exit $c1) · 8 targets ${t8} ms (exit $c8)"; fi

# ── N5 · invalid package.json is not a hook error ────────────────────────
P="$T/n5"; proj "$P"; printf '{"scripts":{"test":"vitest run"},}\n' > "$P/package.json"; : > "$T/n5.jsonl"
mkdir -p "$P/src/server"
sc "$P" "$(write_in n5 "$T/n5.jsonl" "$P/src/server/points.ts" 'export const p = 1')"
if ! grep -q 'ERROR line' "$T/e" && ! awk -F'|' '$4 != "0"' "$P/.st/hookrun.log" 2>/dev/null | grep -q .; then ok "N5 an invalid package.json logs no hook error"
else nok "N5 invalid package.json" "exit $SC · $(grep -m1 'ERROR' "$T/e") · hookrun: $(awk -F'|' '$4 != "0" {print $1 "|" $4 "|" $5}' "$P/.st/hookrun.log" | head -1)"; fi

# ── N2 · build-gate with an unparseable line between the edit and the tests ──
P="$T/n2"; proj "$P"; echo 'export {}' > "$P/src/a.ts"; (cd "$P" && git add -A && git -c user.email=t@x -c user.name=t commit -qm a)
echo 'export const x = 1' > "$P/src/a.ts"; : > "$P/.st/session-baseline.txt"
{ tu Edit "{\"file_path\":\"$P/src/a.ts\",\"old_string\":\"{}\",\"new_string\":\"x\"}"; printf '%s\n' "$SURR"; tu Bash '{"command":"npx vitest run"}'; } > "$T/n2.jsonl"
bg "$P" "$T/n2.jsonl"
case "$BG" in *'"continue": false'*|*'"continue":false'*) nok "N2 tests run after an unparseable line" "blocked: $(printf '%s' "$BG" | head -c 100)" ;;
  *) ok "N2 tests run after an unparseable transcript line still count (no block)" ;; esac

# ── N3 · build-gate with a Windows-form Edit path ────────────────────────
tu Edit '{"file_path":"C:\\Users\\me\\proj\\src\\a.ts","old_string":"{}","new_string":"x"}' > "$T/n3.jsonl"
bg "$P" "$T/n3.jsonl"
case "$BG" in *'"continue": false'*|*'"continue":false'*) ok "N3 an Edit with a C:\\ path is this session's edit (blocked without tests)" ;;
  *) nok "N3 Windows Edit path" "not blocked — C:\\Users\\me\\proj\\src\\a.ts did not match src/a.ts" ;; esac

# ── N6 · handoff lists an indented open task ─────────────────────────────
P="$T/n6"; proj "$P"; mkdir -p "$P/dev/active/w"; printf -- '- [x] done\n  - [ ] nested open task\n' > "$P/dev/active/w/tasks.md"
HO=$(printf '{"hook_event_name":"PreCompact","cwd":"%s"}' "$P" | (cd "$P" && CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" \
     ORANGEKIT_HANDOFF_DIR="$P/.st/handoff" bash "$R/scripts/handoff.sh" 2>/dev/null) | jq -r '.additionalContext // empty' 2>/dev/null)
if printf '%s\n' "$HO" | grep -qx '  - nested open task' && printf '%s\n' "$HO" | grep -q 'progress 1/2'; then ok "N6 an indented task is counted and listed without its checkbox"
else nok "N6 indented task" "$(printf '%s\n' "$HO" | grep -E 'progress|nested' | tr '\n' ' ')"; fi

# ── -c payloads · the negative side (the positive side is in doctor's POS_FX) ──
P="$T/c"; proj "$P"; : > "$T/c.jsonl"
for cmd in 'sh -c "git push origin feature-x"' 'bash -c "git push --force origin my-feature"' 'bash -c "npm test"'; do
  sc "$P" "$(bash_in c "$T/c.jsonl" "$P" "$cmd")"
  [ "$SC" = 0 ] && ok "-c $cmd passes" || nok "-c $cmd" "exit $SC · $(grep -m1 Blocked "$T/e")"
done
sc "$P" "$(bash_in c "$T/c.jsonl" "$P" "bash -c \"sh -c 'git push --force origin main'\"")"
[ "$SC" = 2 ] && grep -q 'force push to a shared branch' "$T/e" && ok "-c a nested sh -c inside bash -c is unwrapped (blocked)" \
  || nok "-c nested payload" "exit $SC"

# ── D · destructive commands are judged by what runs, not by their characters ──
# Columns: want (block · warn · pass, `@main` = run in a checkout of main) <TAB> command (printf %b escapes: \n = newline).
# Sandboxes: feature-x checkout with danger.sh (force push) · dropper.sh (DROP via psql) · fixture.sh (the same text as quoted data) · ok.sh on disk.
# Runs 8 at a time — 220 hook calls one by one cost ~25 s.
P="$T/d"; proj "$P"; (cd "$P" && git checkout -q -b feature-x && mkdir -p sub); : > "$T/d.jsonl"
printf '#!/bin/bash\ngit push --force origin main\n' > "$P/danger.sh"; chmod +x "$P/danger.sh"
printf '#!/bin/bash\npsql -c "DROP TABLE users"\n' > "$P/dropper.sh"
printf '#!/bin/bash\n# test data, not execution\nrun_case "git push --force origin main"\nrun_case '"'"'psql -c "DROP TABLE users"'"'"'\n' > "$P/fixtures.sh"
printf '#!/bin/bash\necho hello\nnpm test\n' > "$P/ok.sh"; chmod +x "$P/ok.sh"
PM="$T/dm"; proj "$PM"; (cd "$PM" && git checkout -q -B main)
dcase() {   # $1 index  $2 want  $3 command (printf %b) → "ok|FAIL <TAB> label <TAB> detail" in $T/d.out.$1
  local want="${2%@main}" dir="$P" c rc=0 got
  [ "$want" != "$2" ] && dir="$PM"
  c=$(printf '%b' "$3")
  bash_in d "$T/d.jsonl" "$dir" "$c" | (cd "$dir" && CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$dir" ORANGEKIT_STATE_DIR="$dir/.st" \
    bash "$R/scripts/security-check.sh" >/dev/null 2>"$T/d.err.$1") || rc=$?
  case "$want" in
    block) [ "$rc" = 2 ] && grep -Eq 'Blocked: (force push to a shared|remote deletion|DROP of|git history|TRUNCATE|prisma|supabase)' "$T/d.err.$1" ;;
    warn)  [ "$rc" = 0 ] && grep -q '⚠️' "$T/d.err.$1" ;;
    pass)  [ "$rc" = 0 ] ;;
  esac && got=ok || got=FAIL
  printf '%s\t%s\t%s\n' "$got" "D $2 $3" "exit $rc · $(grep -m1 -E 'Blocked|⚠️' "$T/d.err.$1")" > "$T/d.out.$1"
}
i=0
while IFS="$(printf '\t')" read -r want cmd; do
  [ -n "$want" ] || continue
  i=$((i + 1)); dcase "$i" "$want" "$cmd" &
  [ $((i % 8)) = 0 ] && wait
done <<'CASES'
block	( git push --force origin main )
block	echo $(git push --force origin main)
block	echo `git push --force origin main`
block	( git push origin +main )
block	echo $(git push origin +main)
block	echo `git push origin +main`
block	( git push origin --delete main )
block	echo $(git push origin --delete main)
block	echo `git push origin --delete main`
block	( git push origin :main )
block	echo $(git push origin :main)
block	echo `git push origin :main`
block	( git push -f origin HEAD:main )
block	echo $(git push -f origin HEAD:main)
block	echo `git push -f origin HEAD:main`
block	git push --force origin refs/heads/main
block	sudo git push --force origin refs/heads/main
block	sudo -u root git push --force origin refs/heads/main
block	env git push --force origin refs/heads/main
block	env -i git push --force origin refs/heads/main
block	env FOO=1 git push --force origin refs/heads/main
block	command git push --force origin refs/heads/main
block	exec git push --force origin refs/heads/main
block	nohup git push --force origin refs/heads/main
block	time git push --force origin refs/heads/main
block	timeout 10 git push --force origin refs/heads/main
block	nice git push --force origin refs/heads/main
block	nice -n 5 git push --force origin refs/heads/main
block	stdbuf -oL git push --force origin refs/heads/main
block	true; git push --force origin refs/heads/main
block	true && git push --force origin refs/heads/main
block	false || git push --force origin refs/heads/main
block	true\ngit push --force origin refs/heads/main
block	( git push --force origin refs/heads/main )
block	{ git push --force origin refs/heads/main; }
block	echo $(git push --force origin refs/heads/main)
block	echo `git push --force origin refs/heads/main`
block	echo | xargs git push --force origin refs/heads/main
block	echo | xargs prisma migrate reset --force
block	echo | xargs supabase db reset
block	echo | xargs psql -c 'DROP TABLE users'
block	echo | xargs psql -c 'TRUNCATE users'
block	eval "git push --force origin main"
block	eval 'git push --force origin main'
block	eval "sh -c 'git push --force origin main'"
block	bash -c "eval 'git push --force origin main'"
block	echo 'git push --force origin main' | bash
block	printf 'git push --force origin main\\n' | sh
block	bash <<'EOF'\ngit push --force origin main\nEOF
block	printf 'git push --force origin main\\n' > p.sh && bash p.sh
block	echo 'git push --force origin main' > p.sh; sh p.sh
block	cat > p.sh <<'EOF'\ngit push --force origin main\nEOF\nbash p.sh
block	echo 'git push --force origin main' > p.sh && chmod +x p.sh && ./p.sh
block	echo 'git push --force origin main' > p.sh; source p.sh
block	echo 'git push --force origin main' > p.sh; . ./p.sh
block	eval "git push origin +main"
block	eval 'git push origin +main'
block	eval "sh -c 'git push origin +main'"
block	bash -c "eval 'git push origin +main'"
block	echo 'git push origin +main' | bash
block	printf 'git push origin +main\\n' | sh
block	bash <<'EOF'\ngit push origin +main\nEOF
block	printf 'git push origin +main\\n' > p.sh && bash p.sh
block	echo 'git push origin +main' > p.sh; sh p.sh
block	cat > p.sh <<'EOF'\ngit push origin +main\nEOF\nbash p.sh
block	echo 'git push origin +main' > p.sh && chmod +x p.sh && ./p.sh
block	echo 'git push origin +main' > p.sh; source p.sh
block	echo 'git push origin +main' > p.sh; . ./p.sh
block	eval "git push origin --delete main"
block	eval 'git push origin --delete main'
block	eval "sh -c 'git push origin --delete main'"
block	bash -c "eval 'git push origin --delete main'"
block	echo 'git push origin --delete main' | bash
block	printf 'git push origin --delete main\\n' | sh
block	bash <<'EOF'\ngit push origin --delete main\nEOF
block	printf 'git push origin --delete main\\n' > p.sh && bash p.sh
block	echo 'git push origin --delete main' > p.sh; sh p.sh
block	cat > p.sh <<'EOF'\ngit push origin --delete main\nEOF\nbash p.sh
block	echo 'git push origin --delete main' > p.sh && chmod +x p.sh && ./p.sh
block	echo 'git push origin --delete main' > p.sh; source p.sh
block	echo 'git push origin --delete main' > p.sh; . ./p.sh
block	bash <<'EOF'\ngit filter-branch --tree-filter true HEAD\nEOF
block	cat > p.sh <<'EOF'\ngit filter-branch --tree-filter true HEAD\nEOF\nbash p.sh
block	printf '%s\\n' 'psql -c "DROP TABLE users"' > d.sh && bash d.sh
block	echo users | xargs -I{} psql -c 'DROP TABLE {}'
block	echo 'DROP TABLE users' | sudo -u postgres psql
block	echo 'DROP TABLE users' | xargs -0 psql -c
block	git -c x=y push --force origin main
block	git -c x=y push origin +main
block	git -C . push --force origin main
block	git -C . push origin +main
block	git --work-tree=. push --force origin main
block	git --work-tree=. push origin +main
block	git --no-pager push --force origin main
block	git --no-pager push origin +main
block	git -p push --force origin main
block	git -p push origin +main
block	git -c a=b -C . push --force origin main
block	git -c a=b -C . push origin +main
block	git --bare push --force origin main
block	git --bare push origin +main
block	echo main | xargs git push --force origin
block	printf 'main\\n' | xargs git push --force origin
block	echo main | xargs -I{} git push --force origin {}
block	git -c alias.fp='push --force' fp origin main
block	git config alias.fp 'push --force' && git fp origin main
block	git -c alias.x='!git push --force origin main' x
block	git push origin feature-x && git push --force origin main
block	git push --force origin "main"
block	git push --force origin 'main'
block	git push -uf origin main
block	CMD="git push --force origin main"; $CMD
block	bash danger.sh
block	sh ./danger.sh
block	./danger.sh
block	source danger.sh
block	bash dropper.sh
block	bash < danger.sh
block	cat danger.sh | bash
block	cd . && bash danger.sh
block	git push --force --all origin
pass	git push origin feature-x
pass	git push --force origin feature-x
pass	git push -u origin HEAD
pass	git push --force-with-lease origin main
pass	git -C sub status
pass	git -c core.pager=cat log -1
pass	git --no-pager log -1
pass	git -C . push origin feature-x
pass	ls | xargs grep foo
pass	grep -rln 'DROP TABLE' . | xargs -I{} echo {}
pass	find . -name "*.sh" | xargs wc -l
pass	eval "$(direnv export bash)"
pass	eval "$(ssh-agent -s)"
pass	eval "$(fnm env --use-on-cd)"
pass	echo 'git push --force origin main' >> NOTES.md
pass	printf 'git push --force origin main\\n' > NOTES.md
pass	cat > doc.md <<'EOF'\ngit push --force origin main\nEOF
pass	echo 'psql -c "DROP TABLE users"' >> NOTES.md
pass	printf 'git push -f origin main\\n' > p.sh
pass	printf 'git push -f origin main\\n' > p.sh && chmod +x p.sh
pass	echo "git push --force origin main"
pass	npm run test
pass	pnpm test
pass	npx vitest run
pass	cd x && npx vitest run | tail; git status | head
pass	ls
pass	git commit -m "docs: never git push --force origin main"
pass	git commit -m "docs: eval 'git push --force origin main' is blocked"
pass	gh pr create --title "block git push --force origin main" --body x
pass	timeout 60 npm test
pass	nice make
pass	sudo apt-get install -y jq
pass	env FOO=1 node x.js
pass	time npm test
pass	nohup node server.js &
pass	command -v jq
pass	exec bash
pass	bash ok.sh
pass	./ok.sh
pass	source ok.sh
pass	echo 'echo hi' > t.sh && bash t.sh
pass	bash fixtures.sh
pass	grep -rn "git push --force" .
pass	bash -n danger.sh
pass	cat danger.sh
pass	shellcheck danger.sh
pass	git config alias.st status && git st
pass	git -c alias.lg='log --oneline' lg -5
pass	git fetch origin main && git rebase origin/main
pass	git push origin HEAD:feature-x
pass	git push origin main:feature-x
pass	source .venv/bin/activate
pass	echo $(git rev-parse HEAD)
pass	( cd sub && git status )
pass	{ ls; pwd; }
pass	xargs -n1 echo < /dev/null
pass	git branch -D old-feature
pass	git push origin --delete old-feature
pass	git push origin :old-feature
pass	psql -c "SELECT 1"
pass	echo "DROP TABLE users" > notes.txt
pass	sudo -u postgres psql -c 'SELECT 1'
pass	bash scripts/missing.sh
warn	git -C . reset --hard HEAD~1
warn	git -c x=y clean -fd
warn	git --no-pager reset --hard
block@main	git push --force origin HEAD
block@main	git push -f origin @
block@main	git push --force origin $(git branch --show-current)
block@main	git -C . push --force origin HEAD
block@main	echo HEAD | xargs git push --force origin
pass@main	git push origin HEAD
pass@main	git push
pass@main	git push --force-with-lease
pass@main	git push -u origin HEAD:feature-y
pass@main	git push --force origin HEAD:feature-y
pass	git push --force origin $(cat branch.txt)
pass	bash -c "npm test && git push origin feature-x"
pass	make deploy
pass	docker compose down -v
pass	git log --grep="push --force"
pass	rg -n 'eval "git push --force origin main"' scripts/
pass	git stash push -m "wip" && git pull --rebase && git stash pop
pass	for f in *.sh; do bash -n "$f"; done
pass	printf '%s\\n' 'psql -c "DROP TABLE users"' > d.sql.sh
pass	cat > deploy.sh <<'EOF'\ngit push --force origin main\nEOF\nchmod +x deploy.sh
pass	kill %1
pass	git push origin v1.2.3
pass	git push --tags
pass	git push origin --delete feature-x
pass	curl -fsSL https://example.com/install.sh | bash
pass	source <(kubectl completion bash)
pass	echo $((1+2))
pass	case x in a) git status;; esac
pass	f() { git status; }; f
pass	if [ -f x ]; then git status; fi
pass	awk '{print $1}' file | sort | uniq -c
pass	npm run build 2>&1 | tail -20
pass	pnpm --filter web test
pass	python3 - <<EOF\nprint("git push --force origin main")\nEOF
pass	node -e "console.log(1)"
pass	bash scripts/x.sh || true
CASES
wait
j=1; while [ "$j" -le "$i" ]; do
  IFS="$(printf '\t')" read -r got lbl det < "$T/d.out.$j"
  [ "$got" = ok ] && ok "$lbl" || nok "$lbl" "$det"
  j=$((j + 1))
done
# Never fail open: an awk that dies inside the simple-command pass (here: on its program) must block, not wave the command through
mkdir -p "$T/deadawk"; RAWK=$(command -v awk)
printf '#!/bin/bash\ncase "$*" in *"CAP = 65536"*) exit 2 ;; esac\nexec "%s" "$@"\n' "$RAWK" > "$T/deadawk/awk"; chmod +x "$T/deadawk/awk"
SC=0; bash_in d "$T/d.jsonl" "$P" 'git push origin feature-x' | (cd "$P" && PATH="$T/deadawk:$PATH" CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" \
  ORANGEKIT_STATE_DIR="$P/.st" bash "$R/scripts/security-check.sh" >"$T/o" 2>"$T/e") || SC=$?
[ "$SC" = 2 ] && grep -q 'could not be parsed' "$T/e" && ok "D a parse failure blocks (fails closed)" || nok "D parse failure" "exit $SC · $(head -1 "$T/e")"

# ── B10 · build-gate counts a Bash WRITE, not a mention (two directions) ──
# Another session changed b/index.tsx. Reads of it, or a write to a/index.tsx, are not this session's edit; a write to it is.
P="$T/b10"; proj "$P"; mkdir -p "$P/a" "$P/b"; echo 'export {}' > "$P/a/index.tsx"; echo 'export {}' > "$P/b/index.tsx"
(cd "$P" && git add -A && git -c user.email=t@x -c user.name=t commit -qm files)
echo 'export const other = 1' > "$P/b/index.tsx"
b10() {   # $1 want (pass|block)  $2 cwd ("" = none recorded)  $3 command
  : > "$P/.st/session-baseline.txt"
  jq -nc --arg c "$3" --arg d "$2" '{type:"assistant"} + (if $d == "" then {} else {cwd:$d} end) + {message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' > "$T/b10.jsonl"
  bg "$P" "$T/b10.jsonl"
  case "$BG" in *'"continue": false'*|*'"continue":false'*) got=block ;; *) got=pass ;; esac
  local lbl; case "$2" in "") lbl="(no cwd)" ;; "$P") lbl="(root)" ;; *) lbl="(${2#"$P"/})" ;; esac
  lbl="$lbl $(printf '%s' "$3" | tr '\n' '~')"
  [ "$got" = "$1" ] && ok "B10 $1 $lbl" || nok "B10 $lbl" "expected $1, got $got"
}
b10 pass  "$P"   'cat b/index.tsx | head -5'
b10 pass  "$P"   'git diff b/index.tsx'
b10 pass  "$P"   'grep -rn useState --include=index.tsx .'
b10 pass  "$P"   'cd a && sed -n 1,20p index.tsx'
b10 pass  "$P/a" 'echo x > index.tsx'
b10 block "$P"   'echo "export const x = 2" > b/index.tsx'
b10 block "$P"   "cd b && sed -i '' s/other/mine/ index.tsx"
b10 block "$P/a" 'cp /tmp/template.tsx ../b/index.tsx'
b10 block "$P"   "$(printf 'cat > /tmp/note.txt <<EOF\nnotes\nEOF\nsed -i.bak s/a/b/ b/index.tsx')"
b10 block ""     'echo x > b/index.tsx'
b10 block "$P"   'npx prettier --write b/index.tsx'

# ── S1 · Windows: the knowledge gate resolves a Bash target against a C:\-style cwd ──
# Simulated: OSTYPE=msys and the cwd sent with backslashes — the hook must still see migrations/x.sql under the project root
P="$T/s1"; proj "$P"; tu Bash '{"command":"ls"}' > "$T/s1.jsonl"
SC=0; bash_in s1 "$T/s1.jsonl" "$(printf '%s' "$P" | tr '/' '\\')" 'echo x > migrations/x.sql' \
  | (cd "$P" && OSTYPE=msys CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" \
     bash "$R/scripts/security-check.sh" >"$T/o" 2>"$T/e") || SC=$?
[ "$SC" = 2 ] && grep -q 'Load these first' "$T/e" && ok "S1 a Bash write under a backslash cwd reaches the knowledge gate (Windows)" \
  || nok "S1 backslash cwd" "exit $SC · $(head -1 "$T/e") — the target was resolved outside the project root"

# ── Windows paths · /c/… from Git Bash and C:/… from a native program are one path ──
sl() { OSTYPE="$1" bash -c 'source "$1/scripts/lib/common.sh" >/dev/null 2>&1; orangekit_slashes "$2"' _ "$R" "$2" 2>&1; }
[ "$(sl msys /c/Users/me/proj)" = "C:/Users/me/proj" ] && [ "$(sl msys /tmp/x)" = "/tmp/x" ] && [ "$(sl darwin /c/Users/me)" = "/c/Users/me" ] \
  && ok "slashes: /c/Users/… → C:/Users/… on a Windows shell only (/tmp untouched)" \
  || nok "slashes /c/…" "msys /c/Users/me/proj → '$(sl msys /c/Users/me/proj)' · msys /tmp/x → '$(sl msys /tmp/x)' · darwin /c/Users/me → '$(sl darwin /c/Users/me)'"

# ── gawk (the Windows awk) · no `\/` escape warning from the write-target check ──
if command -v gawk >/dev/null 2>&1; then
  mkdir -p "$T/gawkbin"; ln -s "$(command -v gawk)" "$T/gawkbin/awk"
  P="$T/gk"; proj "$P"; : > "$T/gk.jsonl"
  SC=0; bash_in gk "$T/gk.jsonl" "$P" 'for f in $(cat /tmp/list.txt); do echo x > $f; done' \
    | (cd "$P" && PATH="$T/gawkbin:$PATH" CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" \
       bash "$R/scripts/security-check.sh" >"$T/o" 2>"$T/e") || SC=$?
  ! grep -q 'escape sequence' "$T/e" && ok "gawk: no escape-sequence warning on stderr (exit $SC)" \
    || nok "gawk escape warning" "$(grep -m1 'escape sequence' "$T/e")"
else echo "skip gawk escape check — gawk not installed (Windows Git Bash and most Linux CI images have it)"; fi

# ── TI · the shared transcript index (common.sh orangekit_transcript_index) is never trusted beyond the transcript ──
# Each case is built so that trusting a stale or damaged cache gives the opposite verdict: a card read only in the appended
# tail must count (pass), a cached Read that is no longer in the transcript must not (block). Never "allow" by mistake.
P="$T/ti"; proj "$P"; TX="$T/ti.jsonl"; CI="$P/.st/transcript-index.ti"
RD=$(tu Read "{\"file_path\":\"$P/.claude/rules/data.md\"}")
tsc() { rm -f "$P/.st/knowledge-gate.ti"; sc "$P" "$(write_in ti "$TX" "$P/migrations/$1.sql" 'create table a (id int);')"; }
committed() { awk 'NR == 1 { print $2; exit }' "$CI" 2>/dev/null; }
size() { wc -c < "$1" | tr -d ' '; }
want() { # $1 case  $2 expected exit (0 pass · 2 block)
  local why=0; if [ "$2" = 2 ]; then grep -q 'Load these first' "$T/e" && why=1; else grep -q 'Load these' "$T/e" || why=1; fi
  if [ "$SC" = "$2" ] && [ "$why" = 1 ]; then ok "TI $1"
  else nok "TI $1" "exit $SC (want $2) · $(head -1 "$T/e")"; fi
}
tu Bash '{"command":"ls"}' > "$TX"
tsc a1; want "first call builds the index (card unread → block)" 2
[ "$(committed)" = "$(size "$TX")" ] && ok "TI the index commits the whole transcript ($(size "$TX") bytes)" || nok "TI committed offset" "$(committed) ≠ $(size "$TX")"
printf '%s\n' "$RD" >> "$TX"
tsc a2; want "a card Read only in the appended tail counts (pass)" 0
[ "$(committed)" = "$(size "$TX")" ] && ok "TI the appended tail is committed" || nok "TI tail committed" "$(committed) ≠ $(size "$TX")"
tu Bash '{"command":"pwd"}' > "$TX"   # same inode, shorter, no Read
tsc b1; want "a shrunk transcript (same inode) is re-read — the cached Read no longer counts" 2
{ tu Bash '{"command":"ls"}'; printf '%s\n' "$RD"; } > "$TX"; tsc b2
# The replacement's second line has the Read line's exact length, so the cached offset still falls on a line boundary —
# only the inode check can tell (the probe byte is a newline, the first line is the same)
PAD=$(printf '%*s' $(( ${#RD} - $(tu Bash '{"command":""}' | wc -c) + 1 )) '' | tr ' ' x)
{ tu Bash '{"command":"ls"}'; tu Bash "{\"command\":\"$PAD\"}"; i=0; while [ $i -lt 40 ]; do tu Bash "{\"command\":\"echo filler $i\"}"; i=$((i+1)); done; } > "$TX.new"
mv "$TX.new" "$TX"                   # new inode, same first line, larger, no Read
tsc b3; want "a replaced transcript (new inode, same first line, larger) is re-read" 2
{ tu Bash '{"command":"ls"}'; printf '%s\n' "$RD"; } > "$TX"; tsc b4
{ tu Bash '{"command":"ls"}'; tu Bash "{\"command\":\"x$PAD-rewritten-in-place\"}"; } > "$TX"   # same inode, longer, the cached offset now falls mid-line
tsc b5; want "a transcript rewritten in place (same inode, longer) is re-read" 2
{ tu Bash '{"command":"ls"}'; printf '%s\n' "$RD"; } > "$TX"; tsc c1
printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' >> "$TX"
tsc c2; want "a compaction appended after the Read resets it (the Read no longer counts)" 2
# A last line cut mid-write — inside a UTF-8 character — is in the view but never committed; completed, it counts
LINE=$(jqb -nc --arg f "$P/.claude/rules/data.md" '{type:"assistant",message:{content:[{type:"tool_use",name:"Read",input:{description:"café menu",file_path:$f}}]}}')
CUT=$(printf '%s' "$LINE" | LC_ALL=C awk '{ print index($0, "caf") + 3 }')   # just after the first byte of é
tu Bash '{"command":"ls"}' > "$TX"; printf '%s' "$LINE" | head -c "$CUT" >> "$TX"
tsc d1; want "a half-written last line (cut inside é) is not read as a Read" 2
[ "$(committed)" -le "$(( $(tu Bash '{"command":"ls"}' | wc -c) ))" ] && ok "TI the half-written line is not committed" || nok "TI partial line committed" "offset $(committed)"
printf '%s' "$LINE" | tail -c +"$((CUT + 1))" >> "$TX"; printf '\n' >> "$TX"
tsc d2; want "the same line, completed, counts (pass)" 0
# The same through the cached tail: the cache covers the file, then a line cut inside é is appended — the offset must not move
tu Bash '{"command":"ls"}' > "$TX"; tsc d3; C0=$(committed)
printf '%s' "$LINE" | head -c "$CUT" >> "$TX"
tsc d4; want "a half-written line in the appended tail is not read as a Read" 2
[ "$(committed)" = "$C0" ] && ok "TI the half-written tail line is not committed (offset stays $C0)" || nok "TI partial tail committed" "offset $(committed) ≠ $C0"
printf '%s' "$LINE" | tail -c +"$((CUT + 1))" >> "$TX"; printf '\n' >> "$TX"
tsc d5; want "the tail line, completed, counts (pass)" 0
# Missing and damaged caches — each one would flip the verdict if trusted; all must fall back to a full read
{ tu Bash '{"command":"ls"}'; printf '%s\n' "$RD"; } > "$TX"; tsc e0
rm -f "$CI"; tsc e1; want "a missing cache is rebuilt (pass)" 0
printf 'garbage\n\001\002' > "$CI"; tsc e2; want "a garbage cache is rebuilt (pass)" 0
tsc e3; head -c "$(( $(size "$CI") - 40 ))" "$CI" > "$CI.t"; mv "$CI.t" "$CI"
tsc e4; want "a truncated cache (header intact, data cut) is rebuilt (pass)" 0
awk 'NR == 1 { $2 = 999999999 } 1' "$CI" > "$CI.t"; mv "$CI.t" "$CI"
tsc e5; want "a cache claiming more bytes than the transcript has is rebuilt (pass)" 0
tu Bash '{"command":"ls"}' > "$TX"; tsc e6                                      # truth: card not read
awk -v l="K	R	$P/.claude/rules/data.md	" '$0 == "P" && !d { print l; d = 1 } 1' "$CI" > "$CI.t"; mv "$CI.t" "$CI"   # a forged Read among the committed lines
tsc e7; want "a cache padded with a forged Read is rebuilt (block — never allow)" 2
# Concurrency: six hook calls at once on one session, with lines appended while they run — every one judges correctly,
# the cache ends valid and no private copy is left behind
{ tu Bash '{"command":"ls"}'; printf '%s\n' "$RD"; } > "$TX"; rm -f "$CI"
i=0; while [ $i -lt 6 ]; do
  ( write_in ti "$TX" "$P/migrations/p$i.sql" 'create table a (id int);' \
    | (cd "$P" && CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" bash "$R/scripts/security-check.sh" >/dev/null 2>&1); echo $? > "$T/pc$i" ) &
  tu Bash "{\"command\":\"echo appended while hooks run $i\"}" >> "$TX"; i=$((i+1))
done; wait
codes=$(cat "$T"/pc[0-5] | tr '\n' ' ')
[ "$codes" = "0 0 0 0 0 0 " ] && ok "TI six concurrent calls all pass (card read)" || nok "TI concurrent calls" "exit codes: $codes"
tsc f1; want "after the concurrent calls the cache still gives the right verdict" 0
[ "$(committed)" = "$(size "$TX")" ] && ok "TI after the concurrent calls the cache is complete" || nok "TI cache after concurrency" "$(committed) ≠ $(size "$TX")"
ls "$P/.st" | grep -q 'transcript-index\.ti\.' && nok "TI private copies left behind" "$(ls "$P/.st" | grep 'transcript-index\.ti\.' | head -3 | tr '\n' ' ')" || ok "TI no private copy left behind"
# build-gate reads the same index: an Edit and the test run that follows it, both only in the appended tail
P="$T/tib"; proj "$P"; echo 'export {}' > "$P/src/a.ts"; (cd "$P" && git add -A && git -c user.email=t@x -c user.name=t commit -qm a)
echo 'export const x = 1' > "$P/src/a.ts"; : > "$P/.st/session-baseline.txt"; TB="$T/tib.jsonl"
tu Bash '{"command":"ls"}' > "$TB"; bg "$P" "$TB"
tu Edit "{\"file_path\":\"$P/src/a.ts\",\"old_string\":\"{}\",\"new_string\":\"x\"}" >> "$TB"; bg "$P" "$TB"
case "$BG" in *'"continue": false'*|*'"continue":false'*) ok "TI build-gate sees an Edit in the appended tail (blocked, no tests)" ;; *) nok "TI build-gate tail Edit" "not blocked" ;; esac
tu Bash '{"command":"npx vitest run"}' >> "$TB"; bg "$P" "$TB"
case "$BG" in *'"continue": false'*|*'"continue":false'*) nok "TI build-gate tail test run" "blocked although tests ran in the tail" ;; *) ok "TI build-gate sees the test run in the appended tail (no block)" ;; esac

# SessionStart warms the same cache off the hook's stdout/stderr and races real gates safely.
P="$T/tiw"; proj "$P"; TX="$T/tiw.jsonl"; CI="$P/.st/transcript-index.tiw"
tsc() { rm -f "$P/.st/knowledge-gate.tiw"; sc "$P" "$(write_in tiw "$TX" "$P/migrations/$1.sql" 'create table a (id int);')"; }
RD=$(tu Read "{\"file_path\":\"$P/.claude/rules/data.md\"}")
start_warm() {
  jqb -nc --arg tp "$TX" --arg d "$P" '{session_id:"tiw",transcript_path:$tp,cwd:$d,source:"resume"}' \
    | CLAUDE_PLUGIN_ROOT="$R" CLAUDE_PROJECT_DIR="$P" ORANGEKIT_STATE_DIR="$P/.st" bash "$R/scripts/session-brief.sh" > "$T/start-o" 2> "$T/start-e"
}
await_warm() { local n=0; while [ ! -f "$CI" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done; }
printf '%s\n' "$RD" > "$TX"
start_warm; await_warm
[ -f "$CI" ] && [ "$(committed)" = "$(size "$TX")" ] && ok "TI SessionStart publishes a complete warm cache" \
  || nok "TI SessionStart warm-up" "cache missing or incomplete"
tsc warm1; want "the first gate uses the resumed session's card Read" 0
rm -f "$CI"; tu Bash '{"command":"ls"}' > "$TX"
start_warm; await_warm
[ -f "$CI" ] && ok "TI SessionStart also warms an unread-card transcript" || nok "TI unread warm-up" "no cache"
tsc warm2; want "an unread card is still blocked after warm-up" 2
# Enough input to overlap the detached build with gate calls; append while both can be reading.
rm -f "$CI"
{ printf '%s\n' "$RD"; awk 'BEGIN { for (i=0;i<20000;i++) print "{\"type\":\"user\",\"message\":\"padding padding padding padding\"}" }'; } > "$TX"
start_warm
i=0; while [ "$i" -lt 6 ]; do
  ( sc "$P" "$(write_in tiw "$TX" "$P/migrations/race$i.sql" 'create table a (id int);')"; echo "$SC" > "$T/wc$i" ) &
  tu Bash "{\"command\":\"echo warm race $i\"}" >> "$TX"; i=$((i+1))
done; wait; await_warm
codes=$(cat "$T"/wc[0-5] | tr '\n' ' ')
[ "$codes" = "0 0 0 0 0 0 " ] && ok "TI SessionStart racing six gates preserves every verdict" || nok "TI warm-up race" "exit codes: $codes"
tsc warm3; want "the cache remains correct after the warm-up race" 0
[ "$(committed)" = "$(size "$TX")" ] && ok "TI raced cache commits all appended lines" || nok "TI warm race offset" "$(committed) != $(size "$TX")"

echo "pass $pass fail $fail"
[ "$fail" -eq 0 ]
