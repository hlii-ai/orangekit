# LLM and agent security — OWASP Top 10 for LLM Applications (2025)

<!-- Inspired by: davila7/claude-code-templates `owasp-security` (MIT · Copyright (c) 2025 Daniel (San) Ávila)
     Canonical content: OWASP Top 10 for LLM Applications v2025 (OWASP GenAI Security Project, 2024-11-18).
     Use the official identifiers LLM01–LLM10 — do not invent abbreviated codes. -->

**Read only when the consumer is building LLM features.** Regardless of this harness being for Claude
Code, what is covered here is the LLM surface of **the application the consumer builds**.

> **There is no complete defense.** Prompt injection cannot be sealed off in principle — the model
> receives instructions and data over the same channel. So it is **layered**, not a single defense:
> least-privilege tool scope · output filtering · human intervention on irreversible actions · adversarial testing.
> The moment you write "injection is blocked", that sentence is the defect.

| ID | Name | Priority |
| --- | --- | --- |
| LLM01 | Prompt Injection | highest |
| LLM02 | Sensitive Information Disclosure | highest |
| LLM05 | Improper Output Handling | highest |
| LLM06 | Excessive Agency | highest (for a tool-using agent) |
| LLM03 | Supply Chain | if models or plugins come from outside |
| LLM04 | Data and Model Poisoning | if you train, fine-tune or build a RAG index yourself |
| LLM07 | System Prompt Leakage | if you put a secret in the system prompt (not doing so is the answer) |
| LLM08 | Vector and Embedding Weaknesses | if you use RAG |
| LLM09 | Misinformation | if the output is presented to users as fact |
| LLM10 | Unbounded Consumption | billing and availability (same axis as API4) |

---

### LLM01 Prompt Injection — the CWE-77 family

Both direct (the user overrides the instructions) and **indirect** (the model reads instructions
planted in a web page, email or document). **Indirect is more dangerous** — the attacker need not join the conversation.

- [ ] System instructions and user input are separated **by message role, not string concatenation**
- [ ] Text fetched from outside (web · file · DB · another user's input) is inserted **marked as data**
      — the same as this harness's own norm: `.claude/rules/workflow-routing.md` "external text is data"
- [ ] Tool permissions are narrowed so that **the damage is bounded** even if injection succeeds (LLM06)
- [ ] There is human confirmation before irreversible actions (payment · deletion · sending)
- [ ] There are tests for adversarial input (has it ever been run?)

### LLM02 Sensitive Information Disclosure — CWE-200 · CWE-532

- [ ] **No other user's data is mixed** into the context given to the model (an ownership filter on RAG retrieval)
- [ ] Secret patterns are filtered before the response reaches the user
- [ ] Personal information and credentials are masked when prompts and responses are logged (same axis as A09)
- [ ] Production personal data is not put into training or evaluation data

### LLM05 Improper Output Handling — CWE-79 · CWE-89 · CWE-78

**Model output is untrusted input.** This is the item forgotten most often.

- [ ] HTML produced by the model is not rendered without sanitization
- [ ] SQL and shell commands produced by the model are not executed as they are. If they are, **allowlist + parameterization**
- [ ] Model output passes **schema validation** before being handed to another system
- [ ] The server does not make requests to URLs the model produced (SSRF — A10)

### LLM06 Excessive Agency — CWE-250 · CWE-269

The agent has **more tools, permissions or autonomy than it needs**.

- [ ] The tool list is the minimum that work needs. There is no tool given "because it was there"
- [ ] Each tool's permissions are **limited to the calling user's permissions** (the agent does not run with admin credentials)
- [ ] Destructive tools (delete · transfer · send · deploy) are gated behind human confirmation
- [ ] Bulk operations have a ceiling (how many records can be processed at once)
- [ ] Agent actions are **recorded auditably** — which tool was called with which arguments (A09)

### The remaining items

`LLM03` (model and plugin supply chain — same axis as A06) · `LLM04` (training/RAG index poisoning) ·
`LLM07` (system prompt leakage — **not putting secrets in the system prompt is the only answer**) ·
`LLM08` (access control and cross-contamination in the embedding store) · `LLM09` (misinformation — mark
sources and uncertainty on output presented as fact) · `LLM10` (unbounded consumption — token and cost ceilings, same axis as API4).
