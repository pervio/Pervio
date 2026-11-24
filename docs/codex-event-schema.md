# Codex `exec --json` 事件 schema(P0 适配器依据)

> 目的:为 Pervio 的 L1 适配器层(`pervio-agent codex …`)提供 Codex 无头事件的归一化依据。
> 标注约定:**[实测]** = 本机真跑 `codex exec --json` 抓到;**[文档]** = 官方文档,未实测;
> **[待验证]** = 需鉴权修复后实测确认。
> 实测环境:codex-cli 0.140.0-alpha.2(VSCode ChatGPT 扩展自带二进制),2026-06-13。
> **新增实测平台(2026-08-06 复扫)**:macOS codex-cli **0.142.0**(homebrew),与原 Linux 0.139/0.140 并列;
> 文中标注 **[实测 2026-08-06]** 的条目均在该环境验证。

## 0. 前置:鉴权 + 稳定路径

- **鉴权(已解决)**:第一轮 standalone `codex exec` 曾报 **401**(`refresh token was revoked`),
  用户 `codex login` 重登后已修复;第二轮起所有 `codex exec --json` 正常 exit 0。
  → 经验:独立 CLI 与扩展 app-server 走不同鉴权路径,token 失效时需重登。
- **稳定路径(已解决)**:已装 standalone 静态二进制,`~/.local/bin/codex`(软链)→
  `~/.codex/packages/standalone/releases/0.139.0-x86_64-unknown-linux-musl/bin/codex`,**不依赖 node/npm**,
  共享 `~/.codex` 鉴权。`pervio-agent` 用 PATH 上的 `codex` 即可。
  > **版本核实**:生产二进制是 **0.139.0**(schema 当初在扩展自带的 0.140.0-alpha.2 上测);
  > 已在 0.139.0 复测:事件 schema 完全一致,`--ask-for-approval` 同样被拒(须 `-c approval_policy`),鉴权正常。

## 1. 事件信封(envelope)—— 名词体系 thread / turn / item

Codex 用 `thread`→`turn`→`item` 三层名词,**与 Claude 的 `system/assistant/stream_event/result` 完全不同**。

| 事件 `type` | 关键字段 | 来源 | 含义 |
|---|---|---|---|
| `thread.started` | `thread_id` (UUID) | **[实测]** | 会话开始;**`thread_id` 即 resume key**(对应 claude `session_id`) |
| `turn.started` | — | **[实测]** | 一轮开始 |
| `item.started` | `item{id,type,status:"in_progress"}` | **[实测]** | 工作项开始。仅对 `command_execution`/`file_change` 观察到;`agent_message` **无** `item.started` |
| `item.completed` | `item{id,type,status:"completed",…}` | **[实测]** | 工作项完成;内容**一次性到齐**(无流式) |
| `turn.completed` | `usage{input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens}` | **[实测]** | 一轮成功结束 + token 用量;顶层**无** cost/model |
| `turn.failed` | `error{message}` | **[实测]** | 一轮失败 |
| `error` | `message` | **[实测]** | 独立错误事件(常与 `turn.failed` 成对出现) |

实测抓到的原始 4 行(turn 因 401 失败):
```json
{"type":"thread.started","thread_id":"019ec14a-9cad-7d72-a27f-a1ec61a8e8a1"}
{"type":"turn.started"}
{"type":"error","message":"Your access token could not be refreshed because your refresh token was revoked. ..."}
{"type":"turn.failed","error":{"message":"..."}}
```

> ✅ **以上 `item.*` 已在第二轮全部实测**(见文末 **§实测补全(P0 第二轮)**):
> 实测到的 `item.type` 仅 `agent_message` / `command_execution` / `file_change`;
> **无 `reasoning` item**(高 effort 也没有,推理只体现为 `usage.reasoning_output_tokens`);
> **不流式**(对抗验证确认,整段一次到达 `item.completed`);
> `/compact` 等价状态事件本轮未触及,仍未知。

## 2. flag 对照(Codex ↔ 我们现有 Claude 概念)

