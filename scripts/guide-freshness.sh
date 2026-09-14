#!/bin/bash
# scripts/guide-freshness.sh — judging the rot (version staleness) of axis packs and installed guides
#
# **Judged by the `pkgs` major, not by date.** doctor's "baseline older than 6 months" is a proxy
# metric — after 6 months with no major bump nothing is stale, and a framework major rising in
# 2 months is stale. What has to be compared (`pack.json` pkgs · the stamp's pkgs=) already
# exists and guide-gate enforces its presence. So this only compares.
#
#   guide-freshness.sh --pack <pack-dir>...      maintainer: the pack pack.json pkgs
#   guide-freshness.sh --guide <guide-dir>       consumer: the SKILL.md/HUB.md baseline · stamp
#       --offline        does not query and **reports the undecided explicitly** (this is not "no rot")
#       --json           also emits machine-readable TSV
#       --timeout <sec>  registry query ceiling (default 15)
#   guide-freshness.sh --self-test    block proof (runs with no network)
#
# **`fixesVariants` is the boundary of automatic freshening.** A major bump in a package listed there
# (framework · ORM) means the premise of the whole pack body has changed, so it is not fixed in a consumer
# session — it warns and hands over to a plugin update. For other packages, **only the affected resource files** are up for rewrite.
#
# A failed query or being offline is **an explicit skip report**. It is not counted as "no rot" — once a silent pass
# cannot be told apart from "checked and clean", this script starts to lie.
#
# Exit codes: 0 = no major bump, 1 = a major bump, 2 = usage or asset error

set -uo pipefail   # no -e: every package is queried to the end so the whole report comes out

FAIL=0; WARN=0; PASS=0; SKIP=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_0=""; }

# doctor.sh's conventions are copied (not sourced — lib/common.sh's set -Eeuo pipefail and its
# ERR trap conflict with the "run every check to the end" policy). return 0 is explicit.
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf "  ${C_C}–${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }

num() { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

TMP=$(mktemp -d 2>/dev/null) || { printf "failed to create a temporary directory\n" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

OFFLINE=0; JSON=0; NETTIMEOUT=15; MODE=""; TARGETS=()

# ── Splitting the name from the major ─────────────────────────────────
# Scoped packages (@aws-sdk/client-dynamodb@3) exist, so cut at **the last @**.
split_spec() { # $1=spec → "name<TAB>declared version (major, or major.minor)"
  local spec="$1" name ver
  ver="${spec##*@}"
  name="${spec%@*}"
  case "$name" in '') printf '%s\t\n' "$spec"; return 0 ;; esac
  case "$ver" in ''|*[!0-9.]*) printf '%s\t\n' "$spec"; return 0 ;; esac
  printf '%s\t%s\n' "$name" "$ver"
  return 0
}

# **In 0.x the minor is the breaking-change axis** (semver: in 0.y.z, y plays the role of the major).
# fastapi · uvicorn · ruff · httpx are all 0.x, so looking at the major alone makes rot invisible forever.
break_level() { # $1=version string → a comparable "break level"
  local v="$1" maj min
  maj="${v%%.*}"
  case "$maj" in ''|*[!0-9]*) printf '%s' "$v"; return 0 ;; esac
  if [ "$maj" != "0" ]; then printf '%s' "$maj"; return 0; fi
  case "$v" in
    *.*) min="${v#*.}"; min="${min%%.*}"; printf '0.%s' "$min" ;;
    *)   printf '0' ;;      # no minor declared — not comparable
  esac
  return 0
}

