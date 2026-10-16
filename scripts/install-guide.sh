#!/bin/bash
# scripts/install-guide.sh — assembles axis packs + seams and installs them as project guide skills
#
# This is the delivery path after the prebuilt unit dropped from "combination" down to "axis". Only the part that
# genuinely depends on the combination is left as a seam, and 2 axis packs + the seam fold into two skills:
#   .claude/skills/{frontend,backend,app}-guide/{SKILL.md, resources/*.md, assembly.json}
# **SKILL.md only appears when a seam exists** — without one, a resources-only install is the normal intermediate state.
#
# **Every verdict is made here.** Whether the pack is usable · whether a seam exists · what is left ·
# whether the baseline is fresh is decided by the data this script reads. If the caller re-decides in prose,
# that copy diverges — it actually did diverge, and became a rule that deleted a healthy assembly.
#
# Usage:
#   install-guide.sh --frontend <pack|none> --backend <pack|none> [--app <app|none>] [--seam <combo>]
#                    [--gate] [--notes <file>] [--dry-run] [--force] [--no-freshness]
#
#   --frontend react-vite     uses guides/frontend/react-vite
#   --backend  supabase       uses guides/backend/supabase
#   --app      react-native   uses guides/app/react-native. If the pack is missing or unfinished, it is recorded in need
#                             as "app" (full generation), exactly like the web screen axis
#
#   The axis value `custom` (user-defined) has no pack, so it is a generation target; `undecided` (not chosen) is
#   skipped like `none` — no guide is built by guesswork for an axis that is still undecided
#   --seam     nextjs+supabase  also installs the prebuilt seam (cache → pack only, when absent)
#   --gate                      passes only axes built as far as SKILL.md to guide-gate.sh.
#                               An axis assembled to resources only is not passed — the gate judges a missing
#                               SKILL.md as FAIL and would misread the normal intermediate state as a failure
#   --notes <file>              carries the preset notes (JSON) into guide-job.json as-is
#   --save-seam <combo>         puts a seam that has just passed audit into the cache (called right after generation)
#   --no-cache                  neither reads nor writes the cache
#   --self-test                 proves "an unfinished pack is not assembled" with a synthetic pack
#   --no-freshness              turns the freshness verdict off. On by default (scripts/guide-freshness.sh)
#                               — it runs only on a first install, and with no network it reports undecided
#
# What is left is recorded in `.orangekit/guide-job.json` — this is the only place that knows what is left per axis.
# When nothing is left, that file is deleted. Closing the work is stack-guide-generator's job.
#
# **A missing or unfinished pack does not cut things off.** That axis is recorded as a generation target and the
# other axis keeps assembling — one missing axis is no reason to throw away the other axis's assembly.
#
# Seam cache — built once per combination:
#   ~/.claude/orangekit/seam-cache/<combo>@<plugin-version>/{frontend,backend,app.<app>.<shape>}/
#   Even with no prebuilt seam, the second project on the same combination assembles without generating.
#   A seam rots on the major version of both axes, so the cache is split by plugin version.
#   **The app seam is not determined by the combination alone** — even for the same react-native, the screen·bridge
#   sections differ depending on whether it is a shell (rn-webview · rn-native-screens) or the app itself (cross-platform).
#   So the app slot's name carries the app value together with the shape (appShell, else deliveryModel). The shape is
#   read from --notes (else guide-job.json's notes), and **if it cannot be read, the app slot does not use the cache**
#   — folding "cannot tell" into some arbitrary shape would hand over a seam for a different shape
#
# Ownership is split (the same structure as install-rules.sh's T1 card ↔ project card):
#   pack files → plugin-owned. Updates are judged by the orangekit-pack stamp
#   seam       → plugin-owned when prebuilt, project-owned when generated (never touched)
#
# Idempotent. Same stamp → skipped / older → .bak then updated / same stamp + different content
# → treated as a user edit and preserved.
#
# **The project pins the stack premise.** When the pkgs major of an installed guide differs from the plugin
# pack, it is not updated — the project stacked code on the stack it started from, and switching to patterns of
# a different major makes the guidance not old but wrong for this project. Raising the version is the project's
# decision, taken when it raises its dependencies. A fix inside the same major (defect · security) is
# updated. To skip that knowingly, use --force.
#
# Exit codes: 0 = success (pending generation included), 1 = post-install verification or gate failure, 2 = usage error

set -Eeuo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
G="$PLUGIN_ROOT/guides"

FE=""; BE=""; SEAM=""; DRY=0; FORCE=0; SAVE_SEAM=""; NO_CACHE=0; CHECK_FRESH=1
GATE=0; NOTES=""; AXIS_STATE=""; FE_STATE=skip; BE_STATE=skip; SELFTEST=0
APP=""; APP_STATE=skip
PLUGIN_VER=$(grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
PLUGIN_VER="${PLUGIN_VER:-0.0.0}"
CACHE_ROOT="${ORANGEKIT_SEAM_CACHE:-$HOME/.claude/orangekit/seam-cache}"
while [ $# -gt 0 ]; do
  case "$1" in
    --frontend) FE="${2:-}"; shift 2 ;;
    --backend)  BE="${2:-}"; shift 2 ;;
    --app)      APP="${2:-}"; shift 2 ;;
    --seam)       SEAM="${2:-}"; shift 2 ;;
    --save-seam)  SAVE_SEAM="${2:-}"; shift 2 ;;
    --no-cache)   NO_CACHE=1; shift ;;
    --gate)       GATE=1; shift ;;
    --notes)      NOTES="${2:-}"; shift 2 ;;
    --no-freshness)    CHECK_FRESH=0; shift ;;
    --check-freshness) CHECK_FRESH=1; shift ;;   # backward compatibility — this is the default now
    --self-test) SELFTEST=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    --force)    FORCE=1; shift ;;
    # --help is the whole header comment. Pinning the range to numbers truncates it the moment the header grows
    -h|--help)  awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *) printf 'FATAL: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -d "$G" ] || { printf 'FATAL: no guides/: %s\n' "$G" >&2; exit 2; }
