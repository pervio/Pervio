# Pervio 部署指南

一台常开的 Mac + 一部 iPhone,基础安装约 15 分钟。装完的效果:手机通过 Tailscale 连接自己的 Mac,运行 Claude Code 和工作流,晨报定时送到锁屏。

---

## 先拿到 App

Pervio 目前通过 TestFlight 公开测试分发,不用申请、不用发邮箱:

1. 手机装好 **TestFlight**(App Store 搜索即有)
2. 在手机上打开 <https://testflight.apple.com/join/EagwZXV1>,点接受,安装 **Pervio**

想自己编译:见仓库根目录 README 的"从源码构建"。

## 第 0 步 · 你需要准备

- 一台 Mac(建议插电常开,它是干活的那台)
- 一部 iPhone
- Mac 上有管理员权限(装东西要输一次密码)。
  怎么判断:系统设置 → 用户与群组,自己名字下方写着"管理员"就是;
  自己买的 Mac、第一个建的账户,几乎都是管理员。
  为什么需要:开"远程登录"、装 Tailscale/Node 属于系统级操作。
  看安装路径不同,macOS 可能弹 0-2 次密码/确认框(App Store 装的
  Tailscale、brew 装的 Node 往往一次都不弹);真弹了,输你平时开机
  解锁的那个密码就行。Pervio 运行本身不要任何特权,只有装这一次可能用到。

---

## 第 1 步 · 打通网络(Tailscale)

Pervio 通过 SSH 连接你自己的 Mac,Tailscale 负责两台设备之间的网络(手机和 Mac 在同一个 Wi-Fi 下只想先试试,可以跳过这一步,直接用 Mac 的局域网地址)。通常优先直连;不能直连时会经过 Tailscale 的加密中继,不是始终直连。

**手机和电脑使用你自己的同一个 Tailscale 账号,并且两端都选择你自己创建/管理的个人网络(tailnet)。** 同一登录账号可能属于多个 tailnet;如果你还在公司/学校的共享网络里,先切到个人网络,否则设备列表不是只有你自己的设备。