| 概念 | Claude(现用) | Codex |
|---|---|---|
| 一次性 prompt | `claude -p "<text>"` | `codex exec "<text>"`(prompt 走 argv;**stdin 必须给 EOF**,否则卡在 "Reading additional input from stdin",见下) |
| 结构化流 | `--output-format stream-json --include-partial-messages` | `--json`(JSONL) |
| resume | `--resume <session_id>` | `codex exec resume <thread_id>` / `resume --last` |
| 权限/沙箱 | `--permission-mode default\|acceptEdits\|plan\|bypassPermissions` | `-s/--sandbox read-only\|workspace-write\|danger-full-access`;审批用 **`-c approval_policy=untrusted\|on-request\|never`**(⚠️ 本构建 `codex exec` **不接受** `--ask-for-approval`,传入 exit 2);`--dangerously-bypass-approvals-and-sandbox`(危险) |
| 跳过 git 检查 | (不需要) | `--skip-git-repo-check` |
| 指定工作目录 | (脚本里 cd) | `-C <dir>` **[实测可用]** |
| 结构化最终输出 | (无) | `--output-schema <file>` / `--output-last-message <file>` |
| 不落 session 文件 | (无) | `--ephemeral` |

**[实测踩坑]**:`codex exec` 即使 prompt 在 argv,仍会尝试从 stdin 读追加输入;
后台/无 TTY 调用若 stdin 不关,会**永久阻塞**在 `Reading additional input from stdin...`。
→ 我们的脚本调用 codex **必须 `< /dev/null`**(或显式关 stdin)。

## 3. 归一化映射(L1 适配器:Codex → 统一 `AgentEvent`)

我们现有 `ClaudeEvent` 要抽象成通用 `AgentEvent`,两个后端各写一个 parser:

| 统一 `AgentEvent` | 来自 Claude | 来自 Codex |
|---|---|---|
| `initialized(sessionId, model)` | `system/init`(session_id, model) | `thread.started`(thread_id);model 从 config/turn 取 |
| `textDelta` | `stream_event` text_delta | `item.completed`(agent_message,**无增量**→ 客户端模拟打字机) |
| `thinkingDelta` | `stream_event` thinking_delta | **无**(codex 不吐推理文本,只有 `usage.reasoning_output_tokens`) |
| `toolUse` | `assistant` content tool_use | `item.started/completed`(`command_execution`:command+aggregated_output+exit_code;`file_change`:changes[].path+kind) |
| `contextUsage` | `assistant` usage(input+cache) | `turn.completed` usage(**轮末累计**,类似 claude `result`,非单请求) |
| `result(text, sessionId, cost, isError)` | `result` | `turn.completed` / `turn.failed` / `error` |
| `compacting` | `system/status` | **未知**(本轮未触及 codex 的 compact) |

**设计要点**:
1. resume id 字段名不同(`session_id` vs `thread_id`)——`ServerProfile`/会话模型要存"后端 + 该后端的 sid"。
2. **[实测]** Codex 只在 `turn.completed.usage` 给轮末累计,**没有** claude 那种每条 assistant 的 per-request usage;
   故 codex 后端的 context ring **只能用轮末值近似**,且每轮末才更新一次(不像 claude 每条消息刷新)。
3. **[实测]** Codex `--json` **不流式**(整段文本只在终态 `item.completed.text` 出现一次,无 delta);
   codex 会话的打字机效果**必须客户端本地模拟**(对 `item.completed.text` 分块播放),不能由事件流驱动。
4. **[实测 2026-08-11,codex-cli 0.146.1]** `token_count` 事件**不在 `exec --json` 流里**——
   它只写进 rollout(`event_msg`/`token_count`,含 `info.model_context_window` 与
   `rate_limits`)。所以额度百分比**没有直播事件可转发**:context 环走 `turn.completed.usage`
   (每轮末一次),usage 行只能在轮末回读 rollout(`pervio-sessions usage --backend codex`)。
   语料 `server/tests/corpus/codex-*.jsonl`(直播流)与 `codex-*.session.jsonl`(rollout)
   并排即可复核:前者只有 4 类事件,后者才有 `token_count`。
5. **[实测]** codex 的 `usage.input_tokens` **已经包含** `cached_input_tokens`
   (rollout 里 `total_tokens == input + output` 恒成立,cached ≤ input),
   与 claude 相反(claude 的 input 不含 cache,三者相加)。
   context 环两边都只能用 `input_tokens`,相加会把 cache 算两遍、把环顶到 100% 以上。