[ "$SELFTEST" -eq 1 ] || [ -n "$SAVE_SEAM" ] || [ -n "$FE" ] || [ -n "$BE" ] || [ -n "$APP" ] || { printf 'FATAL: one of --frontend · --backend · --app is required\n' >&2; exit 2; }

stamp_of() { grep -m1 -oE 'orangekit-(pack|seam): [^ ]+ v[0-9]+\.[0-9]+\.[0-9]+' "$1" 2>/dev/null | awk '{print $3}' || true; }
TODAY=$(date +%Y-%m-%d)
installed=0; updated=0; skipped=0

# ── Idempotent copy of a single file ──────────────────────────────────
put() { # $1=source $2=target
  local src="$1" dst="$2" base sv tv
  base=$(basename "$dst")
  sv=$(stamp_of "$src"); sv="${sv:-none}"
  if [ ! -f "$dst" ]; then
    printf '    + %-30s %s\n' "$base" "$sv"
    [ "$DRY" -eq 0 ] && cp "$src" "$dst"
    installed=$((installed+1)); return 0
  fi
  tv=$(stamp_of "$dst"); tv="${tv:-none}"
  if [ "$sv" = "$tv" ] && [ "$FORCE" -eq 0 ]; then
    if cmp -s "$src" "$dst"; then
      printf '    = %-30s same — skipped\n' "$base"
    else
      printf '    = %-30s user edit — preserved\n' "$base"
    fi
    skipped=$((skipped+1)); return 0
  fi
  printf '    ↑ %-30s %s → %s (backed up)\n' "$base" "$tv" "$sv"
  if [ "$DRY" -eq 0 ]; then cp "$dst" "$dst.bak"; cp "$src" "$dst"; fi
  updated=$((updated+1)); return 0
}

# ── Hub install: strips [Preset:] gating and matches name to the directory ───
# A guide installed into a project is for that project alone, so preset gating is unnecessary, and
# leaving it in makes "Use ONLY when the active preset matches" misfire inside its own project.
put_hub() { # $1=HUB.md $2=target SKILL.md $3=skill name $4=stamp body
  local src="$1" dst="$2" name="$3" info="$4"
  if [ -f "$dst" ] && [ "$FORCE" -eq 0 ] && grep -q 'orangekit-guide: assembled' "$dst" 2>/dev/null; then
    printf '    = %-30s existing assembly — preserved\n' "$(basename "$dst")"
    skipped=$((skipped+1)); return 0
  fi
    printf '    + %-30s (gating removed · name=%s)\n' "$(basename "$dst")" "$name"
  [ "$DRY" -eq 1 ] && { installed=$((installed+1)); return 0; }
  awk -v nm="$name" -v info="$info" '
    NR==1 && $0=="---" { print; inFm=1; next }
    inFm && /^name:/    { print "name: " nm; next }
    inFm && /^description:/ {
      line=$0
      gsub(/\[Preset:[^]]*\] */, "", line)
      gsub(/ *Use ONLY when the active preset matches\./, "", line)
      print line; next }
    inFm && $0=="---"   { print; inFm=0; print info; next }
    /^<!-- orangekit-guide-baseline:/ { next }
    { print }
  ' "$src" > "$dst"
  installed=$((installed+1)); return 0
}

