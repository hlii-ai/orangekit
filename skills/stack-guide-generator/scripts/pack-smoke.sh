#!/bin/bash
# skills/stack-guide-generator/scripts/pack-smoke.sh — axis pack execution-verification harness
#
# The gate (guide-gate.sh) catches what can be caught by reading. In the measurement (2026-08-23) the defects that
# remained after every gate item passed were **caught almost entirely by execution** — the auditor found them by
# building a real project in scratch and running it. One of them was the open redirect present in four shipped copies.
# This script raises that voluntary act into a stage of the pipeline.
#
#   pack-smoke.sh --pack <pack-directory> [options]
#       --profile <name>   toolchain profile (default auto — inferred from pkgs)
#       --out <directory>  working directory (default mktemp, deleted on exit)
#       --keep             keep the working directory (when handing it to audit A)
#       --no-vectors       skip the security vector trials
#       --online           install pack.json's pkgs into the working directory **pinned to the major**.
#                          Without it tsc is a skip and audit A does that installation instead —
#                          that wait sat on the audit's critical path. A network failure is a skip, not a FAIL
#   pack-smoke.sh --self-test
#   pack-smoke.sh --help
#
# There are two markings. Most of a pack's code fences are excerpts, and trying to compile them all becomes a
# false-positive swamp — so the checks apply only to what the author explicitly claimed.
#   `// src/foo.ts`  (first line of the fence) = a **label**. It says which file this fragment belongs to.
#                                     It is restored, but no syntax or type check is applied
#   `<!-- file: src/foo.ts -->`     = a **whole-file claim**. It is subject to syntax and type checks
# Security primitives, configuration files, and test harnesses get the latter — the defects execution caught in the
# measurement were all of that class. The security vector trials look for functions under both markings.
#
# Layer ownership: extraction·stubbing·verdicts belong to this script (toolchain-agnostic); build·typecheck to profiles/<name>.sh.
# A toolchain with no profile **reports its skip explicitly** (no silent omission).
#
# Exit codes: 0 = no defects, 1 = defects, 2 = usage·asset error

set -uo pipefail   # no -e: run every check to the end and emit the whole report

FAIL=0; WARN=0; PASS=0; SKIP=0
C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_D=$'\033[2m'; C_0=$'\033[0m'
[ -t 1 ] || { C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_0=""; }

# Copies doctor.sh's conventions (not a source — lib/common.sh's set -Eeuo pipefail and its
# ERR trap conflict with the "run every check to the end" policy). return 0 is explicit.
ok()   { PASS=$((PASS+1)); printf "  ${C_G}✓${C_0} %s\n" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); printf "  ${C_R}✗${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf "  ${C_Y}!${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf "  ${C_C}–${C_0} %s\n" "$1"; [ -n "${2:-}" ] && printf "      ${C_D}%s${C_0}\n" "$2"; return 0; }
sec()  { printf "\n${C_D}── %s ─────────────────────────────${C_0}\n" "$1"; return 0; }

num() { local v; v=$(printf '%s' "${1:-}" | tr -d '[:space:]'); case "$v" in ''|*[!0-9]*) printf '0';; *) printf '%s' "$v";; esac; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. extraction: restore fences carrying a path comment **fence by fence** ──
# They are not concatenated. The idiom of several fences claiming the same path is often not "sequential excerpts"
# but **alternatives or partial fragments** (an object fragment such as `resolve: {...}` in vite.config.ts),
# and concatenating them builds a chimera that is neither, which produces false positives.
# Each fence leaves one unit file + one manifest row.
#
# Anti-pattern fences (the prose before the fence is ❌ · a comment inside the fence is ❌) are excluded — restoring a bad
# example and handing it to the checks is all false positives. It is the same convention as the gate's codelines().
extract_files() {
  local P="$1" OUT="$2"
  mkdir -p "$OUT/units" || return 1
  awk -v out="$OUT" '
    function isbad(s) { return (index(s,"❌")>0 || (index(s,"✅")==0 && s ~ /(^|[^A-Za-z0-9_])(Bad|BAD)([^A-Za-z0-9_]|$)/)) }
    FNR==1 { inf=0; lastprose=""; pending="" }
    /^[[:space:]]*```/ {
      if (!inf) { inf=1; first=1; path=""; kind="label"; startln=FNR; skipf = isbad(lastprose)
                  if (pending != "") { path=pending; kind="file"; pending="" } }
      else { inf=0; path=""; kind="label" }
      next
    }
    !inf {
      if ($0 ~ /^[[:space:]]*<!--[[:space:]]*file:/) {
        pending=$0; sub(/^[[:space:]]*<!--[[:space:]]*file:[[:space:]]*/,"",pending); sub(/[[:space:]]*-->.*$/,"",pending)
      } else if ($0 ~ /[^[:space:]]/) { lastprose=$0 }
      next
    }
    {
      if (first) {
        first=0
        if (path == "" && $0 ~ /^[[:space:]]*(\/\/|#)[[:space:]]*[A-Za-z0-9_.@][A-Za-z0-9_.@\/-]*\.[A-Za-z]+/) {
          path=$0
          sub(/^[[:space:]]*(\/\/|#)[[:space:]]*/,"",path)
          sub(/[[:space:]].*$/,"",path)
        }
      }
      if (path == "" || skipf) next
      print path "\t" kind "\t" FILENAME "\t" startln "\t" $0
    }
  ' $(ls "$P/PACK.md" "$P"/resources/*.md 2>/dev/null) > "$OUT/.extract.tsv"

  local path kind src ln line key prev="" cur="" u=0 ext
  : > "$OUT/.units.tsv"
  while IFS=$'\t' read -r path kind src ln line; do
    [ -z "$path" ] && continue
    case "$path" in /*|*..*) continue ;;       # absolute paths and parent-directory escapes are not accepted
    esac
    key="$src:$ln"
    if [ "$key" != "$prev" ]; then
      u=$((u+1)); prev="$key"
      ext="${path##*.}"; case "$ext" in "$path") ext="txt";; esac
      cur=$(printf 'u%03d.%s' "$u" "$ext")
      printf '%s\t%s\t%s\t%s\t%s\n' "$cur" "$path" "$(basename "$src")" "$ln" "$kind" >> "$OUT/.units.tsv"
      : > "$OUT/units/$cur"
    fi
    printf '%s\n' "$line" >> "$OUT/units/$cur"
  done < "$OUT/.extract.tsv"
  printf '%s' "$u"
}


# ── ledger requires symbols ────────────────────────────────────────
# **A stub is used only for «what the seam will give».** Without that distinction the stub also covers the pack's
# **wrong paths** and the cross-file consistency errors disappear wholesale — it recurred twice (`app/db/models.py`
# in fastapi, `./model.js` in firebase). Neither was caught by the gate, and it surfaced only when the
# audit reassembled everything at the real paths.
_any_required() { # $1=output directory $2=list of imported names → 0 if any one of them is a requires
  local nm
  [ -s "$1/.requires.txt" ] || return 0     # if the ledger cannot be read, stub as before
  while read -r nm; do
    [ -z "$nm" ] && continue
    grep -qxF "$nm" "$1/.requires.txt" && return 0
  done < <(printf '%s\n' "$2" | tr ',' '\n' \
      | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^type[[:space:]]+//; s/[[:space:]]+as[[:space:]]+.*//' \
      | grep -E '^[A-Za-z_][A-Za-z0-9_]*$')
  return 1
}

# ── source paths of the ledger provides ────────────────────────────
# **A file the pack owns must not be replaced by a stub.** If it is, that file is reported as passing
# **without ever receiving a typecheck or an execution** — in the gcp measurement the entire security boundary of
# that axis (the 6 ownership-check functions of `src/firestore/tasks.ts`) was in exactly that state.
# The cause was that the code fence had no `<!-- file: -->` marking and so was not restored as a unit,
# and neither the gate nor smoke **so much as emitted a WARN** about it.
provides_paths() { # $1=pack directory → list of source paths
  local led="$1/ledger.md"
  [ -f "$led" ] || return 0
  awk '/^## provides/{f=1;next} f&&/^## /{f=0} f' "$led" \
    | grep -oE '`[A-Za-z0-9_./-]+\.(ts|tsx|js|jsx|mts|py)`' \
    | tr -d '`' | sort -u
  return 0
}

