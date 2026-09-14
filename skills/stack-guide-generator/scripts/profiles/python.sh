#!/bin/bash
# profiles/python.sh — the Python profile for pack-smoke.sh
#
# The profile contract is one function: profile_check <working-directory>.
# Inside it, run the checks this toolchain can do and report them with ok/warn/bad/skip
# (those 4 functions and num() are defined by pack-smoke.sh). It produces no exit code —
# the caller sums the verdicts.
#
# **If a dependency is missing, report the skip explicitly.** A silent pass is not
# distinguishable from "checked and clean", and that is the failure mode this harness replaces.
#
# The same three layers as node-ts.sh: syntax (offline) → types (if present) → schema execution.
# The third is why this profile exists — the worst measured defect was a schema whose syntax was perfect,
# and **only execution** revealed that a partial update overwrites fields.

profile_check() {
  local OUT="$1"
  [ -s "$OUT/.units.tsv" ] || { skip "no restored units — nothing to check"; return 0; }
  local PY=""
  command -v python3 >/dev/null 2>&1 && PY="python3"
  [ -z "$PY" ] && command -v python >/dev/null 2>&1 && PY="python"
  [ -z "$PY" ] && { skip "no python — syntax and type checks skipped"; return 0; }

  # ── syntax: runs without a network ──
  # Not every fence that claims a path is a whole file. An indented method body or
  # a configuration fragment is a real idiom. Judging a fragment as a syntax error is a false positive, while
  # closing both eyes to all of them misses the real cut. **If it compiles when placed in a standard insertion
  # context it is a fragment**, and if it fits nowhere it is a syntax error (the same discipline as node-ts.sh).
  cat > "$OUT/.classify.py" <<'CLS'
import sys, os, textwrap
d = sys.argv[1]
only = sys.argv[2:]

def compiles(src):
    try:
        compile(src, "<probe>", "exec")
        return True
    except SyntaxError:
        return False

files = only if only else sorted(os.listdir(d))
for f in files:
    p = os.path.join(d, f)
    if not os.path.isfile(p):
        continue
    src = open(p, encoding="utf-8").read()
    if f.endswith(".toml"):
        try:
            import tomllib
            tomllib.loads(src)
            print("FILE\t%s" % f)
        except ModuleNotFoundError:
            print("UNSUP\t%s\tno tomllib (Python 3.11+ required)" % f)
        except Exception as e:
            print("FRAG\t%s\tTOML fragment: %s" % (f, str(e).split("\n")[0]))
        continue
    if not f.endswith(".py"):
        print("UNSUP\t%s\tneither .py nor .toml" % f)
        continue
    if compiles(src):
        print("FILE\t%s" % f)
        continue
    body = textwrap.indent(src, "    ")
    if compiles("if True:\n" + body):
        print("FRAG\t%s\tstatement fragment" % f)
        continue
    if compiles("class __C:\n" + body):
        print("FRAG\t%s\tclass body fragment" % f)
        continue
    try:
        compile(src, f, "exec")
        msg = ""
    except SyntaxError as e:
        msg = "%s (line %s)" % (e.msg, e.lineno)
    print("SYNTAX\t%s\t%s" % (f, msg))
CLS

  # Only units that claimed a whole file are checked. A label unit is normally a fragment,
  # so judging it as a syntax error makes every one of them a false positive.
  local claimed; claimed=$(awk -F'\t' '$5=="file" {print $1}' "$OUT/.units.tsv" | tr '\n' ' ')
  if [ -z "$(printf '%s' "$claimed" | tr -d ' ')" ]; then
    skip "0 whole-file claims — syntax and type checks skipped" "a label (# path) alone cannot tell whether it is a whole file. Only fences claimed with <!-- file: path --> are checked"
    return 0
  fi
  # shellcheck disable=SC2086
  "$PY" "$OUT/.classify.py" "$OUT/units" $claimed 2>/dev/null > "$OUT/.classify.tsv"
  [ -s "$OUT/.classify.tsv" ] || { skip "the syntax classifier could not run" "$PY could not run the classifier"; return 0; }

  local nfile nfrag nsyn nuns v u msg pth
  nfile=$(num "$(grep -c '^FILE' "$OUT/.classify.tsv" | tr -d ' ')")
  nfrag=$(num "$(grep -c '^FRAG' "$OUT/.classify.tsv" | tr -d ' ')")
  nsyn=$(num "$(grep -c '^SYNTAX' "$OUT/.classify.tsv" | tr -d ' ')")
  nuns=$(num "$(grep -c '^UNSUP' "$OUT/.classify.tsv" | tr -d ' ')")
  [ "$nuns" -gt 0 ] && skip "${nuns} unchecked for syntax" "$(awk -F'\t' '$1=="UNSUP"{printf "%s(%s) ", $2, substr($3,1,40)}' "$OUT/.classify.tsv")— what this profile handles is .py and .toml"
  [ "$nfrag" -gt 0 ] && warn "claimed whole files but ${nfrag} are fragments" "$(awk -F'\t' '$1=="FRAG"{printf "%s(%s) ", $2, $3}' "$OUT/.classify.tsv")— use a label (# path) instead of <!-- file: -->, or make the fence a whole file"

  if [ "$nsyn" -gt 0 ]; then
    while IFS=$'\t' read -r v u msg; do
      [ "$v" = "SYNTAX" ] || continue
      pth=$(awk -F'\t' -v u="$u" '$1==u {print $2" ("$3":"$4")"}' "$OUT/.units.tsv")
      bad "syntax error: $pth" "$msg"
    done < "$OUT/.classify.tsv"
  else
    ok "syntax check passed — ${nfile} claimed whole files"
  fi

  # Only whole files are moved into the real tree (fragments are not typecheck targets)
  local dst
  while IFS=$'\t' read -r v u msg; do
    [ "$v" = "FILE" ] || continue
    dst=$(awk -F'\t' -v u="$u" '$1==u {print $2}' "$OUT/.units.tsv")
    [ -n "$dst" ] || continue
    mkdir -p "$OUT/$(dirname "$dst")" 2>/dev/null
    cat "$OUT/units/$u" >> "$OUT/$dst"
  done < "$OUT/.classify.tsv"

  # ── typecheck: it needs dependencies ──
  local tc=""
  [ -x "$OUT/.venv/bin/pyright" ] && tc="$OUT/.venv/bin/pyright"
  [ -z "$tc" ] && command -v pyright >/dev/null 2>&1 && tc="pyright"
  [ -z "$tc" ] && [ -x "$OUT/.venv/bin/mypy" ] && tc="$OUT/.venv/bin/mypy"
  [ -z "$tc" ] && command -v mypy >/dev/null 2>&1 && tc="mypy"
  if [ -z "$tc" ]; then
    skip "no pyright·mypy — typecheck skipped" "normal when offline. --online installs the pack's pkgs — this item is **unchecked**, not passed"
  else
    # **Tell pyright which interpreter to use.** Without it, it looks at the system python and
    # pours out `Import "sqlalchemy" could not be resolved` — every correct pack becomes
    # a typecheck failure (measured on the fastapi fan-in — a false positive).
    local tout tcode=0 pyargs=""
    [ -x "$OUT/.venv/bin/python" ] && case "$tc" in
      *pyright) pyargs="--pythonpath $OUT/.venv/bin/python" ;;
      *mypy)    pyargs="--python-executable $OUT/.venv/bin/python" ;;
    esac
    # shellcheck disable=SC2086
    tout=$(cd "$OUT" && "$tc" $pyargs app 2>&1) || tcode=$?
    if [ "$tcode" -eq 0 ]; then
      ok "typecheck passed ($tc)"
    else
      bad "typecheck failed ($tc)" "$(printf '%s' "$tout" | grep -E 'error' | head -3 | tr '\n' ';')"
    fi
  fi

  # ── schema execution ──
  # **The worst measured defect was a schema whose syntax was perfect.** partial() and default() overlapped, so
  # a partial update overwrote fields it never sent with their defaults, and only execution revealed it.
  # In Pydantic v2 the same class recurs as a `model_dump()` that does not use `exclude_unset`.
  _pyd_probe "$OUT" "$PY"
  return 0
}

