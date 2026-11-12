#!/bin/bash
# skills/image-generator/scripts/image-gen.sh — OpenAI Images API (gpt-image-2.5-flare), or the Codex CLI without a key
#
# Two automatic paths, chosen by --probe:
#   API    OPENAI_API_KEY set → a direct call to the Images API (billed per image, separately from ChatGPT)
#   Codex  no key, but the Codex CLI is installed and logged in → `codex exec` with its built-in `image_gen` tool, which
#          runs on the ChatGPT login (counts toward the plan's usage, no API key). Only after the user said yes (SKILL.md).
#          Codex only generates — it runs in a read-only sandbox and cannot write to the project. This script takes the
#          new file from $CODEX_HOME/generated_images/ (Codex's own default, per its bundled imagegen skill), copies it
#          to --out and verifies the signature. A file that did not appear there is not accepted: a placeholder drawn
#          with code is a valid PNG too, and must not pass as a generated image.
#          Measured: absent from `codex exec` in codex 0.154.0 (2026-09); works in codex-cli 0.163.0 (2026-11-08, real
#          run: 1254×1254 PNG for a 1024×1024 request). A Codex without it answers IMAGEGEN_UNAVAILABLE and the run
#          ends as undecidable (exit 2) → handoff mode.
#
#   image-gen.sh --probe
#   image-gen.sh --estimate [--size WxH] [--quality Q] [-n N]
#   image-gen.sh --prompt <text> --out <path> [options]
#   image-gen.sh --prompt-file <file> --out <path> [options]
#   image-gen.sh --codex --prompt <text>|--prompt-file <file> --out <path> [--timeout S]
#   image-gen.sh --self-test
#
#   --size        auto or WIDTHxHEIGHT (default 1024x1024)
#                 a multiple of 16 · longest side 3840 · aspect ratio within 3:1 · total pixels 655,360~8,294,400
#   --quality     low | medium | high | xhigh | max | auto   (default medium)
#   --format      png | jpeg | webp                          (default png)
#   --background  transparent | opaque | auto — transparent only on png·webp
#   -n            1~10 (default 1). At 2 or more, a -1 · -2 … suffix is appended to the filename
#   --timeout     seconds (default 180)
#
# **Billing is separate from the ChatGPT subscription.** It is charged as platform API usage. So the
# expected unit price is printed before the call, and after it the response's usage is reported **as a measurement, not an estimate**.
#
# The key is read only from the OPENAI_API_KEY environment variable. It is not taken as an argument (process-list
# exposure) and it is not stored in a file. It is passed to python as an environment variable unchanged.
#
# Exit codes: 0 = success · 1 = failure (input error·API error·file not produced) · 2 = undecidable
#            **Undecidable is not a block.** It means the key or a dependency is missing, and in that case
#            the skill falls back to handoff mode (the prompt is handed to a human). Folding absence into
#            failure makes a false positive, and false positives make the user turn the guard off.
set -uo pipefail   # no -e: run the checks to the end and emit the whole report

