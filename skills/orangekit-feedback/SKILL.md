---
name: orangekit-feedback
description: Files a GitHub issue about orangekit itself — a hook error, a rule or hook misfire, a guide defect, or a feature request — after a duplicate search and the user's confirmation of the full body. Use when the session briefing shows "Bug report drafted", or the user says "report this orangekit bug", "the hook is broken, tell the maintainers", or "send feedback on the plugin". For bugs in the project's own code use /fix-issue.
---

# OrangeKit Feedback

Reports a problem with **orangekit itself** to `https://github.com/hlii-ai/orangekit`. Problems in the
project's own code belong in the project's tracker (`/fix-issue`), not here.

**Opt-in, end to end.** This skill files nothing unless the user first said yes to the session offer (or asked for it
directly) and then said "file it" on the exact text in Step 3. Two confirmations, always. Silence, "looks fine", or a
question is not a yes.

## Step 0: Drafted reports come first

`session-brief` drafts a report for each new orangekit hook error into `.claude/.orangekit/feedback-drafts/<id>.md`
and shows it as "✱ Bug report drafted". The queue is handled **only through the bundled script** — Claude Code guards
direct writes under `.claude/`, so a hand-written `mkdir`/`mv` there stalls on a permission:

```bash
D="${CLAUDE_SKILL_DIR}/scripts/drafts.sh"
bash "$D" list                     # <id><TAB><title> per queued draft (exit 1 = none)
bash "$D" show <id>                # the draft text
bash "$D" mark <id> sent           # after filing
bash "$D" mark <id> dismissed      # after Dismiss
```

If drafts are queued, work through them before anything else:

1. For each draft, run Steps 1–3 with the draft as the starting text (its title, "What happened" and "Expected" are already
   filled; add only the environment and the error record).
2. Step 3 offers **File it · Edit · Dismiss** instead of Cancel.
3. After filing, `mark <id> sent`; after Dismiss, `mark <id> dismissed`. `session-brief` never drafts the same error
   again once it is marked, so do not delete drafts.

With no drafts, start at Step 1.

## Step 1: Collect what happened

Ask in one `AskUserQuestion` call only for what the conversation does not already contain:

- **Kind** — bug · rule/hook misfire · guide defect · feature request
- **What happened** and **what was expected** (for a bug: the steps or command that triggered it)

Then gather the environment without asking — none of it identifies the project:

```bash
grep -m1 '"version"' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"   # plugin version
claude --version 2>/dev/null                                              # Claude Code version
uname -s 2>/dev/null                                                      # OS family
```

Then read orangekit's own error record — what the hooks and the guide pipeline wrote down, so the user does not
have to describe an error from memory:

```bash
S="${ORANGEKIT_STATE_DIR:-.claude/.orangekit}"
# hook failures: hook · UTC time · exit code · line and command (field 3, the project path, is left out)
awk -F'|' '$4 != "0" && $4 != "" {print $1 " | " $2 " | exit " $4 " | " $5}' "$S/hookrun.log" 2>/dev/null | tail -20
ls .orangekit/failed-guides/ 2>/dev/null                                   # guides quarantined after a gate FAIL
grep -o '"status"[^,}]*' .orangekit/guide-job.json 2>/dev/null             # a generation job left failed
```

Put what this finds under an **Error record** heading in the draft. It is not optional context to drop when the
user's description is short — it is the part a maintainer can fix from. The redaction in Step 2 applies to it too:
the command field can contain a path or a token.

From `orangekit.config.json`, take **only** `techStack.presets`, `deliveryModel`, `clientKind` and
`backend.authKind` — stack choices, not project data.

## Step 2: Draft — no secrets, no private code without consent

Write the title (≤ 80 chars) and the body:

```markdown
**Kind:** <kind>
**orangekit:** <version> · **Claude Code:** <version> · **OS:** <os>
**Stack:** <presets · deliveryModel · clientKind · authKind>

### What happened
### Expected
### Steps to reproduce
### Evidence
<error output, doctor lines — redacted>
```

**By default the body never contains**: the project name, the git remote, absolute paths outside the
plugin root (write `<project>/…`), file contents, source code, environment variables, or any value from a
`.env`-like file. Including any of these needs the user's **explicit, separate yes for that item**.

Before showing the draft, scan it and replace each hit with `<redacted>`:

- tokens and keys — `ghp_` · `gho_` · `github_pat_` · `sk-` · `xox[bp]-` · `AKIA[0-9A-Z]{16}` · `AIza` · `-----BEGIN … PRIVATE KEY-----` · JWTs (`eyJ….eyJ…`)
- `password=` · `secret=` · `token=` · `api_key=` values, and credentials inside URLs (`https://user:pass@…`)
- email addresses and internal hostnames

## Step 2b: Look for an existing issue first

Before showing the draft, search open issues for the same problem so that one is not filed twice:

```bash
gh issue list --repo hlii-ai/orangekit --state open --search "<two or three distinctive words from the title>" \
  --json number,title,url --limit 10
```

- **A match with the same error or symptom**: show it (number · title · URL) and offer one choice: add this
  evidence as a comment (`gh issue comment <number> --repo hlii-ai/orangekit --body-file <draft file>`), or file a new issue anyway.
  A comment is also public, so it goes through the same "File it" confirmation in Step 3.
- **No match, or `gh` unavailable**: continue to Step 3. An unavailable `gh` means the duplicate check is skipped, and the
  summary says so.

## Step 3: Show it and ask

Save the body to a temporary file (`mktemp`), print the **title and the full body exactly as they will
be filed**, then ask with `AskUserQuestion`:

```
File this issue on hlii-ai/orangekit? It will be public.
  1. File it
  2. Edit      — say what to change; redraft, show again, ask again
  3. Cancel    — delete the draft, file nothing
```

## Step 4: File

```bash
gh auth status >/dev/null 2>&1 && \
  gh issue create --repo hlii-ai/orangekit --title "<title>" --body-file "<draft file>"
```

Report the issue URL that `gh` prints. **If `gh` is missing, not logged in, or the call fails**, do not
retry with other credentials — print a prefilled link instead:

```bash
python3 -c 'import sys,urllib.parse as u; print("https://github.com/hlii-ai/orangekit/issues/new?title="+u.quote(sys.argv[1])+"&body="+u.quote(open(sys.argv[2],encoding="utf-8").read()))' "<title>" "<draft file>"
```

If that link is longer than about 8,000 characters, GitHub truncates it: print the link with the title
only and the body as a block for the user to paste. Delete the draft file at the end, whatever the outcome.
