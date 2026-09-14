#!/bin/bash
# scripts/install-rules.sh — installs the T1 rule cards into a project
#
# The substantive fix for §1.3. In v2 there was no path at all for the plugin's 697 lines of rules/
# to reach a project (the plugin manifest has no 'rules' component type, and
# orangekit-init had no copy step either). CLAUDE.md declared they were there; they were not.
#
# Usage:
#   install-rules.sh [--dry-run] [--force] [--missing-only] [--quiet]
#
# Idempotent. For a file that is already installed the decision comes from comparing version stamps:
#   - same version  → skipped
#   - older version → updated (a user's edits are backed up as .bak)
#   - user edit detected + same version → skipped (project ownership is respected)
#
#   --missing-only  A file that already exists is **not checked by version** and is left alone. Only missing ones are installed.
#                   This is the mode the session-brief hook uses for its automatic run — an automatic run must not
#                   silently overwrite a user's edits, so updating happens only when a person calls it with no arguments.
#   --quiet         Prints nothing when there is no change (for running every session from a hook)

set -Eeuo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SRC="$PLUGIN_ROOT/rules"
DST="$PROJECT_ROOT/.claude/rules"
# References for progressive loading that the cards link to. Cards refer to them as `../references/<topic>/`,
# and they **must not be put inside `.claude/rules/`** — a .md there is resident every session unless it has paths,
# so "read it only when needed" would not hold.
REFSRC="$PLUGIN_ROOT/references"
REFDST="$PROJECT_ROOT/.claude/references"

DRY=0; FORCE=0; MISSING_ONLY=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --dry-run)      DRY=1 ;;
    --force)        FORCE=1 ;;
    --missing-only) MISSING_ONLY=1 ;;
    --quiet)        QUIET=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  esac
done
say() { [ "$QUIET" -eq 1 ] || printf "$@"; }

[ -d "$SRC" ] || { printf 'FATAL: no plugin rules/: %s\n' "$SRC" >&2; exit 2; }

version_of() { grep -m1 -oE 'orangekit-rule-version: [0-9]+\.[0-9]+\.[0-9]+' "$1" 2>/dev/null | awk '{print $2}' || true; }

say 'T1 rule install\n  plugin:  %s\n  project: %s\n\n' "$SRC" "$DST"

[ "$DRY" -eq 0 ] && mkdir -p "$DST"

installed=0; skipped=0; updated=0
for f in "$SRC"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  target="$DST/$base"
  sv=$(version_of "$f"); sv="${sv:-0.0.0}"

  if [ ! -f "$target" ]; then
    say '  + %-24s (v%s) new\n' "$base" "$sv"
    [ "$DRY" -eq 0 ] && cp "$f" "$target"
    installed=$((installed+1))
    continue
  fi

  # --missing-only: when it already exists the version is not looked at. That is the boundary keeping an automatic run from overwriting.
  if [ "$MISSING_ONLY" -eq 1 ]; then
    skipped=$((skipped+1)); continue
  fi

  tv=$(version_of "$target"); tv="${tv:-0.0.0}"
  if [ "$sv" = "$tv" ] && [ "$FORCE" -eq 0 ]; then
    say '  = %-24s (v%s) same — skipped\n' "$base" "$tv"
    skipped=$((skipped+1))
    continue
  fi

  # Check whether the user edited it (content differs + same version → project-owned)
  if [ "$sv" = "$tv" ] && ! cmp -s "$f" "$target"; then
    say '  = %-24s user edit — preserved\n' "$base"
    skipped=$((skipped+1))
    continue
  fi

  say '  ↑ %-24s v%s → v%s (backup: %s.bak)\n' "$base" "$tv" "$sv" "$base"
  if [ "$DRY" -eq 0 ]; then
    cp "$target" "$target.bak"
    cp "$f" "$target"
  fi
  updated=$((updated+1))
done

# Even under --quiet, report when something really was installed or updated — there are no silent changes
if [ "$QUIET" -eq 1 ] && [ $((installed+updated)) -gt 0 ]; then
  printf '%d T1 rule cards auto-installed (%s)\n' "$((installed+updated))" "${DST#$PROJECT_ROOT/}"
fi
say '\n  new %d · updated %d · kept %d\n' "$installed" "$updated" "$skipped"

# Reference assets the cards link to — they use the same decision rule as the cards (version stamp)
refn=0
if [ -d "$REFSRC" ]; then
  while IFS= read -r rf; do
    rel="${rf#$REFSRC/}"
    rt="$REFDST/$rel"
    if [ ! -f "$rt" ]; then
      [ "$DRY" -eq 0 ] && { mkdir -p "$(dirname "$rt")"; cp "$rf" "$rt"; }
      refn=$((refn+1)); continue
    fi
    [ "$MISSING_ONLY" -eq 1 ] && continue
    rsv=$(version_of "$rf"); rsv="${rsv:-0.0.0}"
    rtv=$(version_of "$rt"); rtv="${rtv:-0.0.0}"
    if [ "$rsv" != "$rtv" ] || [ "$FORCE" -eq 1 ]; then
      if [ "$DRY" -eq 0 ]; then
        cmp -s "$rf" "$rt" || cp "$rt" "$rt.bak"
        cp "$rf" "$rt"
      fi
      refn=$((refn+1))
    fi
  done < <(find "$REFSRC" -name '*.md' -type f 2>/dev/null)
  [ "$refn" -gt 0 ] && say '  + %d reference assets (%s)\n' "$refn" "${REFDST#$PROJECT_ROOT/}"
fi

# Install verification — "copied it" is not "it exists"
if [ "$DRY" -eq 0 ]; then
  # On a glob miss ls exits 1 → the pipefail+ERR trap dies here and the FATAL below never comes out.
  # That is, the code meant to report "0 cards" goes silent precisely when there are 0.
  n=$({ ls -1 "$DST"/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "${n:-0}" -eq 0 ]; then
    printf '\nFATAL: even after installing, there are no rules in %s.\n' "$DST" >&2
    exit 1
  fi
  say '  verified: %s holds %s rules ✓\n' "${DST#$PROJECT_ROOT/}" "$n"

  # Did the references the cards point at actually arrive? With only a link and no file,
  # the model is pointed at "a file it cannot read" and progressive loading quietly breaks.
  dang=0
  for c in "$DST"/*.md; do
    [ -f "$c" ] || continue
    while IFS= read -r lnk; do
      [ -z "$lnk" ] && continue
      [ -f "$DST/$lnk" ] || { printf 'WARN: %s → %s not installed\n' "$(basename "$c")" "$lnk" >&2; dang=$((dang+1)); }
    done < <(grep -ohE '\.\./references/[A-Za-z0-9._/-]+\.md' "$c" 2>/dev/null | sort -u)
  done
  [ "$dang" -eq 0 ] && say '  verified: every card→reference link reaches ✓\n'
fi