## 4. 下一步(P1 能开工的前提)

1. ✅ ~~`codex login` 修复鉴权~~ —— 已完成。
2. ✅ ~~重跑成功的 `codex exec --json` 补全 `item.*`~~ —— 已完成(见 §实测补全)。
3. ✅ ~~装稳定路径的 codex~~ —— 已完成(`~/.local/bin/codex` → 0.139.0 standalone,schema 已复测一致)。
4. ⬜ 实现 `pervio-agent codex` 适配器 + `AgentEvent` 抽象(按下方实测 schema)。**P1 前置已全部就绪。**

---

## 实测补全(P0 第二轮)

> 全部条目均为 [实测]。测试环境:codex 二进制 `openai.chatgpt-26.609.30741`(codex-cli `0.140.0-alpha.2`),路径 `~/.vscode-server/extensions/openai.chatgpt-26.609.30741-linux-x64/bin/linux-x86_64/codex`。调用形式为 `codex exec --json --ephemeral ...`,stdin 一律重定向自 `/dev/null`。

### 0. 关键调用约束(必读,影响命令是否能跑通)[实测]

| 约束 | 实测结论 |
|------|----------|
| `--ask-for-approval` / `-a` | [实测] 本构建的 `codex exec` **不接受** `--ask-for-approval`。传入即报 `error: unexpected argument '--ask-for-approval' found`,**exit 2**。该 flag 是顶层 flag,不出现在 `codex exec --help` 中。审批策略必须用配置覆盖传入:`-c approval_policy="never"`。 |
| 全局 flag 相对 `resume` 的位置 | [实测] `--json`、`--sandbox`/`-s`、`--cd`/`-C`、`-c` 都是父命令 `exec` 的选项,**必须放在 `resume` 子命令之前**。放在 `resume` 之后会触发 clap 用法错误 **exit 2**。只有 `--skip-git-repo-check` 与位置参数(SESSION_ID、PROMPT)属于 `resume`。 |
| stdin 阻塞 | [实测] 不重定向 stdin 时 `codex exec` 会阻塞等待输入,必须 `< /dev/null`。 |
| stderr 噪声行 | [实测] 即使 `< /dev/null` 且已带 PROMPT 位置参数,stderr 仍会出现良性行 `Reading additional input from stdin...`,**不是错误**(exit 0)。个别 resume 运行 stderr 为空。 |
| PROMPT 位置参数 | [实测] PROMPT 为位置参数;省略或传 `-` 时从 stdin 读取;当同时给了 PROMPT 参数又有管道 stdin 时,管道内容作为 `<stdin>` 块追加。 |

### 1. 事件类型(顶层 `type`)完整表 [实测]

每行 JSONL 都是一个对象,带顶层 `type` 字段。

| `type` | 载荷字段 | 含义 / 实测说明 |
|--------|----------|------------------|
| `thread.started` | `thread_id` (string, UUID) | [实测] 线程开始,携带 `thread_id`。**这是 resume 的 key**。resume 时 `thread.started` 回显同一个 `thread_id`。 |
| `turn.started` | (无额外字段) | [实测] 单轮开始。 |
| `item.started` | `item{ id, type, status:"in_progress", ... }` | [实测] 工作项开始。**仅对 `file_change` 和 `command_execution` 观察到**;`agent_message` 未观察到 `item.started`(直接以 `item.completed` 出现)。 |
| `item.completed` | `item{ id, type, status:"completed", ... }` | [实测] 工作项完成,**全部内容一次性到齐**(见各 item.type 表)。 |
| `turn.completed` | `usage{ input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens }` | [实测] 单轮结束,携带聚合 token 用量。**顶层无 cost/model 字段**。 |
| `turn.failed` | `error{ message }` | [已知,round 1] 单轮失败。本轮未触发,沿用 round 1 结论。 |
| `error` | `error{ message }` | [已知,round 1] 顶层错误。本轮未触发,沿用 round 1 结论。 |

说明:`item.*` 事件中,同一 `item.id` 会在 `item.started` → `item.completed` 间复用,`status` 从 `in_progress` 变为 `completed`。

### 2. 工作项类型(`item.type`)完整表 + 承载字段 [实测]

