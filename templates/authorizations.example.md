# 子代理授权记录（本机）

主代理读到有效记录就直接调用，不再重复询问。新增授权时写明日期、Agent、模型、范围。
本文件只存在于本机（`~/.config/agent-orchestration/authorizations.md`），不进 git 仓库。

## 有效授权

| 日期 | Agent / 模型 | 范围 | 备注 |
|---|---|---|---|
| YYYY-MM-DD | DeepSeek Harness，模型跟随 DSH Desktop 的选择，渠道限 runner 的 `DSH_ALLOWED_PROVIDERS` | 默认执行者：适合委派的低、中难度任务和批量重复工作。任务书须具体，主代理独立验收 | 其他渠道和用途不包含在此授权内；增加渠道需重新授权 |
| YYYY-MM-DD | Claude Code `claude-opus-5-5` / `medium` | 高级独立评审，按指南门槛判断，无需逐次询问 | 每个用户任务默认一轮；默认无工具，必要时只允许 Read/Glob/Grep 读专用目录的脱敏副本 |
| YYYY-MM-DD | Codex `gpt-6-astra` / `high` | 跨模型评审（`--sandbox read-only`）；DeepSeek 不适合时的备用执行（`workspace-write`，只写 `--cwd`，不联网） | |
| YYYY-MM-DD | Claude 内置子代理（Explore / sonnet / haiku） | 搜索、读文件、并行查找 | |

## Desktop 子会话模型（本机 CC Switch 配置）

在 CC Switch 里重建模型后 ID 会变，变了要更新这里并重新确认。

| 名称 | 模型 ID | effort | 上游 | 实测日期 |
|---|---|---|---|---|
| DeepSeek | `claude-fable-ccs-xxxxxx` | high | `https://api.deepseek.com/anthropic` / `deepseek-flash` | |

## 已停用

| 日期 | Agent / 模型 | 原范围 | 停用原因 |
|---|---|---|---|

## 核实结论

只记录对以后调用仍有参考价值的结论。详细过程见各次运行的 `summary.json`。
