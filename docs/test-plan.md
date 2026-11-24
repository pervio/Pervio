# 发版关卡与测试计划

这份文档回答三个问题:**我们有哪几层测试、什么时候该跑哪一层、哪些东西机器永远
测不了只能人手过一遍**。写给不看代码的人:每一层都给了"一条命令、跑多久、花不花
钱",功能清单里每一条也都注明了"谁在盯着它"。

发版前照第二节的关卡表走一遍就够了,不需要理解每个测试内部干了什么。

一句话版本:

```bash
bash scripts/test-release.sh            # 发版关卡,不花钱,十几分钟(首次冷构建更久)
bash scripts/test-release.sh --plan     # 先看看真 agent 那层要跑几轮、花多少钱(免费)
bash scripts/test-release.sh --live     # 发版正式跑:同上再加真 agent 契约套件(约 $0.5)
```

## 一、我们有哪几层测试

"层"的分工标准只有一个:**多快能发现问题**。越靠上跑得越快、越便宜,越靠下越慢、
越贵,但抓的是上面抓不到的东西。

| 层 | 它守住什么 | 怎么跑 | 大约多久 | 花钱吗 |
| --- | --- | --- | --- | --- |
| 0 脚本自检 | 测这套自动化本身。用沙箱和假的 `xcodebuild` 演"构建挂了""一台模拟器都没有""sshd 没起来",确认脚本会如实报 FAIL/SKIP 而不是假绿 | `bash scripts/tests/test_scripts.sh` | 半分钟 | 不花 |
| 1 iOS 单测 | App 侧的解码契约(服务器返回的 JSON 变形了 App 会不会白屏)、ChatStore 的竞态(切会话、附件迟到、市场刷新被安装抢先)、SSH 传输(对着沙箱 sshd 做**真握手**:主机指纹不对必须拒、连不上的四种原因各有各的说法、分块上传逐字节相同)、报告渲染(拿**真刊物归档**当输入,断言解析出来的块) | `bash scripts/test-fast.sh` 里的第一段 | 1-3 分钟 | 不花 |
| 2 服务端套件 | `server/bin/` 里每个脚本的行为:对话、审批、后台运行、会话读取、上传、工作流、定时、扇出、子 agent、MCP、安装脚本,外加"跑了两周之后状态还对不对"的长期收敛(注入时钟,不真等)。全部用**假 agent**(shim)驱动,零模型调用;驱动真 `pervio-orchestrate` 的那几个套件跑在**扔掉的 `$HOME`** 里,并且逐个 run 断言"它当时真的落在那个扔掉的家里、真 home 的 `.pervio/wf` 下一个都没出现过"(`test_orchestrate_unit.py` U0/U0b、`test_orchestrate_efficiency.py` E5) | `bash server/tests/run_all.sh` | 5-7 分钟(2026-08-08 实测:机器闲着 4 分 43 秒,机器同时在跑别的活 6 分 30 秒;两次都是 24 个套件全绿。2026-08-09 起是 **26** 个:多了 `make_actions_contract.py --check`(手机/Mac 按钮契约的服务端那一半,见 `CHECKERS`)和看着 `CHECKERS` 的 `no_orphan_checkers` 闸门) | 不花 |
| 2b 事件语料回放 | 用**真 agent 真跑出来、冻结下来的事件流**回放解析代码,并有一条漂移哨兵:CLI 升级后字段结构变了就红 | `bash scripts/test-release.sh` 会带着跑;单独跑是 `python3 server/tests/test_event_corpus.py` | 秒级 | 不花 |
| 3 iOS 冒烟 | 端到端:真起一个沙箱 sshd,真装 App 到模拟器,真发一条消息,断言回复气泡里带回原样的暗号。这是唯一一层"手指点下去到服务器再回来"都走完的测试 | `bash scripts/test-all.sh` 里的第三段 | 数分钟(首次冷构建更久) | 不花 |
| 4 真 agent 契约套件 | 真的 claude / codex 各跑几轮:一轮对话、工作流单步、命令步混合、模型会不会自己选对 MCP 工具、审批 Allow/Deny。**这层验的是"模型端行为没变"**,假 agent 永远测不到 | `bash scripts/test-release.sh --live` | 数分钟 | **花约 $0.5**(claude 8 轮 + codex 3 轮) |
| 4b 老的真 agent e2e | 工作树隔离、子 agent 派发、扇出这三条在真模型下的端到端 | `bash scripts/test-release.sh --e2e` | 数分钟 | **花模型额度** |

第 0-3 层加起来就是 `scripts/test-all.sh`,一分钱不花。第 4 层默认**不跑**,必须
显式加 `--live` / `--e2e`;`--live` 不是新加一层,而是把第 2 层那次调用**加宽**
(付费套件是免费套件的超集),所以汇总表不会因为要花钱就多出一行。

下文第三节里出现的 B1-B6 是第 4 层里那几个场景的编号,对应关系:B1 一轮基本对话、
B2 工作流单步、B3 命令步+agent 步混合、B4 模型自己选 MCP 工具、B5 审批 Allow/Deny、
B6 具名模板带参启动。**B1/B2/B3 有 codex 孪生场景;B4/B5/B6 没有**——不是偷懒,是
codex 物理做不到(理由见第三节 B 段末尾,`--plan` 也会连上游 issue 号一起打出来)。