`item` 对象通用字段:`id`(string,如 `item_0`)、`type`、`status`。其余字段随 `type` 而异。

| `item.type` | 承载字段(`item.*`) | 实测说明 |
|-------------|----------------------|----------|
| `agent_message` | `id`, `type`, `text` | [实测] 模型消息(**一轮可多条**:执行前/间叙述 + 最终答复,均整段到达)。[实测 2026-08-06] 复扫实锤:一条 `command_execution` 前后各夹叙述与答复 = **2 条** `agent_message`(sweep P2);另见 **3 条**与多条命令交错(sweep P4)。适配器取最终答案应取**最后一条**(`pervio-orchestrate._step_output` 已如此);聊天 UI 逐条渲染。完整文本在 `item.text`。多行内容以 `\n` 内嵌于单个 `text`(例如 `"1\n2\n3\n4\n5\n6"`)。**未观察到对应的 `item.started`**,直接 whole 到达 `item.completed`。若 prompt 要求"展示推理",推理文字会被折叠进本 `text`,而非单独 item。 |
| `command_execution` | `id`, `type`, `command`, `aggregated_output`, `exit_code`, `status` | [实测] 执行 shell 命令。`command` 为完整命令串,codex 用登录 shell 包裹(如 `/bin/zsh -lc 'ls -la'`)。`aggregated_output` 为 **stdout+stderr 合并**字符串(`item.started` 时为 `""`,`item.completed` 时填充)。`exit_code` 在 `in_progress` 时为 `null`,`completed` 时为整数(如 `0`)。**命令可并发/交错**:两个 `command_execution` 可同时进入 `in_progress`,且可乱序完成(后启动者先完成)。需让 prompt 明确要求执行 shell 命令才会产生此 item。 |
| `file_change` | `id`, `type`, `changes[]`, `status` | [实测] 文件改动,经模型内置 apply/write 工具(**非** shell 命令)完成,故纯文件编辑只产生 `file_change`、**无伴随 `command_execution`**。**item 顶层无 `path`、无 `diff`/patch 字段**。路径在 `item.changes[].path`(绝对路径),改动种类在 `item.changes[].kind`(已实测 `"add"`=新建文件)。`changes` 为数组,一个 item 可覆盖多文件。本轮**未观察到统一 diff / patch 文本**。 |
| `reasoning` | — | [实测·否定] **即使 `model_reasoning_effort="high"` 也未产生 `reasoning` item.type**。模型推理内容不作为独立 item 或独立流出现。唯一的推理信号是 `turn.completed.usage.reasoning_output_tokens`(聚合 token 数,如 60)。JSONL 中任何位置都无逐 token / 摘要级推理文本字段。 |

`changes[].kind` 取值:[实测] 已确认 `"add"`(新建);`"update"`/`"delete"` 为**推断**(基于命名,本轮未实测触发)— 见第 6 节。

`item.type` 全集本轮仅观察到 `agent_message`、`command_execution`、`file_change` 三种;`reasoning` 经针对性测试确认**不出现**。

### 3. 流式(streaming)结论 + 对打字机 UI 的含义 [实测]

**结论:`codex exec --json` 不做文本增量流式输出 — 经对抗性测试确认。**

[实测] 证据(探针 prompt "Write a 4-sentence paragraph...",exit 0):
- 共 4 行;事件类型 `thread.started(1)`、`turn.started(1)`、`item.completed(1)`、`turn.completed(1)`;item 类型仅 `agent_message(1)`。
- 承载消息的事件**恰好 1 个**(**仅限无工具轮**;[实测 2026-08-06] 带 `command_execution` 的轮可产生**多条** `agent_message`——执行前/间叙述 + 最终答复,见第 2 节表):整段 4 句话一次性到达单个 `item.completed`(`item_0`),`agent_message` 连 `item.started` 都没出现。
- python3 扫描 type 名中的增量信号(delta / updated / partial / output_text / chunk / streaming):**全部为空**。无 `item.id` 跨事件复用,故也不存在 partial-update 式流式。