# Windows shims (Python resolution, CRLF stripping) — canonical in <plugin>/scripts/lib/win-compat.sh
_okc="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/scripts/lib/win-compat.sh"; [ -f "$_okc" ] && . "$_okc"; unset _okc

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; }
num()  { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

API_URL="${ORANGEKIT_IMAGE_API_URL:-https://api.openai.com/v1/images/generations}"
CODEX_BIN="${ORANGEKIT_CODEX_BIN:-codex}"          # the self-test points this at a fake
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"

# `command -v python3` is not enough on Windows: the Microsoft Store alias in WindowsApps is on PATH, but running it
# opens the Store (or exits 9009) instead of running Python. Ask it to actually run
py_ok() { python3 -c 'import sys' >/dev/null 2>&1; }
MODEL="${ORANGEKIT_IMAGE_MODEL:-gpt-image-2.5-flare}"

# The gpt-image-2.5-flare price is per token ($5/1M text input · $8/1M image input · $30/1M image
# output), but OpenAI's own documentation states that "the gpt-image-2 calculator does not estimate 2.5's token
# consumption" (checked 2026-09) — carrying over the per-size $ back-calculation table from the gpt-image-2 era
# would present a wrong number as fact. So until per-size estimates are published, everything is left as
# unknown — we do not claim to know what we do not know.
price_for() {   # $1 size · $2 quality → USD or the empty string
  printf ''
  return 0
}

# ── input validation ─────────────────────────────────────────────────────────
validate_size() {   # $1 size → 0 pass · 1 violation (reason on stdout)
  local s="$1" w h
  [ "$s" = "auto" ] && return 0
  case "$s" in
    [1-9]*x[1-9]*) ;;
    *) printf 'size must be auto or WIDTHxHEIGHT (e.g. 1024x1024)'; return 1 ;;
  esac
  w=$(num "${s%%x*}"); h=$(num "${s##*x}")
  [ "$w" -eq 0 ] || [ "$h" -eq 0 ] && { printf 'the width and height of size must be positive integers'; return 1; }
  [ $((w % 16)) -ne 0 ] || [ $((h % 16)) -ne 0 ] && { printf 'the width and height of size must be multiples of 16 (received: %sx%s)' "$w" "$h"; return 1; }
  [ "$w" -gt 3840 ] || [ "$h" -gt 3840 ] && { printf 'the longest side of size is 3840px'; return 1; }
  local lo=$w hi=$h; [ "$w" -gt "$h" ] && { lo=$h; hi=$w; }
  [ $((hi)) -gt $((lo * 3)) ] && { printf 'the aspect ratio of size cannot exceed 3:1'; return 1; }
  local px=$((w * h))
  [ "$px" -lt 655360 ]  && { printf 'the total pixels of size must be 655,360 or more (received: %s)' "$px"; return 1; }
  [ "$px" -gt 8294400 ] && { printf 'the total pixels of size must be 8,294,400 or fewer (received: %s)' "$px"; return 1; }
  return 0
}
validate_quality() {
  case "$1" in low|medium|high|xhigh|max|auto) return 0 ;;
    *) printf 'quality must be one of low·medium·high·xhigh·max·auto'; return 1 ;; esac
}
validate_format() {
  case "$1" in png|jpeg|webp) return 0 ;;
    *) printf 'format must be one of png·jpeg·webp'; return 1 ;; esac
}
validate_background() {   # $1 background · $2 format
  case "$1" in
    ''|auto|opaque) return 0 ;;
    transparent) case "$2" in png|webp) return 0 ;;
                   *) printf 'background=transparent can be used only with png·webp'; return 1 ;; esac ;;
    *) printf 'background must be one of transparent·opaque·auto'; return 1 ;;
  esac
}

# ── readiness verdict (3 states) ─────────────────────────────────────────────
codex_state() {   # → codex (installed + logged in) · codex-login (installed, not logged in) · none
  command -v "$CODEX_BIN" >/dev/null 2>&1 || { printf 'none'; return 0; }
  if "$CODEX_BIN" login status >/dev/null 2>&1; then printf 'codex'; else printf 'codex-login'; fi
  return 0
}

probe() {   # one line on stdout: ready · codex · codex-login · no-key · unavailable
  if [ -n "${OPENAI_API_KEY:-}" ] && py_ok; then printf 'ready\n'; return 0; fi
  case "$(codex_state)" in
    codex)
      printf 'codex\n'
      printf '%s\n' "No API key, but the Codex CLI is logged in — it can generate on the ChatGPT login. Ask the user first." >&2
      return 0 ;;
    codex-login)
      printf 'codex-login\n'
      printf '%s\n' "The Codex CLI is installed but not logged in — run \`codex login\` to use it, or continue in handoff mode." >&2
      return 2 ;;
  esac
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf 'unavailable\n'; printf '%s\n' "python3 does not run, so the API request cannot be built." >&2; return 2
  fi
  printf 'no-key\n'
  printf '%s\n' "OPENAI_API_KEY is missing and no logged-in Codex CLI — proceed in handoff mode." >&2
  return 2
}

estimate() {   # $1 size · $2 quality · $3 n
  local s="$1" q="$2" n per
  n=$(num "$3"); [ "$n" -lt 1 ] && n=1
  per=$(price_for "$s" "$q")
  if [ -z "$per" ]; then
    printf 'Estimated price: unknown (no per-size published estimate exists yet for the %s model; only the per-token $5/$8/$30 rates are published) — billed separately from the ChatGPT subscription\n' "$MODEL"
    return 0
  fi
  awk -v p="$per" -v n="$n" -v q="$q" -v z="$s" 'BEGIN{
    printf "Estimated price: about $%.3f (%s image(s) · %s · quality=%s) — billed separately from the ChatGPT subscription\n", p*n, n, z, q
  }'
  return 0
}

