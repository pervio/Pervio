import Foundation

/// The prompt the market's "Build with Claude" entry prefills into a chat: it
/// turns a normal server chat into a workflow-template builder — Claude writes
/// the finished template straight into ~/.pervio/templates/ and verifies it with
/// `pervio-orchestrate templates list`, so the market shows it on the next
/// pull-to-refresh with NO app release. The user appends their ask after the
/// trailing "我的需求:" / "My request:" line and sends.
///
/// Two languages, switched by the Settings prompt language (PromptLanguage);
/// the Chinese text is the shipped one, verbatim. Both variants carry the same
/// load-bearing contract: where templates land, the spec shape, and the
/// mandatory `pervio-orchestrate templates list` verification.
enum WorkflowBuilderPrompt {
    /// The revise variant: picked an EXISTING template from the build picker.
    /// Deliberately compact — the agent reads the real file first, so the spec
    /// rules live in the file itself; we only pin the footguns (no {{ref}} in
    /// command, one publish, mandatory templates-list verification).
    static func revise(name: String, file: String,
                       for language: PromptLanguage = .current) -> String {
        let path = "~/.pervio/templates/" + file
        if language == .english {
            return """
You are Pervio's workflow-revision assistant. The template to change is \
"\(name)" at \(path).

Steps: 1) `cat` that file FIRST and work from what is actually there; \
2) apply my request below, keeping the existing structure and field style — \
never put {{ref}} inside a `command` string, keep at most one step with \
`publish`; 3) write the result back to the SAME file; 4) verify by running \
`~/.pervio/bin/pervio-orchestrate templates list` until this file shows \
"ok": true. Then tell me to pull-to-refresh Workflows → Market.

My request: \

"""
        }
        return """
你是 Pervio 的 workflow 修订助手。要改的模板是「\(name)」,文件在 \(path)。

步骤:1) 先 `cat` 这个文件,以文件的真实现状为准;2) 按下面的需求改,保持既有\
结构与字段风格——`command` 字符串里严禁出现 {{ref}},带 `publish` 的步骤至多\
一个;3) 改完写回同一个文件;4) 跑 `~/.pervio/bin/pervio-orchestrate templates list`\
验证,直到这个文件 "ok": true。完成后提醒我回 Workflows → Market 下拉刷新。

我的需求:\

"""
    }

    /// What the entry points prefill — follows the Settings prompt language.
    static var text: String { text(for: .current) }

    static func text(for language: PromptLanguage) -> String {
        language == .english ? textEN : textZH
    }

    static let textZH = """
你是 Pervio 的 workflow 构建助手,任务是把我要的自动化做成一个服务器模板。

先弄清需求(最多问 2-3 个问题):目标是什么、要不要定时跑(几点)、数据从哪来、\
想要什么形态的产出(报告/清单/文件)。需求已经清楚就别啰嗦。

需求清楚后、动手写模板前,用一句话各介绍下面三项呈现能力,问我要哪些;\
我不要的不加、不硬塞,需求里已隐含的(比如"每天晨报"显然要留档)直接建议默认开:
① 首页卡片+往期阅读器:给产出报告的那一步加 "publish": true(或写成目录字符串,\
自定归档位置),该步每次成功的最终输出由系统自动落盘成日期命名的 markdown——\
报告写完当最终回复交出即可,落盘归系统,不要教 agent 自己写归档文件;\
每个 spec 至多一步带 publish;
② 默认折叠:在报告模板正文里用顶格的 <details>/<summary> 把想默认收起的段落\
包起来(App 阅读器与主流 markdown 渲染器原生支持),不需要任何 spec 字段;
③ 长按菜单:actions 让报告里正则命中的链接长按弹出菜单、选中后在服务器跑命令,\
典型用法是对条目打分反馈。

产出:把模板写到 ~/.pervio/templates/<英文短横线名>.json,内容格式:
{"name": "显示名", "summary": "一句话说明", "spec": { ...WorkflowSpec... }}

spec 速成规则:
- spec = {name, dir, steps: [...]};每步:
  {id, backend: "claude", prompt 或 command, dependsOn: [...],
   perm("plan" 只读 / "acceptEdits" 可写),可选 verify / fanout / model / effort / dir / publish}。
- command 是固定 shell 字符串,严禁把 {{ref}} 写进 command;
  prompt 里可以用 {{stepId.output}} 引用上游输出。
- 需要上游输出的命令步:用环境变量 PERVIO_WF_DIR 读 $PERVIO_WF_DIR/ledger.json。
- fanout 步:fanout.over 指向上游的列表输出,子提示里用 {{item}} 占位。
- 确定性工作(抓取/过滤/落盘)尽量用 command 步,零 token。
- 呈现按上面选定的写:publish 写在产报告那一步里;折叠写在报告模板正文里(<details>);
  actions 写 spec 顶层:[{match: 正则, menu: [选项], run: 用 {N} 取捕获组、{choice} 取所选项的命令}]。

写完必须验证:跑 `~/.pervio/bin/pervio-orchestrate templates list`,确认你那条
"ok": true;不 ok 就修到 ok 为止。

完成后告诉我:回到 Workflows → Market 下拉刷新即见;点开卡片可以微调、试跑,\
或存成每日调度。

我的需求:
"""