关于"假 agent(shim)":第 2 层不去真调模型,而是把一个受控的假 `claude` /
`codex` 放进 PATH,让它按剧本输出。好处是又快又免费又可重复;代价是它只能证明
**我们的管子接对了**,不能证明**模型那头没变**。后者是第 2b 层和第 4 层的活。

关于第 1 层里那几条**真连接**的传输测试:它们连的是仓库自带的沙箱 sshd
(`server/tests/e2e_ios/setup.sh`,127.0.0.1:2222,零模型花费、零屏幕副作用)。
沙箱没起的时候,依赖端点的那几条会**如实 SKIP 并打印启动命令**,不依赖端点的
(指纹策略、开 socket 之前就该拒的那几种)照跑不误;但如果你自己指定了
`PERVIO_E2E_CONFIG` 而那个端点是死的,那算 **FAIL 不算 SKIP**——点名要的层不许
静默跳过。

## 二、关卡表:什么时候跑什么

### 情形一:改了代码,还没提交/推送

```bash
bash scripts/test-fast.sh
```

第 1+2 层,几分钟,不花钱。红了就别推。仓库里有个可选的 pre-push 钩子会自动帮你
拦(`git config core.hooksPath .githooks` 装上),默认不启用。

### 情形二:准备发版(TestFlight / App Store)

```bash
bash scripts/test-release.sh --plan     # 可选:先看真 agent 那层要跑几轮、用哪些模型
bash scripts/test-release.sh --live     # 正式跑:全部层 + 真 agent(约 $0.5)
```

跑完看最后两行:

```
SUMMARY: 4 passed, 0 failed, 0 skipped
RESULT: PASS
```

**必须是 `RESULT: PASS` 且 skipped 是 0**,才算过了机器这关。有 skip 说明某一层
根本没跑(通常是模拟器被占、sshd 端口被占),它**不等于通过**,得先把环境弄好再
跑一遍。

数字对不对得上:4 层(脚本自检 / iOS 单测 / 服务端套件 / iOS 冒烟)。曾经多出来的
那一层 `server-orphan-suites`(专跑还没被 `run_all.sh` 收录的免费测试文件)已经
**自己消失了**——事件语料回放和工作流删除都进了 `run_all.sh` 的 `SUITES`,那层现在
只打印一句"没有游离的免费套件"就返回。哪天又有免费套件掉在 `run_all.sh` 外面,它会
自己冒出来变回 5 层——这是设计,不是出错。

"你没要求跑真 agent 层"**不算 skip**——那是你自己的选择,不是环境缺东西;脚本会
在末尾单独提醒你这次没跑它,并在花费那段写"花费 0"。真正的 skip 只有一种含义:
这层本该跑,但跑不了。

然后照第四节的人工清单在真机上过一遍。两关都过了才发。

### 情形三:升级了 claude 或 codex 的 CLI

这是最容易被忽略、也最容易出事的场景:我们的代码一行没改,但对面的输出格式变了。

```bash
python3 server/tests/test_event_corpus.py          # 漂移哨兵:结构变了就红
bash scripts/test-release.sh --live                # 真 agent 契约套件
```

漂移哨兵比对的是**字段集合**(值可以变,结构不能悄悄变)。它红了不一定是坏事,
可能只是对面加了新字段;但必须有人去看一眼、确认解析代码不受影响,然后重新采集
语料(`python3 server/tests/capture_corpus.py`,会花一点额度)。

### 情形四:只改了文档 / 图标 / 文案

跑 `bash scripts/test-fast.sh` 就够了。

## 三、重要功能清单:每条谁在盯着

这份清单是**对着 `ios/Sources/` 和 `server/bin/` 逐个文件走出来的**,不是凭印象
列的。"谁盯着它"那列写的是真实存在的测试文件。

### A. 连服务器与安全

