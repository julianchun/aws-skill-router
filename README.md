# aws-skill-router

A single on-demand router skill that fetches official Agent Toolkit for AWS skills at run time instead of keeping them installed locally. Unofficial. Not affiliated with or endorsed by Amazon Web Services.

## Why

Official Agent Toolkit for AWS skills are installed either as plugins (for example, `aws-core`, which includes 27 skills) or with `aws agent-toolkit add-skill`. Every installed skill's `name` and `description` is in context on every request, even when you are not doing AWS work. This was reported in [aws/agent-toolkit-for-aws#54](https://github.com/aws/agent-toolkit-for-aws/issues/54) — acknowledged by an AWS contributor but never fixed; the issue was automatically closed as not planned after going stale.

Installing this single `aws` router skill avoids keeping official skills installed locally. At run time, the router fetches the matching official skill directly from the public AWS catalog, so it is always the latest version and no official skills are installed or cached locally.

Measured on 2026-11-20 on macOS with Claude Code 2.1.328 using `claude -p "Reply with exactly: OK" --output-format json --max-turns 1 --setting-sources project,local` (user-level settings, skills, and plugins excluded; 3 runs per environment, medians reported — `B` and `C` were identical across runs, and `A` varied by ≤40 tokens). The comparison loads the 27 skill folders from the official `aws-core` Claude Code plugin v1.3.0 ([aws/agent-toolkit-for-aws](https://github.com/aws/agent-toolkit-for-aws), `plugins/aws-core` — marked "Start here" in AWS's README and installed via `/plugin install aws-core@claude-plugins-official`) as project skills, versus this router (1 skill). The AWS MCP Server that `aws-core` also configures was not included, so the real `aws-core` cost is at least this much:

| Setup | Skills in the listing | Extra prompt tokens per request |
|---|---|---|
| Official `aws-core` plugin v1.3.0 (skills only) | 27 | 7,812 |
| aws-skill-router | 1 | 217 |
| **Saving** | | **7,595 per request (~97%)** |

"Extra prompt tokens" is each environment's total minus an empty baseline (`A`). Absolute prompt token totals depend on OS, Claude Code version, model, and your own configuration, so this table reports the difference against an empty baseline, which stays stable. The 27 `aws-core` skills' names and descriptions total 20,980 characters.

Beyond raw token cost, Claude Code limits the total length of the skill listing: when many skills are installed, some are shown with name only (no description) — including unrelated, non-AWS skills — which makes them harder for the model to pick. An earlier measurement with 24 official skills plus the author's other skills showed 8 of the 60 skills in the listing reduced to name only, 5 of them unrelated to AWS; with only the router, all 38 skills kept their descriptions.

## How it works

```text
User AWS request
      │
      ▼
  aws router ──► MCP available? ──► Yes: aws___search_documentation / aws___retrieve_skill
      │
      └──► No (CLI mode):
             1. Match skill from shortcut table (or aws agent-toolkit search-skills)
             2. Fetch metadata & SKILL.md (get-skill-metadata / get-skill-file)
             3. Fetch references/ or assets/ only when SKILL.md asks for them
             4. If the fetched skill routes to another skill, fetch that skill too
```

- **Match → fetch → load references on demand:** The router matches the request against its shortcut table (or searches the catalog), fetches the skill's `SKILL.md`, and pulls `references/` or `assets/` files only when instructed by that skill.
- **MCP vs CLI auto-selection:** If the AWS MCP Server tools (`aws___retrieve_skill`) are available in the current session, the router uses MCP (`aws___search_documentation` with topic `agent_skills` and `aws___retrieve_skill`). Otherwise, it uses the `aws agent-toolkit` CLI with `--region us-east-1 --no-sign-request`.
- **Cross-skill routing:** When a fetched skill instructs the agent to load another AWS skill, the router fetches that second skill through the same path instead of falling back to memory.

## Install

### Claude Code plugin

Inside Claude Code:

```text
/plugin marketplace add julianchun/aws-skill-router
/plugin install aws-skill-router@aws-skill-router
```

Or from the CLI:

```bash
claude plugin marketplace add julianchun/aws-skill-router
claude plugin install aws-skill-router@aws-skill-router
```

When installed as a plugin, the skill is namespaced and appears as `aws-skill-router:aws`.

### `skills` CLI

```bash
npx skills add julianchun/aws-skill-router
```

### Manual copy

Copy `skills/aws` from this repository to `~/.claude/skills/aws`.

## Updating

Official AWS skills never need updating—the router fetches the latest published version from AWS at run time.

To update the router itself when a new version is released:

- **Claude Code plugin:** Background auto-update is off by default for third-party marketplaces. To enable it, open `/plugin` → **Marketplaces** → `aws-skill-router` and turn on auto-update. You can also update manually from the CLI:
  ```bash
  claude plugin marketplace update aws-skill-router
  claude plugin update aws-skill-router@aws-skill-router
  ```
  (Or select **Update marketplace** in `/plugin` → **Marketplaces** to do both.) The new version loads in your next session or after `/reload-plugins`.
- **`skills` CLI:** Rerun `npx skills add julianchun/aws-skill-router`.
- **Manual copy:** Copy `skills/aws` from this repository to `~/.claude/skills/aws` again.

Do not run `aws agent-toolkit update-skill` or `aws agent-toolkit add-skill` alongside the router—that reinstalls official skills locally and brings back their context cost.

**Maintenance:** A weekly GitHub Actions workflow compares the router table with the official catalog and opens a PR when listed names disappear or new skills appear. Merging a PR that bumps the version publishes a GitHub Release automatically. On public repositories, GitHub automatically disables scheduled workflows after 60 days without repository activity, so re-enable the workflow in the **Actions** tab if needed.

## Migrating from the official skills

- **Official Claude Code plugins (`aws-core`, etc.):** If you installed `aws-core` (via `/plugin install aws-core@claude-plugins-official` from the default official Anthropic marketplace), uninstall it from `/plugin` → **Installed**, or run:
  ```bash
  claude plugin uninstall aws-core@claude-plugins-official
  ```
  Other official bundles exist (for example, `aws-agents` and `aws-data-analytics`); remove those the same way if you only want the router.

- **Skills installed via `aws configure agent-toolkit` or `add-skill`:** The interactive `aws configure agent-toolkit` wizard installs default skills and configures the AWS MCP Server. Remove skills installed by the wizard or `aws agent-toolkit add-skill` with:
  1. List what is currently installed:
     ```bash
     aws agent-toolkit list-installed-skills --agent claude-code
     ```
  2. Remove each installed skill:
     ```bash
     aws agent-toolkit remove-skill --skill-name <name> --agent claude-code
     ```

You can keep `aws-core` instead of this router if you prefer the bundled MCP setup; do not install both — they overlap and `aws-core`'s skills are what this router replaces.

## Requirements and limits

- **AWS CLI ≥ 2.35.0** is required for CLI mode (`aws agent-toolkit`).
- **Region:** The Agent Toolkit catalog is available only in `us-east-1`. Every catalog command in the router passes `--region us-east-1`, independent of your configured default region.
- **Latency and network:** Each skill load adds 1–3 CLI calls (or MCP calls) and requires network access to the AWS catalog.
- **Non-interactive mode (`claude -p`):** You must additionally allow the router skill tool, for example `--allowedTools "Skill(aws)"` (or `--allowedTools "Skill(aws-skill-router:aws)"` if installed as a Claude Code plugin).
- **Agent compatibility (`allowed-tools`):** The `allowed-tools` field in `skills/aws/SKILL.md` uses the Claude Code list form; other agents ignore it and the skill works without it (it only pre-approves the read-only catalog commands).
- **Tested on:** macOS (router, plugin install, measurement script) and Linux (CI). The PowerShell script and Windows usage have not been tested by the maintainer yet.

## Security

- **Official source:** Skill content is fetched directly from the official Agent Toolkit for AWS catalog.
- **No credentials for catalog reads:** All catalog queries pass `--no-sign-request` and do not require AWS credentials or an active session.
- **No installed copies:** The router does not install or cache official skills; fetched content exists only in the agent's session.
- **Fetched scripts:** The router instructs the agent to save any script from a skill's `scripts/` directory to a temporary directory and read it in full before running it.
- **Account changes:** The router instructs the agent to confirm with you before any command that creates, changes, or deletes AWS resources; such commands need your own valid credentials.

## Reproduce the numbers

Use the included measurement scripts to compare prompt tokens across three isolated temporary environments (`A-baseline`, `B-official`, and `C-router`). The scripts never install into or modify your skills directory (official skills are installed into a temporary `HOME`). By default, they ignore your user-level settings, skills, and plugins (`--setting-sources project,local`) so the three environments differ only in their project skills; pass `--include-user-config` (`-IncludeUserConfig` on PowerShell) to include your real setup (for example, to observe skill-listing truncation). Absolute totals vary by machine; the differences (`B − A`, `C − A`) are what to compare.

To reproduce the table above, clone `https://github.com/aws/agent-toolkit-for-aws` and point `--skills-dir` (PowerShell: `-SkillsDir`) at its `aws-core` skills directory:

```bash
./scripts/measure-tokens.sh --skills-dir <clone>/plugins/aws-core/skills
```

Without `--skills-dir`, the default installs the 39 skills named in the router's table via `aws agent-toolkit add-skill` instead.

> **API usage note:** Each script runs `claude -p` 9 times by default (3 environments × 3 runs) and costs a small amount of API usage. Both scripts ask for confirmation (`y/N`) before running unless `--yes` / `-Yes` is passed.

### macOS / Linux (Bash)

```bash
./scripts/measure-tokens.sh
```

Options:
- `--skills-dir DIR` — Copy every subdirectory containing `SKILL.md` from `DIR` into `B-official` instead of downloading via `aws agent-toolkit add-skill`.
- `--skills "a,b,c"` — Comma-separated list of official skill names to install via `add-skill` (defaults to the unique skill names in `skills/aws/SKILL.md`).
- `--runs N` — Number of runs per environment (default: `3`).
- `--include-user-config` — Include your user-level settings, skills, and plugins (omits `--setting-sources project,local`).
- `--keep` — Keep the temporary directory after the script finishes.
- `--yes` — Skip the confirmation prompt.

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\measure-tokens.ps1
# Or with PowerShell 7+:
pwsh -ExecutionPolicy Bypass -File .\scripts\measure-tokens.ps1
```

Options:
- `-SkillsDir DIR` — Copy every subdirectory containing `SKILL.md` from `DIR` into `B-official`.
- `-Skills "a,b,c"` — Comma-separated list of official skill names to install via `add-skill` (defaults to the unique skill names in `skills/aws/SKILL.md`).
- `-Runs N` — Number of runs per environment (default: `3`).
- `-IncludeUserConfig` — Include your user-level settings, skills, and plugins (omits `--setting-sources project,local`).
- `-Keep` — Keep the temporary directory after the script finishes.
- `-Yes` — Skip the confirmation prompt.

## License

This repository is licensed under the [MIT License](LICENSE).

Official AWS skills are licensed under Apache-2.0 and are fetched at run time from the AWS catalog; no official AWS skill content is redistributed in this repository.
