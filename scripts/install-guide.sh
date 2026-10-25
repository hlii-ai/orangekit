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
#                    [--gate] [--notes <file>] [--dry-run] [--force] [--no-freshness] [--rules-only]
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
#   --rules-only                installs only the stack rule file (pack RULES.md → .claude/rules/stack-<axis>-<pack>.md).
#                               No guide skill assembly, no record of work left, no gate — this is init's default.
#                               The detailed guide is opt-in (guide A/B: no score difference, and an example overrode a convention)
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

STALE_TSV="$(mktemp)"; VGAP_TSV="$(mktemp)"; trap 'rm -f "$STALE_TSV" "$VGAP_TSV"' EXIT
FE=""; BE=""; SEAM=""; DRY=0; FORCE=0; SAVE_SEAM=""; NO_CACHE=0; CHECK_FRESH=1
GATE=0; NOTES=""; AXIS_STATE=""; FE_STATE=skip; BE_STATE=skip; SELFTEST=0
APP=""; APP_STATE=skip; RULES_ONLY=0
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
    --rules-only) RULES_ONLY=1; shift ;;
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
cache_slot() { # $1=axis [$2=pack directory — if it has variants, the chosen values go into the slot name]
  local base=""
  if [ "$1" != app ]; then base="$1"
  else
    local sh; sh=$(app_shape)
    [ -n "$sh" ] && base="app.$APP.$sh"
  fi
  [ -n "$base" ] || return 0
  # A cached seam (hub included) was written for the variants chosen at the time — a project with a different auth
  # method receiving the same slot gets an assembly whose hub points at auth files that are not there (measured in review).
  # The variant values go into the slot name
  local tag=""
  if [ -n "${2:-}" ] && grep -q '"variants"' "$2/pack.json" 2>/dev/null; then
    local auth shell; auth=$(note_val authKind); shell=$(note_val appShell)
    tag=$(python3 - "$2/pack.json" "$auth" "$shell" 2>/dev/null <<'PYTAG' || true
import json, sys
vs = json.load(open(sys.argv[1])).get('variants') or {}
vals = {'auth': sys.argv[2], 'shell': sys.argv[3]}
print('.'.join(f"{d}-{vals.get(d) or 'none'}" for d in sorted(vs)))
PYTAG
)
  fi
  printf '%s' "$base${tag:+.$tag}"
  return 0
}

# ── Pack variant resources · pack hub ──────────────────────────────────
# Most of what a seam used to be — a function of the combination — has moved into the packs through the standard wire
# contract. The remaining differences are two choices **within an axis** — the auth method (`authKind`) and the app shell
# shape (`appShell`). So a pack carries the files for each choice under `variants/<dimension>/<directory>/`, and pack.json
# `variants` maps a notes value → a directory:
#   "variants": { "auth": { "self-issued": "self-issued", "oidc": "oidc" },
#                 "shell": { "rn-native-screens": "rn", "rn-webview": "rn", "": null } }
# null means "that value has no files"; a value missing from the table is "unresolved" — unresolved is never folded into
# some arbitrary file but left as a generation target (that variant file + the hub). Dimension → notes key: auth=authKind, shell=appShell.
note_val() { # $1=notes key → value (empty string if absent)
  # Source: --notes → guide-job.json → the .orangekit/preset-notes.json init left behind. The job file is deleted when the job
  # closes, so on an update run (no --notes) without the third source the variant reads as "unresolved" and the installed
  # auth files get retired (measured in review)
  local src="" j="$PROJECT_ROOT/.orangekit/guide-job.json" pn="$PROJECT_ROOT/.orangekit/preset-notes.json"
  if [ -n "$NOTES" ] && [ -f "$NOTES" ]; then src="$NOTES"; elif [ -f "$j" ]; then src="$j"; elif [ -f "$pn" ]; then src="$pn"; fi
  [ -n "$src" ] || return 0
  python3 - "$src" "$1" 2>/dev/null <<'PYNOTE' || true
import json, re, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
if isinstance(d.get('notes'), dict): d = d['notes']
v = str(d.get(sys.argv[2]) or '').strip() if isinstance(d, dict) else ''
print(v if re.fullmatch(r'[a-z0-9-]*', v) else '')
PYNOTE
  return 0
}
variant_select() { # $1=pack directory → "F\t<file>" (chosen variant file) · "U\t<dimension>\t<value>" (unresolved)
  local packdir="$1"
  grep -q '"variants"' "$packdir/pack.json" 2>/dev/null || return 0
  local auth shell; auth=$(note_val authKind); shell=$(note_val appShell)
  python3 - "$packdir" "$auth" "$shell" 2>/dev/null <<'PYVAR' || true
import json, os, sys
packdir, auth, shell = sys.argv[1], sys.argv[2], sys.argv[3]
pj = json.load(open(os.path.join(packdir, 'pack.json')))
vs = pj.get('variants') or {}
chosen = {'auth': auth, 'shell': shell}
# If the shell is unresolved, the dimensions the shell owns are unresolved too — web inside a hybrid shell receives its
# token from native, so laying down the web login variant would be wrong guidance (pack.json shellOverrides)
shell_unres = 'shell' in vs and shell not in vs['shell']
over = set(pj.get('shellOverrides') or []) if shell_unres else set()
for dim, table in vs.items():
    val = chosen.get(dim, '')
    if val not in table or dim in over:
        print(f"U\t{dim}\t{val or '(none)'}"); continue
    d = table[val]
    if d is None: continue
    vd = os.path.join(packdir, 'variants', dim, d)
    for f in sorted(os.listdir(vd)) if os.path.isdir(vd) else []:
        if f.endswith('.md'): print(f"F\t{os.path.join(vd, f)}")
PYVAR
  return 0
}