| 功能 | 谁盯着它 |
| --- | --- |
| 保存服务器档案(地址/端口/账号/目录) | 只能人工验 —— 纯 UI 表单,没有服务端对手方 |
| 删除服务器档案要二次确认(整行滑到底不能直接删掉手输的配置) | 只能人工验 —— 手势行为 |
| 私钥/密码存进 Keychain(不落 UserDefaults、不进备份) | `ios/Tests/Store/KeychainTests.swift`(B3:原样取回、覆盖写要先删再加、按 profile 隔离、`ThisDeviceOnly` 不进备份、Keychain 报错读成"没有")。用的是一个照 Apple 文档行为写的假 Security.framework——单测宿主没签名,模拟器上真 `SecItemAdd` 一律回 -34018,拿真 Keychain 测只会留个假绿。**"杀掉 App 重开还能连上"仍然只能真机验** |
| SSH 连接本身(含自研的 AES-CTR + HMAC-ETM 加密套件,为了过 ssh-audit 加固的服务器) | `ios/Tests/Store/AESCTRETMTests.swift`(B4:密钥流对 NIST SP 800-38A F.5.1 向量 + CommonCrypto 独立实现,MAC 对 `CCHmac` 按 `-etm@openssh.com` 的字节串,改一个密文位/改 MAC/换序号重放/畸形帧都必须被拒,换密钥双向生效)+ 第 3 层 iOS 冒烟(真 sshd 真握手) |
| **主机身份**:连上的到底是不是你那台机器(指纹钉死;中间人换了钥匙必须拒) | `ios/Tests/Transport/HostIdentityTests.swift`(A1-A3:对着沙箱 sshd 真握手并跑一条命令;**真换一把主机密钥**之后必须被拒;宽松写法的指纹不许退化成"谁都收";空的/全空白/解析不出东西的指纹在开 socket **之前**就被拒;指纹算法和 `ssh-keygen` 对得上;`probeHostKeys` 是唯一一条允许"先看看对面是谁"的路) |
| 连不上的时候得说清是哪一种(私钥读不了 / 端口没人听 / 域名不存在 / 认证被拒) | `ios/Tests/Transport/ConnectFailureTests.swift`(A4:每种落到自己的错误,而且**两两文字不同**——全都塌成一句"连接断开"就红) |
| **经由(多跳路线)**:手机 → A → B → 目标,每一跳单独钉密钥,拒连时要说清是第几跳 | `ios/Tests/Transport/JumpChainTests.swift`(A5:沙箱起**三台真 sshd** 摆成 A→B→C,靠各自 sshd 日志里新增的 `direct-tcpip` 证明**每一跳都真走过**;`PermitOpen` 让 A 只能开到 B,所以顺序排错、跳过中间跳都连不上;把 B 的钉改成 **A 那把真密钥**必须被拒,而且文案点名「第 2 跳」;缺钉在**开 socket 之前**就拒;终点的钉在最后一段隧道里照样生效) |
| 老配置(单跳 `jumpHost` / 没有跳板)升级到「经由」之后行为不变 | `ios/Tests/Transport/RouteCompatibilityTests.swift`(A5b:老 JSON 解码成一元路线,地址/端口/用户名/钉逐个对上;**没有路线**的老配置走直连,拒连文案**逐字节**还是原来那句、不带跳号,而且两台跳板的日志**一行都不许多**) |
| 上传:分块协议在**真连接**上不丢字节、不留半个文件 | `ios/Tests/Transport/UploadTransferTests.swift`(A5:小文件、正好一整片、跨片边界一字节、多片、二进制敌意字节,落盘都要**逐字节相同**;传到一半取消,服务器上不许留残件) |
| 服务端安装脚本 `server/install.sh`(会覆盖线上启动目录、会重写凭据文件) | `server/tests/test_install.py` |

### B. 聊天(App 的主路径)

| 功能 | 谁盯着它 |
| --- | --- |
| 发消息、流式收回复(claude 后端) | `test_chat.py` + 第 3 层冒烟 + 第 4 层真 agent B1 |
| 发消息、流式收回复(codex 后端) | `test_chat.py` + 第 4 层真 agent B1 的 codex 孪生场景 |
| 网络分片:一个 JSON 被切在 UTF-8 字符中间也要拼得回来 | `ios/Tests/Store/StreamChunkingTests.swift` |
| 事件解析(文本/思考/工具调用/工具结果/计划/错误/最终 result) | `ios/Tests/Contract/EventCorpusTests.swift` + `server/tests/test_event_corpus.py`(用真语料) |
| 思考过程折叠展示 | 同上(解析层);外观只能人工验 |
| 工具 chip + 点开看 diff / 命令 / 写入内容 | `ios/Tests/Contract/DecodingTests.swift`(数据层);外观只能人工验 |
| Markdown 渲染、代码高亮、表格、可折叠区块 | 聊天气泡和刊物用的是同一个 `RichMessageText`,所以它的分块解析在 J 段那几条里被钉住了(标题层级、列表、引用、折叠、数据行、裸链接徽章);**表格、代码高亮和整体排版观感仍然只能人工验** |
| 长按选中文字、复制、查询、分享 | 只能人工验 —— UITextView 的原生手势 |
| 每个会话记住自己的模型/思考档位/运行模式/权限,切会话不串 | `ios/Tests/Store/ConversationParamsTests.swift` |
| 切会话时,上一个会话还在飞的回复不能落到新会话里 | `ios/Tests/Store/ConversationSwitchTests.swift` |
| 排队的后续消息在 App 被杀后还在 | `ios/Tests/Store/QueuePersistenceTests.swift` |
| 顶部用量环(5 小时窗 / 7 天上限 / 分模型额度池) | `test_sessions.py` + `DecodingTests`(`usage.json` 夹具) |
| 长按用户气泡「从这里重新说」(服务端 fork 会话) | `test_sessions.py`(fork) + `ios/Tests/Store/PervioChipTests.swift` |
| Codex 静默思考时的心跳保活(不让手机以为断线) | `test_chat.py` + `test_orchestrate_efficiency.py`(E4b 钉的是心跳**什么时候**到:10 秒的间隔,早到超过 1 秒就红。2026-08-08 在副本上实测:把间隔砍半的变异体 5.05 秒就到、当场红,而旧的"11 秒里 1~2 次"判据对同一个变异体是绿的;时间戳只会被机器负载推后、不会被推早,所以它量的是心跳不是负载。**代价写在这里**:比 1 秒更小的缩短(实测 8.5 秒的变异体 9.09 秒到)落在容差里,看不见) |
| 让 Pervio 起的 codex 会话出现在电脑端 `codex resume` 列表里 | `test_codex_index.py` |