1. **两端都装 Tailscale**
   - Mac:到官方下载页 [https://tailscale.com/download](https://tailscale.com/download) 下载安装;
   - iPhone:App Store 搜「Tailscale」安装。
2. **登录你自己的账号**
   - Mac 上登录/注册你自己的 Tailscale 账号;
   - iPhone 上用**同一个账号**登录,允许它添加 VPN 配置、把开关打开;
   - 核对两端当前选中的都是自己的个人 tailnet;
   - 确认在自己的 Tailscale 设备列表里能看到这台 Mac 和 iPhone。先用官方 Tailscale App 完成首次验证。
3. **记下 Mac 的 IP**
   - Mac 菜单栏点 Tailscale 图标 → 点自己这台机器名,即复制形如 `100.x.y.z` 的地址;
   - 或在终端跑:`tailscale ip -4`
     (若提示找不到命令——App Store 版没把命令放进 PATH——用完整路径:
     `TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4`)
   - 手机 Tailscale 的设备列表里也能看到这台 Mac 和同一个 IP。

> Mac 在线且未睡眠、两端 Tailscale 已连接时,用这个地址访问 Mac。切换 WiFi/蜂窝网络一般不需要重配;删除设备或重新注册后,请重新核对地址。

---

## 第 2 步 · Mac 开三样东西

1. **远程登录(SSH)——必须**
   系统设置 → 通用 → 共享 → 打开「远程登录」。
   "允许访问"选"仅这些用户:你自己"即可。
2. **引擎:Claude Code、Codex 或 Cursor,至少装一个**
   聊天、后台 Run、双开、工作流步骤用哪家都行;市场里自带的工作流模板目前每一步写的都是 Claude,只装 Codex 或 Cursor 的话这些刊物暂时跑不了。
   没有 npm 就先装 Node:[https://nodejs.org](https://nodejs.org)。

   **Claude Code**

   ```
   npm install -g @anthropic-ai/claude-code
   claude
   ```

   跑一次 `claude` 按提示登录你的 Anthropic 账号,能对话即成。
   **登录要在 Mac 自己的"终端"app 里做,不要在手机的终端里做。** 原因:Claude Code 把登录凭据存在 macOS 钥匙串,
   Pervio 在后台起 `claude` 时走的是 SSH 的非交互进程,读不到钥匙串就会报"未登录"——哪怕你在手机终端里能聊。
   如果 Mac 没有图形登录(比如常年黑屏的 mini),或者你就是想在手机终端里装,用长期令牌:

   ```
   claude setup-token                        # 按提示授权,得到一串 token(约一年有效)
   mkdir -p ~/.pervio && chmod 700 ~/.pervio
   printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' '粘贴那串token' > ~/.pervio/credentials.env
   chmod 600 ~/.pervio/credentials.env
   ```

   Pervio 的启动脚本起任何引擎前都会读这个文件,不依赖 `~/.zshrc`(非交互 SSH 不读它)。
   不想在 Mac 上敲命令,也可以在手机 app 的服务器设置里找到「Claude token」一栏,把 `claude setup-token` 的结果粘进去,app 会写到 Mac 上同一个文件。

   **Codex**

   ```
   npm install -g @openai/codex
   codex login
   ```

   按提示用 ChatGPT 账号登录。Codex 把凭据存在 `~/.codex/auth.json`,SSH 下直接能读,没有钥匙串的问题。
   **Cursor**

   ```
   curl https://cursor.com/install -fsS | bash   # 装到 ~/.local/bin/agent,不改 shell 配置
   NO_OPEN_BROWSER=1 ~/.local/bin/agent login    # 打印一个网址,任何设备的浏览器里登录即可
   ```

   免费的 Hobby 账号就能登录。Cursor 的登录态在 `~/.cursor/`,SSH 下能用。它的模型菜单是账号自己的(`agent models`),手机连上后自动拿到。

   手机连上这台 Mac 时会探测装了什么:默认引擎没装、别家装了,就自动切过去,不用手动选;服务器列表下面会写出 `claude ✗ · codex ✓ · cursor ✓ · tmux ✓`。市场里要 Claude 的模板会灰掉并写明原因。

   **工作目录就是范围**:手机上这台机器只看这个文件夹及其子文件夹里的东西——对话列表、全文搜索、后台任务、新对话选目录都出不去(给对话附加文件不受限,`~/a` 的条目也能附上 `~` 下任何文件)。填 `~` 看整台 Mac,填 `~/a` 只看 a。同一台 Mac 可以添加多次,每条配置一个工作目录,各看各的范围(比如一条 `~` 看全部,再按项目各加一条)。

   **第三方供应商(可选)**:GLM、Kimi、MiniMax、DeepSeek 这类兼容端点,可以让 Claude Code 或 Codex 的壳跑它们的模型。在手机 app 的对话设置或服务器设置里「添加供应商」,先从常用里选一家(智谱 GLM、Kimi、MiniMax、DeepSeek、通义千问、OpenRouter;有地区之分的选中国区或国际版),地址和模型名自动填好,只粘 API key;保存时会用 key 问一次它的模型清单。app 写到 Mac 的 `~/.pervio/providers/<名字>.env`(0600),之后在任何对话顶栏的徽章菜单里一点就切。填错了点那一行就能改(地址、模型名、换 key;key 留空就沿用 Mac 上存的);引擎和地址对不上(Claude 填了 `…/v1`、`/paas/v4` 这类 OpenAI 地址,或 Codex 填了 `…/anthropic`)表单会标橙提醒,但不会替你改。已经按官方方式配在 `~/.claude/settings.json` 的 env 或 `~/.codex/config.toml` 的 model_providers 里的,会自动出现在名单里。Cursor 没有这一层,它只认自己的账号。

3. **python3——工作流引擎需要**
   终端跑 `python3 --version`;若弹出"安装命令行开发者工具"就点安装,装完再验一次。
4. **tmux——手机上的"终端"需要**(聊天和工作流不需要)
   `brew install tmux`(没有 Homebrew 先装:[https://brew.sh](https://brew.sh))。没装的话,手机终端会直接告诉你缺它。

**建议**:系统设置 → 显示器 → 打开「显示器关闭时防止自动进入睡眠」(或插电时不睡眠)。Mac 睡死了,定时工作流会睡过头。

(可选)Codex 引擎:装了 `codex` 命令并登录的,双引擎类工作流自动可用;没装也不影响其他一切。

---

## 可选 · 网络不容易直连时

两台设备打不通直连时,Tailscale 会自动改走它的官方加密中继:能用,只是慢一些,不用做任何配置。
想更快,可以在离自己近的地方自建一台 DERP 中继,按 [Tailscale 官方说明](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers) 加进自己的网络规则。
无论走哪条路,Pervio 里填的始终是你自己 Mac 的 `100.x.y.z`,不是中继的地址。

---

## 第 3 步 · 装 app,连上

1. 打开装好的 Pervio(怎么装见开头"先拿到 App")。
2. app 里:服务器 → 添加,表单照下面填(界面为英文,逐字对应):
   - **Name**:随便起,如「我的 Mac」
   - **Host (IP or domain)**:第 1 步记下的 `100.x.y.z`(怎么看 IP 见第 1 步第 3 条)
   - **Port**:留默认 **22**——这是 SSH 的标准端口;只有你自己改过 Mac 的 sshd 端口才需要填别的
   - **Username**:Mac 的登录用户名。**怎么查**:打开 Mac 的"终端",输入 `whoami` 回车,显示的那一串就是(不是"电脑名",也不是 Apple ID)
   - **Method**:**推荐用 Key(密钥)登录**,密码方式可被反复猜试,密钥在数学上猜不动。三条命令生成专用密钥(在 Mac 终端逐条执行):

     ```
     ssh-keygen -t ed25519 -f ~/.ssh/pervio_phone -N ""
     cat ~/.ssh/pervio_phone.pub >> ~/.ssh/authorized_keys
     chmod 600 ~/.ssh/authorized_keys
     ```

     然后 `cat ~/.ssh/pervio_phone` 把**私钥全文**复制,粘进表单的 Key 输入框(私钥只存 iOS 钥匙串,不落盘不上传)。
     图省事也可切到 **Password** 用 Mac 登录密码先跑通,之后再换密钥。
   - **Project dir on server**:留默认 `~` 即可
3. **钉住这台 Mac 的身份(必做)**:表单下方 "Server identity (host-key pinning)" 区,点 **Fetch host key from server**——app 会读取这台 Mac 的身份指纹给你钉住(这一步只看指纹、不登录,你的密码或密钥不会在这时发出去,所以没填凭据也能先取)。它的作用:以后每次连接都核对指纹,**指纹不符直接拒连**,这是防"中间人冒充你的 Mac"的锁;不钉,app 会拒绝连接。
4. 保存并连接。首连 app 会**自动把服务器脚本铺到 Mac**(几秒,页面会显示"正在铺设服务器组件…"),以后 app 升级也自动同步脚本,零维护。

---

## 第 4 步 · 验证与排错

- 主页出现问候语和卡片 = 成功。市场里订阅一个工作流试试(比如论文晨报)。
- **连不上?点报错下面的「运行连接体检」**,它逐项检查并用人话告诉你怎么修:
  - 连接被拒 → 远程登录没开(见第 2 步)
  - 超时 → 先核对手机/Mac 的 Tailscale 已连接、使用自己的同一个账号、Host 是自己 Mac 的当前地址,以及 Mac 没有睡眠;也可能是网络限制
  - 认证失败 → 用户名或密码不对(用户名是 `whoami` 的输出,不是"电脑名")
  - claude 没装/没登录、python3 缺失 → 体检会直接点名,照提示装

## 常见问题

- **换网络要重配吗?** 一般不用。保持两端 Tailscale 已连接,等待网络切换后恢复;如果删除/重新注册设备,请重新核对地址。
- **Mac 重启了?** 一切自恢复,app 重连即可。
- **想卸载?** 删 app;Mac 上的脚本和数据都在 `~/.pervio` 里,删掉它即可。删之前先做两件事:设过定时工作流的,在 app 里把定时都删掉或关掉(或在 Mac 上跑 `launchctl bootout gui/$(id -u)/com.pervio.schedule; rm -f ~/Library/LaunchAgents/com.pervio.schedule.plist`),否则系统里会留下一条每五分钟空跑一次的定时任务;开过终端的,跑 `tmux -L pervio kill-server` 关掉还活着的会话。
- **隐私**:对话、文件、任务只在手机和你自己的 Mac 之间走 SSH,外面再包一层 Tailscale 加密;经过 Tailscale 中继时,中继看得到连接 IP、时间和流量这些元数据,看不到内容。锁屏推送是另一条链路:Mac 把那条通知(标题和一两行正文)交给 Pervio 的推送中继,中继转给苹果 APNs——中继不记录内容,但内容经过它。不想经过中继:在 Mac 上把 `off` 写进 `~/.pervio/push/gateway`,锁屏推送随之关闭(app 开着时仍有本地提醒)。细节见 [apns.md](apns.md)。