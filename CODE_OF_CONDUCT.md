# Code of Conduct

This project adopts **[The Agentic Covenant v1.0](https://github.com/gastownhall/beads/blob/main/CODE_OF_CONDUCT.md)** — the first Code of Conduct designed for communities where humans and AI agents collaborate.

## Why the Agentic Covenant

The ai-dev-playbook is a methodology for AI-supervised development. The rules, scripts, and documentation in this repo govern how agents behave. It follows that the *community* building those rules should itself operate under governance designed for human-agent collaboration.

The Agentic Covenant's three principles align directly with the playbook's philosophy:

| Agentic Covenant Principle | Playbook Equivalent |
|---|---|
| **Operator accountability** — humans are responsible for their agents | Planner/Executor model — the human decides *what*, the agent decides *how* |
| **Understanding over authorship** — comprehension matters, not line-by-line writing | Agent-assisted development — we judge contributions on quality, not tooling |
| **Explicit welcome** — AI-supervised contributions are legitimate | The entire premise of this repo |

## What this means in practice

### For contributors

- Contributions made through AI agents are welcome and valued
- Disclose substantial AI assistance using the `Assisted-by` convention when submitting PRs
- You are accountable for everything submitted under your account, including agent-generated content
- See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution process

### For rule authors

- Rules should be tool-neutral — they apply regardless of which AI assistant is used
- Rule changes that affect agent behavior should be measured (see the [Rule Effectiveness Scorecard](docs/rule-effectiveness-scorecard.md))
- When rules conflict with the Agentic Covenant's agent operating standards, the Covenant takes precedence

### For teams adopting the playbook

- The playbook ships behavioral rules. The Agentic Covenant provides the governance layer.
- Teams adopting the playbook are encouraged to adopt the Agentic Covenant as their project's Code of Conduct
- The `playbook-init.sh` script can distribute `CODE_OF_CONDUCT.md` alongside rules (see [Governance Guide](docs/governance.md))

## Reporting

Report conduct issues to the playbook maintainers. For Pryon-internal projects, use the team's existing escalation path. For the playbook repo itself, contact Kevin Glynn directly.

## Full text

The complete Agentic Covenant is maintained upstream at [gastownhall/beads](https://github.com/gastownhall/beads/blob/main/CODE_OF_CONDUCT.md). This project adopts it in full, with the following customizations:

- **Enforcement contact**: Playbook maintainers (internal Pryon channels)
- **Rate limits**: As defined in the upstream Agentic Covenant defaults (3 open PRs per principal, 5/day)
- **Scope**: All playbook community spaces — Bitbucket repo, Jira PC project, Confluence ADC space, and Slack channels