requires_syms() { # $1=pack directory → list of symbol names (newline separated)
  local led="$1/ledger.md"
  [ -f "$led" ] || return 0
  awk '/^## requires/{f=1;next} f&&/^## /{f=0} f' "$led" \
    | grep -oE '^\|[[:space:]]*`[A-Za-z_][A-Za-z0-9_]*`' \
    | grep -oE '`[A-Za-z_][A-Za-z0-9_]*`' | tr -d '`' | sort -u
  return 0
}

# Folds a relative import against the unit's target path. The target file does not exist yet, so
# realpath cannot be used — this is pure string normalization.
normalize_rel() { # $1=base directory $2=relative path
  local combined seg out="" oldIFS="$IFS"
  combined="$1/$2"
  IFS=/
  # shellcheck disable=SC2086
  set -- $combined
  IFS="$oldIFS"
  for seg in "$@"; do
    case "$seg" in
      ''|'.') ;;
      '..') case "$out" in */*) out="${out%/*}";; *) out="";; esac ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  printf '%s' "$out"
}

# ── 2. stubs: fill in local imports that do not resolve ─────────────
# The ledger's requires are what the seam will give, so with the pack alone they are always unresolved.
# Filling them with stubs is what makes the typecheck see the pack's own defects rather than "the seam is unimplemented".
make_stubs() {
  local OUT="$1" PACK="$2" made=0 orphan=0 spec names mod target
  : > "$OUT/.orphan.txt"
  : > "$OUT/.stubbed.txt"
  requires_syms "$PACK" > "$OUT/.requires.txt" 2>/dev/null || : > "$OUT/.requires.txt"
  provides_paths "$PACK" > "$OUT/.provides.txt" 2>/dev/null || : > "$OUT/.provides.txt"
  [ -s "$OUT/.units.tsv" ] || { printf '0'; return 0; }

  # Both aliases (@/…) and **relative paths** are looked at. In a pack that uses only relative paths not one stub
  # was created, so tsc reported the unimplemented seam as a pack defect (measured on aws-serverless — a false positive).
  # A relative path is relative to **the location of the importing file**, so it is collected together with the unit's target path.
  : > "$OUT/.imports.txt"
  local uid upath uspec
  while IFS=$'\t' read -r uid upath _rest; do
    [ -z "$uid" ] && continue
    [ -f "$OUT/units/$uid" ] || continue
    grep -ohE "import( type)? \{[^}]*\} from '@/[^']*'" "$OUT/units/$uid" 2>/dev/null \
      | while IFS= read -r uspec; do printf '.\t%s\n' "$uspec"; done >> "$OUT/.imports.txt"
    grep -ohE "import( type)? \{[^}]*\} from '\.[^']*'" "$OUT/units/$uid" 2>/dev/null \
      | while IFS= read -r uspec; do printf '%s\t%s\n' "$(dirname "$upath")" "$uspec"; done >> "$OUT/.imports.txt"
    # **A JSDoc type import is not an `import { }` statement.** A JS pack pulls a type in as
    # `/** @typedef {import('../x.js').Task} Task */` — without seeing this form
    # that symbol never enters the stub and TS2694 results (measured on vanilla: task-list.test.js).
    # It is normalized into the `import { A } from 'path'` form so the stub logic below can use it as is.
    grep -ohE "import\('[^']+'\)\.[A-Za-z_][A-Za-z0-9_]*" "$OUT/units/$uid" 2>/dev/null \
      | sed -E "s#import\('([^']+)'\)\.([A-Za-z_][A-Za-z0-9_]*)#import { \2 } from '\1'#" \
      | while IFS= read -r uspec; do
          case "$uspec" in
            *"from '@/"*) printf '.\t%s\n' "$uspec" ;;
            *"from '."*)  printf '%s\t%s\n' "$(dirname "$upath")" "$uspec" ;;
          esac
        done >> "$OUT/.imports.txt"
  done < "$OUT/.units.tsv"
  sort -u -o "$OUT/.imports.txt" "$OUT/.imports.txt"

  # ── Python: `from app.http.handlers import install_error_handlers` ──
  # The ledger's requires are what the seam will give, so with the pack alone they are always unresolved. Without filling
  # them, pyright reports the unimplemented seam as a pack defect and **even the schema execution is blocked**
  # (measured on the fastapi fan-in). Whether a package is local is judged by the top-level directory of the restored
  # unit path — stubbing a library import would mask the real dependency.
  local roots; roots=$(cut -f2 "$OUT/.units.tsv" | grep '/' | cut -d/ -f1 | sort -u)
  local pyline pymod pynames pytarget root
  while IFS= read -r pyline; do
    [ -z "$pyline" ] && continue
    pymod=$(printf '%s' "$pyline" | sed -E 's/^[[:space:]]*from[[:space:]]+([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]+import.*/\1/')
    case "$pymod" in ''|*' '*) continue ;; esac
    root="${pymod%%.*}"
    printf '%s\n' "$roots" | grep -qxF "$root" || continue     # it is a library
    pytarget=$(printf '%s' "$pymod" | tr '.' '/').py
    [ -f "$OUT/$pytarget" ] && continue
    awk -F'\t' '$5=="file"{print $2}' "$OUT/.units.tsv" | grep -qxF "$pytarget" && continue
    # **Do not mask a package with a module.** Stubbing `from app.db import x` as `app/db.py` masks the
    # real `app/db/` package and every module inside it becomes unresolved
    # (measured on the final fastapi fan-in — a correct pack was reported as a typecheck failure).
    [ -d "$OUT/${pytarget%.py}" ] && continue
    cut -f2 "$OUT/.units.tsv" | grep -q "^${pytarget%.py}/" && continue
    pynames=$(printf '%s' "$pyline" | sed -E 's/.*[[:space:]]import[[:space:]]+//; s/#.*//')
    if ! cut -f2 "$OUT/.units.tsv" | grep -qxF "$pytarget" && ! _any_required "$OUT" "$pynames"; then
      printf '%s\t%s\n' "$pytarget" "$(printf '%s' "$pynames" | tr -d '\n')" >> "$OUT/.orphan.txt"
      orphan=$((orphan+1)); continue
    fi
    mkdir -p "$OUT/$(dirname "$pytarget")" 2>/dev/null
    {
      printf '# pack-smoke stub — ledger requires (owned by the seam). The pack alone cannot resolve it.\n'
      printf 'from typing import Any\n'
      # **The form is chosen by usage.** No Python stub form satisfies both positions at once:
      #   `NAME: Any = None` → works in value position but becomes `Variable not allowed in type
      #                         expression` in a type expression
      #   `class NAME: ...`   → works in type position but in value position it becomes `type[NAME]`
      #                         and cannot be passed where a concrete type is required
      # Both produced false positives on the fastapi fan-in where **the stub's own artifact was reported as a pack defect**.
      # So it looks at whether the name is used as a type expression (`-> NAME` · `: NAME` · `[NAME]`)
      # in the unit body and picks either the class or the value form.
      printf '%s\n' "$pynames" | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^.*[[:space:]]+as[[:space:]]+//' \
        | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u | while read -r nm; do
            if grep -rhqE "(->[[:space:]]*$nm\\b|:[[:space:]]*$nm\\b|\\[$nm\\]|except[[:space:]]+$nm\\b)" "$OUT/units" 2>/dev/null; then
              printf 'class %s(Exception):\n' "$nm"
              printf '    def __init__(self, *a: Any, **k: Any) -> None: ...\n'
              printf '    def __call__(self, *a: Any, **k: Any) -> Any: ...\n'
              printf '    def __getattr__(self, n: str) -> Any: ...\n'
            else
              printf '%s: Any = None\n' "$nm"
            fi
          done
    } >> "$OUT/$pytarget"
    printf '%s\n' "$pytarget" >> "$OUT/.stubbed.txt"
    # without __init__.py pyright does not treat it as a package
    local d="$OUT/$(dirname "$pytarget")"
    while [ "$d" != "$OUT" ] && [ -n "$d" ]; do
      [ -f "$d/__init__.py" ] || : > "$d/__init__.py"
      d=$(dirname "$d")
    done
    made=$((made+1))
  done < <(grep -rhE "^[[:space:]]*from[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*[[:space:]]+import[[:space:]]" "$OUT/units" 2>/dev/null | sort -u)

  local base
  while IFS=$'\t' read -r base spec; do
    [ -z "$spec" ] && continue
    names=$(printf '%s' "$spec" | sed -E "s/import( type)? \{//; s/\} from '.*//")
    case "$spec" in
      *"from '@/"*)
        mod=$(printf '%s' "$spec" | sed -E "s/.*from '@\///; s/'$//")
        # whether `@/*` is `src/` or the root is decided by the pack's layout — it is judged from the unit path
        # (nextjs puts app/ and stores/ at the root. Pinning it to src/ makes every correct import unresolved)
        if cut -f2 "$OUT/.units.tsv" | grep -q '^src/'; then target="src/$mod"; else target="$mod"; fi ;;
      *)
        mod=$(printf '%s' "$spec" | sed -E "s/.*from '//; s/'$//")
        target=$(normalize_rel "$base" "$mod") ;;
    esac
    [ -n "$target" ] || continue
    # **TS ESM writes `./model.js` and it resolves to `model.ts`.** Trusting the extension verbatim and stubbing it
    # covers a real sibling module with `any` and **masks the cross-file consistency errors wholesale** —
    # measured in firebase audit A: passing tsc was not evidence of consistency, and only reassembling at the real
    # paths revealed TS2307·TS2459. It is the second recurrence of the same class as `app/db/models.py` in fastapi.
    # **If the pack ships that path as it is, the extension is not changed.** The idiom above belongs to TS packs;
    # in a JavaScript pack `./resource.js` resolves **literally** to `resource.js`.
    # Changing it unconditionally diverges from the unit path (`src/state/resource.js`), which makes it an orphan that
    # receives no stub, and the test harness claimed as a whole file gets **TS2307 everywhere** (measured on vanilla: every test file).
    if ! cut -f2 "$OUT/.units.tsv" | grep -qxF "$target"; then
      case "$target" in
        *.js)  target="${target%.js}.ts" ;;
        *.mjs) target="${target%.mjs}.mts" ;;
        *.ts|*.tsx|*.mts) ;;
        # An extensionless import is not only `.ts` — components ship as `.tsx`. Resolving to `.ts` alone
        # misjudges the `ScreenStates.tsx` the pack really shipped as an orphan (measured on the react-native pack — a false positive)
        *) if cut -f2 "$OUT/.units.tsv" | grep -qxF "$target.tsx"; then target="$target.tsx"; else target="$target.ts"; fi ;;
      esac
    fi
    # **If it is a stub we made, do not skip it — append only the missing names.** Skipping on mere existence
    # puts in only the names of the first import statement and the symbols other files use are never there — TS2305 results
    # (measured on vanilla: `derive` in `store.test.js`). A real file that is not ours is skipped as before.
    if [ -f "$OUT/$target" ] && ! grep -qxF "$target" "$OUT/.stubbed.txt" 2>/dev/null; then continue; fi
    # **If the pack claimed that path as a «whole file», do not stub it.** The unit is still under units/,
    # so a file-existence check does not catch it — laying a stub on top makes the same symbol declared twice
    # when the profile moves it to the real path, and TS2451 results (measured on aws-serverless — a false positive).
    # **A label excerpt is not excluded** — it is not restored, so without a stub it stays
    # unresolved (measured on fastapi: app/http/handlers.py was a label and so received no stub)
    awk -F'\t' '$5=="file"{print $2}' "$OUT/.units.tsv" | grep -qxF "$target" && continue
    # **If it is not in the ledger requires, do not stub it.** That is not something the seam will give but
    # something the pack should have procured itself, and covering it with a stub makes a wrong path disappear.
    # If the exact path is in a unit then **the pack provides it** (it is a label excerpt, so it merely was not restored).
    # It is not an orphan, so stub it as before.
    if ! cut -f2 "$OUT/.units.tsv" | grep -qxF "$target" && ! _any_required "$OUT" "$names"; then
      printf '%s\t%s\n' "$target" "$(printf '%s' "$names" | tr -d '\n')" >> "$OUT/.orphan.txt"
      orphan=$((orphan+1)); continue
    fi
    mkdir -p "$OUT/$(dirname "$target")" 2>/dev/null
    if [ ! -f "$OUT/$target" ]; then
      printf '// pack-smoke stub — ledger requires (owned by the seam). The pack alone cannot resolve it.\n' > "$OUT/$target"
      printf '%s\n' "$target" >> "$OUT/.stubbed.txt"
      made=$((made+1))
    fi
    # **Do not write TS syntax into a `.js` target.** `export type X = any;` is a syntax error in a
    # JavaScript file with checkJs on, and that error is reported as a pack defect.
    local isjs=0; case "$target" in *.js|*.mjs|*.jsx) isjs=1 ;; esac
    printf '%s\n' "$names" | tr ',' '\n' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^type[[:space:]]+//; s/[[:space:]]+as[[:space:]]+.*//' \
      | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | sort -u | while read -r nm; do
          grep -qE "^export (declare )?const $nm[ =:]" "$OUT/$target" && continue
          if [ "$isjs" -eq 1 ]; then
            printf '/** @typedef {any} %s */\n' "$nm"
            printf 'export const %s = /** @type {any} */ (undefined);\n' "$nm"
          else
            # Leaving the value slot as a bare `any` means `x instanceof Stub` cannot narrow `unknown`, so
            # correct code that branches on a seam class (ApiError) falls over with TS18046 (measured on the react-native
            # pack — a false positive). Give it a signature that supports construction, calls, JSX and member access
            printf 'export type %s = any;\n' "$nm"
            printf 'export declare const %s: (new <T = any>(...args: any[]) => any) & (<T = any>(...args: any[]) => any) & { [k: string]: any };\n' "$nm"
          fi >> "$OUT/$target"
        done
  done < "$OUT/.imports.txt"
  printf '%s' "$made"
}


