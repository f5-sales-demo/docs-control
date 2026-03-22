# Persona Activation

This repository uses Sales Engineer persona skills from the
`f5xc-sales-engineer` plugin. When the user's message matches
a trigger pattern below, **invoke the corresponding skill and
follow its instructions exactly**.

## Trigger Map

| Trigger phrases | Skill | Action |
| --------------- | ----- | ------ |
| "prepare the demo", "prep the demo", "get ready for the demo", "is the demo environment ready", "is the demo ready", "the meeting will be starting soon", "check the demo", "pre-flight", "preflight check" | `f5xc-sales-engineer:demo-executor` | Invoke skill, run Prepare stage (delegates to `demo-housekeeping` subagent for Readiness Verification Matrix) |
| "run the demo", "execute the demo", "start the demo", "API demo" | `f5xc-sales-engineer:demo-executor` | Invoke skill, run Execute stage (intro, phases, conclusion) |
| "question and answer", "Q&A", "open it up for questions", "take questions" | `f5xc-sales-engineer:demo-executor` | Invoke skill, enter Q&A stage |
| "tear down", "clean up", "tear down the demo", "end the meeting" | `f5xc-sales-engineer:demo-executor` | Invoke skill, confirm with operator, run Teardown stage |
| "walk through the demo", "present the demo", "show the demo", "walkthrough" | `f5xc-sales-engineer:presenter` | Invoke skill, begin walkthrough sequence |
| "answer questions", "question about", "explain", "what does" | `f5xc-sales-engineer:subject-matter-expert` | Invoke skill, answer as subject matter expert |

## Activation Rules

1. **Invoke the matched skill** using the Skill tool
2. **Follow the skill's execution protocol** — do not improvise
   a different structure
3. **Use `docs/` as the knowledge base** per the skill's
   instructions for product details and technical content
4. **Read convention files** — skills read product-specific content
   from standardized files in the repository root

## Convention Files

Skills read product-specific content from these repo-local files:

| File | Purpose | Required By |
| ---- | ------- | ----------- |
| `PRODUCT_EXPERTISE.md` | Product capabilities, detection signals, threat coverage, compliance alignment, API reference | All skills |
| `WALKTHROUGH_CONFIG.md` | Demo app URL, walkthrough order, detection timing | presenter |
| `SOURCE_INDEX.md` | Research source catalog for demo-researcher agent | demo-executor (Q&A), subject-matter-expert |
| `READINESS_MATRIX.md` | Required/optional variables, readiness checks (T0–T5), API endpoints | demo-executor (Prepare/Teardown) |
| `docs/api-automation/` | Phase files with cURL commands and evidence gates | demo-executor (Execute) |

## Ambiguous Intent

If the user's request relates to the demo but does not clearly
match a single trigger above, invoke the `f5xc-sales-engineer:sales-engineer`
skill. It serves as the index of all available personas and will
help determine the correct one to activate.
