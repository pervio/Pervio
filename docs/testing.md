# 测试体系

> **要发版?先看 [docs/test-plan.md](test-plan.md)。** 那份是给"决定发不发"的人看的:
> 关卡表(改代码后 / 发版前 / 升级 claude 或 codex 后各跑什么)、逐条功能"谁在盯着
> 它"、以及只能人工验的可勾选清单。一条命令是 `bash scripts/test-release.sh`
> (加 `--live` 才跑真 agent、才花额度)。
>
> 这份文档是**给改测试的人**看的:每层内部怎么实现、怎么加新测试、夹具怎么重生成、
> 钩子和夜间任务怎么装。两边不重复。

分层，一条命令跑完。层与层之间的分工是"多快能发现问题"：

| 层 | 内容 | 谁跑 | 耗时 |
| --- | --- | --- | --- |
| 0 `scripts-selftest` | `scripts/tests/test_scripts.sh`：测这套自动化本身（沙箱 + stub） | 只有 `test-all.sh` | 半分钟 |
| 1 `ios-unit` | `ios/Tests/` 下的 Swift 单测（解码契约 + ChatStore 竞态），跑在 iOS 模拟器上；这台机器能起沙箱 sshd 的话，它会**先起一个并轮换主机密钥**，`ios/Tests/Transport/` 才有真服务器可打（见下） | `test-fast.sh` / `test-all.sh` | 3-8 分钟 |
| 2 `server-suites` | `server/tests/run_all.sh`：全部无成本 python/bash 套件 + iOS 夹具新鲜度检查 | `test-fast.sh` / `test-all.sh` | 1-2 分钟 |
| 3 `ios-ui-smoke` | XCUITest 端到端（`server/tests/e2e_ios/run_smoke.sh`）：沙箱 sshd + 临时 HOME + shim claude，发一条消息断言回复气泡带回原样的 nonce | 只有 `test-all.sh` | 数分钟 |
| （可选） `server-e2e-quota` | 真 agent 的 e2e 套件，**花模型额度** | `test-all.sh --with-quota` | 数分钟 |

## 怎么跑

```bash
bash scripts/test-fast.sh          # 第 1+2 层：push 前跑这个
bash scripts/test-all.sh           # 全量（含第 3 层），不花额度
bash scripts/test-all.sh --with-quota   # 再加真 agent 的 e2e（花额度）
bash scripts/test-release.sh       # 发版关卡：同 test-all，外加游离套件、花费汇总、人工清单提醒
bash scripts/test-release.sh --plan     # 真 agent 那层要跑什么、花多少（免费）
bash scripts/test-release.sh --live     # 再加真 agent 契约套件（约 $0.5，见 test-plan.md）

bash server/tests/run_all.sh       # 只跑服务端那层
bash scripts/tests/test_scripts.sh # 测这些脚本本身（沙箱 + stub，半分钟）
```

只有全部通过才 `exit 0`。两行机器可读的结论固定长这样：

```
SUMMARY: 2 passed, 0 failed, 1 skipped
RESULT: PASS (1 skipped)
```

**skip 不等于 pass。** 前提缺失的层会被标成 SKIP 并打印原因，计入 summary，永远
不会被悄悄算进 passed 里。真跑了但挂了的层是 FAIL，整轮红。第 3 层的判定完全按
`run_smoke.sh` 的退出码：`0` 通过、`2` 环境没就绪（SKIP，附上它最后一行原因）、
**其他任何非零都是 FAIL**——"非零一律当成本机跑不了"正是坏掉的冒烟测试能藏几个月
的原因。

## `test-release.sh` 多做的五件事

它和 `test-all.sh` 共用 `scripts/lib/layers.sh`（同一套层机制、同样那两行结论）。
差别全在"发版"这件事本身：

- **`--live` / `--e2e` 不新增一层，而是把第 2 层那次调用加宽**。`run_all.sh` 的付费
  套件是免费套件的超集，分成两层就得把 19 个免费套件白跑第二遍（实测约 190 秒）。
  这也是 `test-all.sh --with-quota` 早就在用的写法。
- **花费汇总**。付费层跑完后，从那一层的日志里把**带数字的** token/cost 行原样抄到
  末尾。格式不是我们定的（属于真 agent 套件），所以只做宽松抓取并**逐字打印**——
  这里编一个数字比什么都不打印更糟。没跑付费层就明说"花费 0"。
