---
name: pack-refresh
description: Raises one axis pack under guides/ to the latest major of its packages and bumps pack.json only after guide-gate and pack-smoke --online pass on the new major. Use when the user asks to "refresh packs", "update pack majors", "check for stale packs", or names a pack to refresh. Manual invocation only.
disable-model-invocation: true
---

# Pack Refresh

<!-- orangekit-doctor: allow-bare-paths — this skill runs only inside the orangekit source repo, where guides/ and skills/ are real paths -->

`pack.json` `pkgs` records **the majors a pack's code was verified on**, not what a consumer should install.
Raising it while the guide still shows the old API makes the stamp lie, and consumers get code that does not
compile. So a refresh is: rewrite the guide for the new major → prove it → only then bump.

The script enforces the last part. `--bump` refuses unless the pack's content is exactly what `--verify` passed.

```bash
R="${CLAUDE_SKILL_DIR}/scripts/pack-refresh.sh"
```

## Step 1: Find what is stale

```bash
bash "$R" --check                      # every pack · or: bash "$R" --check guides/frontend/react-vite
```

Exit 1 means at least one newer major exists. Report a table of pack · package · pinned major → latest major, and
mark packages listed in that pack's `fixesVariants` (framework, router, ORM): those change the premise of the whole
pack, not one resource. Ask the user which pack to refresh; **one pack per run**.

## Step 2: Rewrite the pack for the new major

On a branch, for the chosen pack only:

1. Update the version in `pkgs` in `pack.json` (e.g. `react@18` → `react@19`) — pack-smoke `--online` installs
   these, so the verification really runs against the new major.
2. Read the official migration guide for every bumped package (the release notes or upgrade guide on the project's
   own site — not memory). List the API changes that touch this pack's code.
3. Change the code in `PACK.md`, `HUB.md`, `resources/`, `variants/` to the new API. Keep the structure; change only
   what the migration requires.
4. If a symbol's name or shape changed, update `ledger.md`. If a policy's pattern no longer matches the new API,
   update `policies.md` with its proof example. If the wire format changed, also set `wireContractSince`.

Do not touch `packVersion`, `verified` or the stamps — Step 4 does that.

## Step 3: Prove it

```bash
bash "$R" --verify guides/<axis>/<pack>
```

This runs `guide-gate --pack` and `pack-smoke --pack --online` (npm or pip install of the new majors, then typecheck
and execution). A failure is the work list — fix and run `--verify` again. Never edit the stamps or `packVersion` by
hand to get past it.

If the new major cannot be made to pass in this run, restore the pack (`git checkout -- guides/<axis>/<pack>`) and
report what blocked it. A pack left half-migrated is worse than a stale one.

## Step 4: Bump

```bash
bash "$R" --bump guides/<axis>/<pack> <x.y.z>
```

Use the next plugin release's version for `<x.y.z>`, the same scheme as the other `packVersion` values. The script
raises `packVersion`, sets `verified` to today, rewrites the `PACK.md` stamp with the new `pkgs`, and updates the
stamp of every file changed since the last commit. One verification allows exactly one bump.

## Step 5: Before release

```bash
bash skills/stack-guide-generator/scripts/guide-gate.sh --self-test --regress   # every shipped pack and prebuilt seam
npm test
```

`--regress` catches a prebuilt seam (`guides/seams/`) that still expects the old API. Report: pack, old → new
majors, migration changes made, verification results, and anything left for the next run.
