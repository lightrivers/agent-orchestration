# Codex：评审与备用执行

- 主要用途：Claude 作为主代理时，作为跨模型评审成员，用 `--sandbox read-only`。评审方式与 Claude 评审相同（见 `claude-review.md` 的"评审方式"）。
- 费用较高时，过程中不拉起：不紧急的风险记进 `work/评审_待审.md`，新方案执行前或全部完成后一次审。紧急风险（丢数据、暴露公网、让在跑的任务失败）当场处理，事后补记。
- 备用执行：DeepSeek 不适合且任务确实需要 Codex 工具链时，用默认的 `workspace-write`（只能写 `--cwd`；runner 显式关闭网络）。`--cwd` 设成最小的必要目录。
- 模型默认 `gpt-6-astra` / `high`（`--model` / `--effort` 可改）。
- 子任务控制在 10–20 分钟能完成。runner 默认总超时 3600 秒，连续 900 秒无输出判为卡住（`state=idle_timeout`）。
- 日志里的 `Reconnecting... n/5` 是 CLI 自动重连，不算失败。
- 不要定时发消息"保活"：`codex exec` 每次只有一轮，中途不能插话。
- 走中转站 API key 时，`codex login status` 显示 Not logged in 是正常的。
- 完成条件：有 `turn.completed` 和最终 `agent_message`，没有 `turn.failed` 或非重连类错误。