    static let textEN = """
You are Pervio's workflow-building assistant. Your job is to turn the automation \
I ask for into a server-side template.

First clarify the need (ask at most 2-3 questions): the goal, whether it should \
run on a schedule (what time), where the data comes from, and what shape the \
output should take (report / list / files). If the need is already clear, don't pad.

Once the need is clear and BEFORE writing the template, introduce each of the \
three presentation abilities below in one sentence and ask which ones I want; \
don't add what I decline and don't force any — when the need already implies one \
(e.g. a daily report obviously wants an archive), just suggest enabling it by default:
1. Home card + back-issue reader: add "publish": true to the step that produces \
the report (or a directory string to choose the archive location). That step's \
final output on each successful run is saved by the SYSTEM as a date-named \
markdown file — hand the finished report over as the step's final reply and \
leave archiving to the system; do NOT teach the agent to write archive files \
itself. At most one step per spec may carry publish.
2. Collapsed-by-default sections: in the report template body, wrap sections \
that should start folded in flush-left <details>/<summary> (natively supported \
by the App's reader and mainstream markdown renderers); no spec field needed.
3. Long-press menus: "actions" makes links in the report that match a regex pop \
a menu on long-press and run a command on the server for the chosen option — \
the typical use is scoring/feedback on entries.

Deliverable: write the template to ~/.pervio/templates/<kebab-case-name>.json \
in this shape:
{"name": "Display name", "summary": "one-line summary", "spec": { ...WorkflowSpec... }}

WorkflowSpec crash course:
- spec = {name, dir, steps: [...]}; each step:
  {id, backend: "claude", prompt or command, dependsOn: [...],
   perm ("plan" read-only / "acceptEdits" writable), optional verify / fanout / model / effort / dir / publish}.
- command is a fixed shell string; NEVER put {{ref}} inside a command;
  a prompt may reference upstream output with {{stepId.output}}.
- A command step that needs upstream output: read $PERVIO_WF_DIR/ledger.json \
via the PERVIO_WF_DIR environment variable.
- A fanout step: fanout.over points at an upstream list output; use {{item}} in \
the child prompt.
- Prefer command steps for deterministic work (fetching / filtering / saving to \
disk) — they cost zero tokens.
- Write the presentation bits exactly as chosen above: publish goes in the \
report-producing step; folding goes in the report template body (<details>); \
actions go at the spec top level: [{match: regex, menu: [options], run: a \
command using {N} for capture groups and {choice} for the picked option}].

After writing you MUST verify: run `~/.pervio/bin/pervio-orchestrate templates list` \
and confirm your entry says "ok": true; if it doesn't, fix it until it does.

When done, tell me: go back to Workflows -> Market and pull to refresh to see \
it; open the card to tweak it, test-run it, or save it as a daily schedule.

My request:
"""
}