_pyd_probe() {
  local OUT="$1" PY="$2" pybin="$PY"
  [ -x "$OUT/.venv/bin/python" ] && pybin="$OUT/.venv/bin/python"
  "$pybin" -c 'import pydantic' >/dev/null 2>&1 || {
    skip "no pydantic — schema execution skipped" "if the guide pinned a validation library, this check catches **the class reading does not catch**"
    return 0
  }
  # Find the schema files the pack defined. If there are none there is nothing to check, which is not a pass.
  local sf; sf=$({ grep -rl 'BaseModel' "$OUT/app" 2>/dev/null || true; } | head -3 | tr '\n' ' ')
  if [ -z "$(printf '%s' "$sf" | tr -d ' ')" ]; then
    skip "no file defines BaseModel — schema execution skipped" "it only catches fences claimed as whole files"
    return 0
  fi
  cat > "$OUT/.pydprobe.py" <<'PRB'
import sys, os, importlib.util, inspect
sys.path.insert(0, os.getcwd())
from pydantic import BaseModel, ValidationError


def probe(name, obj, fields):
    # ① an empty object — are the required fields actually rejected
    required = [k for k, f in fields.items() if f.is_required()]
    try:
        obj()
        empty = "pass"
    except ValidationError:
        empty = "reject"
    print("EMPTY\t%s\t%s\t%d required" % (name, empty, len(required)))

    # ② a partial update carrying only 1 field — **do fields it never sent come back filled in**
    #     dumping without exclude_unset is a common save path. If defaults ride along then,
    #     a partial update overwrites the remaining fields (the worst measured defect was this class).
    one = None
    for k in fields:
        for cand in ("x", 1, True):
            try:
                one = (k, obj(**{k: cand}))
                break
            except ValidationError:
                continue
        if one:
            break
    if one:
        k, inst = one
        dumped = inst.model_dump()
        filled = [x for x, v in dumped.items() if x != k and v is not None]
        print("PARTIAL\t%s\t%s\t%s" % (name, k, ",".join(filled) or "-"))
    else:
        print("PARTIAL\t%s\t-\tERR cannot be built from a single field" % name)

    # ③ an unknown key — is it passed, stripped, or rejected
    try:
        obj.model_validate({"__zzz__": 1}, strict=False)
        unknown = "pass"
    except ValidationError as e:
        unknown = "reject" if "extra" in str(e).lower() else "required missing (unknown key ignored)"
    except Exception:
        unknown = "cannot tell"
    print("UNKNOWN\t%s\t%s" % (name, unknown))


found = 0
for path in sys.argv[1:]:
    mod_name = path.replace("/", ".").removesuffix(".py")
    spec = importlib.util.spec_from_file_location(mod_name, path)
    if spec is None or spec.loader is None:
        continue
    m = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(m)
    except Exception as e:
        print("LOAD\t%s\t%s" % (path, str(e).split("\n")[0]))
        continue
    for name, obj in vars(m).items():
        if not (inspect.isclass(obj) and issubclass(obj, BaseModel) and obj is not BaseModel):
            continue
        fields = getattr(obj, "model_fields", {})
        if not fields:
            continue
        found += 1
        try:
            probe(name, obj, fields)
        except Exception as e:
            # **One model failing must not swallow the rest** — schema execution would become
            # a skip wholesale and the reason this profile exists would vanish (measured on the fastapi fan-in).
            print("CLSERR\t%s\t%s" % (name, str(e).split("\n")[0]))
print("FOUND\t%d" % found)
PRB
  local out
  # shellcheck disable=SC2086
  out=$(cd "$OUT" && "$pybin" .pydprobe.py $sf 2>&1)
  local nfound; nfound=$(num "$(printf '%s' "$out" | awk -F'\t' '$1=="FOUND"{print $2}' | tail -1)")
  if [ "$nfound" -eq 0 ]; then
    skip "the schema classes could not be loaded" "$(printf '%s' "$out" | grep '^LOAD' | head -2 | tr '\n' ';') — normal if there is an import that needs a seam stub"
    return 0
  fi
  # **It is a defect only on a partial-update schema.** A default on a create schema is normal, so they are split by name
  # (Update·Patch). Without the split every correct pack FAILs — a false positive kills the check.
  local leak other
  leak=$(printf '%s' "$out" | awk -F'\t' 'tolower($2) ~ /update|patch/ && $1=="PARTIAL" && $4!="-" && $4 !~ /^ERR/ {printf "%s(sent only %s but %s got filled) ", $2, $3, $4}')
  other=$(printf '%s' "$out" | awk -F'\t' 'tolower($2) !~ /update|patch/ && $1=="PARTIAL" && $4!="-" && $4 !~ /^ERR/ {printf "%s(%s) ", $2, $4}')
  if [ -n "$leak" ]; then
    bad "a partial update fills in fields it never sent: $leak" "dumping without exclude_unset makes these defaults overwrite the save — the worst measured defect was this class. Do not put defaults on the optional fields of a partial-update schema (None only)"
  else
    ok "${nfound} schemas executed — the partial-update schema does not fill in fields"
    [ -n "$other" ] && printf "      ${C_D}defaults on the create schema (normal): %s${C_0}\n" "$other"
  fi
  printf "      ${C_D}%s${C_0}\n" "$(printf '%s' "$out" | awk -F'\t' '$1=="EMPTY"{printf "%s:empty-object=%s(%s) ", $2, $3, $4} $1=="UNKNOWN"{printf "unknown-key=%s ", $3}')"
  return 0
}