# ── generation ───────────────────────────────────────────────────────────────
generate() {
  local prompt="$1" out="$2" size="$3" quality="$4" fmt="$5" bg="$6" n="$7" timeout="$8" msg
  if ! py_ok; then
    bad "python3 does not run — undecidable" "The request cannot be built. Proceed in handoff mode."; return 2
  fi
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    bad "OPENAI_API_KEY missing — undecidable (not a block)" \
        "Skip automatic generation and proceed in handoff mode — the prompt is handed to a human."; return 2
  fi
  [ -z "$prompt" ] && { bad "the prompt is empty"; return 1; }
  [ -z "$out" ]    && { bad "--out is required"; return 1; }
  if msg=$(validate_size "$size");            [ -n "$msg" ]; then bad "$msg"; return 1; fi
  if msg=$(validate_quality "$quality");      [ -n "$msg" ]; then bad "$msg"; return 1; fi
  if msg=$(validate_format "$fmt");           [ -n "$msg" ]; then bad "$msg"; return 1; fi
  if msg=$(validate_background "$bg" "$fmt"); [ -n "$msg" ]; then bad "$msg"; return 1; fi
  n=$(num "$n"); { [ "$n" -lt 1 ] || [ "$n" -gt 10 ]; } && { bad "-n must be 1~10"; return 1; }

  local dir; dir=$(dirname "$out")
  mkdir -p "$dir" 2>/dev/null || { bad "cannot create the output directory: $dir"; return 1; }

  estimate "$size" "$quality" "$n"

  ORANGEKIT_IG_PROMPT="$prompt" python3 - "$API_URL" "$MODEL" "$out" "$size" "$quality" "$fmt" "$bg" "$n" "$timeout" <<'PY'
import base64, json, os, sys, urllib.error, urllib.request

url, model, out, size, quality, fmt, bg, n, timeout = sys.argv[1:10]
body = {"model": model, "prompt": os.environ["ORANGEKIT_IG_PROMPT"], "n": int(n), "output_format": fmt}
if size != "auto":
    body["size"] = size
if quality != "auto":
    body["quality"] = quality
if bg:
    body["background"] = bg

req = urllib.request.Request(
    url, data=json.dumps(body).encode(), method="POST",
    headers={"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"],
             "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=float(timeout)) as r:
        payload = json.load(r)
except urllib.error.HTTPError as e:
    detail = e.read().decode("utf-8", "replace")[:500]
    print("  \033[31m✗\033[0m API error HTTP %s" % e.code)
    print("      \033[2m%s\033[0m" % detail)
    sys.exit(1)
except Exception as e:                      # a network drop or timeout is a failure, not undecidable
    print("  \033[31m✗\033[0m API call failed: %s" % e)
    sys.exit(1)

data = payload.get("data") or []
if not data:
    print("  \033[31m✗\033[0m the response carries no image")
    sys.exit(1)

root, ext = os.path.splitext(out)
if not ext:
    ext = "." + ("jpg" if fmt == "jpeg" else fmt)
written = []
for i, item in enumerate(data):
    b64 = item.get("b64_json")
    if not b64:                              # the gpt-image family does not give a url
        print("  \033[31m✗\033[0m the response has no b64_json (item %d)" % i)
        sys.exit(1)
    path = out if len(data) == 1 else "%s-%d%s" % (root, i + 1, ext)
    with open(path, "wb") as f:
        f.write(base64.b64decode(b64))
    if os.path.getsize(path) == 0:
        print("  \033[31m✗\033[0m 0-byte file: %s" % path)
        sys.exit(1)
    written.append(path)

MAGIC = {"png": b"\x89PNG\r\n\x1a\n", "jpeg": b"\xff\xd8\xff", "webp": b"RIFF"}
for path in written:
    with open(path, "rb") as f:
        head = f.read(8)
    if not head.startswith(MAGIC[fmt]):
        print("  \033[31m✗\033[0m not a %s signature: %s" % (fmt, path))
        sys.exit(1)
    print("  \033[32m✓\033[0m %s (%d bytes)" % (path, os.path.getsize(path)))

u = payload.get("usage") or {}
if u:                                        # a measurement, not an estimate — this is the basis of the charge
    print("  \033[2mmeasured usage: %s\033[0m" % json.dumps(u, ensure_ascii=False))
PY
  local rc=$?
  [ "$rc" -eq 0 ] && ok "generation complete" || bad "generation failed (exit $rc)"
  return "$rc"
}

# ── generation through the Codex CLI ──────────────────────────────────────────
# Stops the watchdog's Codex. On Windows npm's bin/codex.js spawns the native codex.exe under node.exe (elsewhere it execs it),
# and a Git Bash kill ends only node.exe — codex.exe would keep running and land a late image. So the Windows process tree
# goes first: only with a Windows pid and taskkill, a failure ignored; the plain kill runs either way (the only step elsewhere).
_winpid() { [ -r "/proc/$1/winpid" ] && cat "/proc/$1/winpid" 2>/dev/null; }
stop_tree() {
  local wp
  case "${OSTYPE:-}" in msys*|cygwin*)
    if command -v taskkill >/dev/null 2>&1 && wp=$(_winpid "$1") && [ -n "$wp" ]; then
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' taskkill /F /T /PID "$wp" >/dev/null 2>&1 || true
    fi ;;
  esac
  kill "$1" 2>/dev/null
}