# ── Does the pack hold every resource it declares ─────────────────────
# "The directory exists" is not "the pack exists". A pack that froze only the L0 contract (pack.json · ledger ·
# policies) and has not written its resources yet really exists in the repo. Judging by existence makes that pack
# indistinguishable from a finished one, so ⓐ with 0 files it kills the caller mid-way with a FATAL after assembly and
# ⓑ with 1/7 it **passes as "verified: 1 resources ✓"**. Comparing the declaration (resources[].file) against the real files is the only verdict.
# Output: the list of missing filenames (space separated). Empty means complete.
pack_missing() { # $1=pack dir
  local packdir="$1" f miss=""
  [ -f "$packdir/pack.json" ] || { printf 'pack.json'; return 0; }
  # The "file" key exists only inside resources[]. "files" (a cluster) does not match, because of the boundary
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$packdir/resources/$f" ] || miss="$miss $f"
  done < <({ grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]+"' "$packdir/pack.json" 2>/dev/null || true; } \
           | sed -E 's/.*"([^"]+)"$/\1/')
  printf '%s' "${miss# }"
  return 0
}

# ── Cache slot name ───────────────────────────────────────────────────
# Web screen·backend use the axis name as-is. The app uses `app.<app>.<shape>` — if the shape cannot be read it
# emits an empty string, and the caller treats that as "no cache" (the header's "the app seam is not determined by the combination alone").
# Where the shape comes from: the --notes file → the existing guide-job.json's notes. appShell if present, else deliveryModel.
app_shape() {
  local src="" j="$PROJECT_ROOT/.orangekit/guide-job.json"
  if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then src="$NOTES"; elif [ -f "$j" ]; then src="$j"; fi
  [ -n "$src" ] || return 0
  python3 -c "
import json,re,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
if 'notes' in d and isinstance(d.get('notes'),dict): d=d['notes']
v=(d.get('appShell') or d.get('deliveryModel') or '') if isinstance(d,dict) else ''
v=str(v).strip()
# A placeholder (<only when hybrid>) or an empty value is not a shape
print(v if re.fullmatch(r'[a-z0-9-]+', v) else '')" "$src" 2>/dev/null || true
  return 0
}
cache_slot() { # $1=axis
  if [ "$1" != app ]; then printf '%s' "$1"; return 0; fi
  local sh; sh=$(app_shape)
  [ -n "$sh" ] && printf 'app.%s.%s' "$APP" "$sh"
  return 0
}

# ── Assembling one axis ───────────────────────────────────────────────
# Leaves AXIS_STATE: complete (through SKILL.md) · resources (waiting for a seam) · generate (no pack, or unfinished)
#                    · pinned (left untouched because the stack premise is pinned)
assemble() { # $1=frontend|backend|app  $2=pack name
  local axis="$1" pack="$2"
  local packdir="$G/$axis/$pack"
  local dst="$PROJECT_ROOT/.claude/skills/$axis-guide"
  local seamdir="" seamsrc="" cslot
  AXIS_STATE=generate
  cslot=$(cache_slot "$axis")
  if [ -n "$SEAM" ] && [ "$axis" != app ] && [ -d "$G/seams/$SEAM/$axis" ]; then
    # Prebuilt seams exist only for the web screen·backend axes — app seams split by shape and are reused only through the cache
    seamdir="$G/seams/$SEAM/$axis"; seamsrc="prebuilt/$SEAM"
  elif [ "$NO_CACHE" -eq 0 ] && [ -n "$cslot" ] && [ -d "$CACHE_ROOT/${FE:-none}+${BE:-none}@$PLUGIN_VER/$cslot" ]; then
    # Cache hit — this combination was built once already and passed its audit
    seamdir="$CACHE_ROOT/${FE:-none}+${BE:-none}@$PLUGIN_VER/$cslot"; seamsrc="cache/${FE:-none}+${BE:-none}@$PLUGIN_VER"
  fi

  # A missing or unfinished pack is not a failure but **the generation path**. Cutting off here throws away the other axis's assembly too
  if [ ! -d "$packdir" ]; then
    printf '  [%s-guide]  no pack (%s) — recording it as a full generation target\n' "$axis" "$pack"
    return 0
  fi
  local miss; miss=$(pack_missing "$packdir")
  if [ -n "$miss" ]; then
    printf '  [%s-guide]  pack %s unfinished — the declared resources are missing: %s\n' "$axis" "$pack" "$miss"
    printf '             Not assembling; recording it as a **full generation target** (half a pack is worse than no pack)\n'
    return 0
  fi

  # Freshness verdict — **it runs only on a first install.**
  # An existing project has already pinned its stack (the PINNED block below), and information that shakes
  # that pin is noise, not a decision. A first install is the opposite — the project has pinned nothing yet,
  # so whether the major the pack assumes still holds today is real material for a decision.
  # "First" is judged by assembly.json — SKILL.md is never created at all without a seam
  # (measured on node-api), so it would misjudge every run as a first install.
  if [ "$CHECK_FRESH" -eq 1 ] && [ ! -f "$dst/assembly.json" ]; then
    local fscript="$PLUGIN_ROOT/scripts/guide-freshness.sh" fcode=0
    if [ -f "$fscript" ]; then
      printf '  [%s-guide]  freshness verdict (%s)\n' "$axis" "$pack"
      bash "$fscript" --pack "$packdir" || fcode=$?
      if [ "$fcode" -ne 0 ]; then
        printf '    ↑ There is a major bump. **The install continues** — the declared major is what this pack\n'
        printf '      actually verified, and patterns of a different major are not old, they are wrong.\n'
        printf '      "the pack premise has changed" is a matter for a plugin update, and "partial rot" means only\n'
        printf '      those resources are up for rewrite (stack-guide-generator Step 4-1).\n'
      fi
    else
      printf '    ! freshness verdict skipped — no %s\n' "$fscript"
    fi
  fi

  # Stack premise pinning — when the pkgs major of the installed copy differs from the pack, the pack is left alone.
  # A policy that lives only in a message is not enforced (declaration site ≠ enforcement site).
  local PINNED=0
  if [ -f "$dst/SKILL.md" ] && [ "$FORCE" -eq 0 ]; then
    local have want
    have=$({ grep -m1 -oE 'pkgs=[^>]*' "$dst/SKILL.md" 2>/dev/null || true; } \
           | grep -oE '[@A-Za-z0-9._/-]+@[0-9]+' | sort -u | tr '\n' ' ')
    want=$({ grep -oE '"[@A-Za-z0-9._/-]+@[0-9.]+"' "$packdir/pack.json" 2>/dev/null | tr -d '"' || true; } \
           | grep -oE '[@A-Za-z0-9._/-]+@[0-9]+' | sort -u | tr '\n' ' ')
    if [ -n "$have" ] && [ -n "$want" ] && [ "$have" != "$want" ]; then
      PINNED=1; AXIS_STATE=pinned
      printf '  [%s-guide]  stack premise pinned — not updating the pack\n' "$axis"
      printf '    installed: %s\n    plugin:    %s\n' "$have" "$want"
      printf '    Move it across with /stack-guide-generator when you raise the dependency, or use --force to skip knowingly\n'
      return 0
    fi
  fi

  printf '  [%s-guide]  pack %s%s\n' "$axis" "$pack" "${seamsrc:+ + seam $seamsrc}"
  [ "$DRY" -eq 0 ] && mkdir -p "$dst/resources"

  local pv; pv=$(grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$packdir/PACK.md" 2>/dev/null || echo v0.0.0)
  local pkgs; pkgs=$(grep -m1 -oE 'pkgs=.*-->' "$packdir/PACK.md" 2>/dev/null | sed 's/ -->//' || true)
  [ -z "$pkgs" ] && pkgs=$(python3 -c "
import json,sys
try: print('pkgs=' + ' '.join(json.load(open('$packdir/pack.json'))['pkgs']))
except Exception: print('')" 2>/dev/null)

  local SEAMLABEL="${seamsrc:-generated}"
  local info="<!-- orangekit-guide: assembled $TODAY combo=${FE:-none}+${BE:-none} packs=$axis/$pack@${pv#v} seam=$SEAMLABEL $pkgs -->"

  for f in "$packdir/resources"/*.md; do [ -f "$f" ] && put "$f" "$dst/resources/$(basename "$f")"; done
  if [ -n "$seamdir" ]; then
    for f in "$seamdir/resources"/*.md; do [ -f "$f" ] && put "$f" "$dst/resources/$(basename "$f")"; done
    # A cache entry may hold only resources and no hub (when it was loaded before hubs existed).
    # Assuming a hub that is not there stops the assembly silently — the split is handled explicitly.
    if [ -f "$seamdir/HUB.md" ]; then
      put_hub "$seamdir/HUB.md" "$dst/SKILL.md" "$axis-guide" "$info"
      AXIS_STATE=complete
    else
      printf '    ! SKILL.md not created — the seam resources are there but there is no hub\n'
      AXIS_STATE=resources
    fi
  else
    printf '    ! SKILL.md not created — there is no seam. stack-guide-generator builds the hub and the seam\n'
    AXIS_STATE=resources
  fi

  # ── Retired resource cleanup ────────────────────────────────────────
  # put() only adds and updates, it **does not delete.** So when a resource name changes in a pack or a seam,
  # the old file stays in the consumer forever. It looks like a harmless dead file, but it is not:
  # --gate checks Navigation coverage with a `resources/*.md` glob, so running the gate in that state
  # FAILs with "uncovered resource" and **quarantines the entire healthy guide**
  # into .orangekit/failed-guides/ (measured).
  #
  # The baseline is **the previous assembly.json** — only files the installer created before are deleted. A file the
  # user added by hand is not in there and is left alone. It is the same boundary put() keeps with
  # "user edit — preserved". No hand-maintained list of retired names, so it works automatically for every
  # future rename and deletion.
  if [ "$DRY" -eq 0 ] && [ -f "$dst/assembly.json" ]; then
    local newfiles="" rf retired=0 oldf
    for rf in "$packdir/resources"/*.md; do
      if [ -f "$rf" ]; then newfiles="$newfiles$(basename "$rf")
"; fi
    done
    if [ -n "$seamdir" ]; then
      for rf in "$seamdir/resources"/*.md; do
        if [ -f "$rf" ]; then newfiles="$newfiles$(basename "$rf")
"; fi
      done
    fi
    # **Only the categories this run actually resolved are cleaned up.** An empty seamdir does not mean "the seam
    # resources are gone" but "this call could not find a seam" — the update command session-brief recommends
    # carries no --seam, and a prebuilt seam is never a cache target, so that is always the case.
    # Retiring seamFiles in that state leaves SKILL.md in place, because put_hub is never called either,
    # and it becomes **a broken hub referring to deleted files**. packFiles is safe because packdir is always resolved.
    local cands; cands=$(grep -oE '"packFiles"[^]]*\]' "$dst/assembly.json" 2>/dev/null \
                         | grep -oE '"[A-Za-z0-9._-]+\.md"' | tr -d '"')
    if [ -n "$seamdir" ]; then
      cands="$cands
$(grep -oE '"seamFiles"[^]]*\]' "$dst/assembly.json" 2>/dev/null \
  | grep -oE '"[A-Za-z0-9._-]+\.md"' | tr -d '"')"
    fi
    while IFS= read -r oldf; do
      if [ -z "$oldf" ]; then continue; fi
      if [ ! -f "$dst/resources/$oldf" ]; then continue; fi
      if printf '%s' "$newfiles" | grep -qxF "$oldf"; then continue; fi
      printf '    - %-30s retired — not in this assembly\n' "$oldf"
      rm -f "$dst/resources/$oldf"
      retired=$((retired+1))
    done < <(printf '%s\n' "$cands" | sort -u)
    if [ "$retired" -gt 0 ]; then
      printf '    %s retired resources cleaned up (against the previous assembly.json)\n' "$retired"
    fi
  fi

  # Assembly ledger — what came from where. The basis on which the gate identifies pack-owned files
  if [ "$DRY" -eq 0 ]; then
    { printf '{\n  "axis": "%s",\n  "pack": "%s/%s",\n  "packVersion": "%s",\n' "$axis" "$axis" "$pack" "${pv#v}"
      printf '  "seam": %s,\n  "assembledAt": "%s",\n' "$([ -n "$seamsrc" ] && printf '"%s"' "$seamsrc" || echo null)" "$TODAY"
      printf '  "packFiles": ['
      first=1; for f in "$packdir/resources"/*.md; do [ -f "$f" ] || continue
        [ $first -eq 0 ] && printf ', '; printf '"%s"' "$(basename "$f")"; first=0; done
      printf '],\n  "seamFiles": ['
      first=1; if [ -n "$seamdir" ]; then for f in "$seamdir/resources"/*.md; do [ -f "$f" ] || continue
        [ $first -eq 0 ] && printf ', '; printf '"%s"' "$(basename "$f")"; first=0; done; fi
      printf ']\n}\n'
    } > "$dst/assembly.json"
  fi

  # Install verification — "copied it" is not "it exists" (the install-rules.sh L79-85 convention)
  if [ "$DRY" -eq 0 ]; then
    local n; n=$({ ls -1 "$dst/resources"/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
    if [ "${n:-0}" -eq 0 ]; then
      printf '\nFATAL: %s/resources is still empty after installing.\n' "$dst" >&2; exit 1
    fi
    printf '    verified: %s resources · assembly.json ✓\n' "$n"
  fi
}

# ── Loading the cache ─────────────────────────────────────────────────
# Only a seam that has been through generation + gate + audit + repair goes in. Putting an unverified artifact into
# the cache makes every later project on that combination inherit the same defect — the cache becomes a defect amplifier.
save_seam() {
  local combo="$1" axis src n=0
  local dir="$CACHE_ROOT/$combo@$PLUGIN_VER"   # referring to an earlier variable in the same local statement is caught by set -u
  [ "$NO_CACHE" -eq 0 ] || { printf '  --no-cache given — not putting it into the cache\n'; return 0; }
  # The app value is read from --app, else from guide-job.json's app — together with the shape it becomes the cache slot name
  if [ -z "$APP" ] && [ -f "$PROJECT_ROOT/.orangekit/guide-job.json" ]; then
    APP=$({ grep -m1 -oE '"app"[[:space:]]*:[[:space:]]*"[^"]+"' "$PROJECT_ROOT/.orangekit/guide-job.json" || true; } | sed -E 's/.*"([^"]+)"$/\1/')
  fi
  local slot
  for axis in frontend backend app; do
    src="$PROJECT_ROOT/.claude/skills/$axis-guide"
    [ -d "$src/resources" ] || continue
    slot=$(cache_slot "$axis")
    if [ -z "$slot" ]; then
      printf '  [app-guide]  could not read the shape (appShell·deliveryModel), so not putting it into the cache — pass --notes and it goes in\n'
      continue
    fi
    # Pack-owned files are not put into the cache — the plugin already has them, and
    # putting them in would hide a pack update behind the cache so it never arrives
    local packfiles=""
    [ -f "$src/assembly.json" ] && packfiles=$(grep -oE '"packFiles"[^]]*\]' "$src/assembly.json" | grep -oE '"[^"]+\.md"' | tr -d '"' | tr '\n' ' ')
    [ "$DRY" -eq 0 ] && mkdir -p "$dir/$slot/resources"
    local f base
    for f in "$src/resources"/*.md; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      case " $packfiles " in *" $base "*) continue;; esac
      [ "$DRY" -eq 0 ] && cp "$f" "$dir/$slot/resources/$base"
      n=$((n+1))
    done
    [ -f "$src/SKILL.md" ] && [ "$DRY" -eq 0 ] && cp "$src/SKILL.md" "$dir/$slot/HUB.md"
  done
  if [ "$n" -eq 0 ]; then
    printf 'FATAL: no seam files to put into the cache (%s)\n' "$combo" >&2; exit 1
  fi
  printf 'seam cache loaded: %s (%s files)\n  %s\n' "$combo@$PLUGIN_VER" "$n" "$dir"
  return 0
}

# ── Gate ──────────────────────────────────────────────────────────────
# **Only an axis built as far as SKILL.md is passed.** The gate's first check is a missing SKILL.md, so passing
# the normal intermediate state that is waiting for a seam produces a wholesale FAIL. Leaving this condition to
# the caller's prose deletes freshly assembled resources across 25 combinations — which is exactly what happened.
GATE_SCRIPT="$PLUGIN_ROOT/skills/stack-guide-generator/scripts/guide-gate.sh"
run_gate() { # $1=axis  → 0 pass / 1 FAIL (quarantined)
  local axis="$1" code=0
  local dst="$PROJECT_ROOT/.claude/skills/$axis-guide"   # referring to an earlier variable in the same local statement is caught by set -u
  if [ ! -f "$GATE_SCRIPT" ]; then
    printf '  ! gate skipped — no %s (this is **unchecked**)\n' "$GATE_SCRIPT"; return 0
  fi
  printf '\n  [%s-guide]  gate\n' "$axis"
  bash "$GATE_SCRIPT" --guide "$dst" --assembly "$dst/assembly.json" || code=$?
  [ "$code" -eq 0 ] && return 0
  # It is moved out of the skills area rather than deleted. Deleting leaves nothing to diagnose, and leaving it in place
  # loads half a guide — under .orangekit/ it is neither
  local quar="$PROJECT_ROOT/.orangekit/failed-guides/$axis-guide"
  rm -rf "$quar"; mkdir -p "$(dirname "$quar")"; mv "$dst" "$quar"
  printf '\n  gate FAIL — %s-guide was taken out of the skills area (no half guide is left behind)\n' "$axis"
  printf '    quarantined: %s — recorded as a regeneration target\n' "${quar#"$PROJECT_ROOT"/}"
  return 1
}

# ── Recording what is left ────────────────────────────────────────────
# This script is the only thing that knows what is left per axis. A caller filling it in by hand gets it wrong.
# Closing it is stack-guide-generator's job (deleted on completion · status=failed on failure).
write_job() {
  local job="$PROJECT_ROOT/.orangekit/guide-job.json" need=""
  case "$FE_STATE" in
    generate)  need="$need \"frontend\"" ;;
    resources) need="$need \"seam:frontend\"" ;;
  esac
  case "$BE_STATE" in
    generate)  need="$need \"backend\"" ;;
    resources) need="$need \"seam:backend\"" ;;
  esac
  case "$APP_STATE" in
    generate)  need="$need \"app\"" ;;
    resources) need="$need \"seam:app\"" ;;
  esac
  need="${need# }"; need="${need// /, }"
  if [ -z "$need" ]; then
    if [ -f "$job" ]; then
      [ "$DRY" -eq 0 ] && rm -f "$job"
      printf '\n  nothing left — deleted the existing guide-job.json\n'
    fi
    return 0
  fi
  printf '\n  left to do: %s\n' "$need"
  [ "$DRY" -eq 1 ] && { printf '    (--dry-run — not writing .orangekit/guide-job.json)\n'; return 0; }
  # Only an assembled axis leaves a pack name — for a generation-target axis, having no pack is the information
  local fpack=null bpack=null apack=null
  case "$FE_STATE" in complete|resources|pinned) fpack="\"frontend/$FE\"" ;; esac
  case "$BE_STATE" in complete|resources|pinned) bpack="\"backend/$BE\"" ;; esac
  case "$APP_STATE" in complete|resources|pinned) apack="\"app/$APP\"" ;; esac

  # Only a caller that reads the preset knows the notes. On a re-call with no --notes, the existing value is carried over
  # — it has to be read before the file is opened (the redirect below empties it first)
  local notes=null
  if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then
    notes=$(cat "$NOTES")                     # $() strips the trailing newline
  elif [ -f "$job" ]; then
    notes=$(python3 -c "
import json
try: print(json.dumps(json.load(open('$job')).get('notes')))
except Exception: print('null')" 2>/dev/null || printf 'null')
  fi

  mkdir -p "$PROJECT_ROOT/.orangekit"
  { printf '{\n  "status": "pending",\n  "combo": "%s+%s",\n' "${FE:-none}" "${BE:-none}"
    printf '  "need": [%s],\n' "$need"
    printf '  "app": "%s",\n' "${APP:-none}"
    printf '  "state": { "frontend": "%s", "backend": "%s", "app": "%s" },\n' "$FE_STATE" "$BE_STATE" "$APP_STATE"
    printf '  "packs": { "frontend": %s, "backend": %s, "app": %s },\n' "$fpack" "$bpack" "$apack"
    printf '  "notes": %s,\n' "$notes"
    # Audit round counter — stack-guide-generator increments it before launching audits and stops at 2.
    # Why it lives in a file: so the counter does not reset to 0 when a cut-off session is picked up (prevents endless re-audits)
    printf '  "auditRound": 0,\n'
    printf '  "createdAt": "%s"\n}\n' "$TODAY"
  } > "$job"
  printf '    recorded: %s — the session brief of the next session reports it\n' "${job#"$PROJECT_ROOT"/}"
  return 0
}

# ── Self-test ─────────────────────────────────────────────────────────
# **If you built a guard, prove it blocks.** Two synthetic packs (complete and unfinished) are created to see
# whether "do not assemble when what was declared is missing" is alive. Alive ≠ working.
run_self_test() {
  local t proj out code=0 pass=0 fail=0
  t=$(mktemp -d) || { printf 'failed to create a temporary directory\n' >&2; exit 2; }
  trap 'rm -rf "$t"' EXIT
  proj="$t/proj"

  local p
  for p in full half; do
    mkdir -p "$t/guides/frontend/$p/resources"
    printf '<!-- orangekit-pack: frontend/%s v1.0.0 verified 2026-01-01 zod@4 -->\n\n# %s axis pack — hub fragment\n' "$p" "$p" \
      > "$t/guides/frontend/$p/PACK.md"
    printf '{\n  "axis": "frontend",\n  "name": "%s",\n  "packVersion": "1.0.0",\n  "pkgs": ["zod@4"],\n  "resources": [\n    { "file": "a.md", "nav": "A" },\n    { "file": "b.md", "nav": "B" }\n  ]\n}\n' "$p" \
      > "$t/guides/frontend/$p/pack.json"
    printf '<!-- orangekit-pack: frontend/%s v1.0.0 -->\n\n# A\n' "$p" > "$t/guides/frontend/$p/resources/a.md"
  done
  # Only full carries b.md as declared. half declares it without carrying it (= an unfinished pack with only L0 frozen)
  printf '<!-- orangekit-pack: frontend/full v1.0.0 -->\n\n# B\n' > "$t/guides/frontend/full/resources/b.md"

  _st() { # $1=pack $2=expected state $3=label [rest=extra arguments]
    local pk="$1" want="$2" label="$3" got; shift 3
    rm -rf "$proj"; mkdir -p "$proj"
    out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" \
          bash "$0" --frontend "$pk" --no-freshness --no-cache "$@" 2>&1) || true
    got=$(printf '%s' "$out" | sed -nE 's/.*state: frontend=([a-z]+).*/\1/p' | head -1)
    if [ "$got" = "$want" ]; then
      printf '  ✓ %s → %s\n' "$label" "$got"; pass=$((pass+1))
    else
      printf '  ✗ %s → %s (expected %s)\n' "$label" "${got:-none}" "$want"; fail=$((fail+1))
    fi
  }

  printf '\ninstall-guide --self-test\n\n'
  _st full "resources" "a complete pack is assembled (resources, since there is no seam)"
  _st half "generate"  "an unfinished pack is not assembled (declared but missing)"

  # An unfinished pack must install **nothing** — leaving half behind is not a block
  if [ -d "$proj/.claude/skills/frontend-guide" ]; then
    printf '  ✗ unfinished pack, yet a skill directory appeared\n'; fail=$((fail+1))
  else
    printf '  ✓ an unfinished pack creates no skill directory\n'; pass=$((pass+1))
  fi
  # And it has to be recorded as work left — if it vanishes silently the user never finds out
  # The need array is read directly — searching for "frontend" alone also hits the state key and misses a mutation
  if grep -q '"need": \["frontend"\]' "$proj/.orangekit/guide-job.json" 2>/dev/null; then
    printf '  ✓ an unfinished pack is recorded as a generation target\n'; pass=$((pass+1))
  else
    printf '  ✗ guide-job.json has no generation target\n'; fail=$((fail+1))
  fi

  # ── Undecided axis · app axis ──────────────────────────────────────
  # If undecided is not skipped like none, "not chosen" becomes a generation target and a guessed guide comes out.
  # The app axis has no pack, so "app" must be in need — drop it and the app code never gets a guide
  _st undecided "skip" "not chosen (undecided) is not a generation target" --app react-native
  if grep -q '"need": \["app"\]' "$proj/.orangekit/guide-job.json" 2>/dev/null; then
    printf '  ✓ the app axis is recorded as a generation target (need = ["app"])\n'; pass=$((pass+1))
  else
    printf '  ✗ the app axis is missing from guide-job.json need\n'; fail=$((fail+1))
  fi

  # ── App axis pack · app seam cache ──────────────────────────────────
  # An app pack must be assembled by the same path as the web screen axis — if it is not, there was no point building the pack.
  # The cache **must split by shape**: even on the same combination, the seam for a shell (rn-webview) and for the app
  # itself (cross-platform) differ. If a project of a different shape receives the cache, wrong screen·bridge guidance gets installed.
  mkdir -p "$t/guides/app/fxapp/resources"
  printf '<!-- orangekit-pack: app/fxapp v1.0.0 verified 2026-01-01 zod@4 -->\n\n# fxapp axis pack\n' > "$t/guides/app/fxapp/PACK.md"
  printf '{\n  "axis": "app",\n  "name": "fxapp",\n  "pkgs": ["zod@4"],\n  "resources": [ { "file": "nav.md", "nav": "Screens" } ]\n}\n' > "$t/guides/app/fxapp/pack.json"
  printf '<!-- orangekit-pack: app/fxapp v1.0.0 -->\n\n# Screens\n' > "$t/guides/app/fxapp/resources/nav.md"
  local cache="$t/cache" ast
  _app() { # $1=notes file|"" $2..=extra args → the app state on stdout
    local nf="$1"; shift
    rm -rf "$proj"; mkdir -p "$proj"
    out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" ORANGEKIT_SEAM_CACHE="$cache" \
          bash "$0" --app fxapp --no-freshness ${nf:+--notes "$nf"} "$@" 2>&1) || true
    printf '%s' "$out" | sed -nE 's/.*state: .*app=([a-z]+).*/\1/p' | head -1
  }
  # Turn the verdict into a value so a failed `[` under set -e does not cut the script off and vanish without a "✗"
  _is() { if "$@" >/dev/null 2>&1; then printf 0; else printf 1; fi; }
  _chk() { # $1=condition (0/1) $2=label
    if [ "$1" -eq 0 ]; then printf '  ✓ %s\n' "$2"; pass=$((pass+1)); else printf '  ✗ %s\n' "$2"; fail=$((fail+1)); fi
  }
  printf '{ "deliveryModel": "hybrid", "appShell": "rn-native-screens" }\n' > "$t/notes-ns.json"
  printf '{ "deliveryModel": "cross-platform", "appShell": "" }\n' > "$t/notes-cp.json"

  ast=$(_app "$t/notes-ns.json")
  _chk "$(_is [ "$ast" = resources ])" "a complete app pack is assembled (no seam, so resources) → ${ast:-none}"
  _chk "$(_is grep -q '"need": \["seam:app"\]' "$proj/.orangekit/guide-job.json" 2>/dev/null)" "waiting for the app seam is recorded as need = [\"seam:app\"]"

  # Place a hub·seam as if generation had finished and load them into the cache → the next project of the same shape is complete
  mkdir -p "$proj/.claude/skills/app-guide/resources"
  printf -- '---\nname: app-guide\ndescription: x\n---\n# Hub\n' > "$proj/.claude/skills/app-guide/SKILL.md"
  printf '# App seam\n' > "$proj/.claude/skills/app-guide/resources/api-client.md"
  CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" ORANGEKIT_SEAM_CACHE="$cache" \
    bash "$0" --save-seam none+none >/dev/null 2>&1 || true
  _chk "$(_is [ -f "$cache/none+none@0.0.0/app.fxapp.rn-native-screens/resources/api-client.md" ])" "the app seam is loaded into a per-shape slot (app.<app>.<shape>) (app·shape read from guide-job.json)"
  _chk "$(_is [ ! -f "$cache/none+none@0.0.0/app.fxapp.rn-native-screens/resources/nav.md" ])" "pack-owned files are not put into the cache"

  ast=$(_app "$t/notes-ns.json")
  _chk "$(_is [ "$ast" = complete ])" "the next project of the same shape is completed from the cache → ${ast:-none}"
  ast=$(_app "$t/notes-cp.json")
  _chk "$(_is [ "$ast" = resources ])" "a different shape does not receive the cache (cross-platform ≠ rn-native-screens) → ${ast:-none}"
  ast=$(_app "")
  _chk "$(_is [ "$ast" = resources ])" "an unknown shape does not receive the cache (\"cannot tell\" is not folded into some shape) → ${ast:-none}"

  # ── Gate FAIL → quarantine ──────────────────────────────────────────
  # **This branch moves the user's installation.** Without a fixture for the code that moves it,
  # "alive" cannot be told apart from "working". A seam that makes the gate fail is built to see
  # ⓐ whether it left the skills area ⓑ whether the quarantined copy remains ⓒ whether it was recorded as a generation target.
  if [ -f "$PLUGIN_ROOT/skills/stack-guide-generator/scripts/guide-gate.sh" ]; then
    mkdir -p "$t/skills/stack-guide-generator/scripts" "$t/guides/seams/full+none/frontend/resources"
    cp "$PLUGIN_ROOT/skills/stack-guide-generator/scripts/guide-gate.sh" \
       "$t/skills/stack-guide-generator/scripts/guide-gate.sh"
    # A hub with neither the required sections nor frontmatter — the gate's first check catches this
    printf '<!-- orangekit-seam: full+none v1.0.0 -->\n\n# Half hub\n' \
      > "$t/guides/seams/full+none/frontend/HUB.md"
    printf '<!-- orangekit-seam: full+none v1.0.0 -->\n\n# Seam resource\n' \
      > "$t/guides/seams/full+none/frontend/resources/seam.md"

    _st full "generate" "a gate FAIL turns it back into a generation target" --seam full+none --gate
    if [ -d "$proj/.orangekit/failed-guides/frontend-guide" ]; then
      printf '  ✓ the quarantined copy stays in .orangekit/failed-guides/ (deleting it leaves nothing to diagnose)\n'; pass=$((pass+1))
    else
      printf '  ✗ no quarantined copy — there is no way to tell what was left after the gate FAIL\n'; fail=$((fail+1))
    fi
    if [ -d "$proj/.claude/skills/frontend-guide" ]; then
      printf '  ✗ gate FAIL, yet it is still in the skills area (half a guide gets loaded)\n'; fail=$((fail+1))
    else
      printf '  ✓ a gate FAIL takes it out of the skills area\n'; pass=$((pass+1))
    fi
  else
    printf '  – gate quarantine fixture skipped — no guide-gate.sh (this is **unchecked**)\n'
  fi

  printf '\n  passed %d · failed %d\n\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
}

if [ "$SELFTEST" -eq 1 ]; then run_self_test; fi
if [ -n "$SAVE_SEAM" ]; then save_seam "$SAVE_SEAM"; exit 0; fi

printf 'Guide assembly\n  plugin:  %s\n  project: %s\n\n' "$G" "$PROJECT_ROOT/.claude/skills"
# undecided (not chosen) is the same as none — no guide is built by guesswork for an undecided axis
_axis_on() { [ -n "$1" ] && [ "$1" != none ] && [ "$1" != undecided ]; }
if _axis_on "$FE"; then assemble frontend "$FE"; FE_STATE="$AXIS_STATE"; fi
if _axis_on "$BE"; then assemble backend  "$BE"; BE_STATE="$AXIS_STATE"; fi
if _axis_on "$APP"; then assemble app "$APP"; APP_STATE="$AXIS_STATE"; fi
printf '\n  new %d · updated %d · kept %d\n' "$installed" "$updated" "$skipped"

gate_failed=0
if [ "$GATE" -eq 1 ] && [ "$DRY" -eq 1 ]; then
  printf '  (--dry-run — not running the gate)\n'
elif [ "$GATE" -eq 1 ]; then
  if [ "$FE_STATE" = complete ]; then
    if ! run_gate frontend; then FE_STATE=generate; gate_failed=1; fi
  fi
  if [ "$BE_STATE" = complete ]; then
    if ! run_gate backend;  then BE_STATE=generate; gate_failed=1; fi
  fi
  if [ "$APP_STATE" = complete ]; then
    if ! run_gate app;      then APP_STATE=generate; gate_failed=1; fi
  fi
fi

printf '\n  state: frontend=%s · backend=%s · app=%s\n' "$FE_STATE" "$BE_STATE" "$APP_STATE"
printf '    complete=skill finished · resources=waiting for a seam · generate=needs generating · pinned=premise pinned · skip=not applicable\n'
write_job
if [ "$gate_failed" -eq 1 ]; then exit 1; fi
exit 0
