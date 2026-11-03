<div align="center">

# agent-orchestration

**贵的模型负责想，便宜的模型负责干。**

一套 Claude Code skill，让一个 Claude 会话当"主代理"：它负责规划、写任务书、派活、验收、拍板；成批的杂活和第二意见交给更便宜或别家的代理（DeepSeek、Codex、Claude CLI）去做。

[English](README.md) | 简体中文

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)
![Deps](https://img.shields.io/badge/deps-python3%20stdlib%20%2B%20bash-green.svg)
![Works with](https://img.shields.io/badge/works%20with-Claude%20Code%20%7C%20Codex-orange.svg)

</div>

---

## 为什么需要它

用顶级模型做长时间、真实环境的任务，大概率会遇到这些问题：

- **什么都自己干。** 扫 300 个文件、写样板脚本、读几兆日志，这些活便宜 10 倍的模型也能干，却在烧主模型的上下文和钱。
- **"完成了"不等于完成了。** 子代理说成功了，没人去看 diff。
- **会话越长越笨。** 干了几个小时上下文很大，你一走开缓存就冷了，回来时它已经开始不看自己的规则。
- **要么问太多，要么问太少。** 五分钟打断你一次，或者不打招呼就执行了不可逆的操作。

这个仓库就是我们在一个持续数周的真实基础设施恢复项目里，用来解决这些问题的那套规则，打包成一条命令就能在任何电脑上装好。

## 包含什么

| skill | 作用 |
|---|---|
| **`subagent-dispatch`** | 什么时候该派活、什么时候不该；怎么写便宜模型不会读歪的任务书；怎么验收。附带 `run_worker.py`，一个 runner 同时支持 **DeepSeek Harness**、**Claude CLI**、**Codex**：每次运行都留下证据（`task.txt`、`request.json`、日志、`summary.json`），从不自动重跑、也不自动换模型。还附带 `check_progress.py`，扫子代理的命令记录，找出不可逆（L3）操作和对受保护路径的写操作。 |
| **`session-orchestration`** | 跨多个会话的长任务怎么协作：一个**主会话**负责和你沟通，**子会话**和子代理通过文件回报；L0–L3 风险级别决定谁能做什么；收件箱和索引让新会话只读少量文档就能接手；主会话上下文太大时按**换届流程**交给新会话。 |

### 亮点

- 💸 **默认分层省钱。** 边界清楚的常规活（批量扫描、哈希比对、写脚本、补测试、资料归纳）自动派给 DeepSeek，主代理只管方向、审查和决定。
- 🧾 **看证据，不听自述。** `handoff_ok` 只说明传输正常。主代理必须亲自打开 diff、跑测试，对照任务书逐条检查。
- 🔍 **跨模型评审有护栏。** Claude CLI 跑在无工具或只读工具、受限模式、关掉 fast mode 的状态下；Codex 跑在只读沙箱、不联网。每个任务默认只评审一轮，多了要你同意。
- 🛑 **机械停点。** 碰真实系统的子代理每条命令、每次改动都要记录，到固定停点就停，不靠它自己判断什么时候该问。
- 🔁 **上下文换届。** 主会话超过约 20 万 token，或你要离开一段时间时，它写一份 ≤2 KB 的交接便签，启动继任者，把子会话转到继任者名下，然后归档自己。
- 🪶 **轻量。** Markdown + Python 标准库 + bash。不需要 Node、MCP 服务器或常驻进程。以符号链接安装，`git pull` 一下所有设备都更新。
- 🔐 **个人信息不进 git。** CLI 路径、授权记录、每台机器的模型 ID 都放在 `~/.config/agent-orchestration/`。

## 和同类项目比较

下面这些项目解决的是相邻的问题，其中几个可以和本项目一起用。

| | agent-orchestration | [Ruflo（原 claude-flow）](https://github.com/ruvnet/ruflo) | [Superpowers](https://github.com/obra/superpowers) | [PAL MCP（原 Zen）](https://github.com/BeehiveInnovations/pal-mcp-server) | [claude-code-router](https://github.com/musistudio/claude-code-router) | [Claude Squad](https://github.com/smtg-ai/claude-squad) / [CCManager](https://github.com/kbwo/ccmanager) |
|---|---|---|---|---|---|---|
| 是什么 | 规则（skill）+ 小 runner | 完整的蜂群平台，带 100+ 代理的 MCP 服务器 | 一套软件开发方法论 skill | 调用其他模型的 MCP 服务器 | 把整个会话转到别的模型的网关 | 并行管理多个会话的终端界面 |
| 主模型掌舵、便宜模型做局部 | ✅ 核心理念 | 部分（路由） | —（同一模型） | ✅ 用于咨询 | ❌ 直接替换模型 | — |
| 委派门槛和任务书规范 | ✅ | — | ✅（计划） | — | — | — |
| 独立验收、每次运行留证据 | ✅ `summary.json` | 日志 | 评审步骤 | — | — | — |
| 和人沟通的规矩（谁问、问什么、何时问） | ✅ | — | 部分 | — | — | — |
| 真实基础设施操作的风险分级与审计 | ✅ L0–L3 + 审计脚本 | — | — | — | — | — |
| 上下文换届流程 | ✅ | 记忆数据库 | — | — | — | — |
| 安装负担 | `./install.sh`，只用标准库 | npm / MCP | 插件 | Python MCP 服务器 | Node / 桌面应用 | brew / npm，需要 tmux |

**适合用它的场景：** 你希望 Claude（或 Codex）在长期、复杂、真实的任务里（不只是写代码，也包括运维）一直当大脑，花得更少，又不牺牲验收。
**更适合用别的：** 想要大规模自主蜂群（Ruflo）；想要严格的 TDD 编码流程（Superpowers，可以和本项目一起用）；只是想让 Claude Code 跑在别的模型上（claude-code-router）。

## 快速开始

```bash
git clone https://github.com/lightrivers/agent-orchestration.git ~/agent-orchestration
cd ~/agent-orchestration && ./install.sh
```

然后初始化一个项目。这一步会往它的 `CLAUDE.md` 加一小段约定，并建好带模板的 `work/`、`outputs/`：

```bash
~/agent-orchestration/install.sh --project-only ~/my-project
```

在 Claude Code 里打开这个项目照常工作。任务合适时 skill 会自动触发，也可以用 `/subagent-dispatch`、`/session-orchestration` 直接调用。

<details>
<summary>全部安装选项</summary>

```text
./install.sh                     把 skill 链接到 ~/.claude/skills，创建 ~/.config/agent-orchestration
./install.sh --codex             同时链接到 ~/.codex/skills
./install.sh --copy              复制而不是链接
./install.sh --project DIR       安装并初始化项目
./install.sh --project-only DIR  只初始化项目
./install.sh --check             跑离线测试，报告 skill 和 CLI 状态（不改任何东西）
./uninstall.sh [--purge]         删除链接或复制目录；--purge 连配置目录一起删
```

环境变量 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`AGENT_ORCH_HOME` 可以改默认位置。

也可以作为插件安装（`/plugin marketplace add lightrivers/agent-orchestration`，再 `/plugin install agent-orchestration`）。插件方式不会创建本机配置，所以仍建议跑一次 `./install.sh`。
</details>

## 工作原理

```text
            你
             │  （只有主会话找你，问题攒起来一次问）
             ▼
   ┌──────────────────┐     任务书      ┌────────────────────────┐
   │      主会话      │ ──────────────▶ │  DeepSeek 子代理（便宜）│
   │ 规划·决定·验收   │ ◀────────────── │  run_worker.py → 日志 + │
   │ 执行 L3          │  summary.json   │  summary.json          │
   └──────────────────┘                 └────────────────────────┘
      │         ▲  SendMessage / 收件箱
      │         │
      ▼         │                        ┌────────────────────────┐
   ┌──────────────────┐      方案       │  Claude CLI / Codex     │
   │      子会话      │ ──────────────▶ │  独立评审              │
   │ 一个会话一个交付物│                 │ （只读，一轮）          │
   └──────────────────┘                 └────────────────────────┘
```

1. 主会话判断：1–2 条命令自己做；L3 准备好再问人；边界清楚派 DeepSeek；能独立交付的开新子会话。
2. 每份任务书都写清目标、证据、范围、步骤、**验收标准**、交付格式。
3. runner 在后台执行并记录一切，主会话自己验收结果。
4. 重要方案执行前做一次跨模型评审。
5. 文档先汇入 `outputs/_收件箱.md`，由便宜的"整理员"子代理归并进状态文件，主会话只审 diff。

## 配置

| 文件 | 用途 |
|---|---|
| `~/.config/agent-orchestration/config.json` | CLI 路径（自动探测）和 `protected_paths`：子代理往这些路径写东西会报 HIGH |
| `~/.config/agent-orchestration/authorizations.md` | 你批准过的代理、模型和范围。只有列在这里的，主会话才会不问你就调用。 |
| `<项目>/CLAUDE.md` | `--project-only` 加的那一小段，里面留了写**本项目专属 L3 操作**的位置 |

CLI 查找顺序：`--cli` → `AGENT_ORCH_{DEEPSEEK,CODEX,CLAUDE}_CLI` → `config.json` → 内置默认。

## 依赖

- 必需：`python3` ≥ 3.9、`bash`、`git`。
- 按需（每个子代理一项）：[DeepSeek Harness Desktop](https://www.deepseek.com/)（默认执行者；设置 `DEEPSEEK_API_KEY` 或在应用里保存密钥）、[Claude Code](https://claude.com/claude-code) CLI（评审）、Codex CLI（评审或备用执行）。没装的子代理只是不能调用。
- 子会话相关工具（`start_session`、`SendMessage`、`detach_session` 等）属于 **Claude Desktop** 的 Code 页。在 CLI 里改用另开终端会话、回报写文件。

## 常见问题

**skill 内容是中文的，用英文聊天能用吗？**
能。不管你用什么语言聊天，Claude 都会读懂并照做。欢迎提 PR 补英文版 skill。

**必须用 DeepSeek 吗？**
不必。选它当默认执行者是因为快且便宜。可以用 `--cli` 指向别的 CLI，或者扩展 `run_worker.py`。

**它会自己花钱吗？**
只在 `authorizations.md` 授权的范围内。新模型、新供应商或可能明显产生费用的调用都要先问你。runner 从不自动重跑或自动换模型。

**怎么更新？**
`git pull`。链接安装立即生效；复制安装要再跑一次 `./install.sh --copy`。

## 目录结构

```text
skills/
  subagent-dispatch/      SKILL.md · reference/ · templates/task-brief.md · scripts/ · tests/
  session-orchestration/  SKILL.md · handover.md · sub-session.md · organizer-brief.md
templates/                配置、授权、CLAUDE.md 片段、项目文件模板
install.sh · uninstall.sh · tests/test_install.sh
```

## 参与贡献

欢迎提 issue 和 PR。提交前请运行：

```bash
./install.sh --check && bash tests/test_install.sh
```

## 许可证

[MIT](LICENSE)
