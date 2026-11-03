<div align="center">

# agent-orchestration

**Let your expensive model think, and let cheap models do the work.**

A set of Claude Code skills that turn one Claude session into a *lead*. The lead plans, writes task briefs, delegates, verifies and decides. Cheaper or cross-vendor agents (DeepSeek, Codex, Claude CLI) do the bulk work and the second opinions.

English | [简体中文](README.zh-CN.md)

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)
![Deps](https://img.shields.io/badge/deps-python3%20stdlib%20%2B%20bash-green.svg)
![Works with](https://img.shields.io/badge/works%20with-Claude%20Code%20%7C%20Codex-orange.svg)

</div>

---

## Why

If you use a frontier model for long, real-world tasks, you have probably hit these problems:

- **It does everything itself.** It scans 300 files, writes boilerplate scripts and reads megabytes of logs. That burns context and money on work a model 10× cheaper could do.
- **"Done" is not done.** Sub-agents say they succeeded, and nobody checks the diff.
- **Long sessions go bad.** After hours of work the context is huge, the cache is cold when you come back, and the model starts ignoring its own rules.
- **Too many questions, or too few.** It either interrupts you every five minutes, or it runs something irreversible without asking.

This repository is the rulebook that fixed these problems for us during a multi-week, real-infrastructure recovery project. It is packaged so you can install it on any machine with one command.

## What you get

| Skill | What it does |
|---|---|
| **`subagent-dispatch`** | When to delegate and when not to, how to write a task brief a cheap model can't misread, and how to accept results. It ships with `run_worker.py`, one runner for **DeepSeek Harness**, **Claude CLI** and **Codex**. Every run leaves an evidence trail (`task.txt`, `request.json`, logs, `summary.json`), and the runner never retries or switches models on its own. It also ships with `check_progress.py`, which audits a worker's command log for irreversible (L3) operations and writes to protected paths. |
| **`session-orchestration`** | A protocol for long tasks that span many sessions. One **lead session** talks to you. **Sub-sessions** and workers report back through files. Risk levels L0–L3 decide who may do what. An inbox and an index keep the docs readable for new sessions, and a **handover procedure** moves the lead to a fresh session when its context gets too large. |

### Highlights

- 💸 **Cost-tiered by default.** Routine, clearly bounded work (bulk scans, hashing, scripts, tests, summaries) goes to DeepSeek automatically. The lead keeps direction, review and decisions.
- 🧾 **Evidence over claims.** `handoff_ok` only means the transport worked. The lead must open the diff, run the tests and check the brief line by line.
- 🔍 **Cross-vendor review with guardrails.** Claude CLI runs with no tools or with read-only tools, in restricted mode, with fast mode off. Codex runs in a read-only sandbox with no network. One review round per task unless you approve more.
- 🛑 **Mechanical stop points.** Workers that touch real systems log every command and change and stop at fixed checkpoints. They never decide on their own when to ask.
- 🔁 **Context handover.** When the lead passes about 200k tokens, or you are about to leave for a while, it writes a ≤2 KB handover note, starts its successor, detaches the sub-sessions and archives itself.
- 🪶 **Lightweight.** Markdown, Python standard library and bash. No Node, no MCP server, no daemon. Installed as symlinks, so `git pull` updates every machine.
- 🔐 **Nothing personal in git.** CLI paths, authorizations and per-machine model IDs live in `~/.config/agent-orchestration/`.

## How it compares

These projects solve neighbouring problems, and several of them combine well with this one.

| | agent-orchestration | [Ruflo (claude-flow)](https://github.com/ruvnet/ruflo) | [Superpowers](https://github.com/obra/superpowers) | [PAL MCP (Zen)](https://github.com/BeehiveInnovations/pal-mcp-server) | [claude-code-router](https://github.com/musistudio/claude-code-router) | [Claude Squad](https://github.com/smtg-ai/claude-squad) / [CCManager](https://github.com/kbwo/ccmanager) |
|---|---|---|---|---|---|---|
| What it is | Rules (skills) + small runner | Full swarm platform, MCP server with 100+ agents | Skills for a software methodology | MCP server for calling other models | Gateway that reroutes the whole session | Terminal UI for parallel sessions |
| Main model stays in charge, cheap model does pieces | ✅ core idea | partly (routing) | — (same model) | ✅ for consults | ❌ replaces the model | — |
| Delegation thresholds and task-brief contract | ✅ | — | ✅ (plans) | — | — | — |
| Independent acceptance and evidence trail per run | ✅ `summary.json` | logs | review step | — | — | — |
| Protocol for talking to the human (who asks what, when) | ✅ | — | partly | — | — | — |
| Risk levels and audit for real-infrastructure ops | ✅ L0–L3 + auditor | — | — | — | — | — |
| Context-handover procedure | ✅ | memory DB | — | — | — | — |
| Install weight | `./install.sh`, stdlib only | npm / MCP | plugin | Python MCP server | Node / desktop app | brew / npm, tmux |

**Choose agent-orchestration when** you want Claude (or Codex) to stay the brain on long, messy, real-world tasks, including ops work and not only coding, and to spend less without giving up verification.
**Choose something else when** you want a big autonomous swarm (Ruflo), a strict TDD coding workflow (Superpowers, which works alongside this), or simply to run Claude Code on another provider (claude-code-router).

## Quick start

```bash
git clone https://github.com/lightrivers/agent-orchestration.git ~/agent-orchestration
cd ~/agent-orchestration && ./install.sh
```

Then set up a project, which adds a short section to its `CLAUDE.md` and creates `work/` and `outputs/` with templates:

```bash
~/agent-orchestration/install.sh --project-only ~/my-project
```

Open the project in Claude Code and work as usual. The skills trigger on their own when a task fits, or you can call them directly with `/subagent-dispatch` and `/session-orchestration`.

<details>
<summary>All installer options</summary>

```text
./install.sh                     link skills into ~/.claude/skills, create ~/.config/agent-orchestration
./install.sh --codex             also link into ~/.codex/skills
./install.sh --copy              copy instead of symlink
./install.sh --project DIR       install and initialize a project
./install.sh --project-only DIR  only initialize a project
./install.sh --check             run offline tests, report skill and CLI status (changes nothing)
./uninstall.sh [--purge]         remove links/copies; --purge also deletes the config dir
```

Override locations with `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `AGENT_ORCH_HOME`.

You can also install it as a plugin (`/plugin marketplace add lightrivers/agent-orchestration`, then `/plugin install agent-orchestration`). The plugin route does not create the per-machine config, so run `./install.sh` once anyway.
</details>

## How it works

```text
            you
             │  (only the lead asks you; questions are batched)
             ▼
   ┌──────────────────┐   task brief    ┌────────────────────────┐
   │   Lead session   │ ──────────────▶ │ DeepSeek worker (cheap)│
   │ plan · decide ·  │ ◀────────────── │ run_worker.py → logs + │
   │ verify · L3 ops  │  summary.json   │ summary.json           │
   └──────────────────┘                 └────────────────────────┘
      │         ▲  SendMessage / inbox
      │         │
      ▼         │                        ┌────────────────────────┐
   ┌──────────────────┐   proposal      │ Claude CLI / Codex     │
   │  Sub-sessions    │ ──────────────▶ │ independent review     │
   │ one deliverable  │                 │ (read-only, one round) │
   └──────────────────┘                 └────────────────────────┘
```

1. The lead decides: 1–2 commands → do it myself. L3 → prepare it and ask the human. Clearly bounded → DeepSeek. Separate deliverable → new sub-session.
2. Every brief states the goal, evidence, scope, steps, **acceptance tests** and output format.
3. The runner executes it in the background and records everything. The lead verifies the result itself.
4. Important plans get one cross-vendor review before they are carried out.
5. Docs flow into `outputs/_收件箱.md` (the inbox). A cheap "organizer" worker folds them into the status file, and the lead only reviews the diff.

## Configuration

| File | Purpose |
|---|---|
| `~/.config/agent-orchestration/config.json` | CLI paths (auto-detected) and `protected_paths`: any worker write there raises a HIGH alert |
| `~/.config/agent-orchestration/authorizations.md` | What you have approved: agents, models and scopes. The lead calls an agent without asking only if it is listed here. |
| `<project>/CLAUDE.md` | The short section added by `--project-only`, including a slot for **project-specific L3 operations** |

CLI lookup order: `--cli` → `AGENT_ORCH_{DEEPSEEK,CODEX,CLAUDE}_CLI` → `config.json` → built-in default.

## Requirements

- Required: `python3` ≥ 3.9, `bash`, `git`.
- Optional, one per worker: [DeepSeek Harness Desktop](https://www.deepseek.com/) (default worker; set `DEEPSEEK_API_KEY` or save the key in the app), [Claude Code](https://claude.com/claude-code) CLI (reviewer) and Codex CLI (reviewer or fallback worker). Workers you don't have are simply unavailable.
- The sub-session tools (`start_session`, `SendMessage`, `detach_session` …) belong to the **Claude Desktop** Code tab. In the CLI, use separate terminal sessions and file-based reports instead.

## FAQ

**The skill text is in Chinese. Will it work for me?**
Yes. Claude reads and follows it regardless of the language you chat in. An English translation of the skills is welcome as a PR.

**Do I need DeepSeek?**
No. It is the default worker because it is fast and cheap. You can point the runner at another CLI with `--cli`, or extend `run_worker.py`.

**Does it spend money on its own?**
Only within `authorizations.md`. New models, providers or anything that may cost noticeably require your approval first. The runner never retries or falls back automatically.

**How do I update?**
Run `git pull`. Symlinked installs update immediately. For copied installs, run `./install.sh --copy` again.

## Project layout

```text
skills/
  subagent-dispatch/      SKILL.md · reference/ · templates/task-brief.md · scripts/ · tests/
  session-orchestration/  SKILL.md · handover.md · sub-session.md · organizer-brief.md
templates/                config, authorizations, CLAUDE.md snippet, project files
install.sh · uninstall.sh · tests/test_install.sh
```

## Contributing

Issues and PRs are welcome. Before submitting, run:

```bash
./install.sh --check && bash tests/test_install.sh
```

## License

[MIT](LICENSE)