# ── Registry query ────────────────────────────────────────────────────
# The ecosystem is decided by pack.json's registry (npm when absent). PyPI takes a single curl.
resolve_latest() { # $1=name $2=registry → the latest version string, or empty
  local name="$1" reg="${2:-npm}"
  # A self-test must not depend on the network — it proves blocking power,
  # it does not measure the registry's state today.
  if [ -n "${ORANGEKIT_FRESHNESS_FAKE:-}" ] && [ -f "$ORANGEKIT_FRESHNESS_FAKE" ]; then
    awk -F'\t' -v n="$name" '$1==n {print $2; found=1} END{ if(!found) print "" }' "$ORANGEKIT_FRESHNESS_FAKE"
    return 0
  fi
  case "$reg" in
    npm)
      command -v npm >/dev/null 2>&1 || return 0
      npm view "$name" version --fetch-timeout "$((NETTIMEOUT*1000))" --no-audit --no-fund 2>/dev/null | tail -1
      ;;
    pypi)
      command -v curl >/dev/null 2>&1 || return 0
      curl -fsS --max-time "$NETTIMEOUT" "https://pypi.org/pypi/$name/json" 2>/dev/null \
        | tr ',' '\n' | grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/'
      ;;
    *) return 0 ;;
  esac
  return 0
}

# ── Getting the pkgs list out of a pack or a guide ────────────────────
specs_of_pack() { # $1=pack dir
  awk '/"pkgs"[[:space:]]*:/{f=1} f{print} f&&/\]/{exit}' "$1/pack.json" 2>/dev/null \
    | grep -oE '"[^"]+@[0-9]+(\.[0-9]+)?"' | tr -d '"' | sort -u
  return 0
}

specs_of_guide() { # $1=guide dir — baseline first, generation stamp when absent
  local f line
  for f in "$1/SKILL.md" "$1/HUB.md"; do
    [ -f "$f" ] || continue
    line=$(grep -m1 -oE '<!-- orangekit-guide-baseline:[^>]*-->' "$f" 2>/dev/null)
    [ -z "$line" ] && line=$(grep -m1 -oE 'pkgs=[^ ]*( [^ ]+@[0-9.]+)*' "$f" 2>/dev/null)
    [ -n "$line" ] && { printf '%s' "$line" | grep -oE '[@A-Za-z0-9_./-]+@[0-9]+(\.[0-9]+)?' | sort -u; return 0; }
  done
  return 0
}

# ── fixesVariants boundary ────────────────────────────────────────────
# When a value (express · prisma · hono · drizzle …) is contained in the package name, it counts as a "pack premise".
is_fixed_variant() { # $1=package name $2=pack dir
  local name="$1" P="$2" v
  [ -f "$P/pack.json" ] || return 1
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    case "$name" in *"$v"*) return 0 ;; esac
  done < <(awk '/"fixesVariants"[[:space:]]*:/{f=1} f{print} f&&/\}/{exit}' "$P/pack.json" 2>/dev/null \
            | grep -oE ':[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')
  return 1
}