- **不许假绿**。真 agent 层依赖 `server/tests/test_agents_live.py` 和
  `run_all.sh --live`。跑之前先确认这两样都在（缺哪个就单独记一条 SKIP 并写明缺的
  是哪个，第 2 层照常不带 `--live` 跑）；跑完再确认日志里真的出现过
  `test_agents_live`——一个把未知参数默默吞掉然后 `exit 0` 的 runner，会让"真 agent
  层"变成一层什么都没测的绿色，这条 FAIL 专治它。
- **`--plan` 先看账再花钱**。转发给 `test_agents_live.py --list`：场景、每条用哪档
  模型、总轮数与上限、每条"codex 没有孪生场景"的原因。全程免费。
- **游离套件兜底**（`server-orphan-suites` 层）。`run_all.sh` 没收录的免费测试文件
  由这一层代跑——没有入口在跑的测试等于不存在，而其中一个盯的是**不可逆的删除**。
  名单是**写死的、且只含免费套件**：用通配符迟早会扫进某个 `*_e2e` / `*_live` 然后
  替你花钱。收录进 `SUITES` 之后这层自动消失（它每次都 `grep` 一遍 `run_all.sh`）。
  另有一条**只检测不执行**的告警：任何 `server/tests/test_*` 既不在 `run_all.sh`
  里、也不在这份名单里，就打印出来——我们不知道一个没见过的文件会不会花钱，所以
  只提醒，绝不替你跑。

**"没要求跑"不记成 SKIP。** 不给 `--live` / `--e2e` 时只打一行说明，不进 summary
的 skip 计数——"我不想花这个钱"和"这层跑不了"是两回事，混在一起会让 `0 skipped`
变成不可能达到的目标，而一个永远达不到的目标等于没有目标。要求跑了却跑不起来
（套件不在、`run_all.sh` 不认这个参数）才是真 SKIP，计数。

收尾时如果有任何 SKIP，脚本会额外用一句话说"SKIP 不是 PASS，发版前请清零"——退出
码仍然是 0（确实没有东西 FAIL），但发版的人得看到这句。关卡怎么用见
[test-plan.md](test-plan.md)。

模拟器机型不写死：脚本每次问 `xcrun simctl list devices available`，优先用已经
booted 的 iPhone。旋钮：

| 环境变量 | 作用 |
| --- | --- |
| `PERVIO_DESTINATION` | 直接给 xcodebuild 的 `-destination`，跳过自动选机型 |
| `PERVIO_SKIP_IOS=1` / `PERVIO_SKIP_SERVER=1` / `PERVIO_SKIP_SMOKE=1` | 手动跳过第 1 / 2 / 3 层（记成 SKIP，不算 pass；`SKIP_SMOKE` 只对 `test-all.sh` / `test-release.sh` 有意义，比如那个 sshd 端口或模拟器正被别的东西占着） |
| `PERVIO_TEST_LOG_DIR` | 每层的完整日志目录（默认 `$TMPDIR/pervio-test-logs/<pid>`，每次运行一份——这些日志是判定依据，共享目录会让并发的两次运行互相截断） |
| `PERVIO_TEST_REPORT_DIR` | 夜间报告目录（默认 `~/.pervio/test-reports`） |
| `PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1` | 这台机器起不了沙箱 sshd 时，允许第 1 层跑完并记成 **UNVER**（见下）而不是红 |
| `PERVIO_UNIT_E2E_PORT` / `PERVIO_UNIT_E2E_ROOT` | 第 1 层自己那个沙箱 sshd 的端口和目录（默认 `2223` / `/tmp/pervio-e2e-ios-unit`，和第 3 层的 `2222` 分开） |

### 第三种结论：`RESULT: UNVERIFIED`

`ios/Tests/Transport/` 那批测试要对着**真的 sshd** 做握手——主机密钥不在 pin 里
必须被拒，这是产品的安全边界，没法用 fake 顶替。找不到端点时它们 `XCTSkip`，而
xcodebuild 把 skip 算进 “0 failures” 并照样打印 `** TEST SUCCEEDED **`。

2026-08-09 实测：仓库自带的每个 runner 都是
`Executed 188 tests, with 17 tests skipped and 0 failures` → `RESULT: PASS`，
17 个全是这一批，含 `testServerKeyOutsideThePinIsRefused`（拒绝中间人）。也就是说
安全边界从来没被跑过，而且没有任何地方说过这件事。