**两个后端不对等,不是漏测**(依据 `docs/codex-event-schema.md` 的实测结论):

- codex **不吐推理文本**,高档位也不吐,只在结束时给一个 `reasoning_output_tokens`
  数字。所以没有 codex 的"思考"语料,也不可能有。
- codex **没有计划模式**(没有 ExitPlanMode 这类事件)。
- codex **没有审批通道**:`codex exec` 是非交互的,压根问不出问题来。它的权限面
  只有 `--sandbox`(拦写入),不会产生一个等你点 Allow/Deny 的请求。
- codex **调不了 MCP 工具**:`codex exec` 会自动取消每一次 MCP 工具调用
  (上游 openai/codex#24135、#16685),没有配置能关掉;所以我们干脆对 codex 一个
  工具都不挂。
- codex 事件里**没有单轮 cost 字段**,只有 token 数;算钱得自己乘单价。

所以真语料里 claude 有六种场景(文本/思考/工具/计划/审批/错误),codex 只有三种
(文本/工具/错误);真 agent 那层里 B4/B5/B6 也只有 claude 一侧。这些是对面 CLI
的事实,不是我们少测了——`bash scripts/test-release.sh --plan` 会把每条"没有孪生
场景"的原因连同上游 issue 号一起打出来。

### C. 审批(手机上点 Allow / Deny)

| 功能 | 谁盯着它 |
| --- | --- |
| Claude 要动文件/跑命令时,手机上弹出 Allow/Deny,选完那一轮**原地继续** | `test_approve.py`(服务端)+ `ios/Tests/Store/PermissionApprovalTests.swift`(B1:决定发到本轮那个被卡住的工具、连点两下只发一次、Deny 带上填的理由而空白不算、多个请求按序各答各的、轮结束后迟到的一点什么都不发、切会话/开新会话要丢掉待批、发送失败要报错并把请求放回来)+ 第 4 层真 agent B5(真 claude,Allow 一次 Deny 一次) |
| 审批事件和 claude 自己的输出合流到同一条管子(不合流手机就看不到弹窗) | `test_chat.py`(`pervio-chat-stream`) |
| 计划模式:Claude 出方案 → 手机上批准/继续改 | `DecodingTests` 的 ExitPlanMode 解析 + `test_event_corpus.py` 的 plan 语料 + `ios/Tests/Store/PlanApprovalTests.swift`(B1:方案要等这轮结束才浮出来、批准会把运行模式换成 `acceptEdits` 并发出继续、"继续改"留在计划模式并带上反馈、关掉不发东西也不动模式、历史里的计划 chip 重新打开取不到文本时要说出来);**弹窗本身的观感只能人工验** |
| Pervio 自家写操作工具(启动工作流/订阅定时/打分)也走审批,并把参数翻成人话 | `test_mcp.py`(哪些工具在免审批清单里);文案只能人工验 |
| Codex 的审批 | **不存在** —— codex 没有审批通道,这条能力只有 claude 有 |

### D. 附件与背景

| 功能 | 谁盯着它 |
| --- | --- |
| 从相册/文件选东西传到服务器,模型能按路径打开 | `test_upload.py` |
| 大图自动压缩后再传 | 只能人工验 |
| 「＋ → 背景…」:翻过去的对话,挑一个当这轮的上下文 | `test_sessions.py`(projects/list/transcript) |
| 跨项目搜索历史对话 | `test_sessions.py`(search) + `DecodingTests`(`search.json`) |
| 浏览服务器目录、把一个文本文件当背景带上 | `DecodingTests` 的 `serverfs-*` 夹具(含目录不存在、二进制文件、文件名里有乱码字符) |
| 背景附件的名字里带 `]` 不能把消息封装撑破 | `ios/Tests/Store/InlineAttachmentFrameTests.swift` |

### E. 后台运行、锁屏与通知

| 功能 | 谁盯着它 |
| --- | --- |
| Run 模式:任务脱离 SSH 在服务器后台跑,手机锁屏/断线都不影响 | `test_run.py`(start/tail/list/status/stop) |
| 浮在页面上的"运行中"胶囊,点开看进度 | `ios/Tests/Store/RunsListTests.swift`(读不懂服务器答复时必须当"不知道",不能当"没在跑") |
| 锁屏实时活动 / 灵动岛显示任务进度 | 只能人工验 —— ActivityKit 在模拟器上不完整,必须真机 |
| 任务完成的本地通知横幅 | 只能人工验 —— 通知权限和横幅展示要真机 |

### F. 工作流(多步 agent 编排)

| 功能 | 谁盯着它 |
| --- | --- |
| 多步依次跑,后一步用 `{{步骤id.output}}` 引用前一步的结果 | `test_orchestrate_unit.py` + 第 4 层真 agent B2/B3 |
| 命令步(不花模型额度的纯脚本步)和 agent 步混着排 | `test_schedule.py`(命令步)+ 第 4 层 B3 |
| 互不依赖的步骤并行跑、并发上限、合并不拖慢 agent | `test_orchestrate_efficiency.py` |
| 每步在自己的 git 工作树里跑,跑完合并,不污染用户当前工作区 | `test_orchestrate_unit.py` + `test_orchestrate_security.py` |
| 冲突、恶意 git 钩子、跑到一半被删、进程崩了 | `test_orchestrate_unit.py`(U4-U8)+ `test_convergence.py`(C2:runner 被 `kill -9` 之后,定时不会被一条永远 running 的记录卡死) |
| 注入、路径穿越、两个工作流互不干扰、文件权限 | `test_orchestrate_security.py` |
| 删除工作流 / 删除定时任务这类**不可逆**操作 | `test_orchestrate_delete.py`(服务端,已收录进 `run_all.sh`)+ `ios/Tests/Store/WorkflowDeleteTests.swift`(B2:删成功要真到服务器;删失败要把行放回来并说明原因;**服务端已经把它从 `list` 里删掉了、重新拉取也看不见它**的那种失败,错误行必须活过这次刷新;定时的删除/停用失败同样要说话)|
| 扇出:上一步产出一个列表,每项各起一个子 agent | `test_fanout.py` + `test_fanout_e2e.py`(真 agent) |
| 子 agent 派发的五道闸(授权/降级/深度/预算/并发) | `test_dispatch.py` + `test_dispatch_e2e.py`(真 agent) |
| 每步可以带一条 `verify` 命令(不过就不算 done)、整个工作流可以带 `setup`(每个新工作树跑一次) | `test_orchestrate_unit.py`(U10) |
| 超时、进程组回收、僵尸进程识别 | `test_audit_fixes.py` |
| App 里画工作流图、编辑步骤、切后端不串模型 id | 只能人工验 —— 编辑器是纯 UI |
| 工作流监控页:跑的时候看进度,跑完看结果 | `DecodingTests`(账本解析);页面只能人工验 |

### G. 定时刊物与出版物

| 功能 | 谁盯着它 |
| --- | --- |
| 订阅一个工作流到每天固定时间跑(增/改/删/开/关/立即跑一次/滴答) | `test_schedule.py` |
| 定时用的是**服务器本地时间**,手机跨时区不能算错第一期 | `ios/Tests/Store/ScheduleFirstIssueTests.swift` |
| 建日程的两条路(编辑器 Save / 市场一键订阅)对**同一个 spec** 必须起同一个日程名 —— 名字是市场判断「已订阅」的唯一线索,两边不一致就会给同一个工作流建出第二条日程,每天双跑双花钱 | `ios/Tests/Store/ScheduleNameAgreementTests.swift`(无名 spec:编辑器存过的那条,市场必须认得出来并拒绝重复;市场自己建的那条,名字必须是编辑器也会给的那个;有名字的 spec 按 spec 的名字来,不许被市场的展示标题顶掉) |
| 首页"今日出版物"卡片(空列表是正常状态,加载失败才提示) | `DecodingTests`(`archives.json`);外观只能人工验 |
| 首页三个快捷入口(新对话 / 工作流 / 让 Claude 帮我搭)点进去不能串页 | `ios/UITests/SmokeTests.swift`(真跑在模拟器上) |
| 往期阅读器(按日期翻刊物) | `DecodingTests`;翻页体验只能人工验 |
| 定时任务在系统层的注册(launchd) | `test_schedule.py` 里用跳过真注册的方式验了文件生命周期;**真的到点会不会被系统唤起,只能人工验** |
| 连着跑了两周之后状态还对不对(每天出刊、`keepRuns` 修剪、归档累积、磁盘不涨) | `server/tests/test_convergence.py`(C1-C4:时钟是**注入**的 `PERVIO_TICK_NOW`,十几天在几秒里演完,不真等;第 N 天时"磁盘上的运行目录 / `list` / schedule 记录"三份账必须讲同一个故事,而且被修剪掉的那些期刊物还留着;runner 猝死后日更不许停;第 7 天和第 13 天的占用**逐项相等**;系统时间回拨或跳变时,一期只出一次) |

### H. 市场与模板

| 功能 | 谁盯着它 |
| --- | --- |
| 内置市场:现成工作流一键装到自己服务器 | `ios/Tests/Store/MarketRefreshRaceTests.swift`(刷新和安装抢跑时不能回退状态) |
| 服务器端模板库(装好的模板会出现在市场里,不用发版) | `test_mcp.py` + `test_schedule.py`;`DecodingTests` 用 `templates.json` 夹具(含一个坏文件) |
| 「让 Claude 帮我写一个工作流」把模板直接写进服务器 | 只能人工验 —— 这是一段提示词 |
| 方法论(playbook)类模板:在对话里加载使用 | 只能人工验 |
| 市场条目的风险提示(工作流是可执行指令,装之前要看清) | 只能人工验 |
| 具名模板带参数一键启动 | 第 4 层真 agent B6 |

### I. 项目、历史与终端

| 功能 | 谁盯着它 |
| --- | --- |
| 项目列表(服务器上 Claude Code 有历史的目录),手输任意目录 | `test_sessions.py` + `DecodingTests`(`projects.json`) |
| 某个目录下的历史对话列表、点进去续聊(和电脑端共享同一份历史) | `test_sessions.py` + `DecodingTests`(`sessions-list.json`) |
| 一条坏记录不能把整屏历史/整个抄本弄空 | `DecodingTests`(逐字段容错解码) |
| 删除历史对话 | `test_sessions.py`(delete) |
| SSH 终端(tmux 保活,断线重连回到同一屏) | `test_term.sh`(参数解析、`~/` 展开、坏 `--dir` 要在碰 tmux 之前就被拒、`--list`/`--kill` 只跟自己那个 `-L pervio` socket 说话;全程用假 tmux,分支没跑到算 FAIL 不算 SKIP);**终端本体只能人工验**(需要真 PTY) |

### J. 论文晨报专线(目前唯一的"成品刊物")

| 功能 | 谁盯着它 |
| --- | --- |
| arXiv 抓取、时间窗过滤、分片(零 token 的数据层) | `test_arxiv_shard.py` 的 a-d(分片格式 + 编号切分不变量、v1 格式回归、429 重试)+ `test_schedule.py` S12 |
| 去重:哪些论文算"已经推荐过",以及 seen 文件被怎么写回磁盘 | `test_arxiv_shard.py` 的 e/f(部分新部分旧的一天、**逐字节**比对写回内容、2000 条上限从**旧**的那一头剪)+ `test_schedule.py` S12/S13(往返 + 两阶段 pending 暂存) |
| 长按论文链接给 👍/👎/多看/少看,写回记忆文件 | `test_feedback.py` |
| 报告里的长按菜单机制(模板声明正则 → 菜单 → 跑服务器命令,参数要正确转义) | `test_feedback.py`(服务端半边)+ `ios/Tests/Render/ReportActionContractTests.swift`(App 半边:菜单挂在哪些块上、命令按真论文 id 重建、捕获组不能从自己那个 shell 词里逃出去)+ `ios/Tests/Render/ReportMenuAttachmentTests.swift`(**渲染器真的把菜单挂上去了**:走一遍它构建出来的 view 值,把每个评分菜单的文字读回来——只信 `actionHits` 这个 helper 的话,哪天渲染器不再给标题挂菜单,上面那份"数量一致"照样全绿);**菜单弹出来好不好按只能人工验** |
| 手机上把刊物渲染出来:标题层级、列表、引用、`<details>` 折叠、数据行、裸链接徽章 | `ios/Tests/Render/ReportStructureTests.swift`(B1:输入是 `ios/Tests/Fixtures/reports/` 里**从真归档原样拷来**的三期论文晨报和一期 GitHub 刊,断言的是解析出来的块类型/层级/文本,不是像素) |
| 同一份报告,手机和 Mac 上的评分按钮必须长在同样的位置 | `ios/Tests/Render/ReportActionContractTests.swift`(B2:两端读同一份 `actions` 规格,**按钮组数量与位置逐一对齐**,任一端漂移就红;四处已知分歧被单独点名,见第六节)+ `ios/Tests/Render/ReportActionSafetyTests.swift`(这份"一致"是**有前提**的:两端对"命中之后允不允许变成按钮"根本没有共同规则——Mac 的 `_argv_safe` 拒绝 `-` 开头的捕获组,手机不拒。今天的正则捕不到破折号所以两边看起来一样;哪天上线的规格能捕到,它先红)+ `test_view.py`(Mac 半边) |
| 报告是不可信输入:里面的 HTML / 脚本片段必须变成可见文字 | `ios/Tests/Render/ReportEscapingTests.swift`(B3:喂的是 `test_view.py` C 组那段同款注入,两块屏幕同一个对手) |
| 刊物的边界形状:空的、只有一个折叠区、超长、CJK 与 emoji 混排 | `ios/Tests/Render/ReportBoundaryTests.swift`(B4:不崩、不吞内容、不卡住) |
| 手机上点一下,报告在 Mac 上自己打开(`pervio-view`) | `server/tests/test_view.py`(只绑 127.0.0.1 + 一次性 token;**开窗是 opt-in**:不给 `--open` 一次都不许碰 `open`,给了也只能是 `open -g`——不抢焦点。前台和 `--detach`(手机真正走的那条)两条路各真跑一遍,J19-J22 拿变异体证明这四条会红。整套跑在一个记录型的假 `open` 后面,测试自己永远不会在屏幕上弹东西)|

`test_view.py` 是**平台相关**的:非 macOS 上 `_raise_on_desktop` 在平台闸门那里就
返回了,`open` 根本不会被调到。所以那几条"开窗"的变异体(J19b/J20b/J22b)在非 Mac
上会**在同一份副本里连那道闸门一起抬掉**,让抢焦点的那行真的执行——否则它们读到的
永远是空日志,变异有没有都绿,名字里却写着 goes RED(2026-08-08 审计点名的就是这
个)。闸门本身在非 Mac 上做什么并没有丢:A10d/f/i/k 对**未改动**的产品断言"什么都
没调、`opened=false`、理由是 not macOS"。



### K. Pervio 自己的 MCP 工具层

| 功能 | 谁盯着它 |
| --- | --- |
| 11 个工具的握手、7 个只读工具免审批、4 个写/花钱工具进审批 | `test_mcp.py` |
| **真模型会不会自己选对工具**(而不是瞎猜) | 第 4 层真 agent B4 —— 这条用贵模型,考的就是判断力 |
| codex 侧挂载只读工具 | **不存在** —— `codex exec` 会自动取消每一次 MCP 调用(openai/codex#24135),所以对 codex 一个工具都不挂;第 4 层里如实标 skip 并写明这个原因 |

## 四、只能人工验的清单(发版前逐条勾)

机器测不了的,基本都是"要么得真机、要么得眼睛"。发版前拿真机走一遍,勾完为止。

**真机能力(模拟器给不出真实结论)**

- [ ] 锁屏实时活动:起一个 Run,锁屏,确认锁屏上出现任务卡片,工具调用在跳
- [ ] 灵动岛:同上,确认岛上有紧凑态,长按能展开
- [ ] 完全切到后台再回来:实时活动会停在最后状态(这是预期行为,不是 bug)
- [ ] 任务完成通知:App 在前台时是横幅,在后台时是通知中心一条
- [ ] 通知权限第一次弹窗的时机和文案
- [ ] 真机后台:发一个 Run,按 Home 键退出,几分钟后回来,进度接得上
- [ ] 断网/切 Wi-Fi 再回来,聊天页不炸、终端能重连回同一屏
- [ ] 私钥保存后杀掉 App 重开,还能连上(Keychain 真的写进去了)

**视觉与排版**

- [ ] 长回复的 Markdown 排版:标题层级、列表、表格、代码块高亮
- [ ] 代码块横向滚动、长行不截断
- [ ] 长按选中一段文字:放大镜、拖拽手柄、复制/查询/分享都在
- [ ] 深色模式下全部页面(App 强制深色)
- [ ] 中文字体/行距在小屏和大屏上都不挤
- [ ] 工具 chip 点开的 diff 视图:增删行颜色、长文件不卡

**交互路径(没有断言能描述"好用")**

- [ ] 审批弹窗:Allow 一次、Deny 一次,两次都要看到那一轮**继续往下走**
      (**只剩"屏幕上那张纸"这一半**:决定发出去之后的整条链路——路由到对的工具、
      连点两下只发一次、失败要报错并放回请求——已经由 `PermissionApprovalTests`
      钉住了;这里要用眼睛确认的是弹窗什么时候出现、按钮点得到、文案读得懂)
- [ ] 计划模式:出方案 → 点"继续改" → 再出方案 → 点批准
      (同上,`PlanApprovalTests` 管住了模式切换和发出去的内容,这里验观感)
- [ ] 工作流编辑器:加步骤、连依赖、切后端(切完模型 id 不能串)、图能画对
- [ ] 市场装一个工作流,确认服务器端 `templates list` 里出现了
- [ ] 定时订阅一个刊物,改时间、停用、再启用、立即跑一次
- [ ] 终端里跑一个长命令,退出 App 再进来,屏幕还在跑
- [ ] 首页"今日出版物"点进去能翻往期
- [ ] 长按论文链接打分,确认记忆文件里多了一行

**发版动作本身**

- [ ] `ios/project.yml` 是源头,版本号/构建号改的是它(不是 Xcode 工程)
- [ ] TestFlight 上传后,在真机上装下来跑一遍上面的真机清单

## 五、真 agent 那层:为什么默认不跑,大概花多少钱

第 4 层每跑一次都在花你自己的模型额度,所以:

1. **默认不跑**。不加 `--live` / `--e2e` 就一分钱不花,跑出来会明确写着"真 agent
   层这次没跑"。
   加了 `--live` 但套件还没装好(或 `run_all.sh` 还不认这个参数),会**如实报
   SKIP 并说明缺的是哪一半**;更要命的那种情况——参数被吞掉、什么都没跑却
   `exit 0`——脚本会当成 **FAIL**,不许一层什么都没测的绿色蒙混过关。
2. **付钱之前能先看账单**。`bash scripts/test-release.sh --plan` 是免费的,它会列出
   要跑哪些场景、每个用哪档模型、总共几轮、上限是多少,以及每条"codex 没有孪生
   场景"的具体原因。看完再决定要不要跑。
3. **能用便宜模型的都用便宜模型**。管子类场景(对话通不通、账本落没落、引用替换
   对不对)一律用最便宜的档;只有两条真正"考判断力"的——模型会不会自己挑对 MCP
   工具、会不会带对参数调具名模板——才用贵档,每类只留一条。
4. **有硬上限,而且是拦在花之前**。整批(冻结语料的采集 + 契约套件)封顶
   claude 25 轮 / codex 15 轮;采集已经用掉 8 / 5,契约套件把自己限在剩下的
   17 / 10,当前计划是 claude 8 轮 + codex 3 轮。套件在**启动每一轮之前**数一遍
   (包括工作流会替它起的那些子轮),要超了就直接拒绝跑,不是跑完再道歉。
   这个计数器只认得当前这个进程,所以连着跑好几次仍然会累计花钱——`--plan` 就是
   给你在按下去之前看清楚的。
5. **跑完有账**。每条打印自己花了多少 token,末尾一份总账;
   `scripts/test-release.sh` 会把带数字的那几行原样抄到最后的"真 agent 花费"里。

什么时候值得花这个钱:发版前一次、升级 claude/codex CLI 后一次。日常改代码不用。

## 六、已知的窟窿(不是 bug,是待办)

诚实记在这里,免得下次有人以为"全绿=全覆盖":

- **删除失败的时候,手机上看到的是"删干净了"**:`delete --wf` / `schedule remove`
  遇到删不掉的残留会 exit 非零、在 stderr 上点名残留路径、JSON 里回
  `deleted:false`;但 `rmtree` 在撞上残留之前已经把 `ledger.json` /
  `schedule.json` 删掉了,于是这条**当场从 `list` 里消失**——手机端看到的是一次
  干净的删除,磁盘上却还整个目录躺着,只有那次调用的返回码和 stderr 知道真相。
  `test_orchestrate_delete.py` 的 b/e 两例钉的就是这个现状(`list == []`),哪天
  把"报告"和"仓库"重新对上,那两条会变红,提醒把这一段一起改掉。
- **两阶段 seen 的后半截是手抄的**:提交步(`cat seen-pending.txt >> seen.txt`
  那一行)住在 `ios/Sources/Models/WorkflowMarket.swift` 的模板里,`test_schedule.py`
  S13 跑的是一份**手工复制**的副本。同一个套件对 verify 门做了逐字对照
  (`VERIFY in _dg`),对提交步没有——模板改了而测试照跑不误,这种漂移能悄悄发生。
  顺带记一笔:论文晨报跑的是两阶段模式(`--seen` + `--pending` 同时给),所以
  合并和上限归提交步管(`sort -u | tail -n 4000`),脚本自己那个 2000 条上限
  (`test_arxiv_shard.py` 的 f 段)只在**不带 `--pending`** 的用法里生效。
- **自研 SSH 加密套件的单测只测到"这两个方法自己"**:`AESCTRETMTests` 把
  `AES128CTRETM` 的加解密和 MAC 对着 CommonCrypto / NIST 向量钉死了,但**握手怎么
  协商到这个套件、密钥怎么导出**仍然只有第 3 层冒烟间接覆盖——而且大多数服务器给
  的是 AES-GCM,冒烟根本走不到 CTR 这条路。
- `pervio-term` 只测到参数解析、`~/` 展开和"只跟自己那个 `-L pervio` socket 说话",
  终端本体(真 PTY、tmux 保活、断线重连)没有自动化测试。
- App 的编辑器类页面(服务器档案、工作流编辑器)没有 UI 测试。
- **runner 被 kill -9 之后,账本自己不会好**:定时那一半是好的——日更照常出,
  `schedule list` 会把这条愈合成 `failed`;但那次运行的 `ledger.json` 永远停在
  `running`,`list` / `status` 跟着一起说 running,于是**两个读者对同一次运行给出
  两种答案**;而且这具尸体不吃 `keepRuns` 的修剪,每崩一次就多占一个目录。
  `test_convergence.py` 的 C2e/C2f 把这个**现状**倒着钉住了(和
  `test_orchestrate_delete.py` 钉删除失败的写法一样):哪天有人把它修好,那两条会
  变红,提醒把这一段和那两条检查一起删掉。
- **手机和 Mac 的报告渲染有四处已知分歧**,都由 `ios/Tests/Render/` 里带
  `KnownDivergence` 前缀的测试倒着钉住,免得它们悄悄变宽:
  (1)两条紧挨着的裸链接,Mac 会给两组按钮、手机只给一组(现有刊物还触发不到);
  (2)`[点我](javascript:...)` 这类非 http(s) 协议,Mac 拒绝变成链接,**手机照样
  变成可点的链接**;(3)大小写混写的 scheme,Mac 认、手机不认;(4)捕获组以 `-`
  开头时(比如 `--force`),Mac 不给那一条画按钮、`/score` 也拒绝这对参数,**手机
  照画菜单、照发命令**——引号只让它变成一个词,不会让它不再是一个以 `--` 开头的
  词。(2)和
  (4)是四条里有安全含义的两条。
- **审批/计划的覆盖停在 store 那一层**:`PermissionApprovalTests` /
  `PlanApprovalTests` 驱动的是真 `ChatStore` 加假 SSH,证明的是"点下去之后发出了
  什么";那张 sheet 本身有没有弹、弹得对不对、按钮点不点得到,没有测试看着,
  只有第四节那两条人工项。

## 七、跑挂了怎么办

- 每一层的完整日志在 `$TMPDIR/pervio-test-logs/<pid>/<层名>.log`(可以用
  `PERVIO_TEST_LOG_DIR` 改地方),汇总表里会直接给出路径。
- `RESULT: FAIL` 一定对应至少一层的 FAIL,先看那层的日志尾部。
- 出现 SKIP 的常见原因:模拟器一台都没有(Xcode 里加一台)、冒烟测试要的端口被占、
  或者你自己设了 `PERVIO_SKIP_*`。**SKIP 不是 PASS**,发版前必须清零。
  (你没加 `--live` 时真 agent 层不会记成 SKIP——见第二节的说明。)
- 想临时跳过某层:`PERVIO_SKIP_IOS=1` / `PERVIO_SKIP_SERVER=1` /
  `PERVIO_SKIP_SMOKE=1`,它们会被记成 SKIP 并写明原因,永远不会被算成通过。

关于这些脚本本身怎么写、怎么加新测试、夹具怎么重生成,见 `docs/testing.md`。
