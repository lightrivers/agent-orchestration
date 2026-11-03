# Desktop 子会话：换成 DeepSeek 等其他模型（仅 Claude Desktop）

适用场景：需要多轮、边做边看的工作（持续 SSH 排查和改设置、陪用户在界面上一步步操作），用户能打开、查看、插话。一次性的批量任务仍然优先用 runner，它会把运行记录和 `summary.json` 落盘，更好验收。Claude 子会话默认用主会话的模型，换渠道由用户决定。

前提：用 CC Switch 之类的工具给 Claude Desktop 配了额外模型（例如 DeepSeek 渠道的 `deepseek-flash`）。本机的模型 ID、effort 和实测日期记在 `$AGENT_ORCH_HOME/authorizations.md` 的"Desktop 子会话模型"表里。

## 查当前模型 ID

在 CC Switch 里重建模型后 ID 会变。查法：先看 `~/Library/Application Support/Claude-3p/configLibrary/_meta.json` 的 `appliedId`，打开它指向的配置文件，在 `inferenceModels` 里找。ID 变了要更新授权记录并请用户重新确认。

## 启动步骤

1. 用 `start_session` 启动 `fresh` 会话。启动时传的 `model` 不生效，第一轮固定用主会话的模型，所以第一轮只发一句很短的话（例如"只回复 ok"），不放真正的任务。
2. 用 `set_session_effort` 设 effort，再用 `set_session_model` 设模型 ID。两项都从下一轮开始生效。
3. 用 `get_session` 确认 `model` 和 `effort` 已经变了（`model` 可能带 `[1m]` 后缀，属正常）。确认后再用 `SendMessage`（`to` 填该会话的 `local_…` id）发真正的任务书。
4. 同一个会话可以中途换模型，重复步骤 2 即可。

## 核实

子会话会照系统提示自称 Claude，它的自我介绍不能当证据。用 CC Switch 时查 `~/.cc-switch/cc-switch.db` 的 `proxy_request_logs` 表，确认 `request_model` 是上面的 ID、`model` 是上游模型、`status_code=200`。

## 限制

- 用 `fork` 启动的会话只能继承主会话的模型。
- 子会话的工具权限和主会话相同，不受 runner 沙箱限制，任务书里要写清范围（套用 `$SKILL/templates/task-brief.md`）。
- 渠道返回 503 时先报告，不要自动换渠道。做完就归档。
- DeepSeek Harness Desktop 是独立 agent，主代理不能直接通信，派活和收结果都要用户手动转贴，尽量不用。
