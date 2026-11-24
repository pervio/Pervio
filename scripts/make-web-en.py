#!/usr/bin/env python3
"""make-web-en — web/en.html = web/index.html with every visible string translated.

    python3 scripts/make-web-en.py        (from the repository root)

Layout, CSS and script stay byte-identical; a string that fails to match, or
any Chinese left in the visible text, stops the build. The captures are swapped
for their English twins (scripts/site-shots.sh stages both languages; an English
capture is not always as tall as the Chinese one, so its height travels with it).
"Docs" and "Setup" lead to web/docs-en.html, the guide in English (written by
hand; scripts/check-docs-en.py holds it to the Chinese guide's shape)."""
import re, sys
src = open("web/index.html", encoding="utf-8").read()
GH = "docs-en.html"
SETUP = "docs-en.html#install"
TF = "https://testflight.apple.com/join/EagwZXV1"
T = [  # (old, new, how many times it must occur) — longer strings before their substrings
 ('<html lang="zh-CN">', '<html lang="en">', 1),
 ('content="Pervio 是一个 iPhone app，用 SSH 连上你自己的电脑，在手机上用电脑里装好的 Claude Code、Codex、Cursor。手机锁屏、断网，任务照样跑，做完了或者要你批准会发通知。开源。"',
  'content="Pervio is an iPhone app. It connects to your own computer over SSH, so you can use the Claude Code, Codex and Cursor installed there from your phone. Tasks keep running when the phone is locked or offline, and you get a notification when one is done or needs your approval. Open source."', 1),
 ('content="用手机指挥你自己电脑上的编程 agent：Claude Code、Codex、Cursor。只走 SSH，开源。"',
  'content="The coding agents on your computer, from your phone: Claude Code, Codex, Cursor. SSH only, open source."', 1),
 # the pictures: each language has its own capture, and its own height
 ('srcset="assets/shots/chat-zh.avif"', 'srcset="assets/shots/chat-en.avif"', 1),
 ('<img src="assets/shots/chat-zh.png" width="720" height="1564" alt="和 Claude Code 的一段对话：它查了三个地方，找到登录接口偶发 500 的原因，改好并通过测试">',
  '<img src="assets/shots/chat-en.png" width="720" height="1564" alt="A conversation with Claude Code: it looks in three places, finds why the login endpoint sometimes returns a 500, fixes it and passes the tests">', 1),
 ('srcset="assets/shots/step-ask-zh.avif"', 'srcset="assets/shots/step-ask-en.avif"', 1),
 ('<img src="assets/shots/step-ask-zh.jpg" width="1320" height="1312" loading="lazy" alt="对话界面：工具调用一行一条，下面是它的结论">',
  '<img src="assets/shots/step-ask-en.jpg" width="1320" height="1540" loading="lazy" alt="The chat screen: one row per tool call, the agent\'s finding underneath">', 1),
 ('srcset="assets/shots/step-run-zh.avif"', 'srcset="assets/shots/step-run-en.avif"', 1),
 ('<img src="assets/shots/step-run-zh.jpg" width="1320" height="1532" loading="lazy" alt="一个还在跑的任务：中途插入的一句话，输入框上方一行写着后台还有一条命令在跑">',
  '<img src="assets/shots/step-run-en.jpg" width="1320" height="1672" loading="lazy" alt="A task still running: a message added midway, and a line above the input box saying one command is still running in the background">', 1),
 ('srcset="assets/shots/step-approve-zh.avif"', 'srcset="assets/shots/step-approve-en.avif"', 1),
 ('<img src="assets/shots/step-approve-zh.jpg" width="1320" height="1568" loading="lazy" alt="审批弹窗：agent 想执行 git push origin release，下面是允许和拒绝">',
  '<img src="assets/shots/step-approve-en.jpg" width="1320" height="1568" loading="lazy" alt="The approval sheet: the agent wants to run git push origin release, with Allow and Deny below">', 1),
 ('srcset="assets/shots/step-duet-zh.avif"', 'srcset="assets/shots/step-duet-en.avif"', 1),
 ('srcset="assets/shots/step-workflow-zh.avif"', 'srcset="assets/shots/step-workflow-en.avif"', 1),
 ('<img src="assets/shots/step-workflow-zh.jpg" width="1320" height="1644" loading="lazy" alt="一条工作流跑到一半的流程图：前四步已完成，第五步正在跑，后两步还没开始">',
  '<img src="assets/shots/step-workflow-en.jpg" width="1320" height="1644" loading="lazy" alt="The diagram of a workflow halfway through: the first four steps are done, the fifth is running, and the last two have not started">', 1),
 ('<img src="assets/shots/step-duet-zh.jpg" width="1320" height="1748" loading="lazy" alt="监督模式下的一组对话：主对话按监督者的意见改了第二遍，下面的横幅写着通过，轮次条上第一轮是继续、第二轮是通过">',
  '<img src="assets/shots/step-duet-en.jpg" width="1320" height="1682" loading="lazy" alt="A Duet in Watch mode: the primary has redone the work after the watcher\'s feedback, a banner below says Passed, and the round rail shows go on for round 1 and pass for round 2">', 1),
 ('<img src="assets/shots/notif-approve-zh.png" width="1277" height="202" loading="lazy" alt="通知：Claude 在等你批准，跑命令">',
  '<img src="assets/shots/notif-approve-en.png" width="1277" height="202" loading="lazy" alt="Notification: Claude is waiting for your approval, run a command">', 1),
 ('<img src="assets/shots/notif-done-zh.png" width="1277" height="202" loading="lazy" alt="通知：shop-api 任务完成，合到 release 分支，再跑一遍全量测试">',
  '<img src="assets/shots/notif-done-en.png" width="1277" height="202" loading="lazy" alt="Notification: shop-api, task finished. Merge it into release and run the full test suite">', 1),
 ('<img src="assets/shots/island-zh.png" width="720" height="230" loading="lazy" alt="灵动岛展开：六步完成了四步，下面是它正在做的动作">',
  '<img src="assets/shots/island-en.png" width="720" height="230" loading="lazy" alt="The Dynamic Island, expanded: four of six steps done, the current action underneath">', 1),
 ('alt="黄昏的海岸，一道雾堤从陆地涌向海面"', 'alt="A coast at dusk, a bank of fog rolling off the land over the sea"', 1),
 ('alt="同一片海岸，雾堤的尽头和天边最后的光"', 'alt="The same coast: the end of the fog bank and the last light on the horizon"', 1),
 # nav
 ('<a class="skip" href="#features">跳到正文</a>', '<a class="skip" href="#features">Skip to content</a>', 1),
 ('aria-label="站内导航"', 'aria-label="Site"', 1),
 ('<a class="hide-s" href="#features">功能</a>', '<a class="hide-s" href="#features">Features</a>', 1),
 ('<a class="hide-s" href="#wire">怎么连</a>', '<a class="hide-s" href="#wire">How it connects</a>', 1),
 ('<a href="docs.html">文档</a>', '<a href="%s">Docs</a>' % GH, 2),
 ('<a href="en.html">EN</a>', '<a href="index.html" lang="zh-CN">中文</a>', 1),
 ('<a class="btn btn--small" href="%s">加入公测</a>' % TF, '<a class="btn btn--small" href="%s">Join the beta</a>' % TF, 1),
 # hero
 ('<h1>用手机指挥<br>你自己电脑上的<br>编程 agent</h1>', '<h1>The coding agents<br> on your computer,<br> from your phone</h1>', 1),
 ('<p class="lead">Pervio 是一个 iPhone app。它用 SSH 连上你的电脑，直接用上面装好的 Claude Code、Codex、Cursor。手机锁屏了、没网了，任务照样在电脑上跑。</p>',
  '<p class="lead">Pervio is an iPhone app. It connects to your computer over SSH and uses the Claude Code, Codex and Cursor already installed there. When the phone is locked or offline, the task keeps running on the computer.</p>', 1),
 ('<a class="btn" href="%s">加入公测</a>' % TF, '<a class="btn" href="%s">Join the beta</a>' % TF, 2),
 ('<a class="btn btn--ghost" href="docs.html#install">安装指南</a>', '<a class="btn btn--ghost" href="%s">Setup guide</a>' % SETUP, 1),
 ('<p class="hero__note">TestFlight 公测，需要 iOS 17。电脑用 Mac，Linux 也可以。开源，不用注册账号。</p>',
  '<p class="hero__note">Public beta on TestFlight, iOS 17 or later. The computer can be a Mac or a Linux machine. Open source, no account needed.</p>', 1),
 # main features
 ('<h2>主要功能</h2>', '<h2>Main features</h2>', 1),
 ('<h3>对话</h3>', '<h3>Chat</h3>', 1),
 ('<p>agent 在电脑上读文件、跑命令、改代码，每一步在对话里占一行，点开能看到 diff 或者完整的命令。</p>',
  '<p>The agent reads files, runs commands and edits code on your computer. Each step is one row in the conversation, and you can open it to see the diff or the full command.</p>', 1),
 ('<p>对话和电脑上的是同一批。在终端或编辑器里聊到一半的，手机上可以接着聊。</p>',
  '<p>These are the same conversations you have on the computer. One you left halfway in the terminal or the editor can be picked up on the phone.</p>', 1),
 ('<figcaption>它查了三个地方，找到了登录接口偶尔返回 500 的原因。</figcaption>',
  '<figcaption>It looked in three places and found why the login endpoint sometimes returns a 500.</figcaption>', 1),
 ('<h3>Run 模式</h3>', '<h3>Run mode</h3>', 1),
 ('<p>任务跑在电脑上，不需要手机一直连着。锁屏、切到别的 app、断网都没关系，回来接着看就行。</p>',
  '<p>The task runs on the computer and doesn\'t need the phone to stay connected. You can lock the screen, switch apps or lose signal, and just read on when you come back.</p>', 1),
 ('<p>它干活的时候你可以插一句话，不用等它停下来（Claude Code 和 Codex 支持）。它放到后台的命令和子 agent，在输入框上方有一行汇总，点开能看每一个在做什么。</p>',
  '<p>You can send it a message while it is working, without waiting for it to stop (Claude Code and Codex). The commands and sub-agents it puts in the background are summed up in one line above the input box. Tap it to see what each one is doing.</p>', 1),
 ('<figcaption>全量测试在后台跑着，中途又发了一句话。</figcaption>',
  '<figcaption>The full test suite is running in the background, and another message was sent midway.</figcaption>', 1),
 ('<h3>审批</h3>', '<h3>Approvals</h3>', 1),
 ('<p>agent 要改文件或者跑命令的时候会先停下来。手机上能看到它要执行什么，你点允许或拒绝。</p>',
  '<p>When the agent wants to edit a file or run a command, it stops first. The phone shows what it is about to run, and you tap Allow or Deny.</p>', 1),
 ('<p>不想每次都点，可以把权限放宽，比如文件改动不再问。也可以让它先出计划，你同意了再动手。</p>',
  '<p>If you don\'t want to tap every time, you can loosen the permission, for example stop asking about file edits. You can also have it write a plan first and start only after you agree.</p>', 1),
 ('<figcaption>它要执行 git push，先停下来问你。</figcaption>', '<figcaption>It wants to run git push and stops to ask first.</figcaption>', 1),
 ('<h3>双开</h3>', '<h3>Duet</h3>', 1),
 ('<p>让两个模型一起做一件事，通常是不同的两家，比如 Claude 和 Codex。</p>',
  '<p>Two models work on the same thing, usually from two different vendors, for example Claude and Codex.</p>', 1),
 ('<p>「监督」是一个干活，另一个检查，有问题就打回去重做，最多三轮，需要你拿主意的时候会通知你。「头脑风暴」是两边各答各的，再由主对话把分歧和结论整理出来。</p>',
  '<p>In Watch, one does the work and the other checks it, sending it back if something is wrong, for up to three rounds. You get a notification when it needs you to decide. In Brainstorm, both answer on their own, and the main conversation then sorts out where they differ and what to conclude.</p>', 1),
 ('<figcaption>Claude 干活，Codex 检查。第一轮被打回，第二轮通过。</figcaption>',
  '<figcaption>Claude does the work and Codex checks it. Sent back in round one, passed in round two.</figcaption>', 1),
 # when the app is closed
 ('<h2>锁屏和通知</h2>', '<h2>Lock screen and notifications</h2>', 1),
 ('<p class="lead">任务做完了，或者停下来等你批准，手机会收到通知。任务在跑的时候，进度显示在灵动岛和锁屏上。</p>',
  '<p class="lead">When a task is done, or has stopped to wait for your approval, the phone gets a notification. While a task is running, its progress shows in the Dynamic Island and on the lock screen.</p>', 1),
 ('<figcaption><b>通知</b>一条是在等你批准，一条是任务做完了。</figcaption>',
  '<figcaption><b>Notifications</b>One is waiting for your approval, the other says a task is done.</figcaption>', 1),
 ('<figcaption><b>灵动岛</b>展开能看到进度。图里这条工作流一共六步，做完了四步。</figcaption>',
  '<figcaption><b>Dynamic Island</b>Expand it to see progress. This workflow has six steps, and four are done.</figcaption>', 1),
 # the rest
 ('<h2>其他功能</h2>', '<h2>Other features</h2>', 1),
 ('<p class="lead">这些也都走那一条 SSH 连接，电脑上不用另外装东西（终端要装 tmux）。</p>',
  '<p class="lead">These also use that one SSH connection, with nothing else to install on the computer (the terminal needs tmux).</p>', 1),
 ('<h3>引擎和供应商</h3>', '<h3>Engines and providers</h3>', 1),
 ('<p>Claude Code、Codex、Cursor 都能用，用的就是你电脑上装好、登录好的那一份。也可以换成第三方供应商，比如智谱 GLM、Kimi、MiniMax、DeepSeek、通义千问、OpenRouter，API key 只存在电脑上。</p>',
  '<p>Claude Code, Codex and Cursor all work, and it is the copy already installed and logged in on your computer. You can also switch to a third-party provider such as GLM, Kimi, MiniMax, DeepSeek, Qwen or OpenRouter. API keys are stored only on the computer.</p>', 1),
 ('<h3>网页预览</h3>', '<h3>Web preview</h3>', 1),
 ('<p>电脑上 localhost 的网页，比如开发服务器、文档站，可以直接在手机上打开。走的还是 SSH，端口不用对外开。看到的页面可以截图发回对话里。</p>',
  '<p>A page on your computer\'s localhost, such as a dev server or a docs site, opens directly on the phone. It still goes through SSH, so no port needs to be opened. You can screenshot the page and send it back into the conversation.</p>', 1),
 ('<h3>终端</h3>', '<h3>Terminal</h3>', 1),
 ('<p>底下是 tmux，所以断线了会话还在，连回来还是原来那一屏。电脑上要装 tmux。</p>',
  '<p>It is tmux underneath, so the session survives a dropped connection and you come back to the same screen. tmux needs to be installed on the computer.</p>', 1),
 ('<h3>文件</h3>', '<h3>Files</h3>', 1),
 ('<p>照片、手机上的文件、电脑上的文件和目录、以前的对话，都可以附进对话里。回复里出现的文件路径，点一下就能打开看。</p>',
  '<p>Photos, files on the phone, files and folders on the computer, and earlier conversations can all be attached. Tap a file path in a reply to open the file.</p>', 1),
 ('<h3>工作流</h3>', '<h3>Workflows</h3>', 1),
 ('<p>把几步事情串起来，定时在电脑上跑，跑完给你一份能直接读的成品，比如每天早上的论文晨报。</p>',
  '<p>Chain several steps together and run them on the computer on a schedule. When they finish you get something you can read as it is, such as a paper digest every morning.</p>', 1),
 ('<p>每一步可以交给不同的引擎，互不依赖的步骤同时跑。自带论文晨报、GitHub 热点日报、深度调研等几个模板，也可以让 agent 按你的描述搭一条。</p>',
  '<p>Each step can go to a different engine, and steps that do not depend on each other run at the same time. Templates are included for a daily paper digest, a GitHub trending digest and deep research, among others, and the agent can build one from your description.</p>', 1),
 ('<figcaption>自带的「深度调研」跑到一半：Claude 和 Codex 各查了一遍，合并做完了，正在复核。</figcaption>',
  '<figcaption>The built-in deep-research template halfway through: Claude and Codex have each finished digging, the merge is done, and the check is running.</figcaption>', 1),
 ('<h3>多台电脑</h3>', '<h3>Several computers</h3>', 1),
 ('<p>可以存多台电脑，也可以经跳板机连接。存了两台以上，一台上的文件和对话可以带到另一台的对话里。每台的主机密钥第一次核对后就固定下来，以后对不上会拒绝连接。</p>',
  '<p>You can save several computers and connect through jump hosts. With two or more saved, a file or a conversation on one can be brought into a conversation on another. Each computer\'s host key is pinned after you check it the first time, and the connection is refused if it ever changes.</p>', 1),
 # how it connects
 ('<h2>对话只存在你的电脑上</h2>', '<h2>Conversations stay on your computer</h2>', 1),
 ('<p>手机和电脑之间只有一条 SSH 连接，没有 Pervio 的账号，也没有 Pervio 的服务器。电脑上不装常驻服务，也不用对外开端口。</p>',
  '<p>Between the phone and the computer there is one SSH connection. There is no Pervio account and no Pervio server. Nothing runs permanently on the computer, and no port needs to be opened.</p>', 1),
 ('<li>SSH 密钥和密码存在手机的钥匙串里。</li>', '<li>SSH keys and passwords are stored in the phone\'s Keychain.</li>', 1),
 ('<li>对话记录就是 Claude Code 这些工具自己存的文件，一直留在电脑上。</li>', '<li>Conversation records are the files that Claude Code and the other tools keep themselves. They stay on the computer.</li>', 1),
 ('<li>只有推送通知会经过我们的中继，经过的是通知的标题和正文。不想用可以关掉。</li>',
  '<li>Only push notifications go through our relay, and what goes through is the notification\'s title and body. You can turn this off.</li>', 1),
 ('aria-label="连接示意图：手机经 SSH 连到你的电脑，推送走另一条路"',
  'aria-label="How it connects: the phone reaches your computer over SSH, and push takes another route"', 1),
 ('<h3>手机上的 Pervio <span>iPhone app</span></h3>', '<h3>Pervio on the phone <span>iPhone app</span></h3>', 1),
 ('<li>对话、后台任务、审批、终端</li>', '<li>Chat, background tasks, approvals, terminal</li>', 1),
 ('<li>密钥在 iOS 钥匙串，主机密钥已固定</li>', '<li>Keys in the iOS Keychain, host key pinned</li>', 1),
 ('<h3>你的电脑 <span>远程登录（sshd）</span></h3>', '<h3>Your computer <span>Remote Login (sshd)</span></h3>', 1),
 ('<li><code>~/.pervio/bin/pervio-*</code>，app 自带，连上时放好</li>', '<li><code>~/.pervio/bin/pervio-*</code>, bundled with the app, copied over on connect</li>', 1),
 ('<li><code>claude</code>、<code>codex</code>、<code>agent</code>，用你自己的登录</li>', '<li><code>claude</code>, <code>codex</code>, <code>agent</code>, with your own logins</li>', 1),
 ('<li>会话记录、后台任务的输出，都在这台机器上</li>', '<li>Session records and background-task output are all on this machine</li>', 1),
 ('<b>推送</b>走另一条路：从电脑到 <code>push.pervio.dev</code>，再经 Apple 到手机，带的只有通知上的文字。',
  '<b>Push</b> takes another route: from the computer to <code>push.pervio.dev</code>, then through Apple to the phone. It carries only the text of the notification.', 1),
 # setup
 ('<h2>安装</h2>', '<h2>Setup</h2>', 1),
 ('<h3>准备电脑</h3>', '<h3>Prepare the computer</h3>', 1),
 ('<p>Mac 在系统设置里打开「远程登录」。Claude Code、Codex、Cursor 至少装一个，并且登录好。</p>',
  '<p>On a Mac, turn on Remote Login in System Settings. Install at least one of Claude Code, Codex or Cursor, and log in.</p>', 1),
 ('<h3>在手机上添加这台电脑</h3>', '<h3>Add the computer on the phone</h3>', 1),
 ('<p>从 TestFlight 装上 Pervio，在「服务器」里填电脑的地址和用户名，选密钥或密码登录，再核对一下主机密钥的指纹。</p>',
  '<p>Install Pervio from TestFlight. Under Servers, enter the computer\'s address and user name, choose a key or a password, then check the host key\'s fingerprint.</p>', 1),
 ('<h3>开始对话</h3>', '<h3>Start a conversation</h3>', 1),
 ('<p>第一次连上时，app 会把要用的脚本放到电脑的 <code>~/.pervio/bin</code>，不用手动装。</p>',
  '<p>On the first connection the app copies the scripts it needs to <code>~/.pervio/bin</code> on the computer. There is nothing to install by hand.</p>', 1),
 ('<p>出门在外要连家里或公司的电脑，可以两边都装 Tailscale，不用把 SSH 开到公网。</p>',
  '<p>To reach a computer at home or at work when you are out, install Tailscale on both. SSH doesn\'t have to be exposed to the internet.</p>', 1),
 ('<a class="link" href="docs.html#install">完整安装指南</a>', '<a class="link" href="%s">Full setup guide</a>' % SETUP, 1),
 # open source
 ('<h2>开源</h2>', '<h2>Open source</h2>', 1),
 ('<p>app、电脑上的脚本、推送中继的代码都在 GitHub 上，MIT 许可。安全设计和已知的限制写在 SECURITY.md 里。</p>',
  '<p>The app, the scripts on the computer and the push relay are all on GitHub under the MIT license. The security design and its known limits are in SECURITY.md.</p>', 1),
 ('<a class="btn btn--ghost" href="privacy.html">隐私</a>', '<a class="btn btn--ghost" href="privacy.html#en">Privacy</a>', 1),
 ('<td>iPhone app(SwiftUI)</td>', '<td>iPhone app (SwiftUI)</td>', 1),
 ('<td>放到电脑上的脚本，app 自带</td>', '<td>scripts copied to the computer, bundled with the app</td>', 1),
 ('<td>推送中继</td>', '<td>push relay</td>', 1),
 ('<td>服务端测试，CI 上全跑</td>', '<td>server-side tests, all run in CI</td>', 1),
 ('<td>安装与功能文档</td>', '<td>setup and feature docs</td>', 1),
 ('<td>安全设计与边界</td>', '<td>security design and limits</td>', 1),
 # try it + footer
 ('<h2>试用</h2>', '<h2>Try it</h2>', 1),
 ('<p>现在在 TestFlight 公测，免费。需要一台装了 Claude Code、Codex 或 Cursor 的电脑。</p>',
  '<p>Free, in public beta on TestFlight. You need a computer with Claude Code, Codex or Cursor installed.</p>', 1),
 ('<a class="btn btn--ghost" href="docs.html">看文档</a>', '<a class="btn btn--ghost" href="%s">Read the docs</a>' % GH, 1),
 ('aria-label="页脚"', 'aria-label="Footer"', 1),
 ('<a href="docs.html#install">安装</a>', '<a href="%s">Setup</a>' % SETUP, 1),
 ('<a href="privacy.html">隐私</a>', '<a href="privacy.html#en">Privacy</a>', 1),
 ('<a href="support.html">支持</a>', '<a href="support.html">Support</a>', 1),
 ('<a href="en.html" lang="en">English</a>', '<a href="index.html" lang="zh-CN">中文</a>', 1),
 ('Pervio 以 MIT 许可开源。照片：<a class="link" href="https://commons.wikimedia.org/wiki/File:Fog_bank_forming_over_Mattole_beach_(54103432351).jpg">Mattole 海滩上空正在形成的雾堤</a>，美国土地管理局加州分局拍摄，公有领域，取自 Wikimedia Commons。',
  'Pervio is open source under the MIT license. Photograph: <a class="link" href="https://commons.wikimedia.org/wiki/File:Fog_bank_forming_over_Mattole_beach_(54103432351).jpg">Fog bank forming over Mattole beach</a>, Bureau of Land Management California, public domain, via Wikimedia Commons.', 1),
]
out = src
for old, new, n in T:
    c = out.count(old)
    if c != n:
        sys.exit("expected %d of %r, found %d" % (n, old[:50], c))
    out = out.replace(old, new)
# nothing Chinese may remain in what a visitor reads (comments in <style>/<script> are not shown)
visible = re.sub(r"<style.*?</style>|<script.*?</script>", "", out, flags=re.S)
visible = visible.replace('lang="zh-CN">中文</a>', "")
left = sorted(set(re.findall(r"[一-鿿　-〿＀-￯]+", visible)))
if left:
    sys.exit("untranslated: " + " | ".join(left))
open("web/en.html", "w", encoding="utf-8").write(out)
print("web/en.html written, %d strings translated" % len(T))
