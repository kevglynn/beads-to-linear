# Multi-Agent Review

Structural code changes benefit from review by multiple independent perspectives. A single reviewer — human or AI — has blind spots. This rule defines a two-tier review protocol.

## When to trigger

Multi-agent review is required when:
- A component is decomposed (split into multiple production files)
- A shared component is created or significantly changed
- A structural refactor touches 3+ production files (excluding tests, docs, generated files, mechanical renames)
- The change affects accessibility, state management, or CSS architecture

Multi-agent review is NOT required for:
- Bug fixes with clear, narrow scope
- Config/chore/docs beads
- Token substitutions or mechanical migrations with no structural change
- Test-only or docs-only changes

## Lifecycle sequencing

Multi-agent review fits into the bead completion workflow defined in `bead-completion.md`:

1. Implement the work
2. **Self-review against ACs** (per bead-completion.md)
3. **Tier 1: same-model multi-lens review** (this rule)
4. Fix findings, commit
5. **Tier 2: cross-model review** (this rule — human-assisted)
6. Fix findings, commit
7. `bd close` with evidence

Tier 1 supplements the self-review — it does not replace it.

## Tier 1: Same-model multi-lens review (agent does this autonomously)

After the self-review step, the agent performs **three independent review passes** with distinct lenses. If the tool supports parallel subagents or review agents, launch them concurrently; otherwise, run sequentially:

| Review lens | Focus | Catches |
|---|---|---|
| `code-reviewer` | Correctness, edge cases, race conditions, error paths | Logic bugs, state management issues, missing guards |
| `architect-reviewer` | Pattern consistency, component boundaries, reusability | Architectural drift, duplication, wrong abstractions |
| `simplify` | Over-engineering, unnecessary complexity, premature abstraction | Gold-plating, dead code, abstractions without consumers |

### How to launch review passes

Each pass must run with independent context — reviewing the same files but not seeing the other passes' findings until triage.

- **Cursor:** Spawn three subagents via the Task tool, one per lens (`code-reviewer`, `architect-reviewer`, `simplify`). Each subagent gets the bead context and file contents listed below. Launch all three in parallel in a single message.
- **Claude Code:** Run three separate tool invocations or subprocess calls. Each starts with only the bead context and file contents — no prior pass results.
- **Fallback (no parallelism):** Run three sequential passes. Write findings from each pass to a file or bead note before starting the next to prevent anchoring on your own prior findings.

### Context for each review pass

Each review pass must include:
1. The **bead description and acceptance criteria** (from `bd show <id>`)
2. The **full file contents** of all changed/created files
3. The **bead type** (feature/refactor/bug) to calibrate review depth
4. The **shared components** the change depends on (so reviewers can check integration)
5. A **brief change summary** (what was done, what the goals were)

### After collecting results

1. Categorize findings as Critical / Important / Minor
2. Fix Critical and Important findings immediately
3. Create beads for Minor findings and deferred extractions (per `beads-quality.md`)
4. Commit fixes as a separate commit (not amended into the original)

## Tier 2: Cross-model review (human-assisted)

Different AI models have genuinely different architectures, training data, and failure modes. Same-model multi-lens review catches framing-dependent issues but not model-specific blind spots.

### Policy

Tier 2 is **strongly recommended** for all structural changes. If deferred under time pressure, create a bead to track the cross-model review before merge.

Tier 2 is **required** (not deferrable) when the change touches:
- Shared primitives (design system components, shared hooks)
- App shell or navigation infrastructure
- Authentication, authorization, or security boundaries
- State management architecture

### Prerequisites

The work must be **committed and pushed** before Tier 2 handoff. This ensures:
- Review works across worktrees and machines
- External models can reference actual file contents
- The snapshot is reproducible (aligns with `worktree-awareness.md`)

### What the agent provides

A ready-to-paste review prompt containing:
1. **Change summary** — what was done and why (2-3 sentences)
2. **File list** — exact paths to review
3. **Review focus areas** — specific concerns from the change
4. **What Tier 1 already caught** — so external reviewers don't duplicate known findings

### Template

```
Review this structural refactor with a critical eye. Accept or reject each
finding with a reason — don't rubber-stamp.

## Change
[Agent fills: 2-3 sentence summary]

## Files
[Agent fills: file paths]

## Focus areas
[Agent fills: specific concerns]

## Already addressed (from prior review)
[Agent fills: Tier 1 findings that were fixed]
```

### What the human does

Send the prompt to 2-3 different models (e.g., Codex, Gemini, Sonnet, GPT). Collect findings. The agent then triages and addresses them using the same Critical/Important/Minor framework.

### When models disagree

When two models flag opposite findings, treat the **more conservative** finding as the starting position. Document the disagreement in the triage. Do not let conflicting findings cancel each other out — the conservative option is the default unless there's a clear reason to override.

## Evidence in bead close

When closing a bead that triggered multi-agent review, the `bd close --reason` must note:
- Whether Tier 1 ran and what categories of findings were addressed
- Whether Tier 2 was completed, deferred (with tracking bead ID), or not required
- This is in addition to the AC-mapped evidence required by `bead-completion.md`

## Knowledge capture from review findings

When a Tier 1 or Tier 2 finding reveals a **pattern-level insight** — not a localized bug, but a systemic pattern like hidden coupling, an undocumented convention, or a recurring architectural anti-pattern — capture it with `bd remember --key <area>-<topic>` after the finding is resolved. These are high-signal memories because they represent knowledge the implementing agent didn't already have.

## Tracking

All deferred findings — from both tiers — must be captured as beads with proper descriptions and acceptance criteria per `beads-quality.md`.
