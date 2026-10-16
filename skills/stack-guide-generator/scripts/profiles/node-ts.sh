#!/bin/bash
# profiles/node-ts.sh — the Node/TypeScript profile for pack-smoke.sh
#
# The profile contract is one function: profile_check <working-directory>.
# Inside it, run the checks this toolchain can do and report them with ok/warn/bad/skip
# (those 4 functions and num() are defined by pack-smoke.sh). It produces no exit code —
# the caller sums the verdicts.
#
# **If a dependency is missing, report the skip explicitly.** A silent pass is not
# distinguishable from "checked and clean", and that is the failure mode this harness replaces.

profile_check() {
  local OUT="$1"
  [ -s "$OUT/.units.tsv" ] || { skip "no restored units — nothing to check"; return 0; }
  command -v node >/dev/null 2>&1 || { skip "no node — syntax and type checks skipped"; return 0; }

  # ── syntax: it runs without a network ──
  # Types are stripped with Node's stripTypeScriptTypes and then parsed. `--check` does not apply type
  # stripping and judges every correct TS as a syntax error (measured during development) — it is not used.
  #
  # Not every fence that claims a path is a whole file. A configuration fragment such as
  # `resolve: { alias: ... }` is a real idiom. Judging a fragment as a syntax error is a false positive,
  # and closing both eyes to all of them misses the real cut. So **if it parses when placed in a standard
  # insertion context it is a fragment, and if it fits nowhere it is a syntax error**.
  cat > "$OUT/.classify.mjs" <<'CLS'
import { stripTypeScriptTypes } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const dir = process.argv[2];
const only = process.argv.slice(3);
const strips = (code) => { try { stripTypeScriptTypes(code, { mode: 'strip' }); return true; } catch { return false; } };
const files = only.length ? only : readdirSync(dir).sort();
for (const f of files) {
  const src = readFileSync(join(dir, f), 'utf8');
  // JSX and SFC are not type-stripping targets — they are not judged but reported as unchecked.
  if (/\.(tsx|jsx|vue|svelte)$/.test(f))              { console.log(`UNSUP\t${f}\tJSX/SFC is not a stripping target`); continue; }
  // a format this toolchain does not parse — `check_fence_imports` already excepts data files,
  // but only the classifier was out of step, so `firestore.rules` was caught as a syntax error (C1 measured).
  if (/\.(rules|ya?ml|toml|sql|env|ini|cfg|txt|md|graphql|prisma|html?|css|scss|sass|less|svg)$/.test(f)) {
    console.log(`UNSUP\t${f}\ta format this toolchain does not parse`); continue;
  }
  if (/\.json$/.test(f)) {
    const noComments = src.replace(/^\s*\/\/.*$/gm, '');
    try { JSON.parse(noComments); console.log(`FILE\t${f}`); }
    catch (e) { console.log(`FRAG\t${f}\tJSON fragment, or it contains comments`); }
    continue;
  }
  if (strips(src))                                    { console.log(`FILE\t${f}`); continue; }
  if (strips(`const __o = {\n${src}\n};`))            { console.log(`FRAG\t${f}\tobject fragment`); continue; }
  if (strips(`function __f() {\n${src}\n}`))          { console.log(`FRAG\t${f}\tstatement fragment`); continue; }
  if (strips(`class __C {\n${src}\n}`))               { console.log(`FRAG\t${f}\tclass body fragment`); continue; }
  let msg = '';
  try { stripTypeScriptTypes(src, { mode: 'strip' }); } catch (e) { msg = String(e.message).split('\n')[0]; }
  // There is syntax that strip-only mode **rejects but that is correct TypeScript** — enum · namespace ·
  // parameter properties cannot be erased by removing types alone (they generate code), so Node blocks them.
  // Counting these as syntax errors makes a correct pack FAIL (the aws-serverless pilot warned of it).
  if (/not supported in strip-only mode/.test(msg)) { console.log(`UNSUP\t${f}\t${msg}`); continue; }
  console.log(`SYNTAX\t${f}\t${msg}`);
}
CLS

  # Only units that claimed a whole file are checked. A label unit is normally a fragment,
  # so judging it as a syntax error makes every one of them a false positive (measured during development: 24 cases across 5 packs).
  local claimed; claimed=$(awk -F'\t' '$5=="file" {print $1}' "$OUT/.units.tsv" | tr '\n' ' ')
  if [ -z "$(printf '%s' "$claimed" | tr -d ' ')" ]; then
    skip "0 whole-file claims — syntax and type checks skipped" "a label (// path) alone cannot tell whether it is a whole file. Only fences claimed with <!-- file: path --> are checked"
    return 0
  fi
  # shellcheck disable=SC2086
  node "$OUT/.classify.mjs" "$OUT/units" $claimed 2>/dev/null > "$OUT/.classify.tsv"
  if [ ! -s "$OUT/.classify.tsv" ]; then
    skip "the syntax classifier could not run" "node $(node --version 2>/dev/null) does not support stripTypeScriptTypes (Node 22.13+ required)"
    return 0
  fi

  local nfile nfrag nsyn nuns v u msg pth
  nfile=$(num "$(grep -c '^FILE' "$OUT/.classify.tsv" | tr -d ' ')")
  nfrag=$(num "$(grep -c '^FRAG' "$OUT/.classify.tsv" | tr -d ' ')")
  nsyn=$(num "$(grep -c '^SYNTAX' "$OUT/.classify.tsv" | tr -d ' ')")
  nuns=$(num "$(grep -c '^UNSUP' "$OUT/.classify.tsv" | tr -d ' ')")
  [ "$nuns" -gt 0 ] && skip "${nuns} unchecked for syntax" "$(awk -F'\t' '$1=="UNSUP"{printf "%s(%s) ", $2, substr($3,1,40)}' "$OUT/.classify.tsv")— syntax that Node's type stripping cannot handle (JSX·SFC·enum·namespace·parameter properties). **It may be correct TypeScript** — it is judged only in an environment that has tsc (audit A)"
  [ "$nfrag" -gt 0 ] && warn "claimed whole files but ${nfrag} are fragments" "$(awk -F'\t' '$1=="FRAG"{printf "%s(%s) ", $2, $3}' "$OUT/.classify.tsv")— use a label (// path) instead of <!-- file: -->, or make the fence a whole file"

  if [ "$nsyn" -gt 0 ]; then
    while IFS=$'\t' read -r v u msg; do
      [ "$v" = "SYNTAX" ] || continue
      pth=$(awk -F'\t' -v u="$u" '$1==u {print $2" ("$3":"$4")"}' "$OUT/.units.tsv")
      bad "syntax error: $pth" "$msg"
    done < "$OUT/.classify.tsv"
  else
    ok "syntax check passed — ${nfile} claimed whole files"
  fi
  # ── typecheck: it needs dependencies ──
  # **Restoration and tsconfig generation happen regardless of whether tsc exists.** It used to return right
  # here when tsc was absent, leaving neither the real file tree nor a tsconfig — then ⓐ the working directory
  # audit A takes over stops being a «nearly finished scratch project» (which is the reason --keep
  # exists) and ⓑ **the premise of the verdict cannot be checked**: a check running and a check seeing its
  # targets are different things, and the latter is written in tsconfig — without that file there is no way to confirm it.
  local tsc=""
  command -v tsc >/dev/null 2>&1 && tsc="tsc"
  [ -z "$tsc" ] && [ -x "$OUT/node_modules/.bin/tsc" ] && tsc="$OUT/node_modules/.bin/tsc"

  # Only whole files are moved into the real tree (fragments are not typecheck targets).
  # **The units strip-only mode rejected are moved too.** That UNSUP does not mean «this pack is wrong» but
  # «Node's type stripper cannot erase it» (enum · namespace · parameter properties), and
  # the skip wording above itself says "it may be correct TypeScript — it is judged only in an environment that
  # has tsc". Yet if they are not moved they are **never judged even with tsc** —
  # in the NestJS pack constructor injection is exactly parameter properties, so services and controllers
  # dropped wholesale outside the typecheck (measured on node-nest — a miss). Unsupported formats (JSX·yaml etc.) stay out.
  local dst promoted=0
  while IFS=$'\t' read -r v u msg; do
    case "$v" in
      FILE) ;;
      # **JSX (.tsx·.jsx) is moved too.** The stripper just cannot erase it; tsc (`jsx: preserve`) still judges it —
      # leave it out and whole screen·component files are **never type-checked once** and stay green (measured on the
      # react-native pack — a miss: ScreenStates.tsx · _layout.tsx). SFCs (.vue·.svelte) tsc cannot read, so they stay out.
      UNSUP) case "$u" in *.tsx|*.jsx) promoted=$((promoted+1)) ;; *)
               case "$msg" in *"not supported in strip-only mode"*) promoted=$((promoted+1)) ;; *) continue ;; esac ;;
             esac ;;
      *) continue ;;
    esac
    dst=$(awk -F'\t' -v u="$u" '$1==u {print $2}' "$OUT/.units.tsv")
    [ -n "$dst" ] || continue
    mkdir -p "$OUT/$(dirname "$dst")" 2>/dev/null
    cat "$OUT/units/$u" >> "$OUT/$dst"
  done < "$OUT/.classify.tsv"

  # **`@/*` is not nailed to `src/`.** The layout differs per pack — nextjs puts `app/`·`stores/`
  # at the project root and does not use `src/`. With only one of them every correct import of that pack
  # becomes unresolved (measured — a false positive).
  #
  # **`baseUrl` is not used.** TypeScript 7 removed it, so
  # `error TS5102: Option 'baseUrl' has been removed` makes **every correct pack fail the typecheck**
  # (measured on the firebase pilot). Since TS 4.4 `paths` is resolved relative to tsconfig without baseUrl,
  # so it means the same thing in both 5 and 7.
  #
  # `types: []` **erases even the implicit globals** — even with @types/node installed, Buffer·process
  # become «names that do not exist» and a correct pack FAILs (measured on aws-serverless — 2 false positives).
  # If they are installed put them in; only when there are none is it emptied.
  # **Every installed @types is loaded.** Pinning just one puts the rest the pack declared out of view —
  # `@types/jest` was installed but it was nailed to `["node"]`, so the test files the pack shipped failed
  # with `Cannot find name 'describe'` (measured on node-nest — a false positive). A real project's
  # tsconfig omits types and loading them all is the default; the reason a list is built here is
  # to hold it down to `[]` when not a single one is installed.
  local types='[]' tnames
  tnames=$(ls "$OUT/node_modules/@types" 2>/dev/null | sed 's/^/"/; s/$/"/' | tr '\n' ',' | sed 's/,$//')
  [ -n "$tnames" ] && types="[$tnames]"
  # **A pack that uses decorators can only be checked with a tsconfig that turns them on.** TypeScript 5
  # reads decorators as the ES standard (Stage 3) when experimentalDecorators is off, and
  # that syntax **has no parameter decorators** and the signature of a property decorator differs too —
  # a correct NestJS pack fails wholesale with TS1240 (measured on node-nest — a false positive).
  # It is derived from the restored units: both `@Pascal(` at the head of a line and `(@Pascal(` in an argument position are looked at.
  local deco='false'
  if grep -rqE '(^|\()[[:space:]]*@[A-Z][A-Za-z0-9_]*[[:space:]]*[({]' "$OUT/units" 2>/dev/null; then
    deco='true'
  fi
  # **`include` is not hardcoded.** The top-level layout differs per pack — firebase keeps everything
  # under `functions/`, so with a fixed list **tsc did not see one line of the pack's code**
  # (the verdict was green even when `TS18003: No inputs were found` came out). It is derived from the
  # top-level directories of the restored units.
  local inc; inc=$(cut -f2 "$OUT/.units.tsv" 2>/dev/null | grep '/' | cut -d/ -f1 | sort -u \
    | sed 's#^#"#; s#$#/**/*"#' | tr '\n' ',' | sed 's/,$//')
  # **The extension of the files placed at the root is not nailed to one.** With only `"*.ts"`, the `main.js` a JS-axis pack
  # puts at the root is outside tsc's view, so **planting an intended type error still yields «typecheck passed»**
  # (measured — a miss). What is in `include` and what is checked are different things.
  inc="${inc:+$inc,}\"*.ts\",\"*.js\",\"*.mjs\",\"*.cjs\""
  # **`checkJs` is split by the pack's language.** With `allowJs` alone a `.js` is merely parsed and JSDoc
  # types are **not checked at all** — the type-standard slot of a JS-axis pack (JSDoc + runtime schema
  # validation) ends up with zero verifiers. But turning it on globally makes the config fragments a TS pack
  # ships (the `vite.config.js` family) newly become check targets, which false-positives. So it is turned on
  # **only when there is not a single TS among the restored units** — then this pack is a JS pack.
  local hasts checkjs='false'
  hasts=$(num "$(cut -f2 "$OUT/.units.tsv" 2>/dev/null | grep -cE '\.(ts|tsx|mts|cts)$' | tr -d ' ')")
  [ "$hasts" -eq 0 ] && checkjs='true'
  # **If there are stubs, `noImplicitAny` is turned off.** A stub is `any` by definition, so every argument of
  # a callback consuming it becomes an implicit any — that TS7006 **measures the stub, not the pack**
  # (measured on vanilla: in a real project the same file passes with no errors).
  # The remaining strict items (strictNullChecks etc.) stay on. The omission is **reported explicitly**.
  local nia='true'
  if [ -s "$OUT/.stubbed.txt" ]; then nia='false'; fi
  cat > "$OUT/tsconfig.json" <<TSC
{
  "compilerOptions": {
    "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler",
    "strict": true, "noImplicitAny": $nia, "noEmit": true, "skipLibCheck": true,
    "experimentalDecorators": $deco, "emitDecoratorMetadata": $deco,
    "jsx": "preserve", "allowJs": true, "checkJs": $checkjs,
    "paths": { "@/*": ["./src/*", "./*"] },
    "types": $types
  },
  "include": [$inc]
}
TSC
  [ "$checkjs" = "true" ] && ok "judged a JS pack — checkJs is turned on (JSDoc types get checked)"
  [ "$deco" = "true" ] && ok "judged a decorator pack — experimentalDecorators·emitDecoratorMetadata are turned on" \
      "with them off TypeScript reads decorators as the ES standard and every parameter decorator becomes an error"
  [ "$nia" = "false" ] && warn "noImplicitAny off — $(wc -l < "$OUT/.stubbed.txt" | tr -d ' ') seam stubs are any" "an implicit any on a callback argument that consumes a stub is not a pack defect. **Only this item is unchecked** and the rest of strict is on"
  [ "$promoted" -gt 0 ] && ok "${promoted} syntax-unchecked units are put into the typecheck targets" \
      "what strip-only mode rejected may be correct TypeScript — tsc judges it"
  if [ -z "$tsc" ]; then
    skip "no tsc — typecheck skipped" "normal when offline. Audit A runs 'npm i -D typescript' in this working directory and then uses tsconfig.json as is — this item is **unchecked**, not passed"
    return 0
  fi

  local tout
  if tout=$("$tsc" -p "$OUT/tsconfig.json" 2>&1); then
    ok "typecheck passed ($tsc)"
  else
    bad "typecheck failed" "$(printf '%s' "$tout" | grep -E 'error TS' | head -3 | tr '\n' ';')"
  fi
  return 0
}
