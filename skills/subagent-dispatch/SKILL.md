---
name: subagent-dispatch
description: 选择、调用、验收外部子代理（DeepSeek 默认执行者、Claude CLI / Codex 评审）。当任务是低、中难度且边界清楚的批量或脚本工作（多文件扫描、哈希比对、格式转换、写脚本、补测试、按模板生成文档、资料归纳），或需要对重要方案做跨模型独立评审，或要派 DeepSeek 模型的 Desktop 子会话时使用。
---

# 子代理调用指南

本文中 `$SKILL` 指本 skill 所在目录（加载时显示的 Base directory；`install.sh` 默认装在 `~/.claude/skills/subagent-dispatch`）。本机专属的东西不在仓库里，在配置目录 `$AGENT_ORCH_HOME`（默认 `~/.config/agent-orchestration/`）：

- `config.json`：三个 CLI 的路径、受保护路径列表。
- `authorizations.md`：本机的授权记录、Desktop 子会话模型 ID、核实结论。

Claude Code 或 Codex 作为主代理时都按本文件执行。

## 分工

- **主代理**：规划、拆分任务、写任务书、审核产物、做决定，对最终结果负责。
- **DeepSeek**：默认执行者，批量处理边界清楚的低、中难度任务。
- **评审**：重要方案在实施前交另一个模型独立评审。Claude 主代理找 Codex，Codex 主代理找 Claude CLI；也可以按需找同模型复核，但要在报告中标明。

## 什么时候应该委派

低、中难度、在授权范围内、主代理能快速验收（有测试、diff、清单或可抽查的输出）的任务，属于下面任一类时，默认交给 DeepSeek，不需要先问用户：

- 批量、重复的工作：多文件扫描、哈希比对、格式转换、批量改写、结果整理。
- 边界清楚的实现：写脚本、补测试、按明确规格改代码、按模板生成文档。
- 读得多、想得少的工作：通读大量文件后按指定问题汇总，资料归纳。

下面这些由主代理自己做：

- 一两条命令就能完成的检查。
- 需求还说不清楚、要先和用户确认的问题。
- 每一步都依赖上一步结果、强耦合的改动，拆开反而更慢。
- 需要把密钥、密码、2FA、cookie 写进任务书或日志的任务。（凭据应由脚本从钥匙串等处读取，不经过模型。）

边界清楚但拿不准是否值得委派时，倾向于委派：写任务书的过程本身能帮主代理理清问题，DeepSeek 失败的代价通常只是几分钟和少量 token。会直接改动正式文件、难以回滚的任务，先让它改副本。

## 任务书要求

DeepSeek 响应快，但质量依赖任务边界和验收条件是否明确。派发前补齐以下信息；缺项无法从上下文推断时先澄清，不要写成"帮我看看""优化一下"这类许愿式指令。涉及改动真实环境（服务器、配置）的任务，套用 `$SKILL/templates/task-brief.md`（风险级别、变更记录、机械停点）。

- **目标**：要实现或回答什么，完成后应看到什么结果。
- **背景与证据**：相关文件、现状、已知约束和主代理已经确认的事实。
- **范围**：允许改哪些文件、哪些内容不应改；读写、联网和命令权限分别写清楚。
- **步骤与判断**：需要先检查什么，遇到歧义时如何处理；要求标出假设，不自行扩大范围。
- **验收标准**：可执行的检查、预期结果和失败条件，不只写"质量好"或"没有问题"。
- **交付格式**：改动文件、关键决定、测试结果、未完成项；需要机器处理时再要求 JSON。

## 拆分与并行

- 复杂任务拆成范围不重叠、能独立验收的子任务。
- 有依赖关系的子任务串行执行；没有依赖的可以并行派发。
- 同一个文件同一时间只给一个子代理写。并行任务不要跑全仓格式化、git 操作或共享构建缓存。
- 对重要文件，先让子代理改副本，主代理验收后再落到正式位置。
- 所有子任务完成后，由主代理整合，再统一验收。

## 调用与验收流程

1. 任务文件写在调用方工作区：`work/tasks/<任务名>.txt`；运行记录放 `work/worker-runs`。runner 给每次运行生成独立目录，多个主代理同时调用不会冲突。
2. 后台运行 runner（Claude 用 Bash `run_in_background`），不要用前台命令等待。
3. 进程退出后读 `summary.json`。`handoff_ok` 只说明传输层正常（退出码、完成事件、权限拒绝、schema），不代表任务完成。
4. 主代理亲自验收：打开改动过的文件、看 diff、跑测试，对照任务书逐条检查。不以子代理自称完成代替验收。
5. 调研类结果要抽查来源链接是否存在（子代理列出的链接曾出现 404）。

任务文件和运行记录（`task.txt`、`request.json`、日志、`summary.json`）都会落盘：不要把密钥、token、密码或个人数据写进任务文件。