[实测] 没有任何 flag 能开启流式:
- `codex exec --help` 与顶层 `--help` 中 stream/delta/partial/incremental/chunk **零匹配**。唯一输出机制是 `--json`(JSONL 事件),外加 `--output-last-message`、`--output-schema`。
- 尝试 `--enable streaming|stream|output_text_delta|deltas` 全部被拒:`Error: Unknown feature flag`(**exit 1**)。

**对打字机 UI 的含义:** 无法用 codex 的真实 token delta 驱动打字机效果。完整文本只在终态 `item.completed.text` 出现一次。任何逐字渲染必须**客户端自行模拟**(本地对 `item.completed.text` 分块/逐字播放),不能由 codex 流式事件喂入。若需逐行处理,适配器须把 `agent_message.text` 当作完整最终消息,自行按 `\n` 切分。

### 4. Resume 结论 [实测]

**结论:resume 可用,exit 0,且能正确跨轮记忆上下文。**

[实测] 验证:首轮告知 secret word,resume 轮提问"What was the secret word..."正确返回 `banana`(thread `019ec15d-9e1a-77c1-abd0-d430c1ffe252`)。

- **resume key 是 `thread_id`**(由 `thread.started` 携带)。resume 轮 `thread.started` 回显同一 `thread_id`。
- **可用调用形式(关键:全局 flag 必须在 `resume` 之前)**:
  ```
  codex exec --json --sandbox read-only -C "$D" -c model_reasoning_effort=low \
    resume "$TID" --skip-git-repo-check "<prompt>"
  ```
- [实测·否定] 把 `--json`/`--sandbox`/`-C` 放在 `resume` 之后(`codex exec resume "$TID" --json ...`)会 **exit 2 / clap 用法错误**。只有 `--skip-git-repo-check` 与位置参数属于 `resume`。
- resume 轮事件序列与普通轮一致:`thread.started` / `turn.started` / `item.completed`(仅 `agent_message`) / `turn.completed`;`agent_message.text` whole 到达。该轮 `usage`:`input_tokens=23825, cached_input_tokens=18688, output_tokens=51, reasoning_output_tokens=37`。
- `resume` 是 `codex exec` 的子命令(`Resume a previous session by id or pick the most recent with --last`)。`codex exec` 其他子命令:`review`、`help`。

### 5. `--sandbox` 与 `--ask-for-approval` 完整枚举 [实测]

[实测] `--sandbox` / `-s <SANDBOX_MODE>` — 恰好 3 个值:

| 值 | 说明 |
|----|------|
| `read-only` | 只读 |
| `workspace-write` | 可写工作区 |
| `danger-full-access` | 完全访问 |

附注:[实测] `--dangerously-bypass-approvals-and-sandbox` 是独立布尔 flag(**非** sandbox 枚举值),完全禁用 sandbox+审批。

[实测] `--ask-for-approval` / `-a <APPROVAL_POLICY>` — 4 个值:

| 值 | 说明 |
|----|------|
| `untrusted` | |
| `on-failure` | **已标记 DEPRECATED**,仅命令失败时升级;建议改用 `on-request`/`never` |
| `on-request` | 模型自行决定何时询问 |
| `never` | 从不询问;执行失败回传给模型 |

**枚举有效性 ≠ flag 可用**:[实测] 如第 0 节所述,本构建 `codex exec` **不接受 `--ask-for-approval` flag 本身**(顶层 flag,不在 `exec --help` 中,传入 exit 2)。在 `codex exec` 下设置审批策略须用 `-c approval_policy="<value>"`,枚举值同上。`codex exec --help` 仅显示 `--sandbox` 与 `--dangerously-bypass-approvals-and-sandbox`。

### 6. 仍不确定 / 需进一步实测的项(诚实标注)

- **`file_change` 的 `changes[].kind` 完整枚举**:[实测] 仅确认 `"add"`。`"update"`(修改已有文件)与 `"delete"`(删除)为**推断**,本轮未触发实测,值的确切拼写未经验证。
- **`file_change` 是否会输出 diff/patch 文本**:[实测] 本轮所有 `file_change` 仅含 `path`+`kind`,无统一 diff。是否存在某种场景/配置下携带 patch 文本,**未确证**。
- **`turn.failed` / 顶层 `error` 的精确结构**:[已知,round 1] 形如 `error{message}`,但本轮(round 2)未主动触发失败路径复核,字段是否还有其他键**未在本轮验证**。
- **`agent_message` 是否在某些场景会有 `item.started`**:[实测] 本轮所有运行中 `agent_message` 均无 `item.started`。是否存在产生 `item.started` 的场景**未观察到,不能完全排除**。
- **多文件 `file_change` 的实际形态**:[实测] `changes` 为数组,理论上一个 item 可覆盖多文件,但本轮仅实测到单文件 `add`,多文件聚合形态**未实测**。
- **`command_execution` 是否有独立 stdout/stderr 字段**:[实测] 仅见合并的 `aggregated_output`,未见分离字段;是否存在分离字段**未发现/未确证**。