# ── Wire contract pinning ─────────────────────────────────────────────
# A pack names a standard contract (guides/contracts/) through pack.json `wireContract`. A generated or cached seam was
# written to **the pack's contract at install time** and is owned by the project, so this script does not update it —
# which means updating only a pack whose contract changed leaves one guide teaching the new code (`UNAUTHENTICATED`) in the pack
# and the old code (`UNAUTHORIZED`) in the seam. An installed copy's contract is assembly.json `wireContract`; with none, it is
# an installed copy from before the standard contract (legacy).
#
# The verdict is made over **the whole combination** — pinning one axis while updating the other makes the two guides diverge.
# An installed copy with no seam (no SKILL.md) has nothing to diverge from, so it is updated. A prebuilt seam is owned by the
# plugin, so it is updated only when this run resolves that seam as well (--seam).
pack_contract() { # $1=pack directory
  local v; v=$({ grep -m1 -oE '"wireContract"[[:space:]]*:[[:space:]]*"[^"]*"' "$1/pack.json" 2>/dev/null || true; } \
                | sed -E 's/.*"([^"]*)"$/\1/')
  printf '%s' "${v:-legacy}"
}
installed_contract() { # $1=install directory
  local v; v=$({ grep -m1 -oE '"wireContract"[[:space:]]*:[[:space:]]*"[^"]*"' "$1/assembly.json" 2>/dev/null || true; } \
                | sed -E 's/.*"([^"]*)"$/\1/')
  printf '%s' "${v:-legacy}"
}
# **legacy is not a divergence by itself.** Most installed copies from before the standard contract are of packs whose wire
# values did not change. Only a pack whose values really changed declares pack.json `wireContractSince` (the packVersion
# that carried the change), and a legacy installed copy counts as diverged only when it is older than that edition. legacy → none
# is the same — a pack with no HTTP boundary does not declare it.
vlt() { # $1 < $2 (dot-separated versions)
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}
contract_drift() { # $1=axis $2=pack → prints "installed → pack" when they diverge
  local dst="$PROJECT_ROOT/.claude/skills/$1-guide" packdir="$G/$1/$2" have want since iv cslot
  [ -f "$dst/assembly.json" ] && [ -f "$dst/SKILL.md" ] && [ -f "$packdir/pack.json" ] || return 0
  have=$(installed_contract "$dst"); want=$(pack_contract "$packdir")
  [ "$have" = "$want" ] && return 0
  if [ "$have" = legacy ]; then
    since=$({ grep -m1 -oE '"wireContractSince"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$packdir/pack.json" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -n "$since" ] || return 0
    iv=$({ grep -m1 -oE '"packVersion"[[:space:]]*:[[:space:]]*"[0-9.]+"' "$dst/assembly.json" 2>/dev/null || true; } | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -n "$iv" ] && ! vlt "$iv" "$since" && return 0
  fi
  if grep -q 'seam=prebuilt/' "$dst/SKILL.md" 2>/dev/null && [ -n "$SEAM" ] && [ -d "$G/seams/$SEAM/$1" ]; then
    return 0   # the same run updates the plugin-owned seam along with it
  fi
  # If this run resolves the cache of the current edition, that seam was made to the current contract — it is updated along with it
  cslot=$(cache_slot "$1")
  if [ "$NO_CACHE" -eq 0 ] && [ -n "$cslot" ] && [ -d "$CACHE_ROOT/${FE:-none}+${BE:-none}@$PLUGIN_VER/$cslot" ]; then
    return 0
  fi
  printf '%s → %s' "$have" "$want"
  return 0
}

# ── Stack rule file ───────────────────────────────────────────────────
# What must be followed is injected as a `paths:` rule, not as a skill (where the model decides whether to read it).
# The name takes a `stack-` prefix so it never collides with `rules/`. It is installed **before** the pin check and
# assembly — an axis whose stack premise is pinned still has to receive the must-follow rules
put_rules_card() { # $1=axis $2=pack $3=pack directory
  [ -f "$3/RULES.md" ] || return 0
  printf '  [%s-guide]  core card → .claude/rules/stack-%s-%s.md\n' "$1" "$1" "$2"
  [ "$DRY" -eq 0 ] && mkdir -p "$PROJECT_ROOT/.claude/rules"
  put "$3/RULES.md" "$PROJECT_ROOT/.claude/rules/stack-$1-$2.md"
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
  cslot=$(cache_slot "$axis" "$packdir")
  # If the notes a prebuilt seam assumed (auth method and the like) differ from this project, it is not used — using it
  # makes the two guides teach opposites, the frontend self-issued and the backend OIDC (measured in review). Fall through to generation
  local seamconflict=""
  if [ -n "$SEAM" ] && [ -f "$G/seams/$SEAM/seam.json" ]; then
    local sak pak; pak=$(note_val authKind)
    sak=$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])).get('notes') or {}).get('authKind',''))" "$G/seams/$SEAM/seam.json" 2>/dev/null || true)
    if [ -n "$sak" ] && [ -n "$pak" ] && [ "$sak" != "$pak" ]; then seamconflict="authKind $sak ≠ project $pak"; fi
  fi
  if [ -n "$seamconflict" ] && [ -d "$G/seams/$SEAM/$axis" ]; then
    printf '  [%s-guide]  not using prebuilt seam %s — %s\n' "$axis" "$SEAM" "$seamconflict"
  fi
  if [ -z "$seamconflict" ] && [ -n "$SEAM" ] && [ "$axis" != app ] && [ -d "$G/seams/$SEAM/$axis" ]; then
    # Prebuilt seams exist only for the web screen·backend axes — app seams split by shape and are reused only through the cache
    seamdir="$G/seams/$SEAM/$axis"; seamsrc="prebuilt/$SEAM"
  elif [ "$NO_CACHE" -eq 0 ] && [ -n "$cslot" ] && [ -d "$CACHE_ROOT/${FE:-none}+${BE:-none}@$PLUGIN_VER/$cslot" ]; then
    # Cache hit — this combination was built once already and passed its audit
    seamdir="$CACHE_ROOT/${FE:-none}+${BE:-none}@$PLUGIN_VER/$cslot"; seamsrc="cache/${FE:-none}+${BE:-none}@$PLUGIN_VER"
  fi

  # A missing or unfinished pack is not a failure but **the generation path**. Cutting off here throws away the other axis's assembly too
  if [ ! -d "$packdir" ]; then
    if [ "$RULES_ONLY" -eq 1 ]; then
      printf '  [%s-guide]  no pack (%s) — no stack rule file. Only the universal rules (security.md) apply\n' "$axis" "$pack"
    else
      printf '  [%s-guide]  no pack (%s) — recording it as a full generation target\n' "$axis" "$pack"
    fi
    return 0
  fi
  local miss; miss=$(pack_missing "$packdir")
  if [ -n "$miss" ]; then
    printf '  [%s-guide]  pack %s unfinished — the declared resources are missing: %s\n' "$axis" "$pack" "$miss"
    printf '             Not assembling; recording it as a **full generation target** (half a pack is worse than no pack)\n'
    return 0
  fi

  put_rules_card "$axis" "$pack" "$packdir"
  if [ "$RULES_ONLY" -eq 1 ]; then AXIS_STATE=rules; return 0; fi

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
      local fout; fout=$(bash "$fscript" --pack "$packdir" --json 2>&1) || fcode=$?
      printf '%s\n' "$fout" | sed '/── TSV/,$d'
      if [ "$fcode" -eq 1 ]; then
        # Keep the major-bump rows — they are what init asks "apply now / pin to the verified major" on,
        # and the input to stack-guide-generator's refresh job. The verdict is made here and not redone in prose
        printf '%s\n' "$fout" | awk -F'\t' -v ax="$axis" '$4=="major_up" {print ax "\t" $1 "\t" $2 "\t" $3 "\t" $5 "\t" $6}' >> "$STALE_TSV"
        printf '    ↑ There is a major bump. **The install continues with the declared (verified) major.**\n'
        printf '      init asks the user whether to apply it — recorded in what is left as refresh:%s\n' "$axis"
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
           | { grep -oE '[@A-Za-z0-9._/-]+@[0-9]+' || true; } | sort -u | tr '\n' ' ')
    # ↑ In a hub with no pkgs= stamp (a SKILL.md the generator wrote, and the like) this grep exits 1 on no match, and
    #   pipefail + set -e **ends the installer without a message** (the contract-pinning fixture exposed it)
    # Read only from the pkgs array — scanning the whole file reads `"wireContract": "http-standard@1"` as a package, so it
    # never matches have (the hub stamp) and every update run was "stack premise pinned" and pack fixes never arrived (measured in review)
    want=$({ awk '/"pkgs"[[:space:]]*:/{f=1} f{print} f&&/\]/{exit}' "$packdir/pack.json" 2>/dev/null | grep -oE '"[@A-Za-z0-9._/-]+@[0-9.]+"' | tr -d '"' || true; } \
           | { grep -oE '[@A-Za-z0-9._/-]+@[0-9]+' || true; } | sort -u | tr '\n' ' ')
    if [ -n "$have" ] && [ -n "$want" ] && [ "$have" != "$want" ]; then
      PINNED=1; AXIS_STATE=pinned
      printf '  [%s-guide]  stack premise pinned — not updating the pack\n' "$axis"
      printf '    installed: %s\n    plugin:    %s\n' "$have" "$want"
      printf '    Move it across with /stack-guide-generator when you raise the dependency, or use --force to skip knowingly\n'
      return 0
    fi
  fi

  # Wire contract pinning — main made the verdict over the whole combination. Only an axis with an installed copy stops
  if [ -n "$CONTRACT_HOLD" ] && [ -f "$dst/assembly.json" ] && [ -f "$dst/SKILL.md" ]; then
    AXIS_STATE=pinned
    printf '  [%s-guide]  wire contract pinned — not updating the pack (%s)\n' "$axis" "${CONTRACT_HOLD# }"
    printf '    The installed seam was written to the old contract. Updating only the pack makes one guide teach two contracts.\n'
    printf '    For a prebuilt seam, pass --seam <combination> as well and it is updated along with it. For a generated seam,\n'
    printf '    ask /stack-guide-generator to "regenerate the seam" and move it together with the pack (--force updates only the pack and\n'
    printf '    mixes it with the old seam — use it only when you plan to fix the seam by hand)\n'
    return 0
  fi

  printf '  [%s-guide]  pack %s%s\n' "$axis" "$pack" "${seamsrc:+ + seam $seamsrc}"
  [ "$DRY" -eq 0 ] && mkdir -p "$dst/resources"

  local pv; pv=$(grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$packdir/PACK.md" 2>/dev/null || echo v0.0.0)
  local pkgs; pkgs=$(grep -m1 -oE 'pkgs=.*-->' "$packdir/PACK.md" 2>/dev/null | sed 's/ -->//' || true)
  [ -z "$pkgs" ] && pkgs=$(python3 -c "
import json,sys
try: print('pkgs=' + ' '.join(json.load(open('$packdir/pack.json'))['pkgs']))
except Exception: print('')" 2>/dev/null)

  # Preserve an existing generated seam — when this run resolved no seam but the previous assembly.json lists seam files
  # (an update run on an installed copy completed by a generated or cached seam), those files belong to the project. Even
  # if the pack now carries a file of the same name it does not overwrite it, nor swap in the pack hub — overwriting pushes
  # the project's seam out to .bak and leaves the hub pointing at the old seam (measured in review)
  local OLDSEAM=""
  if [ -z "$seamdir" ] && [ -f "$dst/assembly.json" ]; then
    OLDSEAM=$({ grep -oE '"seamFiles"[^]]*\]' "$dst/assembly.json" 2>/dev/null || true; } \
              | { grep -oE '"[A-Za-z0-9._-]+\.md"' || true; } | tr -d '"')
  fi

  # Variant selection — a prebuilt seam owns auth and shell too, so nothing is chosen. A cached seam carries the variant
  # values in its slot name (cache_slot), so the variant files for those values are laid down with it — variant files are pack-owned and not in the cache
  local vsel="" vfiles="" vunres="" usehub=0
  case "$seamsrc" in prebuilt/*) ;; *)
    vsel=$(variant_select "$packdir")
    vfiles=$(printf '%s\n' "$vsel" | awk -F'\t' '$1=="F"{print $2}')
    vunres=$(printf '%s\n' "$vsel" | awk -F'\t' '$1=="U"{print $2"="$3}' | tr '\n' ' ')
    vunres="${vunres% }" ;;
  esac
  if [ -z "$seamdir" ] && [ -z "$OLDSEAM" ]; then
    # Pack hub: only when every variant is resolved and the other axes use the same wire contract — the hub was written for the contract
    if [ -f "$packdir/HUB.md" ] && [ -z "$vunres" ] && [ "$HUB_OK" -eq 1 ]; then usehub=1; fi
    if [ -n "$vunres" ]; then
      printf '%s\n' "$vunres" | tr ' ' '\n' | awk -v ax="$axis" -F= 'NF==2{print ax "\t" $1 "\t" $2}' >> "$VGAP_TSV"
    fi
  fi

  local SEAMLABEL="${seamsrc:-generated}"
  [ "$usehub" -eq 1 ] && SEAMLABEL="pack"
  local info="<!-- orangekit-guide: assembled $TODAY combo=${FE:-none}+${BE:-none} packs=$axis/$pack@${pv#v} seam=$SEAMLABEL $pkgs -->"

  # When the seam has a resource of the same name, the seam wins — laying down both repeats update·.bak on every run
  local PACKLIST=""
  for f in "$packdir/resources"/*.md; do
    [ -f "$f" ] || continue
    if [ -n "$seamdir" ] && [ -f "$seamdir/resources/$(basename "$f")" ]; then continue; fi
    if printf '%s\n' "$OLDSEAM" | grep -qxF "$(basename "$f")"; then
      printf '    = %-30s project seam — preserved (not laying down the pack file of the same name)\n' "$(basename "$f")"
      continue
    fi
    put "$f" "$dst/resources/$(basename "$f")"
    PACKLIST="$PACKLIST$(basename "$f")
"
  done
  if [ -n "$vfiles" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      if printf '%s\n' "$OLDSEAM" | grep -qxF "$(basename "$f")"; then
        printf '    = %-30s project seam — preserved (not laying down the pack variant)\n' "$(basename "$f")"
        continue
      fi
      put "$f" "$dst/resources/$(basename "$f")"
      PACKLIST="$PACKLIST$(basename "$f")
"
    done <<< "$vfiles"
  fi
  if [ "$usehub" -eq 1 ]; then
    put_hub "$packdir/HUB.md" "$dst/SKILL.md" "$axis-guide" "$info"
    AXIS_STATE=complete
  elif [ -z "$seamdir" ] && [ -n "$OLDSEAM" ] && [ -f "$dst/SKILL.md" ]; then
    printf '    = keeping the existing seam·hub — project-owned (to switch to the pack hub, delete the seam and reassemble)\n'
    AXIS_STATE=complete
  elif [ -n "$seamdir" ]; then
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
    if [ -n "$vunres" ]; then
      printf '    ! SKILL.md not created — a variant the pack does not have (%s). stack-guide-generator builds only that file and the hub\n' "$vunres"
    elif [ -f "$packdir/HUB.md" ] && [ "$HUB_OK" -eq 0 ]; then
      printf '    ! SKILL.md not created — another axis uses a different wire contract, so the pack hub cannot be used. Building a seam\n'
    else
      printf '    ! SKILL.md not created — there is no seam. stack-guide-generator builds the hub and the seam\n'
    fi
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
  # No retirement while a variant is unresolved — an update run that could not read the notes would delete the installed
  # auth files and leave only the hub, a broken guide (measured in review). Unresolved means "unknown", not "gone"
  if [ "$DRY" -eq 0 ] && [ -f "$dst/assembly.json" ] && [ -z "$vunres" ]; then
    local newfiles="$PACKLIST" rf retired=0 oldf
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
    # An empty array (`"seamFiles": []`) means no grep match → pipefail + set -e ends the installer silently.
    # That is exactly the run in which a project first installed without a seam receives its first seam
    local cands; cands=$({ grep -oE '"packFiles"[^]]*\]' "$dst/assembly.json" 2>/dev/null || true; } \
                         | { grep -oE '"[A-Za-z0-9._-]+\.md"' || true; } | tr -d '"')
    if [ -n "$seamdir" ]; then
      cands="$cands
$({ grep -oE '"seamFiles"[^]]*\]' "$dst/assembly.json" 2>/dev/null || true; } \
  | { grep -oE '"[A-Za-z0-9._-]+\.md"' || true; } | tr -d '"')"
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
      printf '  "wireContract": "%s",\n' "$(pack_contract "$packdir")"
      printf '  "seam": %s,\n  "assembledAt": "%s",\n' "$([ -n "$seamsrc" ] && printf '"%s"' "$seamsrc" || echo null)" "$TODAY"
      printf '  "packFiles": ['
      first=1; while IFS= read -r f; do [ -n "$f" ] || continue
        [ $first -eq 0 ] && printf ', '; printf '"%s"' "$f"; first=0; done <<< "$PACKLIST"
      printf '],\n  "seamFiles": ['
      first=1; if [ -n "$seamdir" ]; then for f in "$seamdir/resources"/*.md; do [ -f "$f" ] || continue
        [ $first -eq 0 ] && printf ', '; printf '"%s"' "$(basename "$f")"; first=0; done
      else while IFS= read -r f; do [ -n "$f" ] && [ -f "$dst/resources/$f" ] || continue
        [ $first -eq 0 ] && printf ', '; printf '"%s"' "$f"; first=0; done <<< "$OLDSEAM"; fi
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
    local spk; spk=$({ grep -m1 -oE '"pack"[[:space:]]*:[[:space:]]*"[^"]+"' "$src/assembly.json" 2>/dev/null || true; } | sed -E 's/.*"([^"]+)"$/\1/')
    slot=$(cache_slot "$axis" "${spk:+$G/$spk}")
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
  # Major bump — the assembly finished on the verified major; whether to move to the latest major is the user's call
  local sax
  for sax in frontend backend app; do
    if awk -F'\t' -v a="$sax" '$1==a{f=1} END{exit !f}' "$STALE_TSV" 2>/dev/null; then need="$need \"refresh:$sax\""; fi
  done
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

  local stale_json vgap_json
  vgap_json=$(python3 - "$VGAP_TSV" 2>/dev/null <<'PYVGAP' || printf '[]'
import json, sys
rows = [dict(zip(('axis', 'dim', 'value'), l.rstrip('\n').split('\t')))
        for l in open(sys.argv[1], encoding='utf-8') if l.count('\t') == 2]
print(json.dumps(rows, ensure_ascii=False))
PYVGAP
)
  stale_json=$(python3 - "$STALE_TSV" 2>/dev/null <<'PYSTALE' || printf '[]'
import json, sys
rows = []
for ln in open(sys.argv[1], encoding='utf-8'):
    c = ln.rstrip('\n').split('\t')
    if len(c) < 4:
        continue
    c += [''] * (6 - len(c))
    rows.append({'axis': c[0], 'pkg': c[1], 'majors': c[2], 'latest': c[3],
                 'premise': c[4] == 'yes', 'files': c[5].split()})
print(json.dumps(rows, ensure_ascii=False))
PYSTALE
)
  mkdir -p "$PROJECT_ROOT/.orangekit"
  { printf '{\n  "status": "pending",\n  "combo": "%s+%s",\n' "${FE:-none}" "${BE:-none}"
    printf '  "need": [%s],\n' "$need"
    printf '  "app": "%s",\n' "${APP:-none}"
    printf '  "state": { "frontend": "%s", "backend": "%s", "app": "%s" },\n' "$FE_STATE" "$BE_STATE" "$APP_STATE"
    printf '  "packs": { "frontend": %s, "backend": %s, "app": %s },\n' "$fpack" "$bpack" "$apack"
    printf '  "notes": %s,\n' "$notes"
    # Major-bump list: axis · package · declared→latest major · latest version · pack premise (fixesVariants) or not · affected resources
    printf '  "stale": %s,\n' "$stale_json"
    # Variants the pack does not have — the generator builds only these files and the pack hub, not a whole seam
    printf '  "variantGaps": %s,\n' "$vgap_json"
    # Audit round counter — stack-guide-generator increments it before launching an audit and stops at 1.
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
  trap 'rm -rf "$t" "$STALE_TSV" "$VGAP_TSV"' EXIT
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
  # Both carry a core card — if an unfinished pack's card were installed, the assembly block would be only half a block
  for p in full half; do
    printf -- '---\npaths:\n  - "src/**"\n---\n<!-- orangekit-pack: frontend/%s v1.0.0 -->\n\n# %s core card\n' "$p" "$p" > "$t/guides/frontend/$p/RULES.md"
  done

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
  # Core card — it must be installed even with no seam (resources state). What must be followed may not wait on generation
  local card="$proj/.claude/rules/stack-frontend-full.md"
  if cmp -s "$t/guides/frontend/full/RULES.md" "$card"; then
    printf '  ✓ the core card is installed into .claude/rules/ (even while waiting for a seam)\n'; pass=$((pass+1))
  else
    printf '  ✗ the core card was not installed, or differs from the source\n'; fail=$((fail+1))
  fi
  # A card the project edited is preserved at the same stamp — overwriting it silently erases the project's decision
  printf '\n- a rule the project added\n' >> "$card"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend full --no-freshness --no-cache 2>&1) || true
  if grep -q 'a rule the project added' "$card"; then
    printf '  ✓ an edited card at the same stamp is preserved\n'; pass=$((pass+1))
  else
    printf '  ✗ the edited card was overwritten\n'; fail=$((fail+1))
  fi
  # An axis whose stack premise is pinned still receives the core card — the pin blocks pack skill updates, not must-follow rules
  printf -- '---\nname: frontend-guide\n---\n<!-- orangekit-guide: assembled pkgs=zod@3 -->\n' > "$proj/.claude/skills/frontend-guide/SKILL.md"
  rm -f "$card"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend full --no-freshness --no-cache 2>&1) || true
  if printf '%s' "$out" | grep -q 'state: frontend=pinned' && cmp -s "$t/guides/frontend/full/RULES.md" "$card"; then
    printf '  ✓ an axis whose stack premise is pinned still receives the core card\n'; pass=$((pass+1))
  else
    printf '  ✗ no core card on a pinned axis (or it was not judged pinned)\n'; fail=$((fail+1))
  fi

  # --rules-only (init's default) — the rule file only. With no skill, no work left and no gate, no "guide generation unfinished" notice appears
  _st full "rules" "--rules-only installs only the rule file" --rules-only
  if cmp -s "$t/guides/frontend/full/RULES.md" "$proj/.claude/rules/stack-frontend-full.md" \
     && [ ! -e "$proj/.claude/skills/frontend-guide" ] && [ ! -e "$proj/.orangekit/guide-job.json" ]; then
    printf '  ✓   …the card is there, and there is no skill directory and no guide-job.json\n'; pass=$((pass+1))
  else
    printf '  ✗   …the card is missing, or a skill or guide-job.json appeared\n'; fail=$((fail+1))
  fi
  _st nopack "generate" "--rules-only installs nothing for an axis with no pack" --rules-only
  if [ ! -e "$proj/.orangekit/guide-job.json" ] && [ ! -e "$proj/.claude/skills" ]; then
    printf '  ✓   …it is not recorded as a generation target (the detailed guide is opt-in)\n'; pass=$((pass+1))
  else
    printf '  ✗   …an axis with no pack left guide-job.json or a skill behind\n'; fail=$((fail+1))
  fi

  _st half "generate"  "an unfinished pack is not assembled (declared but missing)"
  if [ -e "$proj/.claude/rules/stack-frontend-half.md" ]; then
    printf '  ✗ an unfinished pack, yet its core card was installed\n'; fail=$((fail+1))
  else
    printf '  ✓ an unfinished pack does not install its core card either\n'; pass=$((pass+1))
  fi

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

  # ── Wire contract pinning ─────────────────────────────────────────
  # **This branch blocks updates of the consumer's installed copy.** Both are pinned: that it blocks when it should
  # (old contract + generated seam) and that it does not block when it should not (--force · no seam · updating the prebuilt
  # seam along with it) — over-blocking is a silent failure in which the fix never arrives.
  mkdir -p "$t/guides/frontend/wcp/resources" "$t/guides/seams/wcp+none/frontend/resources"
  printf '<!-- orangekit-pack: frontend/wcp v2.0.0 verified 2026-01-01 zod@4 -->\n\n# wcp axis pack\n' > "$t/guides/frontend/wcp/PACK.md"
  printf '{\n  "axis": "frontend",\n  "name": "wcp",\n  "packVersion": "2.0.0",\n  "wireContract": "http-standard@1",\n  "wireContractSince": "2.0.0",\n  "pkgs": ["zod@4"],\n  "resources": [ { "file": "a.md", "nav": "A" } ]\n}\n' > "$t/guides/frontend/wcp/pack.json"
  printf '<!-- orangekit-pack: frontend/wcp v2.0.0 -->\n\n# A (new contract)\n' > "$t/guides/frontend/wcp/resources/a.md"
  printf -- '---\nname: frontend-guide\ndescription: x\n---\n# Hub\n' > "$t/guides/seams/wcp+none/frontend/HUB.md"
  printf '<!-- orangekit-seam: wcp+none v2.0.0 -->\n\n# Seam\n' > "$t/guides/seams/wcp+none/frontend/resources/s.md"
  _wc() { # $1=seam source (generated|prebuilt/wcp+none|none) $2=installed contract (""=legacy) $3..=extra args → state
    local src="$1" have="$2" d="$proj/.claude/skills/frontend-guide"; shift 2
    rm -rf "$proj"; mkdir -p "$d/resources"
    printf '<!-- orangekit-pack: frontend/wcp v1.0.0 -->\n\n# A (old contract)\n' > "$d/resources/a.md"
    printf '{\n  "axis": "frontend",\n  "pack": "frontend/wcp",\n  "packVersion": "1.0.0",\n%s  "seam": null,\n  "packFiles": ["a.md"],\n  "seamFiles": []\n}\n' \
      "${have:+  \"wireContract\": \"$have\",\n}" > "$d/assembly.json"
    [ "$src" != none ] && printf -- '---\nname: frontend-guide\ndescription: x\n---\n<!-- orangekit-guide: assembled 2026-01-01 combo=wcp+none packs=frontend/wcp@1.0.0 seam=%s -->\n# Hub\n' "$src" > "$d/SKILL.md"
    out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" \
          bash "$0" --frontend wcp --no-freshness --no-cache "$@" 2>&1) || true
    printf '%s' "$out" | sed -nE 's/.*state: frontend=([a-z]+).*/\1/p' | head -1
  }
  _new() { _is grep -q 'new contract' "$proj/.claude/skills/frontend-guide/resources/a.md"; }
  ast=$(_wc generated "")
  _chk "$(_is [ "$ast" = pinned ])" "an old-contract installed copy + a generated seam does not update the pack → ${ast:-none}"
  _chk "$(_is [ "$(_new)" = 1 ])" "  …and the pack file really is unchanged"
  ast=$(_wc generated "http-standard@1")
  _chk "$(_is [ "$ast" != pinned ])" "the same contract is updated → ${ast:-none}"
  _chk "$(_is [ "$(_new)" = 0 ])" "  …and the pack file really was updated"
  ast=$(_wc generated "" --force)
  _chk "$(_is [ "$ast" != pinned ])" "--force overrides contract pinning → ${ast:-none}"
  ast=$(_wc none "")
  _chk "$(_is [ "$ast" != pinned ])" "an installed copy with no seam has nothing to diverge from and is updated → ${ast:-none}"
  ast=$(_wc prebuilt/wcp+none "" --seam wcp+none)
  _chk "$(_is [ "$ast" = complete ])" "resolving the prebuilt seam as well updates it along with the pack → ${ast:-none}"
  ast=$(_wc prebuilt/wcp+none "")
  _chk "$(_is [ "$ast" = pinned ])" "even with a prebuilt seam, the pack alone is not updated without --seam → ${ast:-none}"
  ast=$(_wc generated "http-standard@1")
  _chk "$(_is grep -q '"wireContract": "http-standard@1"' "$proj/.claude/skills/frontend-guide/assembly.json")" "the updated installed copy records its contract (the basis of the next verdict)"
  # legacy is not a divergence by itself — only a pack whose wire values changed (declares wireContractSince) stops.
  # Without this, **every** installed copy from before the standard contract would never receive a fix (over-blocking)
  sed -i.bak '/"wireContractSince"/d' "$t/guides/frontend/wcp/pack.json" && rm -f "$t/guides/frontend/wcp/pack.json.bak"
  ast=$(_wc generated "")
  _chk "$(_is [ "$ast" != pinned ])" "a pack whose wire values did not change updates a legacy installed copy too → ${ast:-none}"
  sed -i.bak 's#"wireContract": "http-standard@1",#"wireContract": "http-standard@1",\
  "wireContractSince": "1.0.0",#' "$t/guides/frontend/wcp/pack.json" && rm -f "$t/guides/frontend/wcp/pack.json.bak"
  ast=$(_wc generated "")
  _chk "$(_is [ "$ast" != pinned ])" "an installed copy already past the edition of that change is updated → ${ast:-none}"

  # ── Major bump → what is left: refresh:<axis> ─────────────────────────
  # The assembly finishes on the verified major and leaves the basis for handing the latest-major decision to the user.
  # If it is not recorded, init has nothing to ask and a stale guide is installed silently — this branch is pinned down
  if [ -f "$PLUGIN_ROOT/scripts/guide-freshness.sh" ]; then
    mkdir -p "$t/scripts"; cp "$PLUGIN_ROOT/scripts/guide-freshness.sh" "$t/scripts/"
    printf 'zod\t5.0.0\n' > "$t/fake-latest.tsv"
    rm -rf "$proj"; mkdir -p "$proj"
    out=$(ORANGEKIT_FRESHNESS_FAKE="$t/fake-latest.tsv" CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" \
          bash "$0" --frontend full --no-cache 2>&1) || true
    _chk "$(_is grep -q '"refresh:frontend"' "$proj/.orangekit/guide-job.json")" "records a major bump as refresh:frontend in what is left"
    _chk "$(_is grep -q '"pkg": "zod", "majors": "4→5"' "$proj/.orangekit/guide-job.json")" "  …puts the bumped package and majors into stale"
    _chk "$(_is grep -q '# A' "$proj/.claude/skills/frontend-guide/resources/a.md")" "  …the assembly still finishes on the verified major"
    printf 'zod\t4.9.0\n' > "$t/fake-latest.tsv"
    rm -rf "$proj"; mkdir -p "$proj"
    out=$(ORANGEKIT_FRESHNESS_FAKE="$t/fake-latest.tsv" CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" \
          bash "$0" --frontend full --no-cache 2>&1) || true
    _chk "$(_is [ "$(grep -c 'refresh:' "$proj/.orangekit/guide-job.json" 2>/dev/null || true)" = 0 ])" "leaves no refresh when the major is the same"
  else
    printf '  – freshness-record fixture skipped — no guide-freshness.sh (this is **unchecked**)\n'
  fi

  # ── Pack variants · pack hub ──────────────────────────────────────────
  # The only path that reaches complete without a seam. A wrong pick installs another auth method's guidance, and folding
  # an unresolved value into any value does the same silently — pinning down pick · unresolved · contract mismatch
  local vp="$t/guides/frontend/vp" bn="$t/guides/backend/bn"
  mkdir -p "$vp/resources" "$vp/variants/auth/self-issued" "$vp/variants/auth/oidc" "$bn/resources"
  printf '<!-- orangekit-pack: frontend/vp v1.0.0 verified 2026-01-01 zod@4 -->\n# vp\n' > "$vp/PACK.md"
  printf -- '---\nname: vp\ndescription: x\n---\n# pack hub\n' > "$vp/HUB.md"
  printf '{\n  "axis": "frontend",\n  "name": "vp",\n  "packVersion": "1.0.0",\n  "wireContract": "http-standard@1",\n  "variants": { "auth": { "self-issued": "self-issued", "oidc": "oidc" } },\n  "pkgs": ["zod@4"],\n  "resources": [ { "file": "a.md", "nav": "A" } ]\n}\n' > "$vp/pack.json"
  printf '<!-- orangekit-pack: frontend/vp v1.0.0 -->\n# A\n' > "$vp/resources/a.md"
  printf '<!-- orangekit-pack: frontend/vp v1.0.0 -->\n# Self-issued\n' > "$vp/variants/auth/self-issued/auth-and-session.md"
  printf '<!-- orangekit-pack: frontend/vp v1.0.0 -->\n# OIDC\n' > "$vp/variants/auth/oidc/auth-and-session.md"
  printf '<!-- orangekit-pack: backend/bn v1.0.0 verified 2026-01-01 zod@4 -->\n# bn\n' > "$bn/PACK.md"
  printf '{\n  "axis": "backend",\n  "name": "bn",\n  "packVersion": "1.0.0",\n  "wireContract": "none",\n  "pkgs": ["zod@4"],\n  "resources": [ { "file": "b.md", "nav": "B" } ]\n}\n' > "$bn/pack.json"
  printf '<!-- orangekit-pack: backend/bn v1.0.0 -->\n# B\n' > "$bn/resources/b.md"
  _vp() { # $1=authKind $2..=extra args → frontend state
    local ak="$1"; shift
    rm -rf "$proj"; mkdir -p "$proj"
    printf '{ "authKind": "%s" }\n' "$ak" > "$t/notes-vp.json"
    out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" \
          bash "$0" --frontend vp --no-freshness --no-cache --notes "$t/notes-vp.json" "$@" 2>&1) || true
    printf '%s' "$out" | sed -nE 's/.*state: frontend=([a-z]+).*/\1/p' | head -1
  }
  local vd="$proj/.claude/skills/frontend-guide"
  ast=$(_vp self-issued)
  _chk "$(_is [ "$ast" = complete ])" "with variants resolved and the same contract, the pack hub completes it (0 generated) → ${ast:-none}"
  _chk "$(_is grep -q 'Self-issued' "$vd/resources/auth-and-session.md")" "  …lays down the variant matching authKind (self-issued)"
  _chk "$(_is grep -q '"auth-and-session.md"' "$vd/assembly.json")" "  …records the variant file as pack-owned (the basis of cache·retirement verdicts)"
  ast=$(_vp oidc)
  _chk "$(_is grep -q 'OIDC' "$vd/resources/auth-and-session.md")" "a different authKind lays down a different variant (oidc)"
  ast=$(_vp custom)
  _chk "$(_is [ "$ast" = resources ])" "a variant the pack lacks is not folded into any value but left as a generation target → ${ast:-none}"
  _chk "$(_is grep -q '"dim": "auth", "value": "custom"' "$proj/.orangekit/guide-job.json")" "  …records what is missing in variantGaps"
  _chk "$(_is [ ! -f "$vd/resources/auth-and-session.md" ])" "  …lays down no variant at all"
  # Shell-owned auth — with a hybrid shell (a shell value the pack does not have), the web login variant is not laid down
  python3 - "$vp/pack.json" <<'PYSO'
import json, sys
j = json.load(open(sys.argv[1])); j['variants']['shell'] = {'': None}; j['shellOverrides'] = ['auth']
json.dump(j, open(sys.argv[1], 'w'), ensure_ascii=False, indent=2)
PYSO
  rm -rf "$proj"; mkdir -p "$proj"
  printf '{ "authKind": "self-issued", "appShell": "rn-native-screens" }\n' > "$t/notes-vp.json"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend vp --no-freshness --no-cache --notes "$t/notes-vp.json" 2>&1) || true
  _chk "$(_is [ ! -f "$vd/resources/auth-and-session.md" ])" "with the shell unresolved, the shell-owned auth variant is not laid down either (shellOverrides)"
  _chk "$(_is grep -q '"dim": "auth", "value": "self-issued"' "$proj/.orangekit/guide-job.json")" "  …auth is left as a generation target too (variantGaps)"
  ast=$(_vp self-issued)
  _chk "$(_is [ "$ast" = complete ])" "web with no shell (empty appShell) still completes with the pack hub → ${ast:-none}"
  ast=$(_vp self-issued --backend bn)
  _chk "$(_is [ "$ast" = resources ])" "another axis on a different wire contract (none) means no pack hub → ${ast:-none}"
  ast=$(_vp self-issued --backend custom)
  _chk "$(_is [ "$ast" = resources ])" "another axis with no pack (custom) means no pack hub → ${ast:-none}"

  # ── Update runs — protect the consumer's installed copy (4 measured in review) ─────
  # ① stack-premise pinning read the @1 of wireContract as a package and blocked every rerun as pinned
  _vp self-issued >/dev/null
  mkdir -p "$proj/.orangekit"; printf '{ "authKind": "self-issued" }\n' > "$proj/.orangekit/preset-notes.json"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend vp --no-freshness --no-cache 2>&1) || true
  ast=$(printf '%s' "$out" | sed -nE 's/.*state: frontend=([a-z]+).*/\1/p' | head -1)
  _chk "$(_is [ "$ast" = complete ])" "rerunning a completed installed copy is not pinned (only pkgs are compared) → ${ast:-none}"
  # ② an update run with no --notes — rereads the variant from preset-notes.json to protect the auth file,
  #    and when even that is missing (unresolved) it retires nothing
  _chk "$(_is [ -f "$vd/resources/auth-and-session.md" ])" "  …rechooses the variant from preset-notes.json even without --notes"
  rm -f "$proj/.orangekit/preset-notes.json"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend vp --no-freshness --no-cache --force 2>&1) || true
  _chk "$(_is [ -f "$vd/resources/auth-and-session.md" ])" "an update run that does not know the variant does not retire the installed variant file"
  # ③ an installed copy completed by a generated seam — even if the pack gains a file of the same name it is not overwritten, nor is the hub swapped
  rm -rf "$proj"; mkdir -p "$vd/resources"
  printf -- '---\nname: frontend-guide\ndescription: x\n---\n# generated hub\n' > "$vd/SKILL.md"
  printf '# project seam\n' > "$vd/resources/auth-and-session.md"
  printf '{\n  "axis": "frontend",\n  "pack": "frontend/vp",\n  "packVersion": "1.0.0",\n  "wireContract": "http-standard@1",\n  "seam": null,\n  "packFiles": ["a.md"],\n  "seamFiles": ["auth-and-session.md"]\n}\n' > "$vd/assembly.json"
  printf '{ "authKind": "self-issued" }\n' > "$t/notes-vp.json"
  out=$(CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend vp --no-freshness --no-cache --notes "$t/notes-vp.json" 2>&1) || true
  ast=$(printf '%s' "$out" | sed -nE 's/.*state: frontend=([a-z]+).*/\1/p' | head -1)
  _chk "$(_is grep -q 'project seam' "$vd/resources/auth-and-session.md")" "does not overwrite a generated seam file with the pack variant (project-owned)"
  _chk "$(_is grep -q 'generated hub' "$vd/SKILL.md")" "  …does not swap the generated hub for the pack hub"
  _chk "$(_is grep -q '"seamFiles": \["auth-and-session.md"\]' "$vd/assembly.json")" "  …carries the seam ownership record forward (the next run protects it too) → ${ast:-none}"
  # ④ a prebuilt seam whose auth method differs from the project is not used
  mkdir -p "$t/guides/seams/vp+none/frontend/resources"
  printf '{ "combo": "vp+none", "notes": { "authKind": "oidc" } }\n' > "$t/guides/seams/vp+none/seam.json"
  printf -- '---\nname: frontend-guide\ndescription: x\n---\n# prebuilt hub\n' > "$t/guides/seams/vp+none/frontend/HUB.md"
  printf '# prebuilt\n' > "$t/guides/seams/vp+none/frontend/resources/s.md"
  ast=$(_vp self-issued --seam vp+none)
  _chk "$(_is [ ! -f "$vd/resources/s.md" ])" "a prebuilt seam with a different auth method is not used (oidc seam ≠ self-issued) → ${ast:-none}"
  ast=$(_vp oidc --seam vp+none)
  _chk "$(_is [ -f "$vd/resources/s.md" ])" "  …the same auth method uses it"
  # ⑤ cache slots split by variant value — a generated seam for another auth method is not received
  local vc="$t/vcache"
  mkdir -p "$vc/vp+none@0.0.0/frontend.auth-oidc.shell-rn-webview/resources"
  printf -- '---\nname: frontend-guide\ndescription: x\n---\n# cached hub\n' > "$vc/vp+none@0.0.0/frontend.auth-oidc.shell-rn-webview/HUB.md"
  printf '# cached bridge\n' > "$vc/vp+none@0.0.0/frontend.auth-oidc.shell-rn-webview/resources/shell-bridge.md"
  for ak in self-issued oidc; do
    rm -rf "$proj"; mkdir -p "$proj"
    printf '{ "authKind": "%s", "appShell": "rn-webview" }\n' "$ak" > "$t/notes-vp.json"
    out=$(ORANGEKIT_SEAM_CACHE="$vc" CLAUDE_PLUGIN_ROOT="$t" CLAUDE_PROJECT_DIR="$proj" bash "$0" --frontend vp --no-freshness --notes "$t/notes-vp.json" 2>&1) || true
    if [ "$ak" = self-issued ]; then
      _chk "$(_is [ ! -f "$vd/resources/shell-bridge.md" ])" "does not receive a cached seam built for another auth method (variant values in the slot name)"
    else
      _chk "$(_is [ -f "$vd/resources/shell-bridge.md" ])" "  …the same variant values receive the cache"
    fi
  done


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
# The pack hub was written for the standard wire contract — use it only when every axis with a pack is on the same HTTP contract.
# If the other side is BaaS (none) or another contract, that combination is still a combination seam
HUB_OK=1; _wc0=""
for _ax in frontend:"$FE" backend:"$BE" app:"$APP"; do
  _pk="${_ax#*:}"; _ax="${_ax%%:*}"
  _axis_on "$_pk" || continue
  # An axis with no pack (custom and the like) has no guarantee it follows the standard contract — that pair's pack hub is not used
  [ -f "$G/$_ax/$_pk/pack.json" ] || { HUB_OK=0; continue; }
  _wc=$(pack_contract "$G/$_ax/$_pk")
  case "$_wc" in none|legacy) HUB_OK=0 ;; esac
  if [ -z "$_wc0" ]; then _wc0="$_wc"; elif [ "$_wc" != "$_wc0" ]; then HUB_OK=0; fi