## 入口

从调用方工作区根目录运行：

```sh
R=$SKILL/scripts/run_worker.py
mkdir -p work/tasks work/worker-runs
# DeepSeek：默认执行者
python3 -B $R deepseek --cwd "$PWD" --task-file work/tasks/X.txt --runs-dir work/worker-runs
# Claude 评审：先准备 work/reviews/X/ 专用目录和脱敏证据
python3 -B $R claude --cwd work/reviews/X --task-file work/tasks/X.txt --runs-dir work/worker-runs
python3 -B $R claude ... --tools Read,Glob,Grep              # 只读专用证据目录
python3 -B $R claude ... --max-budget-usd 1                 # 可选：设 CLI 估算停止阈值
# Codex 评审：只读
python3 -B $R codex --cwd work/reviews/X --task-file work/tasks/X.txt --runs-dir work/worker-runs --sandbox read-only
# Codex 备用执行：只能写 --cwd
python3 -B $R codex --cwd work/X --task-file work/tasks/X.txt --runs-dir work/worker-runs
# 通用选项
python3 -B $R <worker> ... --resume <session_id>            # 续做（Claude 续审需先获授权）
python3 -B $R <worker> ... --schema work/tasks/X.schema.json # 结构化输出（Codex / Claude）
python3 -B $R <worker> ... --cli /path/to/cli               # 临时指定 CLI
python3 -B $R <worker> ... --keep-session                   # 不归档这次的会话记录（DeepSeek / Claude）
```

工作目录与会话记录：
- 每次调用 CLI，它都会按 `--cwd` 在自己的会话目录里记一条会话（DSH：`~/.dsh/sessions/<目录编码>/`；Claude：`~/.claude/projects/<目录编码>/`）。DSH Desktop、AgentsAnywhere 这类软件扫描这些目录，所以每换一个 `--cwd` 侧栏就多一个工作区，每跑一次就多一条会话。
- `--cwd` 用固定目录：DeepSeek 一律用调用方工作区根目录；评审用 `work/reviews/<X>/`。不要用系统临时目录、`C:\Windows\System32`、家目录这类目录，也不要为了"干净"每次新建一个目录。
- runner 跑完后自动把这次的会话记录挪进 `$AGENT_ORCH_HOME/session-archive/<worker>/`（DeepSeek、Claude），挪空的工作区目录一并删掉，侧栏就不会再出现它们；结果记在 `summary.json` 的 `session_archive`。`--resume <id>` 时先按清单挪回原处再续做，跑完再归档。要在软件里打开这条会话时加 `--keep-session`。
- Codex 的会话状态在它自己的 sqlite 里，runner 不动；一次性评审加 `--ephemeral`。

CLI 路径的查找顺序：`--cli` → 环境变量 `AGENT_ORCH_DEEPSEEK_CLI` / `AGENT_ORCH_CODEX_CLI` / `AGENT_ORCH_CLAUDE_CLI` → `config.json` 的 `cli.<worker>` → 内置默认（macOS 用应用包内路径，Claude 取 PATH 上的 `claude`；其他系统一律从 PATH 找）。实际用的路径和来源记在 `request.json` 的 `cli_path` / `cli_source`。