# ── 2-B. toolchain installation (--online) ──────────────────────────
# **The major is pinned.** For 0.x the minor is read too — in semver's 0.y.z the y is the breaking-change
# axis, and letting the minor slip drops an entry such as `fastapi@0.141` from the install list entirely
# (measured on the fastapi fan-in: 5 of 12 were silently missing).
# The pack fixed typescript@5, yet `npm i typescript` fetches 7.x today —
# a verdict from a different major is not «stale» but «wrong» for this pack.
# Without the installation tsc cannot find the modules and pours out TS2307. So instead of installing only typescript,
# every pkg the pack declared goes in at the same major.
install_toolchain() {
  local P="$1" OUT="$2" specs sp
  specs=$(awk '/"pkgs"[[:space:]]*:/{f=1} f{print} f&&/\]/{exit}' "$P/pack.json" 2>/dev/null \
    | grep -oE '"[^"]+@[0-9]+(\.[0-9]+)?"' | tr -d '"' | sort -u | tr '\n' ' ')
  if [ -z "$(printf '%s' "$specs" | tr -d ' ')" ]; then
    skip "pack.json has no pkgs carrying a major — installation skipped" "the typecheck gets its verdict from the profile instead"
    return 0
  fi
  # The ecosystem is decided by pack.json's registry (npm if absent).
  local reg; reg=$(grep -m1 -oE '"registry"[[:space:]]*:[[:space:]]*"[^"]+"' "$P/pack.json" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/')
  reg="${reg:-npm}"
  local n; n=$(printf '%s' "$specs" | wc -w | tr -d ' ')

  if [ "$reg" = "pypi" ]; then
    # `name@N` → `name>=N,<N+1`. Pinning the major means the same thing across ecosystems.
    local pyspecs="" nm mj
    for sp in $specs; do
      nm="${sp%@*}"; mj="${sp##*@}"; mj="${mj%%.*}"
      case "$mj" in ''|*[!0-9]*) continue ;; esac
      pyspecs="$pyspecs $nm>=$mj,<$((mj+1))"
    done
    local venv="$OUT/.venv"
    if command -v uv >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      if (cd "$OUT" && uv venv "$venv" >/dev/null 2>&1 && uv pip install --python "$venv/bin/python" $pyspecs) >"$OUT/.pip.log" 2>&1; then
        ok "toolchain installed (uv) — ${n} pinned to their major"
      else
        skip "toolchain installation failed — the typecheck and schema execution stay unchecked" "$(tail -2 "$OUT/.pip.log" | tr '\n' ' ') — normal when offline"
      fi
    elif command -v python3 >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      if (cd "$OUT" && python3 -m venv "$venv" >/dev/null 2>&1 && "$venv/bin/pip" install -q $pyspecs) >"$OUT/.pip.log" 2>&1; then
        ok "toolchain installed (venv+pip) — ${n} pinned to their major"
      else
        skip "toolchain installation failed — the typecheck and schema execution stay unchecked" "$(tail -2 "$OUT/.pip.log" | tr '\n' ' ') — normal when offline"
      fi
    else
      skip "no uv·python3 — toolchain installation skipped" "$specs"
    fi
    return 0
  fi

  command -v npm >/dev/null 2>&1 || { skip "no npm — toolchain installation skipped" "$specs"; return 0; }
  printf '{ "name": "pack-smoke", "private": true, "type": "module" }\n' > "$OUT/package.json"
  # shellcheck disable=SC2086
  if (cd "$OUT" && npm i -D --silent --no-audit --no-fund $specs) >"$OUT/.npm.log" 2>&1; then
    ok "toolchain installed — ${n} pinned to their major"
  else
    skip "toolchain installation failed — the typecheck stays unchecked" "$(tail -2 "$OUT/.npm.log" | tr '\n' ' ') — normal when offline"
  fi
  return 0
}