codex_generate() {   # $1 prompt · $2 out · $3 timeout
  local prompt="$1" out="$2" timeout="$3" st
  st=$(codex_state)
  [ "$st" = none ] && { bad "Codex CLI not installed — undecidable" "Proceed in handoff mode."; return 2; }
  [ "$st" = codex-login ] && { bad "Codex CLI not logged in — undecidable" "Run \`codex login\`, or proceed in handoff mode."; return 2; }
  [ -z "$prompt" ] && { bad "the prompt is empty"; return 1; }
  [ -z "$out" ]    && { bad "--out is required"; return 1; }
  case "$out" in *.png|*.jpg|*.jpeg|*.webp) ;; *) bad "--out must end in .png · .jpg · .webp"; return 1 ;; esac
  timeout=$(num "$timeout"); [ "$timeout" -lt 30 ] && timeout=30
  mkdir -p "$(dirname "$out")" 2>/dev/null || { bad "cannot create the output directory: $(dirname "$out")"; return 1; }

  local w; w=$(mktemp -d 2>/dev/null) || { bad "failed to create a temp directory"; return 1; }
  mkdir -p "$CODEX_HOME_DIR/generated_images" 2>/dev/null || true
  : > "$w/.start"                       # files newer than this marker are this run's output
  printf '%s\n' \
    "Use your built-in image_gen tool to generate exactly one image for the brief below." \
    "Do not write code, do not draw it with any library, and do not use scripts/image_gen.py or any API key." \
    "If the built-in image_gen tool is not available in this session, do not create an image in any other way —" \
    "reply with exactly IMAGEGEN_UNAVAILABLE and nothing else. Otherwise reply with exactly GENERATED." \
    "" "Brief:" "$prompt" > "$w/prompt.txt"
  printf '  generating through the Codex CLI (counts toward your ChatGPT plan usage; up to %ss)…\n' "$timeout"

  # A watchdog instead of timeout(1), which macOS does not ship. `exec` makes the background pid Codex itself — without it
  # the kill hit only the subshell and Codex kept running, landing a late image in generated_images after we gave up
  ( cd "$w" && exec "$CODEX_BIN" exec --skip-git-repo-check --sandbox read-only --ephemeral -C "$w" \
      -o "$w/last.txt" - < "$w/prompt.txt" > "$w/log.txt" 2>&1 ) &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waited" -ge "$timeout" ] && { stop_tree "$pid"; bad "Codex did not finish within ${timeout}s"; rm -rf "$w"; return 1; }
    sleep 1; waited=$((waited+1))
  done
  wait "$pid"; local rc=$?

  local src
  src=$(find "$CODEX_HOME_DIR/generated_images" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.webp' \) \
          -newer "$w/.start" 2>/dev/null | while IFS= read -r f; do printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"; done \
          | sort -t "$(printf '\t')" -k1,1n | tail -1 | cut -f2)
  # The image decides first. "Unavailable" is read only from Codex's final message as an exact line — the prompt itself says
  # IMAGEGEN_UNAVAILABLE, and codex exec echoes the prompt into its log, so searching the log read every run as unavailable
  if [ -z "$src" ] && tr -d '\r' < "$w/last.txt" 2>/dev/null | grep -qx '[[:space:]]*IMAGEGEN_UNAVAILABLE[[:space:]]*'; then
    bad "this Codex CLI has no built-in image_gen in non-interactive mode — undecidable" \
        "Proceed in handoff mode (paste the prompt into ChatGPT or the Codex desktop app)."
    rm -rf "$w"; return 2
  fi
  if [ -z "$src" ]; then
    bad "Codex produced no image in $CODEX_HOME_DIR/generated_images (codex exit $rc)" "$(tail -3 "$w/log.txt" 2>/dev/null | tr '\n' ' ')"
    rm -rf "$w"; return 1
  fi
  cp "$src" "$out" || { bad "copy failed: $src → $out"; rm -rf "$w"; return 1; }
  local head; head=$(LC_ALL=C od -An -tx1 -N8 "$out" 2>/dev/null | tr -d ' \n')
  case "$head" in
    89504e470d0a1a0a*|ffd8ff*|52494646*) ;;
    *) bad "not an image signature: $out"; rm -rf "$w"; return 1 ;;
  esac
  case "$out:$head" in
    *.png:89504e47*|*.jpg:ffd8ff*|*.jpeg:ffd8ff*|*.webp:52494646*) ;;
    *) warn "the file Codex returned is a different format than the --out extension" "keep it as is, or re-save with the matching extension" ;;
  esac
  # A signature alone is 8 bytes — a truncated or placeholder file passed as "generated" (measured in a real session:
  # a 14-byte file). For PNG read the IHDR chunk: its width and height must be there and non-zero; any format must be
  # at least 1 KB. The dimensions are printed so the skill can compare them with what was asked
  local bytes dims=""; bytes=$(num "$(wc -c < "$out" | tr -d ' ')")
  if [ "$bytes" -lt 1024 ]; then bad "the image is only ${bytes} bytes — truncated or a placeholder, not a generated image"; rm -rf "$w"; return 1; fi
  case "$head" in
    89504e47*)
      local ihdr; ihdr=$(LC_ALL=C od -An -tx1 -j12 -N12 "$out" 2>/dev/null | tr -d ' \n')
      case "$ihdr" in 49484452*) ;; *) bad "PNG without an IHDR header: $out"; rm -rf "$w"; return 1 ;; esac
      local wd ht; wd=$((16#${ihdr:8:8})); ht=$((16#${ihdr:16:8}))
      if [ "$wd" -eq 0 ] || [ "$ht" -eq 0 ]; then bad "PNG with zero dimensions: ${wd}x${ht}"; rm -rf "$w"; return 1; fi
      dims=" · ${wd}x${ht}" ;;
  esac
  ok "$out (${bytes} bytes${dims}) — from ${src#$CODEX_HOME_DIR/}"
  rm -rf "$w"
  return 0
}

# ── self-test ────────────────────────────────────────────────────────────────
self_test() {
  sec "image-gen.sh self-test (no network)"
  local t; t=$(mktemp -d) || { bad "failed to create a temp directory"; return 1; }
  trap 'rm -rf "$t"' RETURN

  _case() {   # $1 description · $2 expected exit · shift 2 → the command to run
    local desc="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    [ "$got" -eq "$want" ] && ok "$desc (exit $got)" || bad "$desc — exit $got, expected $want"
  }

  # size validation — every violation is 1
  _case "size 1024x1024 passes"              0 validate_size 1024x1024
  _case "size auto passes"                   0 validate_size auto
  _case "size 1000x1000 rejected (multiple of 16)" 1 validate_size 1000x1000
  _case "size 4096x1024 rejected (longest side)"   1 validate_size 4096x1024
  _case "size 3072x512 rejected (aspect ratio)"    1 validate_size 3072x512
  _case "size 512x512 rejected (total pixels)"     1 validate_size 512x512
  _case "malformed size rejected"            1 validate_size 1024X1024
  _case "quality medium passes"              0 validate_quality medium
  _case "quality ultra rejected"             1 validate_quality ultra
  _case "format png passes"                  0 validate_format png
  _case "format gif rejected"                1 validate_format gif
  _case "transparent background + png passes"  0 validate_background transparent png
  _case "transparent background + jpeg rejected" 1 validate_background transparent jpeg

  # 3 states — a missing key is **undecidable (2)**, not failure (1)
  local out
  out=$(OPENAI_API_KEY= CODEX_BIN=/nonexistent/codex probe 2>/dev/null); local rc=$?
  [ "$rc" -eq 2 ] && [ "$out" = "no-key" ] && ok "no key → no-key · exit 2 (not a block)" \
    || bad "the no-key verdict is wrong — '$out' · exit $rc" "folding undecidable into failure makes a false positive"
  out=$(OPENAI_API_KEY=sk-test-not-real probe 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "ready" ] && ok "key present → ready · exit 0" \
    || bad "the key-present verdict is wrong — '$out' · exit $rc"

  # Attempt generation with no key → 2 (it does not go out to the network)
  ( OPENAI_API_KEY= CODEX_BIN=/nonexistent/codex generate "x" "$t/a.png" 1024x1024 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 2 ] && ok "generation attempted with no key → exit 2 (handed to handoff mode)" \
    || bad "generation attempted with no key is not 2"

  # Even with a key, bad input is cut off with 1 before the network
  ( OPENAI_API_KEY=sk-test-not-real generate "x" "$t/b.png" 1000x1000 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok "bad size → exit 1 before the call" || bad "a bad size was not caught before the call"
  ( OPENAI_API_KEY=sk-test-not-real generate "" "$t/c.png" 1024x1024 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok "empty prompt → exit 1" || bad "an empty prompt was not caught"

  # ── Codex path, with a fake codex (no network, no account) ──
  mkdir -p "$t/bin" "$t/codexhome"
  cat > "$t/bin/codex" <<'FAKE'
#!/bin/bash
# fake codex: FAKE_LOGIN=0|1 · FAKE_MODE=png|tiny|unavailable|workspace-only|none
case "$1" in
  login) [ "${FAKE_LOGIN:-1}" = 1 ] && { echo "Logged in using ChatGPT"; exit 0; } || { echo "Not logged in"; exit 1; } ;;
  exec)  out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done; echo "user"; cat   # echoes the prompt, as codex exec does
         case "${FAKE_MODE:-png}" in
           png)            mkdir -p "$CODEX_HOME/generated_images/s1"; { printf '\211PNG\r\n\032\n\000\000\000\rIHDR\000\000\004\000\000\000\003\000\010\006\000\000\000'; head -c 2048 /dev/zero; } > "$CODEX_HOME/generated_images/s1/ig_1.png"; echo GENERATED > "$out" ;;
           tiny)           mkdir -p "$CODEX_HOME/generated_images/s1"; printf '\211PNG\r\n\032\nsample' > "$CODEX_HOME/generated_images/s1/ig_1.png"; echo GENERATED > "$out" ;;
           unavailable)    echo IMAGEGEN_UNAVAILABLE > "$out" ;;
           workspace-only) printf '\211PNG\r\n\032\ndrawn' > ./drawn.png; echo GENERATED > "$out" ;;
           none)           echo GENERATED > "$out" ;;
         esac; exit 0 ;;