Windows 上：
- 文中的 `python3` 换成 `python` 或 `py -3`，路径分隔符用 `\`；Bash 工具里用 Git Bash 时照原样即可。
- CLI 要指向真正的 `.exe`。npm 装的 `codex.cmd` 这类 `.cmd` / `.bat` 垫片会被 runner 拒绝，因为 `cmd.exe` 会截断多行任务文本。
- 例外（仅 Windows）：DeepSeek Harness 在 Windows 上只提供 `<安装目录>\resources\runtime\cli\bin\dsh.cmd`。`cli.deepseek` 直接填它即可，runner 会认出这个布局，绕过 `cmd.exe` 直接启动 `DeepSeek Harness.exe`（`request.json` 里记 `windows_electron_launcher: true`）。macOS 不走这段逻辑，Mac 上不用运行或验证。
- DeepSeek 密钥最省事的给法是设置用户环境变量 `DEEPSEEK_API_KEY`。
- 超时后 runner 用 `taskkill /T /F` 结束整个进程树。

监督改动真实环境的子代理时，用 `$SKILL/scripts/check_progress.py <任务目录>` 扫它写的 `progress.md` / `changes.md`（退出码 2 = 有 HIGH 报警，1 = 只有 MEDIUM）。受保护路径来自 `config.json` 的 `protected_paths` 和 `--protected-path`。

## 失败处理

所有 worker 都一样：runner 不自动重跑，失败后先查清原因再决定。

- **先看已有结果**：读 `summary.json` 的 `state`、错误和日志，再看工作区 diff。子代理可能已经改完，只是退出阶段失败。
- **超时或输出被截断**：DeepSeek 官方渠道单次请求最多输出 32k token（`scripts/dsh-task.patch.yml` 的 `maxTokens`）。把任务拆小后重新派发，不要原样重跑。
- **只完成一部分**：有 `session_id` 时用 `--resume <id>` 续做，任务文件写明"已完成 X，继续未完成的 Y"。
- **结果不对**：先检查任务书是否含糊，修改任务书后再派一次。同一任务失败两次，由主代理接手。
- **鉴权失败、要求付费、模型不可用**：停止并报告，不要自动换模型或供应商。

## DeepSeek：默认执行者

- 模型跟随 DSH Desktop：runner 每次运行读取 `$DSH_HOME/profiles/desktop/cordis.patch.yml` 里的 `agent-default-model`（即 Desktop 模型选择器当前的渠道和模型），生成一层叠加 patch 放进运行目录（`dsh-desktop-selection.patch.yml`），叠在 `scripts/dsh-task.patch.yml` 之上。DSH Desktop 在任意会话的输入框里切换模型（含 effort），都会同时改写这个全局默认，所以子代理用的是用户最后一次切换的选择；设置 > 模型页只管渠道和密钥，不选模型。子代理下次运行就跟着换，不用改 skill。实际用的渠道记在 `request.json` 的 `config_source` / `config_provider` / `config_model`，汇报时要说明。
- 只允许 `DSH_ALLOWED_PROVIDERS` 里的渠道（`deepseek-official`、`opencode-go`）；Desktop 选了别的渠道（例如 `deepseek-account`），runner 直接报错、不启动。增加渠道要先取得用户授权，再改这个常量。
- 插件渠道：Desktop 选的渠道来自插件时（目前是 `dsh-opencode-go` 插件），headless 不加载插件，runner 按 `DSH_PLUGIN_PROVIDER_ROUTES` 改走同一网关的内置渠道（`dsh-opencode-go` → `opencode-go`），模型和 effort 不变，key 用插件配置里的 `apiKeyEnv`。只有 DSH 内置目录里有的模型能这样跑（如 `deepseek-v4.1-flash`）；插件独有的新模型（如 `gemini-4-argon`、`kimi-k3.1-pro`）会被 DSH 拒绝，这时用 `--patch` 或 Desktop 子会话。`request.json` 的 `config_desktop_provider` 记录 Desktop 原本选的渠道。
- Desktop 从没选过模型时用 `scripts/dsh-task.patch.yml` 的默认值：provider `deepseek-official`，endpoint `https://api.deepseek.com/anthropic`，模型 `deepseek-flash` / `high`。传 `--patch` 时完全手动，不读 Desktop。
- 入口：官方 DeepSeek Harness Desktop 包内的 CLI（macOS 默认 `/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh`）。不依赖 PATH 上的其他 `dsh`；别的位置用 `config.json` 指定。
- 凭据：所选渠道的 key 环境变量（官方为 `DEEPSEEK_API_KEY`，其他渠道取 Desktop 配置里的 `apiKeyEnv`，如 `OPENCODE_GO_API_KEY`）。优先用已有的环境变量，未设置时只从 `$DSH_HOME/.credentials.yaml`（默认 `~/.dsh/.credentials.yaml`）读取这一个键。读 Desktop 配置需要 `ruby`（允许插件写入的未加引号时间戳）。运行记录不保存密钥。
- 超时：默认总时长 600 秒，连续 300 秒无输出判为卡住。需要更长时调大 `--timeout` / `--idle-timeout`，但优先拆小任务。
- 完成条件：`turn_end.reason.kind=completed`。

## 其他执行方式（按需读）

- 需要多轮、用户能打开查看插话的工作（持续 SSH 排查、陪用户在界面上操作），且主代理在 Claude Desktop：读 `$SKILL/reference/desktop-session.md`。
- 要找 Claude CLI 做独立评审：读 `$SKILL/reference/claude-review.md`。
- 要找 Codex 做评审或备用执行：读 `$SKILL/reference/codex.md`。

## 授权与维护

- 授权记录在 `$AGENT_ORCH_HOME/authorizations.md`。读到有效记录就直接调用，不再重复询问；用户新给的授权要写进去。
- 记录没有覆盖的调用（新模型、新供应商、可能产生明显费用的调用），先说明 Agent、模型、范围和原因，征得同意后再调用。
- `requested_model` 只能证明请求了什么，不能证明服务端实际用了哪个模型或如何计费。
- 修改 runner 或本指南后，运行 `python3 -B $SKILL/tests/test_worker.py` 和 `python3 -B $SKILL/tests/test_check_progress.py`（离线，不调用模型）。改动规则本身应提交到 skill 所在的 git 仓库，本机专属内容只写进配置目录。