done
CONTRACT_HOLD=""
if [ "$FORCE" -eq 0 ]; then
  for _ax in frontend:"$FE" backend:"$BE" app:"$APP"; do
    _pk="${_ax#*:}"; _ax="${_ax%%:*}"
    _axis_on "$_pk" || continue
    _d=$(contract_drift "$_ax" "$_pk")
    if [ -n "$_d" ]; then CONTRACT_HOLD="$CONTRACT_HOLD $_ax: $_d"; fi
  done
fi
if _axis_on "$FE"; then assemble frontend "$FE"; FE_STATE="$AXIS_STATE"; fi
if _axis_on "$BE"; then assemble backend  "$BE"; BE_STATE="$AXIS_STATE"; fi
if _axis_on "$APP"; then assemble app "$APP"; APP_STATE="$AXIS_STATE"; fi
printf '\n  new %d · updated %d · kept %d\n' "$installed" "$updated" "$skipped"

gate_failed=0
if [ "$RULES_ONLY" -eq 1 ]; then
  :   # no skill was assembled, so there is nothing to gate
elif [ "$GATE" -eq 1 ] && [ "$DRY" -eq 1 ]; then
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
printf '    complete=skill finished · resources=waiting for a seam · generate=needs generating · pinned=premise pinned · skip=not applicable · rules=rule file only\n'
# --rules-only records no work left — the detailed guide is opt-in, not "unfinished". An existing job file is left untouched too
if [ "$RULES_ONLY" -eq 1 ]; then
  printf '    The detailed guide skill was not installed (opt-in) — if needed, run again without --rules-only, or /stack-guide-generator\n'
else
  write_job
fi
if [ "$gate_failed" -eq 1 ]; then exit 1; fi
exit 0