# ── 3. security vectors: actually run section A of security-vectors.md ──
# The largest finding of the measurement (the open redirect) was of this class, and three audits missed it by reading.
run_vectors() {
  local OUT="$1"
  sec "security vectors (return-path validation)"
  command -v node >/dev/null 2>&1 || { skip "no node — vector trials skipped" "install it and run again. What was not run is not reported as run"; return 0; }

  local u pth fn found=""
  while IFS=$'\t' read -r u pth _ _; do
    [ -z "$u" ] && continue
    fn=$(grep -oE "export (async )?(function|const) (safe|validate|sanitize)[A-Za-z0-9_]*" "$OUT/units/$u" 2>/dev/null \
         | awk '{print $NF}' | grep -iE '(return|redirect|internal|path|url)' | head -1)
    [ -n "$fn" ] && { found="units/$u|$fn"; break; }
  done < "$OUT/.units.tsv"
  if [ -z "$found" ]; then
    skip "no return-path validation function found" "normal if this pack does not define one — if it does, it needs a path comment on the first line to be restored"
    return 0
  fi

  local vf="${found%%|*}" vn="${found##*|}"
  cat > "$OUT/.vectors.mjs" <<'VEC'
const [, , modPath, fnName] = process.argv;
globalThis.window = { location: { origin: 'https://app.example', href: 'https://app.example/' } };
const FB = '/__fallback__';
const ATTACK = [
  ['A1  //host',            '//evil.example'],
  ['A2  /\\host',           '/\\evil.example'],
  ['A3  absolute',          'https://evil.example'],
  ['A4  javascript:',       'javascript:alert(1)'],
  ['A5  /..//host',         '/..//evil.example'],
  ['A6  /../..//host',      '/../..//evil.example'],
  ['A7  encoded //',        '%2f%2fevil.example'],
  ['A8  CRLF',              '/tasks\n\rSet-Cookie: x=1'],
  ['A9  leading tab',       '\tjavascript:alert(1)'],
  ['A10 empty',             ''],
];
const NORMAL = [
  ['A11 query+hash',        '/tasks?filter=open#top'],
  ['A12 nested',            '/tasks/123'],
];
const unsafe = (v) => typeof v !== 'string'
  || !v.startsWith('/') || v.startsWith('//') || v.startsWith('/\\')
  || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(v) || /[\x00-\x1f]/.test(v);

const mod = await import(modPath);
const fn = mod[fnName];
if (typeof fn !== 'function') { console.log(`ERR\tcannot import the function ${fnName}`); process.exit(0); }
for (const [label, input] of ATTACK) {
  let out; try { out = fn(input, FB); } catch (e) { out = `THREW ${e.message}`; }
  console.log(`${unsafe(out) ? 'FAIL' : 'PASS'}\t${label}\t${JSON.stringify(input)}\t${JSON.stringify(out)}`);
}
for (const [label, input] of NORMAL) {
  let out; try { out = fn(input, FB); } catch (e) { out = `THREW ${e.message}`; }
  const broken = (out === FB) || unsafe(out);
  console.log(`${broken ? 'FAIL' : 'PASS'}\t${label}\t${JSON.stringify(input)}\t${JSON.stringify(out)}`);
}
VEC

  local res
  res=$(cd "$OUT" && node --experimental-strip-types .vectors.mjs "./$vf" "$vn" 2>&1)
  if ! printf '%s' "$res" | grep -qE '^(PASS|FAIL|ERR)'; then
    skip "vector could not be executed ($vn)" "$(printf '%s' "$res" | tail -2 | tr '\n' ' ')"
    return 0
  fi
  printf '%s\n' "$res" > "$OUT/vector-report.tsv"

  local nf; nf=$(num "$(grep -c '^FAIL' "$OUT/vector-report.tsv" | tr -d ' ')")
  local np; np=$(num "$(grep -c '^PASS' "$OUT/vector-report.tsv" | tr -d ' ')")
  if [ "$nf" -gt 0 ]; then
    bad "$vn — ${nf}/$((nf+np)) vectors failed to block" "$vf"
    grep '^FAIL' "$OUT/vector-report.tsv" | while IFS=$'\t' read -r _ label inp outp; do
      printf "      ${C_R}%-18s${C_0} %s → %s\n" "$label" "$inp" "$outp"
    done
  else
    ok "$vn — all ${np} vectors as expected (10 blocked · 2 legitimately allowed)"
  fi
  return 0
}

# ── 4. delegation to the profile ────────────────────────────────────
# It is judged by the extension of the restored units — more accurate than pack.json's pkgs string
# (the supabase pack has no typescript in pkgs but all its code is TS).
detect_profile() {
  local OUT="$1" exts
  exts=$(cut -f2 "$OUT/.units.tsv" 2>/dev/null | sed -E 's/.*\.//' | sort -u | tr '\n' ' ')
  case " $exts " in
    *" ts "*|*" tsx "*|*" mts "*|*" js "*|*" mjs "*|*" vue "*) printf 'node-ts'; return ;;
  esac
  case " $exts " in *" py "*) printf 'python'; return ;; esac
  printf 'none'
}

run_profile() {
  local P="$1" OUT="$2" prof="$3"
  sec "toolchain profile ($prof)"
  local ps="$SCRIPT_DIR/profiles/$prof.sh"
  if [ ! -f "$ps" ]; then
    skip "no profile '$prof' — build and typecheck skipped" "the extension point is the 4 functions of profiles/<name>.sh. This pack's toolchain has not been filled in yet"
    return 0
  fi
  # shellcheck disable=SC1090
  . "$ps"
  profile_check "$OUT"
  return 0
}

