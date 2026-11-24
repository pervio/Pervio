# Pervio 环境速查(本服务器装有 Pervio 远程编排层,以下能力可直接使用)

- 工作流编排 CLI:`~/.pervio/bin/pervio-orchestrate`,子命令:`start --spec-b64 <b64(spec json)>` / `status --wf <id>` / `list` / `delete --wf <id>` / `templates list` / `archives list` / `schedule {list|add --b64|remove --id|fire --id|tick}`。
- 每次运行的目录:`~/.pervio/wf/<runId>/` —— `ledger.json`(账本:状态、每步输出全文、错误、fanout 计数、publishedTo)、`spec.json`(配方)、`<步骤id>.jsonl`(各 agent 步的完整对话流)。查"某次运行发生了什么"先读账本,再按需翻 jsonl。
- 模板(用户的个人市场):`~/.pervio/templates/*.json`(裸 spec 或 `{name,summary,spec}` 包装);定时任务的 spec 在 `~/.pervio/schedules/<id>/spec.json`。
- 带参数跑一个模板:读它的 JSON → 按需改字段(如 `dir`、prompt 里的输入约定)→ `start --spec-b64 "$(base64 < 改好的.json)"`。运行会出现在手机 App 的 Workflows → Recent。
- 用户在对话里让你跑 workflow 时,**尽量把结果带回对话**:起跑后轮询 `status --wf` 到 done/failed,然后读账本把关键输出/失败原因讲给用户——别让用户自己去 App 里翻。
- spec 速记:`steps[{id, backend:"claude", prompt 或 command, dependsOn, perm(plan/acceptEdits), verify, fanout{over,max,maxParallel,timeoutSec,tolerateAllFail}, publish:true|"<目录>"}]`。`publish` = 该步输出自动归档成 `<目录>/<日期>.md`(出版物:首页卡片+往期阅读器)。`command` 是固定 shell 串,**禁止**写 `{{ref}}`(要上游输出就用环境变量 `PERVIO_WF_DIR` 读 ledger.json);prompt 里可用 `{{步骤id.output}}`,fanout 子提示用 `{{item}}`。
- 出版物:归档目录下按 `YYYY-MM-DD.md` 存;论文晨报的书架是 `~/.pervio/papers/archive`,兴趣档案 `interests.md`(用户所有,勿改)、代理记忆 `memory.md`;打分回写用 `~/.pervio/bin/pervio-feedback --id <arxivId> --verdict 👍|👎|少看|多看`。
- 纪律:`delete`/`schedule remove` 是破坏性动作,`start` 消耗真实模型额度——执行前先向用户确认一句。