check_target() { # $1=label $2=asset dir $3=pack|guide
  local label="$1" DIR="$2" kind="$3" reg="npm"
  sec "$label"

  local specs
  if [ "$kind" = "pack" ]; then
    specs=$(specs_of_pack "$DIR")
    reg=$(grep -m1 -oE '"registry"[[:space:]]*:[[:space:]]*"[^"]+"' "$DIR/pack.json" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/')
    reg="${reg:-npm}"
  else
    specs=$(specs_of_guide "$DIR")
  fi

  local n; n=$(num "$(printf '%s' "$specs" | grep -c . | tr -d ' ')")
  if [ "$n" -eq 0 ]; then
    warn "no pkgs to compare against" "With no entry carrying a major, rot is **never visible** — fill in pack.json's pkgs or orangekit-guide-baseline"
    return 0
  fi

  if [ "$OFFLINE" -eq 1 ]; then
    skip "offline — ${n} left undecided" "This is **not \"no rot\".** Run it again when a network is available"
    return 0
  fi

  # Query in parallel. The registry round trip is the only cost.
  local spec name major
  : > "$TMP/jobs.txt"
  while IFS= read -r spec; do
    [ -z "$spec" ] && continue
    IFS=$'\t' read -r name major < <(split_spec "$spec")
    [ -n "$major" ] || continue
    printf '%s\t%s\n' "$name" "$major" >> "$TMP/jobs.txt"
  done <<< "$specs"

  : > "$TMP/res.tsv"
  while IFS=$'\t' read -r name major; do
    [ -z "$name" ] && continue
    { printf '%s\t%s\t%s\n' "$name" "$major" "$(resolve_latest "$name" "$reg")" >> "$TMP/res.tsv"; } &
  done < "$TMP/jobs.txt"
  wait

  local latest lmaj same=0 minor=0 majorup=0 unknown=0 files fixed
  : > "$TMP/report.tsv"
  while IFS=$'\t' read -r name major latest; do
    [ -z "$name" ] && continue
    if [ -z "$latest" ]; then
      unknown=$((unknown+1))
      printf '%s\t%s\t?\tundecided\t\n' "$name" "$major" >> "$TMP/report.tsv"
      continue
    fi
    # 0.x is compared down to the minor, 1.0 and above by major alone
    lmaj=$(break_level "$latest")
    local dmaj; dmaj=$(break_level "$major")
    if [ "$dmaj" = "0" ] && [ "${latest%%.*}" = "0" ]; then
      # The declaration is only `name@0` — in 0.x the minor is the break axis, so there is nothing to compare
      minor=$((minor+1)); printf '%s\t%s\t%s\t0x_minor_undeclared\t\n' "$name" "$major" "$latest" >> "$TMP/report.tsv"
      continue
    fi
    if [ "$lmaj" = "$dmaj" ]; then
      same=$((same+1)); printf '%s\t%s\t%s\tsame\t\n' "$name" "$major" "$latest" >> "$TMP/report.tsv"
    elif [ "$(num "${lmaj%%.*}")" -lt "$(num "${dmaj%%.*}")" ] || { [ "${lmaj%%.*}" = "${dmaj%%.*}" ] && [ "$(num "${lmaj#*.}")" -lt "$(num "${dmaj#*.}")" ]; }; then
      # The declaration is higher than the latest — a typo, or something that is not an npm package was put in the list
      minor=$((minor+1)); printf '%s\t%s\t%s\tdeclared_higher\t\n' "$name" "$major" "$latest" >> "$TMP/report.tsv"
    else
      majorup=$((majorup+1))
      files=""
      [ -d "$DIR/resources" ] && files=$({ grep -rlF "$name" "$DIR/resources" 2>/dev/null || true; } | xargs -n1 basename 2>/dev/null | sort -u | tr '\n' ' ')
      # **A premise change happens only on a major bump.** What fixesVariants declares is "which
      # framework or ORM", and a 0.x minor bump does not change that choice.
      # Promoting a 0.x minor to a premise change would ring "update the plugin" on every FastAPI
      # release and kill the signal.
      fixed="no"
      if is_fixed_variant "$name" "$DIR" && [ "${dmaj%%.*}" != "${lmaj%%.*}" ]; then fixed="yes"; fi
      printf '%s\t%s\t%s\tmajor_up\t%s\t%s\n' "$name" "$dmaj→$lmaj" "$latest" "$fixed" "$files" >> "$TMP/report.tsv"
    fi
  done < "$TMP/res.tsv"

  [ "$same" -gt 0 ] && ok "${same} at the same major"
  [ "$unknown" -gt 0 ] && skip "${unknown} query failures — undecided" "$(awk -F'\t' '$4=="undecided"{printf "%s ", $1}' "$TMP/report.tsv")— this is not \"no rot\""
  local nhigh n0x
  nhigh=$(num "$(awk -F'\t' '$4=="declared_higher"' "$TMP/report.tsv" | grep -c . | tr -d ' ')")
  n0x=$(num "$(awk -F'\t' '$4=="0x_minor_undeclared"' "$TMP/report.tsv" | grep -c . | tr -d ' ')")
  [ "$nhigh" -gt 0 ] && warn "${nhigh} entries whose declared version is higher than the latest" "$(awk -F'\t' '$4=="declared_higher"{printf "%s(declared %s ↔ latest %s) ", $1, $2, $3}' "$TMP/report.tsv")— a typo, or **something that is not a registry package** (a runtime version, say) was put in the list"
  [ "$n0x" -gt 0 ] && warn "${n0x} entries that are 0.x with no minor declared" "$(awk -F'\t' '$4=="0x_minor_undeclared"{printf "%s(declared %s ↔ latest %s) ", $1, $2, $3}' "$TMP/report.tsv")— **in 0.y.z, y is the breaking-change axis.** With \`name@0\` rot is never visible — write the minor too, as in \`name@0.141\`"

  if [ "$majorup" -eq 0 ]; then
    ok "no major bump — fresh"
  else
    local nm om lt fx fl
    while IFS=$'\t' read -r nm om lt st fx fl; do
      [ "$st" = "major_up" ] || continue
      if [ "$fx" = "yes" ]; then
        bad "the pack premise has changed: $nm $om (latest $lt)" "This package is listed in fixesVariants — **it is not fixed in a consumer session.** It is a matter for a plugin update (a new axis pack), and for now installing the declared major as-is is right"
      else
        if [ -n "$fl" ]; then
          warn "partial rot: $nm $om (latest $lt)" "Affected resources: $fl — rewrite only these files and concentrate audit B there"
        else
          warn "partial rot (toolchain): $nm $om (latest $lt)" "No resource mentions it by name — it appears only in config, commands and the type environment. There is nothing to rewrite, but **pack-smoke's --online install moves to this major**"
        fi
      fi
    done < "$TMP/report.tsv"
  fi

  [ "$JSON" -eq 1 ] && { printf "\n${C_D}── TSV (name · declared major · latest · verdict · fixesVariants · affected files) ──${C_0}\n"; cat "$TMP/report.tsv"; }
  return 0
}


# ── Self-test: proving the blocking power ─────────────────────────────
# **Alive ≠ working.** It checks that a fixture with a planted defect really receives exit 1, and
# that it receives it **for the intended reason** (ORANGEKIT_FX_WHY=1 prints the reason).
_fx_pack() { # $1=dir $2=fixesVariants JSON fragment $3=pkgs fragment
  mkdir -p "$1/resources" || return 1
  cat > "$1/pack.json" <<EOF
{
  "axis": "backend", "name": "fx", "packVersion": "0.0.0",
  "fixesVariants": $2,
  "pkgs": [$3]
}
EOF
  printf '# fx\n\n`express` is used. `pino` too.\n' > "$1/resources/a.md"
  return 0
}

_fx_run() { # $1=label $2=expected exit $3=pack dir $4=expected reason (grep)
  local out code
  out=$(ORANGEKIT_FRESHNESS_FAKE="$TMP/fake.tsv" bash "$0" --pack "$3" 2>&1); code=$?
  if [ "$code" -ne "$2" ]; then
    bad "$1 → exit $code (expected $2)" "$(printf '%s' "$out" | grep -E '✗|!|passed ' | head -3 | tr '\n' ';')"
    return 0
  fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -q "$4"; then
    bad "$1 → exit $code but **for a different reason**" "expected reason: $4 / actual: $(printf '%s' "$out" | grep -E '✗|!' | head -2 | tr '\n' ';')"
    return 0
  fi
  ok "$1 → exit $code"
  [ -n "${ORANGEKIT_FX_WHY:-}" ] && printf "      ${C_D}%s${C_0}\n" "$(printf '%s' "$out" | grep -E '✗|!' | head -2 | sed 's/^  *//' | tr '\n' ';')"
  return 0
}

run_self_test() {
  printf "\n${C_D}guide-freshness --self-test${C_0}  (block proof · no network)\n"
  printf 'express\t5.2.1\nprisma\t7.9.1\npino\t9.9.9\nzod\t4.4.3\n' > "$TMP/fake.tsv"

  sec "harmless fixtures (must pass)"
  _fx_pack "$TMP/clean" '{ "framework": "express" }' '"express@5", "pino@9", "zod@4"'
  _fx_run "every major matches → fresh" 0 "$TMP/clean" ""

  sec "positive fixtures (must block)"
  _fx_pack "$TMP/variant" '{ "orm": "prisma" }' '"express@5", "prisma@6"'
  _fx_run "major bump of a fixesVariants package → pack premise change" 1 "$TMP/variant" "the pack premise has changed"

  _fx_pack "$TMP/partial" '{ "framework": "express" }' '"express@5", "pino@8"'
  _fx_run "major bump of any other package → partial rot" 1 "$TMP/partial" "partial rot"

  _fx_pack "$TMP/nopkgs" '{}' ''
  _fx_run "empty pkgs means rot is never visible → WARN" 1 "$TMP/nopkgs" "no pkgs to compare against"

  sec "0.x — the minor is the breaking-change axis"
  printf 'fastapi\t0.141.1\nuvicorn\t0.52.4\nexpress\t5.2.1\n' > "$TMP/fake.tsv"
  _fx_pack "$TMP/zerominor" '{}' '"fastapi@0.115"'
  _fx_run "0.115 → 0.141 is a breaking bump" 1 "$TMP/zerominor" "partial rot"

  _fx_pack "$TMP/zeronominor" '{}' '"fastapi@0"'
  _fx_run "a 0.x declaration with no minor has nothing to compare → WARN" 1 "$TMP/zeronominor" "no minor declared"

  _fx_pack "$TMP/zerosame" '{}' '"fastapi@0.141", "uvicorn@0.52"'
  _fx_run "a matching 0.x minor is fresh" 0 "$TMP/zerosame" ""

  printf 'express\t5.2.1\nprisma\t7.9.1\npino\t9.9.9\nzod\t4.4.3\n' > "$TMP/fake.tsv"

  sec "fixesVariants — a premise change only on the major"
  printf 'fastapi\t0.141.1\n' > "$TMP/fake.tsv"
  _fx_pack "$TMP/fvminor" '{ "framework": "fastapi" }' '"fastapi@0.115"'
  _fx_run "0.x minor bump in fixesVariants → partial rot (not a premise change)" 1 "$TMP/fvminor" "partial rot"

  printf 'fastapi\t1.2.0\n' > "$TMP/fake.tsv"
  _fx_pack "$TMP/fvmajor" '{ "framework": "fastapi" }' '"fastapi@0.141"'
  _fx_run "major bump in fixesVariants → premise change" 1 "$TMP/fvmajor" "the pack premise has changed"

  printf 'express\t5.2.1\nprisma\t7.9.1\npino\t9.9.9\nzod\t4.4.3\n' > "$TMP/fake.tsv"

  sec "an undecided is not counted as a pass"
  printf '' > "$TMP/fake.tsv"
  _fx_pack "$TMP/unknown" '{}' '"express@5"'
  _fx_run "a failed query is a skip, not 'no rot'" 0 "$TMP/unknown" "undecided"
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pack)    MODE="pack";  shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do TARGETS+=("$1"); shift; done ;;
    --guide)   MODE="guide"; shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do TARGETS+=("$1"); shift; done ;;
    --self-test) MODE="selftest"; shift ;;
    --offline) OFFLINE=1; shift ;;
    --json)    JSON=1; shift ;;
    --timeout) NETTIMEOUT="$(num "${2:-15}")"; shift 2 || exit 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
    *) printf "unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
  esac
