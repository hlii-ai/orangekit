<!-- An asset used only by orangekit-init. SKILL.md calls it in procedure order.
     Kept in the body, all 486 lines would enter the context before the interview even ends. -->

# Step 5–6: create orangekit.config.json · CLAUDE.md

### Step 5: Create orangekit.config.json

Create `orangekit.config.json` from the collected information:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/hlii-ai/orangekit/main/schema/orangekit.config.schema.json",

  "project": {
    "name": "<input>",
    "language": "<BCP-47 tag — ko | en | id | vi | the normalized result of an 'Other' input>",
    "languageLabel": "<that language's endonym — 한국어 | English | Bahasa Indonesia | Tiếng Việt | ...>",
    "experienceLevel": "<input>"
  },

  "techStack": {
    "presets": { "frontend": "<Step 2 choice>", "backend": "<Step 2 choice>" },
    "preset": "<frontend>+<backend>",           // backward-compatible notation — presets is canonical

    // Dimensions — not axes. They do not pick a pack; they turn the pack's conditional slots on and off
    "deliveryModel": "<web | hybrid | native | api-only — Step 2 ① choice>",
    "clientKind": "<browser | app>",            // derived: browser for web, app for the rest
    "pwa": false,                                // only meaningful for web. Turns on the service-worker and install slots
    "nativeStack": "",                           // only for native. React Native, Flutter, etc.
    "vcsPlatform": "<github | gitlab>",          // the Step 0 remote decision. Splits the issue and change-request commands

    // Project-level values — build-gate and health-check read these. Always fill them
    "framework": "<representative framework>",
    "language": "<representative language>",
    "packageManager": "<representative package manager>",
    "commands": { "build": "<input>", "test": "<input>", "lint": "<input>" },

    "frontend": {                                // frontend axis (empty when none)
      "framework": "<input or preset default>",
      "language": "<input or preset default>",
      "packageManager": "<input or preset default>",
      "commands": { "build": "", "test": "", "lint": "" },
      "sourceDir": "<preset default>",
      "additionalStack": []
    },
    "backend": {                                 // backend axis
      "backendType": "<baas | serverless | cloud-server | framework-builtin | empty>",
      "cloudProvider": "<input or null>",
      "database": "<preset default or input>",
      "dataAccess": "<preset default or input>",
      "auth": "<Step 4.5 input>",
      "framework": "<self-hosted server only>",
      "language": "<self-hosted server only>",
      "packageManager": "<self-hosted server only>",
      "commands": { "build": "", "test": "", "lint": "" },
      "sourceDir": "<self-hosted server only>"
    },
    "additionalStack": []                        // base + both axes, accumulated
  },

  "domains": {
    "sourceDir": "<input>",
    "sharedPackage": "<input>",
    "importAlias": "<input>",
    "repoTopology": "<monorepo | single | msa — the Step 4.7 choice>"
  },

  // Create it empty — do not ask here.
  // /image-generator asks once, **on the first image request**, and records
  // imageProvider ("openai" | "manual"). Put a feature you may never use into the
  // initial interview and the interview only gets longer while most projects throw the answer away.
  "assets": {}
}
```

### Step 6: Create CLAUDE.md

**The canonical source is `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.hbs`.** Do not copy the template
body into this skill — a copy is a source of drift, and in v3 this skill's inline copy did diverge
from the canonical source, so the "task routing" section never reached the project.

1. Read `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.md.hbs`
2. Substitute the Handlebars expressions with values from `orangekit.config.json`:
   - `{{project.name}}` · `{{techStack.framework}}` and so on → the matching value
   - `{{#if ...}}...{{/if}}` → if the condition is true keep only the body; if false delete the whole block
   - `{{#each techStack.additionalStack}}` → expand one line per item
   - `{{#if (eq project.language "ko")}}` and the like → keep only the branch matching the actual setting.
     **The two lines under Response Language (the localization and terminology contract) are not a branch — do not delete them**
3. **Leave the `<plugin-root>` placeholder as it is** — the absolute path is shown on the
   'self-test' line of every session brief, so nailing it in here breaks when the plugin path changes
4. Write it to the project root as `CLAUDE.md` (if a file exists, follow the Step 0 backup confirmation)

**Do not delete the `.claude/rules/workflow-routing.md` pointer in the "harness" section.**
The body of the P0–P6 Phase table lives in that card and Step 7 installs it — do not write the
table into CLAUDE.md again (if the copies diverge, `doctor --fast` fails).

> **Keep CLAUDE.md to around 100 lines.** Do not put in the project structure tree, technology-specific
> rules or code style details — those can be explored live or are handled by `.claude/rules/`.
> For every line, ask "does Claude make a mistake if I delete this line?" and delete it if not.
