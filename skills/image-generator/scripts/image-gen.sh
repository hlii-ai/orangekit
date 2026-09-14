#!/bin/bash
# skills/image-generator/scripts/image-gen.sh — direct call to the OpenAI Images API (gpt-image-2.5-flare)
#
# **Why Codex is not called.** The Codex CLI's built-in `image_gen` tool is desktop-app only —
# measured: it is absent from the tool list in both `codex exec` and `codex app-server` (the plugin path)
# (codex 0.154.0 · absent even though image_generation in features is stable/true).
# The fallback script Codex ships also ends up requiring OPENAI_API_KEY. So rather than depend on whether
# Codex is installed and on its internal paths, we call the API directly.
#
#   image-gen.sh --probe
#   image-gen.sh --estimate [--size WxH] [--quality Q] [-n N]
#   image-gen.sh --prompt <text> --out <path> [options]
#   image-gen.sh --prompt-file <file> --out <path> [options]
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

FAIL=0; WARN=0; PASS=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; }
num()  { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

API_URL="${ORANGEKIT_IMAGE_API_URL:-https://api.openai.com/v1/images/generations}"
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
probe() {   # one line on stdout: ready · no-key · unavailable
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'unavailable\n'; printf '%s\n' "python3 is missing, so the request cannot be built." >&2; return 2
  fi
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    printf 'no-key\n'
    printf '%s\n' "OPENAI_API_KEY is missing — proceed in handoff mode instead of generating automatically." >&2
    return 2
  fi
  printf 'ready\n'; return 0
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
  if ! command -v python3 >/dev/null 2>&1; then
    bad "python3 missing — undecidable" "The request cannot be built. Proceed in handoff mode."; return 2
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
  out=$(OPENAI_API_KEY= probe 2>/dev/null); local rc=$?
  [ "$rc" -eq 2 ] && [ "$out" = "no-key" ] && ok "no key → no-key · exit 2 (not a block)" \
    || bad "the no-key verdict is wrong — '$out' · exit $rc" "folding undecidable into failure makes a false positive"
  out=$(OPENAI_API_KEY=sk-test-not-real probe 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "ready" ] && ok "key present → ready · exit 0" \
    || bad "the key-present verdict is wrong — '$out' · exit $rc"

  # Attempt generation with no key → 2 (it does not go out to the network)
  ( OPENAI_API_KEY= generate "x" "$t/a.png" 1024x1024 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 2 ] && ok "generation attempted with no key → exit 2 (handed to handoff mode)" \
    || bad "generation attempted with no key is not 2"

  # Even with a key, bad input is cut off with 1 before the network
  ( OPENAI_API_KEY=sk-test-not-real generate "x" "$t/b.png" 1000x1000 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok "bad size → exit 1 before the call" || bad "a bad size was not caught before the call"
  ( OPENAI_API_KEY=sk-test-not-real generate "" "$t/c.png" 1024x1024 medium png "" 1 5 ) >/dev/null 2>&1
  [ $? -eq 1 ] && ok "empty prompt → exit 1" || bad "an empty prompt was not caught"

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
MODE=""; PROMPT=""; OUT=""; SIZE="1024x1024"; QUALITY="medium"; FMT="png"; BG=""; N=1; TIMEOUT=180
while [ $# -gt 0 ]; do
  case "$1" in
    --probe)       MODE="probe" ;;
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
  generate)  generate "$PROMPT" "$OUT" "$SIZE" "$QUALITY" "$FMT" "$BG" "$N" "$TIMEOUT"; exit $? ;;
  *)         usage; exit 1 ;;
esac
