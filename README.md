# aws-skill-router

A single on-demand router skill that fetches official Agent Toolkit for AWS skills at run time instead of keeping them installed locally. Unofficial. Not affiliated with or endorsed by Amazon Web Services.

## Why

Every installed official AWS skill's `name` and `description` is in context on every request, even when you are not doing AWS work. This router replaces them with one `aws` skill that fetches the matching official skill from the public AWS catalog at run time — always the latest version, with nothing installed locally.

| Setup | Skills in the listing | Extra prompt tokens per request |
|---|---|---|
| Official `aws-core` plugin v1.3.0 (skills only) | 27 | 7,812 |
| aws-skill-router | 1 | 89 |
| **Saving** | | **7,723 per request (~99%)** |

Extra prompt tokens over an empty session; measured 2026-11-21 on macOS with Claude Code 2.1.329, 3 runs each, user config excluded; the AWS MCP Server that aws-core also configures was not included. Reproduce with `scripts/measure-tokens.sh` (see `--help`).

With many skills installed, Claude Code shortens the skill listing and some skills (including non-AWS ones) lose their descriptions.

Reported in [aws/agent-toolkit-for-aws#54](https://github.com/aws/agent-toolkit-for-aws/issues/54) — acknowledged by an AWS contributor but never fixed; the issue was automatically closed as not planned after going stale.

## Install

The router is a standard [Agent Skill](https://agentskills.io/specification), packaged for the same agents as the official toolkit.

**Claude Code**

```text
/plugin marketplace add julianchun/aws-skill-router
/plugin install aws-skill-router@aws-skill-router
```

The skill then appears as `aws-skill-router:aws`.

**Codex**

```text
codex plugin marketplace add julianchun/aws-skill-router
codex plugin add aws-skill-router@aws-skill-router
```

**Cursor:** Settings → Plugins → Team Marketplaces → Add Marketplace → Import from Repo, enter `julianchun/aws-skill-router`, then install **aws-skill-router** from the Plugins panel.

**Devin:** `devin plugins install julianchun/aws-skill-router`

**Kiro, fx and other agents:** `npx skills add julianchun/aws-skill-router` (add `-a <agent>` to pick one).

**Check it works:** ask an AWS question (e.g. "How do I add a rate-based rule to AWS WAF for CloudFront?"); Claude should load the `aws` skill and run `aws agent-toolkit get-skill-file --skill-name waf ...`.

**Requirements:** AWS CLI ≥ 2.35.0 (no AWS credentials needed to read the catalog).

## How it works

- Picks the matching skill from a shortcut table or searches the catalog, fetches its `SKILL.md`, and loads `references/` or `assets/` only when needed.
- Follows cross-skill routing when a fetched skill points to another AWS skill.
- Uses the AWS MCP Server tools if available; otherwise uses the `aws agent-toolkit` CLI with `--region us-east-1 --no-sign-request`.

## Notes

- **Migrating:** Remove official skills first — `claude plugin uninstall aws-core@claude-plugins-official` (same for other official bundles).
  For skills installed with `aws configure agent-toolkit` or `add-skill`, run `aws agent-toolkit list-installed-skills --agent claude-code` then `aws agent-toolkit remove-skill --skill-name <name> --agent claude-code`. Do not install `aws-core` and this router together.

- **Updating:** Official skills never need updating.
  For the router, enable auto-update in `/plugin` → Marketplaces (off by default for third-party marketplaces), or run `claude plugin update aws-skill-router@aws-skill-router` after `claude plugin marketplace update aws-skill-router`. Do not use `aws agent-toolkit add-skill` or `update-skill` alongside the router.

- **Limits:** The catalog is only in `us-east-1`; each skill load adds 1–3 CLI calls and needs network.
  With `claude -p`, allow `Skill(aws-skill-router:aws)` (or `Skill(aws)` for a manual install).

- **Security:** Content comes from the official AWS catalog; the skill instructs the agent to read fetched scripts before running them and to confirm before changing AWS resources.

- **Permissions:** `allowed-tools` pre-approves the read-only `aws agent-toolkit` catalog commands in Claude Code. Other agents may ask before running them.

- **Tested on:** Claude Code on macOS (CI checks run on Linux); Codex plugin install on macOS. Cursor, Devin, Kiro and Windows are not yet tested.

- **Maintenance:** A weekly workflow checks the router table against the official catalog and opens a PR when it changes.

## License

[MIT](LICENSE). Official AWS skills are Apache-2.0 and are fetched at run time, not redistributed here.