done

[ -n "$MODE" ] || { printf -- "one of --pack or --guide is required\n" >&2; exit 2; }
if [ "$MODE" = "selftest" ]; then
  run_self_test
  printf "\n────────────────────────────────────────────\n"
  printf "  passed %s · WARN %s · SKIP %s · FAIL %s\n" "$PASS" "$WARN" "$SKIP" "$FAIL"
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi
[ "${#TARGETS[@]}" -gt 0 ] || { printf -- "--%s <dir> is required\n" "$MODE" >&2; exit 2; }
[ "$(num "$NETTIMEOUT")" -gt 0 ] || NETTIMEOUT=15

printf "\n${C_D}guide-freshness${C_0}  %s targets  ${C_D}(%s · query ceiling %ss)${C_0}\n" \
  "${#TARGETS[@]}" "$MODE" "$NETTIMEOUT"

for t in "${TARGETS[@]}"; do
  if [ ! -d "$t" ]; then bad "target missing: $t"; continue; fi
  check_target "$(basename "$(dirname "$t")")/$(basename "$t")" "${t%/}" "$MODE"
done

printf "\n────────────────────────────────────────────\n"
printf "  passed %s · WARN %s · SKIP %s · premise changes %s\n" "$PASS" "$WARN" "$SKIP" "$FAIL"
# Exit code 1 means "there is a major bump", not a failure — the caller branches on it.
[ "$FAIL" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 1
exit 0