现在第 1 层自己把沙箱 sshd 起起来并**轮换主机密钥**，所以这些测试真的跑；
判定只看日志里有没有 skip，不看运行器的意图：

| 情况 | 结论 |
| --- | --- |
| 端点起来了，日志 0 个 skip | `PASS` |
| 起不来，测试 skip 了 | `ios-unit FAIL` + `SECURITY BOUNDARY NOT VERIFIED`，并逐个点名没跑的测试 |
| 起不来，但你显式 `PERVIO_ALLOW_UNVERIFIED_TRANSPORT=1` | `ios-unit UNVER`，收尾是 `RESULT: UNVERIFIED`，**永远不会**是 `RESULT: PASS` |

`SUMMARY:` 那行只在右边追加 `, N unverified`，老的 grep 不受影响；`RESULT:` 换了
词，是为了让任何盯着 “PASS” 的钩子/夜间日志/人在这种情况下都读不到它。
这三条各有回归测试（`scripts/tests/test_scripts.sh` D-T27…D-T30）。

`ios/Pervio.xcodeproj` 是 gitignore 的产物，`project.yml` 才是源头；脚本发现工程
缺失或比 `project.yml` 旧时会自己 `xcodegen generate`。第 1 层的构建产物落在
`ios/DerivedData/`（同样 gitignore，留着是为了增量——想要一次冷构建就删掉它）。

## pre-push 钩子（模板，默认不启用）

`.githooks/pre-push` 跑 `scripts/test-fast.sh`，红了就拦住 push。装/卸：

```bash
git config core.hooksPath .githooks     # 装
git config --unset core.hooksPath       # 卸
```

一次性绕过（真的紧急时）：`git push --no-verify`。只删分支的 push 不触发测试。
钩子是靠 git 从 stdin 喂 ref 列表来判断有没有东西要推的，所以别直接手跑它——想
先看看会不会挂，跑 `bash scripts/test-fast.sh` 就是同一件事。

仓库里**不预装**这个钩子：`.git/hooks/` 不进版本库，`core.hooksPath` 也不由任何
脚本替你设置——`scripts/tests/test_scripts.sh` 里有一条测试专门盯着这件事。

## 夜间全量任务（launchd 模板，同样不自动安装）

`scripts/nightly-tests.sh` 是被调度的入口：跑 `scripts/test-all.sh`，把整轮输出
（含 `RESULT:` 那行）追加进 `~/.pervio/test-reports/<YYYY-MM-DD>.log`，退出码跟着
测试走，并清掉 30 天前的旧报告（`PERVIO_TEST_REPORT_KEEP_DAYS` 可调）。

安装（`__REPO__` 换成你的检出路径）：

```bash
cd /path/to/Pervio
mkdir -p ~/Library/LaunchAgents
sed "s|__REPO__|$PWD|g" scripts/launchd/app.pervio.nightly-tests.plist.template \
  > ~/Library/LaunchAgents/app.pervio.nightly-tests.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/app.pervio.nightly-tests.plist
launchctl print gui/$(id -u)/app.pervio.nightly-tests | head -20   # 确认已加载
```

立刻试跑一次（不等到凌晨 3:30）：

```bash
launchctl kickstart -p gui/$(id -u)/app.pervio.nightly-tests
tail -f ~/.pervio/test-reports/$(date +%F).log
```

卸载：

```bash
launchctl bootout gui/$(id -u)/app.pervio.nightly-tests
rm ~/Library/LaunchAgents/app.pervio.nightly-tests.plist
```

几点前提，别踩：

- 用 **LaunchAgent 不是 LaunchDaemon**：xcodebuild 和模拟器要登录着的图形会话。
- Mac 睡着就不跑，launchd 会在下次唤醒时补跑一次；想准点就 `caffeinate` 或在
  节能设置里开定时唤醒。
- launchd 给的 PATH 很窄，模板里显式塞了 `/opt/homebrew/bin`（`xcodegen` 在那）。
- 脚本崩在写报告之前的话，痕迹在 `/tmp/pervio-nightly-tests.launchd.log`。

## 怎么加新测试

- **Swift 单测**：往 `ios/Tests/` 里加 `*.swift` 就行，`project.yml` 里
  `PervioTests` 的 `sources: Tests` 会自动收；不用改工程文件。测试名带上它钉住的
  缺陷编号（`testR3_…`），回归时一眼知道退回了什么。