run_smoke() {
  local P="$1"
  printf "\n${C_D}pack-smoke${C_0}  %s  ${C_D}(work %s)${C_0}\n" "$P" "$OUT_DIR"
  [ -d "$P" ] || { printf "pack directory missing: %s\n" "$P" >&2; exit 2; }
  [ -f "$P/PACK.md" ] || { printf "PACK.md missing: %s\n" "$P" >&2; exit 2; }

  sec "code-fence restoration (only those with a path comment)"
  local n; n=$(extract_files "$P" "$OUT_DIR")
  if [ "$(num "$n")" -eq 0 ]; then
    warn "0 fences restored" "no fence carries a path marking — nothing becomes subject to execution verification"
  else
    local nfile nlabel
    nfile=$(num "$(awk -F'\t' '$5=="file"' "$OUT_DIR/.units.tsv" | grep -c .)")
    nlabel=$(num "$(awk -F'\t' '$5=="label"' "$OUT_DIR/.units.tsv" | grep -c .)")
    ok "${n} fences restored — ${nfile} whole-file claims · ${nlabel} labels"
    [ "$nfile" -eq 0 ] && warn "0 fences claim a whole file" "there is nothing for the syntax and type checks. Put <!-- file: path --> in front of the security primitive·configuration·test harness fences"
  fi

  local st; st=$(make_stubs "$OUT_DIR" "$P")
  if [ "$(num "$st")" -gt 0 ]; then
    ok "${st} stubs created for unresolved local imports (ledger requires)" \
       "$(cut -f1 "$OUT_DIR/.stubbed.txt" 2>/dev/null | tr '\n' ' ')"
  else
    ok "no unresolved local imports"
  fi

  # **If a file the pack owns was replaced by a stub, that is not a pass but an unchecked file.**
  # A source path assigned by the ledger provides is shipped by the pack, so a stub must not cover it.
  # If it is covered, that file's code is reported green **without ever receiving a typecheck or an execution** —
  # in the gcp measurement the entire security boundary of that axis (the 6 ownership-check functions of
  # `src/firestore/tasks.ts`) was in that state, and the cause was that the code fence had no
  # `<!-- file: -->` marking and so was not restored as a unit. Neither the gate nor smoke so much as emitted a WARN.
  local ownstub=0 pp
  if [ -s "$OUT_DIR/.provides.txt" ] && [ -s "$OUT_DIR/.stubbed.txt" ]; then
    while IFS= read -r pp; do
      [ -z "$pp" ] && continue
      case "$pp" in *.d.ts) continue ;; esac        # a library type declaration is not owned by the pack
      if grep -qxF "$pp" "$OUT_DIR/.stubbed.txt"; then
        bad "a file the pack owns was replaced by a stub: $pp" \
            "this path was assigned by the ledger provides. Put <!-- file: $pp --> on that code fence so it is restored as a unit — right now this file received neither a typecheck nor an execution"
        ownstub=$((ownstub+1))
      fi
    done < "$OUT_DIR/.provides.txt"
  fi
  [ "$ownstub" -eq 0 ] && [ -s "$OUT_DIR/.provides.txt" ] && ok "no pack-owned file was replaced by a stub"
  # **A local import that is not in the ledger requires and does not resolve is a pack defect.**
  # Covering it with a stub makes a wrong path disappear — a class that recurred twice (fastapi `app/db/models.py`,
  # firebase `./model.js`). Both «passed» the typecheck and surfaced only when the audit reassembled
  # at the real paths.
  # **Two cases are separated.** If the pack ships the same file name **at a different path**, that is a wrong path
  # and it is a defect (FAIL). If no such name exists at all, it is an example app symbol the project creates and is
  # normal (WARN — only the list is left). Without separating them, FAILing everything breaks 6 shipped packs, and
  # **a false positive kills the check.**
  local orph mism=0 illus=0 t nm base
  orph=$(num "$(grep -c . "$OUT_DIR/.orphan.txt" 2>/dev/null | tr -d ' ')")
  if [ "$orph" -gt 0 ]; then
    : > "$OUT_DIR/.mismatch.txt"; : > "$OUT_DIR/.illus.txt"
    while IFS=$'\t' read -r t nm; do
      [ -z "$t" ] && continue
      base=$(basename "$t")
      if cut -f2 "$OUT_DIR/.units.tsv" | grep -qE "(^|/)$base$"; then
        printf '%s\t%s\n' "$t" "$nm" >> "$OUT_DIR/.mismatch.txt"; mism=$((mism+1))
      else
        printf '%s\t%s\n' "$t" "$nm" >> "$OUT_DIR/.illus.txt"; illus=$((illus+1))
      fi
    done < "$OUT_DIR/.orphan.txt"
    if [ "$mism" -gt 0 ]; then
      bad "${mism} path mismatches — the pack ships the same file **at a different path**" \
          "$(awk -F'\t' '{printf "%s ", $1}' "$OUT_DIR/.mismatch.txt")— the import path and the shipping path forked. On assembly the module is not found (the class that surfaced only when the audit reassembled at the real paths)"
    fi
    [ "$illus" -gt 0 ] && warn "${illus} local imports the pack does not ship" \
        "$(awk -F'\t' '{printf "%s ", $1}' "$OUT_DIR/.illus.txt")— normal if it is an example app symbol the project creates. Check whether it is in the ledger's «Symbols appearing in examples» table"
  fi

  [ "$ONLINE" -eq 1 ] && { sec "toolchain installation (--online)"; install_toolchain "$P" "$OUT_DIR"; }
  [ "$PROFILE" = "auto" ] && PROFILE=$(detect_profile "$OUT_DIR")
  run_profile "$P" "$OUT_DIR" "$PROFILE"
  [ "$NO_VECTORS" -eq 0 ] && run_vectors "$OUT_DIR" || skip "security vectors skipped (--no-vectors)" ""
}