esac
exit 2
FAKE
  chmod +x "$t/bin/codex"
  local FC="$t/bin/codex"
  out=$(OPENAI_API_KEY= CODEX_BIN="$FC" FAKE_LOGIN=1 probe 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "codex" ] && ok "no key + Codex logged in → codex · exit 0" || bad "codex verdict wrong — '$out' · exit $rc"
  out=$(OPENAI_API_KEY= CODEX_BIN="$FC" FAKE_LOGIN=0 probe 2>/dev/null); rc=$?
  [ "$rc" -eq 2 ] && [ "$out" = "codex-login" ] && ok "Codex installed, not logged in → codex-login · exit 2" || bad "codex-login verdict wrong — '$out' · exit $rc"
  out=$(OPENAI_API_KEY=sk-test-not-real CODEX_BIN="$FC" FAKE_LOGIN=1 probe 2>/dev/null); rc=$?
  [ "$out" = "ready" ] && ok "a key still wins over Codex → ready" || bad "with a key the API path must be chosen — got '$out'"
  ( CODEX_BIN="$FC" CODEX_HOME_DIR="$t/codexhome" CODEX_HOME="$t/codexhome" FAKE_MODE=png codex_generate "a cat" "$t/out/cat.png" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && [ "$(LC_ALL=C od -An -tx1 -N4 "$t/out/cat.png" 2>/dev/null | tr -d ' \n')" = 89504e47 ] && ok "Codex image copied from generated_images to --out and verified" \
    || bad "Codex generation path failed (exit $rc)"
  out=$( ( CODEX_BIN="$FC" CODEX_HOME_DIR="$t/codexhome1" CODEX_HOME="$t/codexhome1" FAKE_MODE=png codex_generate "a cat" "$t/out/d.png" 30 ) 2>&1 )
  printf '%s' "$out" | grep -q '1024x768' && ok "the PNG's real dimensions are reported (1024x768)" || bad "PNG dimensions not reported" "$(printf '%s' "$out" | tail -1)"
  ( CODEX_BIN="$FC" CODEX_HOME_DIR="$t/codexhome4" CODEX_HOME="$t/codexhome4" FAKE_MODE=tiny codex_generate "a cat" "$t/out/tiny.png" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "a 14-byte 'PNG' (signature only) is refused, not reported as generated" || bad "a truncated placeholder passed as an image (exit $rc)"
  ( CODEX_BIN="$FC" CODEX_HOME_DIR="$t/codexhome2" CODEX_HOME="$t/codexhome2" FAKE_MODE=unavailable codex_generate "a cat" "$t/out/u.png" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && [ ! -f "$t/out/u.png" ] && ok "image_gen unavailable in codex exec → exit 2, nothing written (handoff)" || bad "unavailable image_gen not reported as undecidable (exit $rc)"
  ( CODEX_BIN="$FC" CODEX_HOME_DIR="$t/codexhome3" CODEX_HOME="$t/codexhome3" FAKE_MODE=workspace-only codex_generate "a cat" "$t/out/w.png" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && [ ! -f "$t/out/w.png" ] && ok "an image that did not come from generated_images is refused" || bad "a code-drawn file was accepted (exit $rc)"
  ( CODEX_BIN="$FC" FAKE_LOGIN=0 codex_generate "a cat" "$t/out/l.png" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && ok "Codex not logged in → exit 2 before any call" || bad "not-logged-in Codex was called (exit $rc)"
  ( CODEX_BIN="$FC" codex_generate "a cat" "$t/out/x.gif" 30 ) >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "unsupported --out extension → exit 1 before the call" || bad "a .gif target was not refused"

  # Watchdog stop (stop_tree), simulated: a fake Windows pid and a logging taskkill. The target must die in every case
  mkdir -p "$t/winbin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$TK_LOG"\nexit "${TK_RC:-0}"\n' > "$t/winbin/taskkill"; chmod +x "$t/winbin/taskkill"
  st_case() {   # $1 OSTYPE · $2 Windows pid ('' = none) · $3 taskkill exit → "<taskkill args>|dead|alive"
    local p n=0 st_wp="$2"; : > "$t/tk.log"; sleep 30 >/dev/null 2>&1 & p=$!
    ( OSTYPE="$1"; _winpid() { [ -n "$st_wp" ] && printf "%s\n" "$st_wp"; }; PATH="$t/winbin:$PATH" TK_LOG="$t/tk.log" TK_RC="$3" stop_tree "$p" )
    while kill -0 "$p" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$p" 2>/dev/null; then kill "$p"; printf '%s|alive' "$(cat "$t/tk.log")"; else printf '%s|dead' "$(cat "$t/tk.log")"; fi
    wait "$p" 2>/dev/null
  }
  out=$(st_case msys 4242 0)
  [ "$out" = "/F /T /PID 4242|dead" ] && ok "Windows: the watchdog ends Codex's process tree (taskkill /F /T), then kills" || bad "Windows tree kill wrong — '$out'"
  out=$(st_case msys 4242 1)
  [ "$out" = "/F /T /PID 4242|dead" ] && ok "Windows: a failing taskkill is ignored and the kill still runs" || bad "a failing taskkill stopped the kill — '$out'"
  out=$(st_case msys '' 0)
  [ "$out" = "|dead" ] && ok "Windows without a Windows pid: no taskkill, the kill still runs" || bad "taskkill ran without a Windows pid — '$out'"
  out=$(st_case darwin 4242 0)
  [ "$out" = "|dead" ] && [ "$(st_case linux-gnu 4242 0)" = "|dead" ] && ok "macOS · Linux: only the kill, as before (no taskkill)" || bad "taskkill ran outside Windows — '$out'"
  # Real Windows only: npm's codex there is a sh shim that execs node.exe, which spawns the native binary as a child
  case "${OSTYPE:-}" in msys*|cygwin*)
    if command -v node >/dev/null 2>&1 && command -v tasklist >/dev/null 2>&1; then
      printf '%s\n' "require('child_process').spawn(process.execPath, ['-e', 'require(\"fs\").writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1e9)', process.argv[2]], { stdio: 'ignore' }); setInterval(() => {}, 1e9)" > "$t/node-parent.js"
      printf '#!/bin/sh\nexec node "%s" "$@"\n' "$t/node-parent.js" > "$t/npm-codex"; chmod +x "$t/npm-codex"
      local p cw n=0; ( exec "$t/npm-codex" "$t/child.pid" ) & p=$!
      while [ ! -s "$t/child.pid" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
      cw=$(cat "$t/child.pid" 2>/dev/null); stop_tree "$p"; sleep 1; kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
      if [ -z "$cw" ]; then bad "npm-codex shape: the node child never started"
      elif tasklist //FI "PID eq $cw" //NH 2>/dev/null | grep -qi node; then
        bad "Windows: node.exe's native child (codex.exe in npm's codex) survived the watchdog stop"; taskkill //F //PID "$cw" >/dev/null 2>&1
      else ok "Windows (real): the watchdog stop also ends node.exe's native child, as npm's codex runs codex.exe"; fi
    fi ;;
  esac

  # Price notice — gpt-image-2.5-flare has no published per-size price, so everything must be 'unknown'
  estimate 1024x1024 medium 1 | grep -q 'unknown' \
    && ok "price: medium, with no published per-size figure, is 'unknown'" || bad "it pretends to know a price it does not know"
  estimate 1536x1024 high 1 | grep -q 'unknown' \
    && ok "price: wide high is 'unknown' too (the gpt-image-2 back-calculation table is not reused)" \
    || bad "it emitted the gpt-image-2 era numbers verbatim"
  estimate 1024x1024 xhigh 1 | grep -q 'unknown' \
    && ok "a quality with no published estimate is also stated as 'unknown'" || bad "it pretends to know a price it does not know"
  estimate 1024x1024 medium 1 | grep -q 'separately from the ChatGPT subscription' \
    && ok "the billing notice is attached to the price line" || bad "the billing notice is missing"

  printf "\n  pass %s · warn %s · fail %s\n" "$PASS" "$WARN" "$FAIL"
  [ "$FAIL" -gt 0 ] && return 1
  return 0
}

# ── arguments ────────────────────────────────────────────────────────────────
MODE=""; PROMPT=""; OUT=""; SIZE="1024x1024"; QUALITY="medium"; FMT="png"; BG=""; N=1; TIMEOUT=180; VIA_CODEX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --probe)       MODE="probe" ;;
    --codex)       VIA_CODEX=1 ;;
    --estimate)    MODE="estimate" ;;
    --self-test)   MODE="self-test" ;;
    --prompt)      MODE="generate"; PROMPT="${2:-}"; shift ;;
    --prompt-file) MODE="generate"; PROMPT=$(cat "${2:-}" 2>/dev/null); shift ;;
    --out)         OUT="${2:-}"; shift ;;
    --size)        SIZE="${2:-}"; shift ;;
    --quality)     QUALITY="${2:-}"; shift ;;
    --format)      FMT="${2:-}"; shift ;;
    --background)  BG="${2:-}"; shift ;;
    -n)            N="${2:-}"; shift ;;
    --timeout)     TIMEOUT="${2:-}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             printf ' unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$MODE" in
  probe)     probe; exit $? ;;
  estimate)  estimate "$SIZE" "$QUALITY" "$N"; exit 0 ;;
  self-test) self_test; exit $? ;;
  generate)  if [ "$VIA_CODEX" -eq 1 ]; then codex_generate "$PROMPT" "$OUT" "$TIMEOUT"; exit $?; fi
             generate "$PROMPT" "$OUT" "$SIZE" "$QUALITY" "$FMT" "$BG" "$N" "$TIMEOUT"; exit $? ;;
  *)         usage; exit 1 ;;
esac