- **服务端套件**：写 `server/tests/test_*.py`，然后把文件名加进
  `server/tests/run_all.sh` 的 `SUITES`。
- **端到端**：`ios/UITests/` + `server/tests/e2e_ios/`。入口是 `run_smoke.sh`
  （它自己起沙箱 sshd、生成带 UI target 的一次性工程、跑完拆掉），单独调试：
  `bash server/tests/e2e_ios/run_smoke.sh --keep`。改它时守住那三个退出码
  （0 / 1 / 2），第 3 层就是照着它们分 PASS / FAIL / SKIP 的。
- **要真服务器的传输层测试**：`ios/Tests/Transport/` 靠环境变量找沙箱端点，找不到
  就 XCTSkip。第 1 层现在自己负责把端点喂进去：`setup.sh rotate` 停掉沙箱 sshd、
  换一把**新的**主机密钥、在同地址同 `authorized_keys` 上重启，然后把换掉之前那把
  交给 `PERVIO_E2E_STALE_PIN`（`TEST_RUNNER_` 前缀是 xcodebuild 唯一支持的入口）。
  `testPinFromBeforeAHostKeyRotationIsRefused` 就是靠这个才真的跑起来的——在此之前
  没有任何地方设过这个变量，它是一条永远 skip 的绿线。
  轮换本身不许自证：`rotate` 成功前必须过三关（新旧两行不同、真 ssh 客户端钉新
  key 能进、钉旧 key 被拒），否则它宁可报错也不说自己轮换过。
  端点在的那一趟里**任何 skip 都是红的**——`ios/Tests/` 里统共只有两处 XCTSkip
  （没端点、没旧 key），这一趟两样都给了。
  跑完还会再跑一遍**负对照**：把服务器**当前**这把 key 当作"轮换前的 key"喂回去，
  那条测试必须变红、而且必须是"nothing was rotated"那一条断言红的。它要是绿了，
  说明这条测试给任何 pin 都会过——那是脚本自己失败，不是靠人记得手动验一次。
- **多跳路线（经由）**：`setup.sh start` 现在起的是**三台** sshd —— 目标 `PORT`、
  中间跳 `PORT+1`、最外跳 `PORT+2`，三把不同的主机密钥，而且每台的 `PermitOpen`
  只放行**下一台**。这不是摆设：最外跳物理上够不到目标，所以"顺序排错""跳过中间
  跳"在这套沙箱上是连不上，而不是碰巧连上了。两条独立的证据线——`setup.sh
  verify-chain` 用**原版 ssh** 的 `-J A,B` 走一遍并数两份日志里的 `direct-tcpip`，
  `ios/Tests/Transport/JumpChainTests.swift` 用 App 自己的实现走一遍、数同样两份。
  一个坑记下来：`ssh -J` **不会**把命令行 `-o` 传给中间那几跳（只传
  `-l/-p/-J/-F/-v`），所以 `verify-chain` 的身份和 host-key 策略必须写进 `-F` 指
  的那个 ssh_config，否则第一跳就 "Host key verification failed"。旧沙箱目录没有
  这台最外跳，`SandboxEndpoint.routeProfile()` 会照老规矩 XCTSkip 并告诉你重启。
- **脚本本身**：`scripts/tests/test_scripts.sh`，用沙箱 + stub 的
  `xcodebuild`/`xcrun`/`run_all.sh`/`run_smoke.sh` 驱动，可以直接演"xcodebuild
  挂了""一台模拟器都没有""sshd 没准备好"这些情况，不需要真让它们发生。它自己是
  `test-all.sh` 的第 0 层——注意它跑的沙箱里也有一份 `test-all.sh`，所以进沙箱前
  会带上 `PERVIO_SELFTEST_ACTIVE=1`，嵌套的那层直接 SKIP，否则会无限套娃。

## 夹具怎么重生成

`ios/Tests/Fixtures/*.json` 全是真脚本的 stdout，禁止手写：

```bash
python3 server/tests/export_fixtures.py          # 重新导出
python3 server/tests/export_fixtures.py --check  # 只检查是否漂移（run_all.sh 会跑这个）
```

服务端输出形状一变，`--check` 就红——这样"夹具过期但 iOS 测试照绿"不会发生。
改完记得把新夹具连同产生它的代码一起提交。