run_self_test() {
  printf "\n${C_D}pack-smoke --self-test${C_0}  (proof of blocking ability)\n"
  local fx="$OUT_DIR/fx"
  mkdir -p "$fx/broken/resources" "$fx/fixed/resources" || { bad "failed to build the fixtures"; return; }

  local m
  for m in broken fixed; do
    printf '<!-- orangekit-pack: frontend/fx v0 -->\n# fx pack\n' > "$fx/$m/PACK.md"
    printf '{ "axis": "frontend", "name": "fx", "pkgs": ["typescript@5"] }\n' > "$fx/$m/pack.json"
  done

  # The pre-repair shape — it checks only the origin. In the measurement all four shipped copies were this shape.
  cat > "$fx/broken/resources/routing.md" <<'FXB'
# Return path

<!-- file: src/lib/safeReturnTo.ts -->
```ts
// src/lib/safeReturnTo.ts
export function safeReturnTo(raw: unknown, fallback = '/'): string {
  if (typeof raw !== 'string' || raw === '') return fallback;
  try {
    const url = new URL(raw, window.location.origin);
    if (url.origin !== window.location.origin) return fallback;
    return url.pathname + url.search + url.hash;
  } catch { return fallback; }
}
```
FXB

  # The post-repair shape — it validates the resulting pathname
  cat > "$fx/fixed/resources/routing.md" <<'FXF'
# Return path

<!-- file: src/lib/safeReturnTo.ts -->
```ts
// src/lib/safeReturnTo.ts
export function safeReturnTo(raw: unknown, fallback = '/'): string {
  if (typeof raw !== 'string' || raw === '') return fallback;
  try {
    const url = new URL(raw, window.location.origin);
    if (url.origin !== window.location.origin) return fallback;
    const p = url.pathname;
    if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return fallback;
    return p + url.search + url.hash;
  } catch { return fallback; }
}
```
FXF

  # ── path mismatch fixture ───────────────────────────────────────
  # **The class where a stub covered the pack's wrong path.** It recurred twice (fastapi `app/db/models.py`,
  # firebase `./model.js`) — both «passed» the typecheck and surfaced only when the audit reassembled
  # at the real paths. Stubs are used for the ledger requires only.
  mkdir -p "$fx/pathbad/resources" || { bad "failed to build the path fixture"; return; }
  printf '<!-- orangekit-pack: backend/fx v0 -->\n# fx pack\n' > "$fx/pathbad/PACK.md"
  printf '{ "axis": "backend", "name": "fx", "pkgs": ["typescript@5"] }\n' > "$fx/pathbad/pack.json"
  cat > "$fx/pathbad/ledger.md" <<'FXPL2'
## provides — this pack defines these

| symbol | definition file | shape | nature |
| --- | --- | --- | --- |
| `keys` | a.md | `keys.task(o, i) => string` | key assembly |

## requires — the seam must provide these

| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `logger` | project | structured logger | owned by the seam |
FXPL2
  cat > "$fx/pathbad/resources/a.md" <<'FXPA2'
# Keys

<!-- file: src/db/keys.ts -->
```ts
export const keys = { task: (o: string, i: string) => `${o}#${i}` }
```

<!-- file: src/db/tasks.ts -->
```ts
import { keys } from '../model/keys'
export const pk = keys.task('a', 'b')
```
FXPA2

  # ── Python profile fixture ──────────────────────────────────────
  # The worst defect of the measurement was **a syntactically perfect schema** — partial() and default() overlapped
  # so a partial update overwrote fields it had not sent, and only execution revealed it.
  # In Pydantic v2 the same class recurs as «a non-None default on an optional field».
  mkdir -p "$fx/py-ok/resources" "$fx/py-bad/resources" || { bad "failed to build the python fixtures"; return; }
  for m in py-ok py-bad; do
    printf '<!-- orangekit-pack: backend/fx v0 -->\n# fx pack\n' > "$fx/$m/PACK.md"
    printf '{ "axis": "backend", "name": "fx", "registry": "pypi", "pkgs": ["pydantic@2"] }\n' > "$fx/$m/pack.json"
  done
  cat > "$fx/py-ok/resources/schemas.md" <<'FXPOK'
# Schema

<!-- file: app/schemas.py -->
```python
# app/schemas.py
from pydantic import BaseModel, ConfigDict


class TaskUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    status: str | None = None
```
FXPOK
  cat > "$fx/py-bad/resources/schemas.md" <<'FXPBAD'
# Schema

<!-- file: app/schemas.py -->
```python
# app/schemas.py
from pydantic import BaseModel, ConfigDict


class TaskUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    status: str = "open"
    priority: int = 0
```
FXPBAD

  # ── markup and style sheets are not judged as syntax errors (a false positive) ──
  # A frontend axis pack claims `index.html`·`styles.css` as whole files. Node's type
  # stripping cannot parse them, yet the classifier counted them as **syntax errors** — in the measurement
  # a correct pack received FAIL 2. One false positive kills the check.
  mkdir -p "$fx/js-markup/resources" || { bad "failed to build the markup fixture"; return; }
  printf '<!-- orangekit-pack: frontend/fx v0 -->\n# fx pack\n' > "$fx/js-markup/PACK.md"
  printf '{ "axis": "frontend", "name": "fx", "pkgs": ["typescript@7"] }\n' > "$fx/js-markup/pack.json"
  cat > "$fx/js-markup/resources/entry.md" <<'FXJSM'
# Entry point

<!-- file: index.html -->
```html
<!doctype html>
<html lang="ko"><body><div id="app"></div></body></html>
```

<!-- file: src/styles.css -->
```css
:root { --gap: 8px; }
```

<!-- file: src/main.js -->
```js
/**
 * @param {string} id
 * @returns {number}
 */
export function mount(id) { return id }
```

<!-- file: entry.js -->
```js
/** @type {number} */
export const answer = 'not a number'
```
FXJSM

  # ── JS pack stub fixture — a label source + a whole-file test ─────
  # On vanilla (the first JavaScript axis) 4 JS defects of pack-smoke surfaced only on real assets:
  # ⓐ `./x.js` was unconditionally turned into `x.ts`, which diverged from the unit path so it received no stub (TS2307)
  # ⓑ TS syntax was written into a `.js` stub, so checkJs raised a syntax error
  # ⓒ it skipped on mere file existence, so the names of the second import statement were missing (TS2305)
  # ⓓ a JSDoc `import('...').Type` was not seen as an import, so the type was missing (TS2694).
  # All four can be judged **without tsc**, from the artifact (the stub file) — a fixture that runs offline too.
  mkdir -p "$fx/js-stub/resources" || { bad "failed to build the JS stub fixture"; return; }
  printf '<!-- orangekit-pack: frontend/fxjs v0 -->\n# fxjs pack\n' > "$fx/js-stub/PACK.md"
  printf '{ "axis": "frontend", "name": "fxjs", "pkgs": ["typescript@7"] }\n' > "$fx/js-stub/pack.json"
  # If the ledger declares a source path, that path being covered by a stub is **unchecked** — it must be a FAIL.
  # gcp's 6 ownership-check functions and vanilla's 6 modules were green in exactly this state.
  cat > "$fx/js-stub/ledger.md" <<'FXJSL'
## provides — this pack defines these

| symbol | definition file | shape | nature |
| --- | --- | --- | --- |
| `createStore` | store.md | **`src/store/create.js`** — `(initial) => store` | store |

## requires — the seam must provide these

| symbol | kind | shape | reason |
| --- | --- | --- | --- |
| `Task` | project | domain type | owned by the seam |
FXJSL
  cat > "$fx/js-stub/resources/store.md" <<'FXJSS'
# Store

```js
// src/store/create.js
export function createStore(initial) { return initial }
export function derive(store, fn) { return fn(store) }
```

```js
// src/schemas/task.js
/** @typedef {{ id: string }} Task */
export const TASK_KEY = 'task'
```

<!-- file: test/a.test.js -->
```js
import { createStore } from '../src/store/create.js'
/** @typedef {import('../src/schemas/task.js').Task} Task */
export const a = createStore(1)
```

<!-- file: test/b.test.js -->
```js
import { derive } from '../src/store/create.js'
export const b = derive(1, (x) => x)
```
FXJSS

  local out code
  sec "positive fixtures (must be blocked)"
  out=$(bash "$0" --pack "$fx/broken" --no-vectors 2>&1); code=$?
  [ "$code" -eq 0 ] && ok "the extraction·stub stage lets a defect-free pack through → exit 0" || bad "the extraction stage failed for no reason → exit $code"

  code=0; out=$(bash "$0" --pack "$fx/broken" 2>&1) || code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'failed to block'; then
    ok "pre-repair safeReturnTo → exit 1 ($(printf '%s' "$out" | grep -oE '[0-9]+/[0-9]+ vectors failed to block'))"
    printf '%s\n' "$out" | grep -E '^      .*A[0-9]' | head -3
  else
    bad "pre-repair safeReturnTo was not blocked → exit $code" "$(printf '%s' "$out" | grep -E '✓|✗|–' | tail -2 | tr '\n' ';')"
  fi

  code=0; out=$(bash "$0" --pack "$fx/pathbad" --no-vectors 2>&1) || code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'path mismatches'; then
    ok "the same file imported from a different path → exit 1 (for the intended reason)"
    [ -n "${ORANGEKIT_FX_WHY:-}" ] && printf "      ${C_D}%s${C_0}\n" "$(printf '%s' "$out" | grep '✗' | head -1 | sed 's/^  *//')"
  else
    bad "it does not catch a path mismatch → exit $code" "$(printf '%s' "$out" | grep -E '✗|!' | head -2 | tr '\n' ';')"
  fi

  code=0; out=$(bash "$0" --pack "$fx/py-bad" --no-vectors 2>&1) || code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'a partial update fills in fields it never sent'; then
    ok "a default on a partial-update schema → exit 1 (for the intended reason)"
    [ -n "${ORANGEKIT_FX_WHY:-}" ] && printf "      ${C_D}%s${C_0}\n" "$(printf '%s' "$out" | grep '✗' | head -1 | sed 's/^  *//')"
  elif [ "$code" -ne 1 ]; then
    bad "a default on a partial-update schema → exit $code (expected 1)" "the python profile does not catch this class"
  else
    bad "exit 1 but for **a different reason**" "$(printf '%s' "$out" | grep '✗' | head -2 | tr '\n' ';')"
  fi

  sec "harmless fixtures (must pass)"
  code=0; out=$(bash "$0" --pack "$fx/py-ok" --no-vectors 2>&1) || code=$?
  [ "$code" -eq 0 ] && ok "every optional field defaulting to None → exit 0 (no false positive)" \
    || bad "it FAILs a correct Pydantic schema → exit $code" "$(printf '%s' "$out" | grep '✗' | head -2 | tr '\n' ';')"

  code=0; out=$(bash "$0" --pack "$fx/js-markup" --no-vectors --keep --out "$fx/out-js" 2>&1) || code=$?
  if printf '%s' "$out" | grep -q 'a format this toolchain does not parse'; then
    ok "html·css whole-file claims → reported as unchecked rather than as syntax errors"
  else
    bad "it judges markup and style sheets as syntax errors" "$(printf '%s' "$out" | grep '✗' | head -2 | tr '\n' ';')"
  fi

  # **A check running and a check seeing its targets are different things.** tsc may be absent offline, so what is
  # asserted is not the verdict itself but **the premise of the verdict** (the generated tsconfig) — if those two are
  # wrong, planting a JSDoc type error still yields «typecheck passed» (measured — a miss).
  if [ -f "$fx/out-js/tsconfig.json" ]; then
    if grep -q '"checkJs": true' "$fx/out-js/tsconfig.json"; then
      ok "JS pack → checkJs on (with allowJs alone not one JSDoc type is checked)"
    else
      bad "this is a JS pack yet checkJs is off" "$(grep -o 'checkJs[^,]*' "$fx/out-js/tsconfig.json")"
    fi
    if grep -q '"\*\.js"' "$fx/out-js/tsconfig.json"; then
      ok "root JS is in include (with only \"*.ts\" main.js is outside tsc's view)"
    else
      bad "root JS is not in include" "$(grep -o '"include".*' "$fx/out-js/tsconfig.json")"
    fi
  else
    bad "tsconfig was not generated" "$fx/out-js/tsconfig.json missing — the premise of the verdict cannot be confirmed"
  fi

  code=0; out=$(bash "$0" --pack "$fx/fixed" --no-vectors --keep --out "$fx/out-ts" 2>&1) || code=$?
  if [ -f "$fx/out-ts/tsconfig.json" ] && grep -q '"checkJs": false' "$fx/out-ts/tsconfig.json"; then
    ok "TS pack → checkJs off (turning it on globally false-positives the config fragments a TS pack ships)"
  else
    bad "checkJs was turned on in a TS pack" "config fragments (the vite.config.js family) newly become check targets and false positives result"
  fi

  # ── decorator pack (measured on node-nest) ─────────────────────────
  # Two things are asserted. Not the verdict itself but **the premise of the verdict** — tsc is absent offline.
  #   ⓐ is experimentalDecorators turned on? If it is off, TypeScript reads decorators as
  #     the ES standard and **every parameter decorator becomes an error** (TS1240 — a false positive)
  #   ⓑ are the units strip-only mode rejected placed in the real tree? If they are not, then even with tsc
  #     those files are **never checked** — in NestJS constructor injection is parameter properties,
  #     so services and controllers dropped out wholesale (a miss)
  mkdir -p "$fx/deco/resources" || { bad "failed to build the decorator fixture"; return; }
  printf '<!-- orangekit-pack: backend/fx v0 -->\n# fx pack\n' > "$fx/deco/PACK.md"
  printf '{ "axis": "backend", "name": "fx", "pkgs": ["typescript@5"] }\n' > "$fx/deco/pack.json"
  cat > "$fx/deco/resources/a.md" <<'FXDECO'
# Service

<!-- file: src/tasks.service.ts -->
```ts
import { Injectable } from '@nestjs/common';
import { Repo } from './repo';

@Injectable()
export class TasksService {
  constructor(private readonly repo: Repo) {}

  find(id: string): string {
    return this.repo.get(id);
  }
}
```
FXDECO

  code=0; out=$(bash "$0" --pack "$fx/deco" --no-vectors --keep --out "$fx/out-deco" 2>&1) || code=$?
  if [ -f "$fx/out-deco/tsconfig.json" ] && grep -q '"experimentalDecorators": true' "$fx/out-deco/tsconfig.json"; then
    ok "decorator pack → experimentalDecorators on (with it off, correct Nest code fails wholesale with TS1240)"
  else
    bad "this is a decorator pack yet experimentalDecorators is off" "$(grep -o 'experimentalDecorators[^,]*' "$fx/out-deco/tsconfig.json" 2>/dev/null)"
  fi
  if [ -f "$fx/out-deco/src/tasks.service.ts" ]; then
    ok "units strip-only rejected are placed in the real tree too (parameter properties do not leak outside the typecheck)"
  else
    bad "the parameter-property file is not in the real tree" "it was restored but not placed in the typecheck target tree — even with tsc it is never checked"
  fi
  if [ -f "$fx/out-ts/tsconfig.json" ] && grep -q '"experimentalDecorators": false' "$fx/out-ts/tsconfig.json"; then
    ok "TS pack with no decorators → experimentalDecorators off (the detection is not always-on)"
  else
    bad "there are no decorators yet experimentalDecorators was turned on" "a detection that is unconditionally true separates nothing"
  fi


  # ── JSX whole files · extensionless .tsx imports · instanceof stubs (measured on the react-native pack) ──
  # All three are "premises of the verdict" — tsc is absent offline, so we assert the premise, not the result.
  #   (a) Does a .tsx whole file land in the real tree? If not, screens·components are outside the typecheck (a miss)
  #   (b) Does `@/components/Badge` resolve to the Badge.tsx the pack shipped? Resolving to .ts alone misjudges it as an orphan (a false positive)
  #   (c) Does the seam stub carry a construct signature? With a bare any, `e instanceof ApiError` cannot
  #     narrow unknown and correct code falls over with TS18046 (a false positive)
  mkdir -p "$fx/jsx/resources" || { bad "failed to create the JSX fixture"; return; }
  printf '<!-- orangekit-pack: app/fx v0 -->\n# fx pack\n' > "$fx/jsx/PACK.md"
  printf '{ "axis": "app", "name": "fx", "pkgs": ["typescript@6"] }\n' > "$fx/jsx/pack.json"
  printf '## requires\n\n| symbol | kind | shape | reason |\n| --- | --- | --- | --- |\n| `ApiError` | project | error class | seam |\n' > "$fx/jsx/ledger.md"
  cat > "$fx/jsx/resources/a.md" <<'FXJSX'
# Screen

<!-- file: src/components/Badge.tsx -->
```tsx
export function Badge({ label }: { label: string }) {
  return <span>{label}</span>;
}
```

<!-- file: src/lib/msg.ts -->
```ts
import { ApiError } from '@/api/http';
import { Badge } from '@/components/Badge';

export const shown = Badge;
export function msg(e: unknown): string {
  if (e instanceof ApiError) return String(e.code);
  return 'x';
}
```
FXJSX
  code=0; out=$(bash "$0" --pack "$fx/jsx" --no-vectors --keep --out "$fx/out-jsx" 2>&1) || code=$?
  if [ -f "$fx/out-jsx/src/components/Badge.tsx" ]; then
    ok "a JSX whole file lands in the real tree (screens·components do not leak out of the typecheck)"
  else
    bad "the JSX whole file is not in the real tree" "it was restored but not placed in the typecheck target tree — even with tsc it is never checked"
  fi
  if grep -q 'Badge' "$fx/out-jsx/.orphan.txt" 2>/dev/null; then
    bad "an extensionless import misjudged a shipped .tsx as an orphan" "$(tr '\n' ';' < "$fx/out-jsx/.orphan.txt")"
  else
    ok "an extensionless import resolves to the .tsx the pack shipped (no orphan misjudgment)"
  fi
  if grep -qE '^export declare const ApiError: \(new ' "$fx/out-jsx/src/api/http.ts" 2>/dev/null; then
    ok "the seam stub carries a construct signature (instanceof narrows unknown)"
  else
    bad "the seam stub is a bare any" "$(grep ApiError "$fx/out-jsx/src/api/http.ts" 2>/dev/null | tr '\n' ';') — the instanceof branch falls over with TS18046"
  fi

  code=0; out=$(bash "$0" --pack "$fx/js-stub" --no-vectors --keep --out "$fx/out-jsstub" 2>&1) || code=$?
  local stub="$fx/out-jsstub/src/store/create.js"
  if [ -f "$stub" ]; then
    ok "the label source of a JS pack is stubbed as .js (turning it into .ts diverges from the unit and gives TS2307)"
    grep -q '@typedef' "$stub" && ok "the stub is JSDoc syntax (writing export type into a .js makes checkJs raise a syntax error)" \
      || bad "TS syntax was written into a JS stub" "$(head -3 "$stub" | tr '\n' ';')"
    if grep -q 'createStore' "$stub" && grep -q 'derive' "$stub"; then
      ok "the stub merges the names of several import statements (with only the first statement, TS2305)"
    else
      bad "the stub dropped the names of the second import statement" "only $(grep -c 'export const' "$stub") declared"
    fi
  else
    bad "no stub was created for the label source of the JS pack" "$stub missing — every whole-file test receives TS2307"
  fi
  # If a pack-owned file is replaced by a stub it must be a FAIL (positive) — this reads the exit of the --pack run above
  if printf '%s' "$out" | grep -q 'a file the pack owns was replaced by a stub'; then
    ok "it catches a pack-owned file being covered by a stub (where unchecked used to be reported green)"
  else
    bad "a pack-owned file was covered by a stub and it still passes" "this path was assigned by the ledger provides — that code receives neither a typecheck nor an execution"
  fi

  if [ -f "$fx/out-jsstub/src/schemas/task.js" ] && grep -q 'Task' "$fx/out-jsstub/src/schemas/task.js"; then
    ok "a JSDoc import('...').Type is a stub target too (without seeing it, TS2694)"
  else
    bad "the JSDoc type import was not reflected in the stub" "a JS pack does not pull types in with import { }"
  fi

  code=0; out=$(bash "$0" --pack "$fx/fixed" 2>&1) || code=$?
  if [ "$code" -eq 0 ]; then ok "post-repair safeReturnTo → exit 0 (no false positive)"
  else bad "the repaired shape was a false positive → exit $code" "$(printf '%s' "$out" | grep '✗' | head -2 | tr '\n' ';')"; fi

  # Variants — when a vulnerable form exists in only one variant, a run over the base resources/ alone **never sees** that file
  mkdir -p "$fx/vfx/resources" "$fx/vfx/variants/auth/a1" "$fx/vfx/variants/auth/a2"
  printf '<!-- orangekit-pack: frontend/vfx v0 -->\n# vfx pack\n' > "$fx/vfx/PACK.md"
  printf '{ "axis": "frontend", "name": "vfx", "pkgs": ["typescript@5"], "variants": { "auth": { "x1": "a1", "x2": "a2" } } }\n' > "$fx/vfx/pack.json"
  printf '# Base\n' > "$fx/vfx/resources/base.md"
  cp "$fx/fixed/resources/routing.md" "$fx/vfx/variants/auth/a1/routing.md"
  cp "$fx/broken/resources/routing.md" "$fx/vfx/variants/auth/a2/routing.md"
  code=0; out=$(bash "$0" --pack "$fx/vfx" 2>&1) || code=$?
  if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'combination \[auth=a2\] FAIL'; then ok "a vulnerable form in only one variant is caught by the combination run → exit 1"
  else bad "missed the vulnerable form in a variant → exit $code" "$(printf '%s' "$out" | grep -E '✗|combination' | head -3 | tr '\n' ';')"; fi
  if printf '%s' "$out" | grep -q 'combination \[auth=a1\] passed'; then ok "the repaired variant passes (verdict per combination)"
  else bad "the repaired variant combination did not pass"; fi
}

# ════════════════════════════════════════════════════════════════════
MODE=""; PACK=""; PROFILE="auto"; OUT_DIR=""; KEEP=0; NO_VECTORS=0; ONLINE=0

[ $# -eq 0 ] && { printf "no arguments (see --help)\n" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pack)        MODE="smoke"; PACK="${2:-}"; shift 2 || exit 2 ;;
    --profile)     PROFILE="${2:-}"; shift 2 || exit 2 ;;
    --out)         OUT_DIR="${2:-}"; shift 2 || exit 2 ;;
    --keep)        KEEP=1; shift ;;
    --no-vectors)  NO_VECTORS=1; shift ;;
    --online)      ONLINE=1; shift ;;
    --self-test)   MODE="selftest"; shift ;;
    -h|--help)     sed -n '2,25p' "$0" | sed -E 's/^#[[:space:]]?//'; exit 0 ;;
    *)             printf "unknown option: %s (see --help)\n" "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$OUT_DIR" ]; then
  OUT_DIR=$(mktemp -d 2>/dev/null) || { printf "failed to create the working directory\n" >&2; exit 2; }
  [ "$KEEP" -eq 0 ] && trap 'rm -rf "$OUT_DIR"' EXIT
else
  mkdir -p "$OUT_DIR" || exit 2
fi

# A pack with variants (variants/<dimension>/<directory>/) is assembled and run per combination — the complete-file claims
# of variant files are not in the base resources/, so a solo run **never compiles them** (same rule as guide-gate)
run_smoke_combos() {
  local P="$1" name; name=$(basename "$P")
  local combos; combos=$(python3 - "$P" <<'PYCOMBO'
import itertools, json, os, sys
P = sys.argv[1]
vs = json.load(open(os.path.join(P, 'pack.json'))).get('variants') or {}
dims = sorted(vs)
choices = [sorted({d for d in vs[k].values()}, key=lambda x: (x is None, x or '')) for k in dims]
for combo in itertools.product(*choices):
    print(' '.join(f"{k}={v if v is not None else '-'}" for k, v in zip(dims, combo)))
PYCOMBO
) || { bad "could not read pack.json variants"; return 0; }
  local label i=0 cdir kv dim dir f out code
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    i=$((i+1)); cdir="$OUT_DIR/combo$i/$name"
    mkdir -p "$cdir/resources"
    cp "$P"/*.md "$P/pack.json" "$cdir/" 2>/dev/null
    cp "$P"/resources/*.md "$cdir/resources/" 2>/dev/null
    for kv in $label; do
      dim="${kv%%=*}"; dir="${kv#*=}"
      [ "$dir" = "-" ] && continue
      for f in "$P/variants/$dim/$dir"/*.md; do [ -f "$f" ] && cp "$f" "$cdir/resources/"; done
    done
    python3 - "$cdir/pack.json" <<'PYNOVAR'
import json, sys
j = json.load(open(sys.argv[1])); j.pop('variants', None)
json.dump(j, open(sys.argv[1], 'w'), ensure_ascii=False, indent=2)
PYNOVAR
    printf "\n${C_D}── variant combination [%s] ─────────────────────────────${C_0}\n" "$label"
    local extra=""; [ "$ONLINE" -eq 1 ] && extra="--online"; [ "$NO_VECTORS" -eq 1 ] && extra="$extra --no-vectors"
    code=0; out=$(bash "$0" --pack "$cdir" --out "$OUT_DIR/combo$i-work" $extra 2>&1) || code=$?
    printf '%s\n' "$out" | grep -E '^\s+[✓✗!–-]' | sed 's/^/  /'
    if [ "$code" -eq 0 ]; then ok "combination [$label] passed"; else bad "combination [$label] FAIL"; fi
  done <<< "$combos"
  # "variants": {} — a declaration that there are no combinations. 0 is not folded into a FAIL; run the base resources only
  [ "$i" -gt 0 ] || run_smoke "$P"
  return 0
}

case "$MODE" in
  smoke)    [ -n "$PACK" ] || { printf -- "--pack <directory> is required\n" >&2; exit 2; }
            if grep -q '"variants"' "$PACK/pack.json" 2>/dev/null; then run_smoke_combos "$PACK"; else run_smoke "$PACK"; fi ;;
  selftest) run_self_test ;;
  *)        printf "no mode: --pack or --self-test (see --help)\n" >&2; exit 2 ;;
esac

printf "\n${C_D}────────────────────────────────────────────${C_0}\n"
printf "  pass %s · ${C_Y}WARN %s${C_0} · ${C_C}SKIP %s${C_0} · ${C_R}FAIL %s${C_0}\n" "$PASS" "$WARN" "$SKIP" "$FAIL"
[ "$KEEP" -eq 1 ] && printf "  ${C_D}working directory: %s${C_0}\n" "$OUT_DIR"
printf "\n"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