## 7. P1 实现已知限制(codex 后端)

P1 落地了 chat + run 的 codex 后端(实测 chat + resume 通过),以下为已知、刻意未做(避免瞎猜)的限制,留 P1b/P2:

- **context ring 不显示**:codex 事件流无 `contextWindow`,`parseCodex` 固定 `contextWindow: nil`,故 ring 在 codex 会话隐藏(`contextTokens` 仍按 `turn.completed.usage` 算但不展示)。**不硬编码窗口大小**(那是猜)。P1b 可从服务器 `~/.codex/models_cache.json` 读 gpt-5.x 的真实窗口经 pervio 回传后启用。
- **跨会话历史 / 抽屉已含 codex [实测 2026-08-06]**:2026-08-05/06 已发布——`pervio-sessions` 的 list、transcript(`--backend codex`)、search 三条路径均覆盖 codex 会话(sweep P6 三项全部实测通过)。
  ~~**跨会话历史 / 抽屉不含 codex**:codex 会话落在 `~/.codex/sessions`,而 app 的 `pervio-sessions`(历史抽屉 / loadHistory / loadContext)只读 `~/.claude/projects`。所以**从历史抽屉重进一个 codex 老会话不会回填 transcript**;同一会话内的 resume(thread_id 实时捕获回传)正常。P2:教 `pervio-sessions` 也读 `~/.codex/sessions`。~~
  (旧结论 2026-08-05/06 作废:上述 P2 已落地发布,codex 会话已进历史/搜索。)
- **附件(uploads)对 codex 可达 —— 读不受沙箱限制 [实测 2026-08-06]**:codex 在 `workspace-write` 与 `read-only` 两种沙箱下都能**直接读取工作目录之外的任意文件**;沙箱限制的是**写与网络**,不限制读。探针方法:在 /tmp 放探针文件,让 codex 在两种沙箱模式下分别读取,内容均原样读回。因此 `~/.pervio/uploads` 的**路径引用**对 codex 直接可用——无需 `--add-dir`,无需内联分叉。
  **已落地 2026-08-13**:背景会话附件(`ChatStore.attachContext`)的 codex 内联分叉已删除,两个后端共用
  上传+路径一条路;内联的产出端(frame)一并删除,只保留 `foldContextFrames` 读旧 transcript。
  **平台补充 [实测 2026-08-06]**:macOS codex-cli 0.142.0(homebrew)双向复核通过——`workspace-write` 下读 `~/.pervio/uploads` 内文件、`read-only` 下读 `-C` 之外的整棵目录树,均原样读回。
  ~~**附件(uploads)对 codex 不可达**:claude 路径用 `--add-dir ~/.pervio/uploads`;codex 分支 P1 未加 `--add-dir`(该 flag 仅在 help 见过、未运行时验证)。codex 在 `workspace-write` 沙箱下只能访问项目目录。P1b:运行时验证 codex `--add-dir` 后再启用。~~
  (旧结论 2026-08-06 作废:「只能访问项目目录」是对沙箱语义的误读——沙箱约束写/网络、不约束读;当时只看了 flag/help,从未实测过读路径。)
- **打字机效果**:codex 不流式(整段一次到 `item.completed`),故 codex 气泡是整段出现而非逐字。P5 可客户端模拟。
- **删除 workflow 不清 codex rollout(刻意)[实测 2026-08-06]**:`pervio-orchestrate delete` 有意不删 codex step 落在 `~/.codex/sessions` 的 rollout 文件(`_sweep_conversations` 中已注明),故已删除的 codex workflow 的会话仍会出现在历史/搜索里。
