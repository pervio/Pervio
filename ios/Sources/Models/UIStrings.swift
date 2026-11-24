import Foundation

/// App-interface strings (chrome: button labels, footers, confirmations, toasts)
/// in one language-aware place, built the SAME way `Prompts` builds the wire
/// seeds: a plain function per string, branching on `PromptLanguage.current`.
///
/// Why not a String Catalog (.xcstrings): the language switch is already a
/// custom UserDefaults setting (`PromptLanguage`, key `pervio.promptLanguage`),
/// read on every access so a Settings change applies live. A catalog would key
/// off the SYSTEM locale instead and ignore that setting — splitting the app in
/// two ("prompts follow the toggle, UI follows the phone"). One toggle drives
/// both here, and every string is byte-for-byte pinnable in a test, exactly like
/// `Prompts`. Adding a third language is two files: a `PromptLanguage` case and
/// a branch per function (switch to `switch lang` for exhaustiveness first).
///
/// The Chinese strings are the shipped ones, verbatim — do not touch their
/// wording. Boundary (deliberate): this covers app CHROME only. It does NOT
/// cover market catalog titles/summaries or server-authored template/report
/// bodies — those are CONTENT and keep their author's language (same boundary
/// `PromptLanguage`'s header draws for server templates).
enum L {
    private static func t(_ lang: PromptLanguage, _ zh: String, _ en: String) -> String {
        lang == .chinese ? zh : en
    }

    // MARK: - Market: subscribe / install / run buttons

    static func subscribe(_ lang: PromptLanguage = .current) -> String {
        t(lang, "订阅", "Subscribe")
    }
    static func subscribing(_ lang: PromptLanguage = .current) -> String {
        t(lang, "订阅中…", "Subscribing…")
    }
    static func subscribed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已订阅", "Subscribed")
    }
    /// Subscribe button that also states the hour it arms (a publication row).
    static func subscribeDaily(_ time: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "订阅 · 每天 \(time)", "Subscribe · daily \(time)")
    }
    static func install(_ lang: PromptLanguage = .current) -> String {
        t(lang, "安装到服务器", "Install on server")
    }
    static func installing(_ lang: PromptLanguage = .current) -> String {
        t(lang, "安装中…", "Installing…")
    }
    static func installed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已安装", "Installed")
    }
    static func run(_ lang: PromptLanguage = .current) -> String {
        t(lang, "运行…", "Run…")
    }
    /// The confirm-and-go verb inside the run sheet (no ellipsis — this one acts).
    static func runNow(_ lang: PromptLanguage = .current) -> String {
        t(lang, "运行", "Run")
    }
    /// A playbook row's one-tap "load into a conversation".
    static func useInChat(_ lang: PromptLanguage = .current) -> String {
        t(lang, "在对话中用", "Use in chat")
    }

    // MARK: - Market: blocked-subscribe labels + the sentence under them

    static func blockedNameConflict(_ lang: PromptLanguage = .current) -> String {
        t(lang, "名字冲突", "Name conflict")
    }
    static func blockedNameFirst(_ lang: PromptLanguage = .current) -> String {
        t(lang, "先起个名字", "Name it first")
    }
    /// The Mac this market is open on has no such engine installed.
    static func blockedEngineMissing(_ b: AgentBackend, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没装 \(b.rawValue)", "No \(b.rawValue) here")
    }
    /// Row note under that button: which engine, where it is missing, what fixes it.
    static func subscriptionNoteEngineMissing(_ b: AgentBackend,
                                              _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这个工作流要用 \(b.label),这台 Mac 上没装 \(b.rawValue) —— "
            + "订阅了也跑不起来。装好、重新连一次,就能订。",
          "This workflow runs on \(b.label), and this Mac has no \(b.rawValue) — "
            + "subscribing would only schedule failures. Install it, reconnect, then subscribe.")
    }
    /// Row note: a schedule under this name exists but several same-named rows
    /// claim it, so it can't be attributed here.
    static func subscriptionNoteNameTaken(_ name: String, _ n: Int,
                                          _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "已有日程叫「\(name)」,但这里有 \(n) 个工作流同名 —— "
            + "分不清那条日程是不是这一个。再订阅只会多一条同名日程、每天多跑一次;"
            + "先在编辑器里给它改个名字。",
          "A schedule named \"\(name)\" already exists, but \(n) workflows here "
            + "share that name — there's no telling which one it belongs to. "
            + "Subscribing again only adds another schedule under the same name that "
            + "runs an extra time every day; rename it in the editor first.")
    }
    /// Row note: a nameless spec falls into the shared bucket name.
    static func subscriptionNoteUnnamed(_ name: String,
                                        _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这个工作流没有名字,排程会叫「\(name)」—— 所有没名字的"
            + "工作流都用这个名字,服务器上已经有一条,分不清是不是这一个。"
            + "先在编辑器里给它起个名字,再来订阅。",
          "This workflow has no name, so its schedule would be called \"\(name)\" — "
            + "every nameless workflow uses that name, one already exists on the server, "
            + "and there's no telling whether it's this one. Give it a name in the "
            + "editor first, then subscribe.")
    }

    // MARK: - Market: subscribe / install toasts

    static func toastAlreadySubscribed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已订阅过了,无需重复", "Already subscribed — no need to do it again")
    }
    static func toastInstalled(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已安装到服务器模板库", "Installed to the server's template library")
    }

    // MARK: - Market: top blurb, shelves, footers

    static func marketIntro(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "刊物:订阅一次,服务器每天定时印制,首页出卡片,零接触。能力:装进服务器随叫随到,或点「运行」立刻跑一次——都不经过编辑器;想改步骤用详情页的「自定义…」。",
          "Publications: subscribe once and the server prints one on schedule every "
            + "day, straight to a home-screen card — hands-free. Capabilities: install "
            + "one on the server for on-demand use, or tap Run to run it once now — "
            + "neither goes through the editor; to change steps, use \"Customize…\" on "
            + "the detail page.")
    }
    static func shelfPublications(_ lang: PromptLanguage = .current) -> String {
        t(lang, "刊物 · 每日送达", "Publications · delivered daily")
    }
    static func shelfCapabilities(_ lang: PromptLanguage = .current) -> String {
        t(lang, "能力 · 随叫随到", "Capabilities · on demand")
    }
    static func publicationFooterNoProfile(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "从某台服务器的 Workflows 页进入市场,即可一键订阅。",
          "Open the market from a server's Workflows page to subscribe with one tap.")
    }
    static func publicationFooterProfiled(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "带「我的」标记的刊物同样能在这里一键订阅;订阅后在 Workflows 页管理:改时间、暂停、删除。",
          "Publications tagged \"Mine\" subscribe with one tap here too; manage them "
            + "afterwards on the Workflows page: change the time, pause, or delete.")
    }
    static func capabilityFooterNoProfile(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "从某台服务器的 Workflows 页进入市场,即可一键安装或运行。",
          "Open the market from a server's Workflows page to install or run with one tap.")
    }
    static func capabilityFooterEmpty(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "你自己的模板会按同样规则混入这两排货架——用上面的入口让 Claude 建一个,或在编辑器里「存为模板」。",
          "Your own templates mix into these two shelves by the same rule — use the "
            + "entry above to have Claude build one, or \"Save as template\" in the editor.")
    }
    static func capabilityFooterMixed(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "带「我的」标记的行来自你服务器的模板库,点开进编辑器;带「剧本」的是装进对话执行的方法论,点开看正文、在对话中用。",
          "Rows tagged \"Mine\" come from your server's template library — tap to open "
            + "the editor; rows tagged \"Playbook\" are methodologies you run inside a "
            + "conversation — tap to read the text, then use it in a chat.")
    }

    // MARK: - Market: template row chips

    static func chipMine(_ lang: PromptLanguage = .current) -> String {
        t(lang, "我的", "Mine")
    }
    static func chipPlaybook(_ lang: PromptLanguage = .current) -> String {
        t(lang, "剧本", "Playbook")
    }
    /// A playbook's body length, in characters.
    static func charCount(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(n) 字", "\(n) chars")
    }

    // MARK: - Market: Build-with-Claude card

    static func buildWithClaudeTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "和 Claude 一起构建 workflow", "Build a workflow with Claude")
    }
    static func buildWithClaudeSubtitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "用一句话描述你要的自动化,Claude 会直接把模板建到服务器;回来下拉刷新即见。",
          "Describe the automation you want in one sentence and Claude builds the "
            + "template straight onto the server; come back and pull to refresh to see it.")
    }

    // MARK: - Market detail: presentation chips

    static func chipPublish(_ dir: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "出版:\(dir)", "Publishes: \(dir)")
    }
    static func chipFold(_ sections: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "折叠:\(sections)", "Folds: \(sections)")
    }
    static func chipActions(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "动作:\(n) 项", "Actions: \(n)")
    }
    /// What joins items inside one chip. The ideographic comma is a Chinese
    /// character in its own right — an English chip that reads "A、B" is still
    /// half-Chinese, however translated the words around it are.
    static func listSeparator(_ lang: PromptLanguage = .current) -> String {
        t(lang, "、", ", ")
    }

    // MARK: - Market detail: action-section copy

    static func subscribeDetailNote(_ time: String, _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "订阅即开始:服务器每天 \(time) 自动印制,首页出卡片;首期立刻安排,全程不进编辑器。",
          "Subscribing starts it: the server prints one automatically every day at "
            + "\(time), onto a home-screen card; the first issue is scheduled right "
            + "away, and the editor is never involved.")
    }
    static func installDetailNote(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "安装进服务器模板库,之后随叫随到;「运行」只确认目录,立刻开跑。",
          "Install it into the server's template library for on-demand use; Run just "
            + "confirms the directory, then starts immediately.")
    }
    static func customize(_ lang: PromptLanguage = .current) -> String {
        t(lang, "自定义…", "Customize…")
    }
    static func customizeNote(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "自定义 = 进编辑器改步骤、时间或目录,再自己跑或订阅。",
          "Customize = open the editor to change steps, time, or directory, then run "
            + "or subscribe it yourself.")
    }
    static func customizeTo(_ lang: PromptLanguage = .current) -> String {
        t(lang, "自定义到…", "Customize on…")
    }

    // MARK: - Capability run sheet

    static func changeProjectDir(_ lang: PromptLanguage = .current) -> String {
        t(lang, "换个项目目录…", "Change project directory…")
    }
    static func runSheetEmptyDirFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "目录不能为空——能力要知道在哪个项目里干活。",
          "The directory can't be empty — a capability needs to know which project to work in.")
    }
    static func runSheetReadyFooter(_ serverName: String,
                                    _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "在 \(serverName) 的这个目录里立刻跑一次,进度和结果在监控页看。",
          "Runs once now in this directory on \(serverName); watch progress and "
            + "results on the monitor page.")
    }

    // MARK: - Editor: publish section

    static func publishSectionOffLabel(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这个工作流不出刊:没有任何步骤打开「Publish as home card」。",
          "This workflow prints nothing: no step has \"Publish as home card\" turned on.")
    }
    static func publishSectionOffFooter(_ root: String,
                                        _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "想让它每天在首页出卡片:点开某个步骤 → 最下面的 Publish → 打开开关。归档目录留空即用 \(root)/<工作流名>。",
          "To give it a daily home-screen card: open a step → Publish at the bottom → "
            + "turn the switch on. Leave the archive directory empty to use "
            + "\(root)/<workflow name>.")
    }

    // MARK: - Editor: save-as-template menu hint + success alert

    static func templateMenuHint(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "Copy 导出到剪贴板,可粘贴进市场页的 Import 或发给别人;顶栏的 Save 把它存成你自己的模板(市场「我的」)。",
          "Copy exports to the clipboard — paste it into the market's Import or send it "
            + "to someone; Save in the bar keeps it as a template of your own (the market's Mine).")
    }
    static func templateSavedAlert(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "已存成你的模板(市场「我的」里能看到)",
          "Saved as a template of yours (see Mine in the market)")
    }
    // MARK: - Templates of mine: delete (2026-10-20)
    static func deleteTemplate(_ lang: PromptLanguage = .current) -> String { t(lang, "删除模板", "Delete template") }
    static func deleteTemplateConfirm(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "删掉模板「\(name)」?Mac 上的这个文件是唯一一份;已经订阅出去的定时不受影响。",
          "Delete the template “\(name)”? The file on the Mac is the only copy; schedules already made from it are not affected.")
    }
    // MARK: - Schedules: change the daily time (2026-10-20)
    static func changeTime(_ lang: PromptLanguage = .current) -> String { t(lang, "改时间", "Change time") }
    static func changeTimeNote(_ tz: String, _ lang: PromptLanguage = .current) -> String {
        let z = tz.isEmpty ? "" : (lang == .chinese ? "(服务器时区 \(tz))" : " (server time zone \(tz))")
        return t(lang, "按 Mac 自己的钟走\(z);改完从下一次该跑的时候生效。",
                 "On the Mac's own clock\(z); takes effect from the next due time.")
    }

    // MARK: - Schedule first-issue toasts (shared by subscribe + editor Save)

    static func firstIssueScheduledToday(_ hhmm: String,
                                         _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "已订阅,首期今天 \(hhmm) 自动送达",
          "Subscribed — the first issue arrives automatically today at \(hhmm)")
    }
    /// The slot already went by today — the next print is TOMORROW's tick.
    /// Since 2026-09-01 subscribing never fires a run by itself (a 订阅 tap
    /// that quietly burned a full pipeline run surprised the very user it was
    /// meant to reassure); 现在来一期 is the explicit way to get one now.
    static func firstIssueTomorrow(_ hhmm: String,
                                   _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "已订阅,下期明天 \(hhmm) 自动送达",
          "Subscribed — the next issue arrives tomorrow at \(hhmm)")
    }
    /// The subscribed row/detail's explicit fire-one-now verb — also the way
    /// to reprint an issue whose slot got missed today.
    static func runIssueNow(_ lang: PromptLanguage = .current) -> String {
        t(lang, "现在来一期", "Run an issue now")
    }

    // Codex "already has an active writer": another client (VS Code's plugin)
    // holds the conversation; the phone can end it and take the thread over.
    // Groups: one primary conversation + partners answering in parallel.
    static func groupOpen(_ lang: PromptLanguage = .current) -> String { t(lang, "双开…", "Duet…") }
    static func groupTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "组", "Duet") }
    /// Two-windows mode has no primary: the windows are Partner 1 and Partner 2.
    static func groupPartnerN(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "伙伴 \(n)", "Partner \(n)") }
    // Engines + providers (the badge, the settings sheet, the server form)
    static func providerAccountDefault(_ lang: PromptLanguage = .current) -> String { t(lang, "账号默认", "Account default") }
    static func providerNoKey(_ lang: PromptLanguage = .current) -> String { t(lang, "缺钥匙", "no key") }
    static func providerNoneHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这台 Mac 还没有第三方供应商。点上面添加一次(写到 Mac),之后在这里选。", "No third-party provider on this Mac yet. Add one above (it is written to the Mac), then pick it here.")
    }
    static func providerAdd(_ lang: PromptLanguage = .current) -> String { t(lang, "添加供应商…", "Add provider…") }
    static func providerVendor(_ lang: PromptLanguage = .current) -> String { t(lang, "常用供应商", "Vendor") }
    static func providerCustom(_ lang: PromptLanguage = .current) -> String { t(lang, "自定义", "Custom") }
    static func providerRegion(_ lang: PromptLanguage = .current) -> String { t(lang, "地区", "Region") }
    static func providerRegionPick(_ lang: PromptLanguage = .current) -> String { t(lang, "选地区", "Pick a region") }
    static func providerRegionHint(_ lang: PromptLanguage = .current) -> String { t(lang, "钥匙按地区发,中国区和国际版不通用。", "Keys are issued per region; a China key does not work on the international endpoint.") }
    static func providerPresetHint(_ lang: PromptLanguage = .current) -> String { t(lang, "选了供应商,地址和模型名就填好了,你只粘钥匙;保存时会用钥匙问一次它的模型清单。", "Pick a vendor and the URL and model names are filled in; you paste only the key. On save, the vendor is asked for its live model list.") }
    static func providerRefreshModels(_ lang: PromptLanguage = .current) -> String { t(lang, "刷新模型名", "Refresh models") }
    static func providerModelsLive(_ lang: PromptLanguage = .current) -> String { t(lang, "模型名来自供应商", "models from the vendor") }
    static func providerModelsPreset(_ lang: PromptLanguage = .current) -> String { t(lang, "模型名是预设,未核", "preset models, unverified") }
    static func providerEdit(_ lang: PromptLanguage = .current) -> String { t(lang, "编辑这家…", "Edit this provider…") }
    static func providerEditTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "编辑供应商", "Edit provider") }
    static func providerKeyKeep(_ lang: PromptLanguage = .current) -> String { t(lang, "留空 = 沿用 Mac 上已存的钥匙", "empty = keep the key stored on the Mac") }
    static func providerNameFixed(_ lang: PromptLanguage = .current) -> String { t(lang, "名字是 Mac 上的文件名,改不了;要换名就删掉重加。点一行可改其余的。", "The name is the file's name on the Mac and cannot change; to rename, delete and add again.") }
    static func providerUrlLooksOpenAI(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这像 OpenAI 兼容地址(…/v1、/paas/v4 这类)。Claude Code 走的是 Anthropic 兼容地址,一般以 /anthropic 结尾,否则会报“模型有问题”。",
          "This looks like an OpenAI-compatible URL (…/v1, /paas/v4). Claude Code needs the Anthropic-compatible one, usually ending in /anthropic, or it reports a model problem.")
    }
    static func providerUrlLooksAnthropic(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这像 Anthropic 兼容地址(…/anthropic)。Codex 走的是 OpenAI 兼容地址,一般以 /v1 结尾。",
          "This looks like an Anthropic-compatible URL (…/anthropic). Codex needs the OpenAI-compatible one, usually ending in /v1.")
    }
    static func providerUrlVendorHas(_ url: String, _ lang: PromptLanguage = .current) -> String { t(lang, "这家给这个引擎的地址是 \(url)", "This vendor's URL for this engine is \(url)") }
    static func dirOutsideScope(_ lang: PromptLanguage = .current) -> String { t(lang, "不在这台机器的工作目录之内", "Outside this server's working directory") }

    // MARK: - Server settings: logins the Mac must hold for the SSH process (credentials.env)

    static func claudeTokenHeader(_ lang: PromptLanguage = .current) -> String { t(lang, "Claude 登录令牌(SSH 用)", "Claude token (for SSH)") }
    static func claudeTokenPlaceholder(_ lang: PromptLanguage = .current) -> String { t(lang, "粘贴 claude setup-token 的输出", "paste the output of `claude setup-token`") }
    static func claudeTokenNote(_ lang: PromptLanguage = .current) -> String {
        t(lang, "在 Mac 自己的终端里运行 claude setup-token,把结果粘贴到这里。它只写进 Mac 的 ~/.pervio/credentials.env(0600),手机不保存。解决 SSH 下“Claude 未登录”。",
          "Run `claude setup-token` in the Mac's own Terminal and paste the result here. It is written to ~/.pervio/credentials.env on the Mac (0600) and never kept on the phone. Fixes “Claude 未登录” over SSH.")
    }
    static func cursorKeyHeader(_ lang: PromptLanguage = .current) -> String { t(lang, "Cursor API key(SSH 用)", "Cursor API key (for SSH)") }
    static func cursorSectionHeader(_ lang: PromptLanguage = .current) -> String { t(lang, "Cursor 登录(SSH 用)", "Cursor sign-in (for SSH)") }
    static func cursorKeyAlternative(_ lang: PromptLanguage = .current) -> String { t(lang, "改用 API key", "Use an API key instead") }
    static func cursorKeyPlaceholder(_ lang: PromptLanguage = .current) -> String { t(lang, "粘贴 cursor.com 生成的 API key", "paste an API key made at cursor.com") }
    static func cursorKeyNote(_ lang: PromptLanguage = .current) -> String {
        t(lang, "不想登录也可以用 API key:在 cursor.com → Settings → API Keys 生成一个粘贴到这里。它只写进 Mac 的 ~/.pervio/credentials.env(0600),手机不保存。",
          "An API key works instead of signing in: make one at cursor.com → Settings → API Keys and paste it here. It is written to ~/.pervio/credentials.env on the Mac (0600) and never kept on the phone.")
    }
    static func cursorFileLoginOnMac(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Mac 上已有 Cursor 的文件登录(agent login),不需要 key。", "Cursor is logged in on the Mac through its file store (agent login) — no key needed.")
    }
    static func cursorKeyOnFile(_ on: Bool, _ lang: PromptLanguage = .current) -> String {
        on ? t(lang, "Mac 上已有 key。", "A key is on the Mac.") : t(lang, "Mac 上还没有 key。", "No key on the Mac yet.")
    }
    static func credentialSave(_ lang: PromptLanguage = .current) -> String { t(lang, "写到 Mac", "Save to Mac") }
    static func credentialSaving(_ lang: PromptLanguage = .current) -> String { t(lang, "写入中…", "Saving…") }
    static func credentialClear(_ lang: PromptLanguage = .current) -> String { t(lang, "从 Mac 清除", "Clear on Mac") }
    static func credentialSaved(_ lang: PromptLanguage = .current) -> String { t(lang, "已写到 Mac。", "Saved on the Mac.") }
    static func credentialCleared(_ lang: PromptLanguage = .current) -> String { t(lang, "已从 Mac 清除。", "Cleared on the Mac.") }
    static func credentialWriteFailed(_ lang: PromptLanguage = .current) -> String { t(lang, "没能写到 Mac。", "Could not write it to the Mac.") }
    /// Shown under Cursor's "Run security unlock-keychain and try again".
    static func cursorKeychainHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Cursor 在这台 Mac 上还没有能用的登录(有也在钥匙串里,SSH 读不到)。点下面的「登录 Cursor」,在网页上登一次,每台 Mac 一次。",
          "Cursor has no usable login on this Mac (a keychain one is unreadable over SSH). Tap “Log in to Cursor” below and sign in once on the web, once per Mac.")
    }
    static func cursorLoginHint(_ lang: PromptLanguage = .current) -> String { t(lang, "Cursor 需要在这台 Mac 上登录一次", "Cursor needs one sign-in on this Mac") }
    static func cursorLoginButton(_ lang: PromptLanguage = .current) -> String { t(lang, "登录 Cursor", "Log in to Cursor") }
    static func cursorLoginWaiting(_ lang: PromptLanguage = .current) -> String { t(lang, "在浏览器里登完会自动继续…", "Continues by itself once you have signed in…") }
    static func cursorLoggedIn(_ account: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "Cursor 已登录(\(account)),重发刚才那条。", "Cursor is signed in (\(account)); resending that message.")
    }
    static func cursorLoginFailed(_ why: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "Cursor 登录没完成:\(why)", "The Cursor sign-in did not finish: \(why)")
    }
    static func cursorLoginStatus(_ account: String?, _ lang: PromptLanguage = .current) -> String {
        if let a = account, !a.isEmpty { return t(lang, "已登录:\(a)", "Signed in: \(a)") }
        return t(lang, "未登录", "Not signed in")
    }
    static func dirScopeHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这也是这台机器在手机上的范围:填 ~ 看全部,填 ~/a 只看 a 及其子文件夹(对话、搜索、后台任务、新对话选目录都只在里面;给对话附加文件不受限)。同一台 Mac 可以添加多次,每条配置一个工作目录,各看各的范围。",
          "This is also the server's scope on the phone: ~ shows everything, ~/a only a and its sub-folders (conversations, search, background tasks and the new-conversation folder picker stay inside; attaching files to a chat is not limited). The same Mac can be added as many times as you like, each entry with its own working directory and so its own scope.")
    }
    static func providerPresetsMissing(_ err: String?, _ lang: PromptLanguage = .current) -> String {
        let tail = (err?.isEmpty == false) ? "(\(err!))" : ""
        return t(lang, "没拿到厂商预设:这台 Mac 的服务端脚本可能还没更新(重新连接会自动铺上),或读取失败\(tail)。可先选「自定义」手填。",
                 "No vendor presets came back: this Mac's server scripts may be out of date (reconnecting paves them), or the read failed\(tail). Custom still works.")
    }
    static func refreshNow(_ lang: PromptLanguage = .current) -> String { t(lang, "刷新", "Refresh") }
    static func chipContextGeneric(_ lang: PromptLanguage = .current) -> String { t(lang, "背景对话", "Background conversation") }
    static func chipBuildWorkflow(_ lang: PromptLanguage = .current) -> String { t(lang, "搭建工作流", "Build a workflow") }
    static func chipReviseWorkflow(_ name: String, _ lang: PromptLanguage = .current) -> String { t(lang, "修订:\(name)", "Revise: \(name)") }
    static func providerRowHint(_ lang: PromptLanguage = .current) -> String { t(lang, "点一行可以改地址、模型名或换钥匙;左滑删除或刷新模型名。", "Tap a row to change its URL, model names or key; swipe left to delete or refresh its models.") }
    static func engineNotInstalled(_ lang: PromptLanguage = .current) -> String { t(lang, "这台 Mac 没装", "not installed on this Mac") }
    static func engineLockedNote(_ lang: PromptLanguage = .current) -> String { t(lang, "对话已开始,引擎锁定;换引擎 = 新开一段", "Conversation started: engine locked; switch = new conversation") }
    static func engineMoreSettings(_ lang: PromptLanguage = .current) -> String { t(lang, "更多设置…", "More settings…") }
    // Directories: picking one, completing one, switching one
    static func dirChooseTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "选目录", "Choose a directory") }
    static func dirTypeHint(_ lang: PromptLanguage = .current) -> String { t(lang, "敲几个字,候选出在下面;点一个补全一级", "Type a few characters — completions appear below; tap one to fill a level") }
    static func dirUseThis(_ lang: PromptLanguage = .current) -> String { t(lang, "就用这个目录", "Use this directory") }
    static func dirRecent(_ lang: PromptLanguage = .current) -> String { t(lang, "最近", "Recent") }
    static func dirBrowseMac(_ lang: PromptLanguage = .current) -> String { t(lang, "浏览 Mac 上的目录…", "Browse the Mac…") }
    static func dirTypePath(_ lang: PromptLanguage = .current) -> String { t(lang, "或敲路径", "Or type a path") }
    static func dirSetDefault(_ lang: PromptLanguage = .current) -> String { t(lang, "设为默认目录", "Set as default directory") }
    static func dirDefaultTag(_ lang: PromptLanguage = .current) -> String { t(lang, "默认", "default") }
    /// The pencil menu's first row; the folder is the section's title, so the
    /// row does not repeat it (the person: the old three lines read as a blob).
    static func dirNewHere(_ lang: PromptLanguage = .current) -> String { t(lang, "新开一段", "New conversation") }
    /// Deleting a conversation asks first (2026-10-21): the Mac's record goes with it.
    static func deleteConversation(_ lang: PromptLanguage = .current) -> String { t(lang, "删除这段对话", "Delete this conversation") }
    static func deleteConversationAsk(_ lang: PromptLanguage = .current) -> String { t(lang, "删除这段对话?", "Delete this conversation?") }
    static func deleteConversationBody(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "「" + name + "」会从 Mac 上删掉,不能恢复。", "“" + name + "” is deleted from the Mac. This cannot be undone.")
    }
    static func dirNewElsewhere(_ lang: PromptLanguage = .current) -> String { t(lang, "换个目录新开…", "New in another directory…") }
    static func dirNewElsewhereCarry(_ lang: PromptLanguage = .current) -> String { t(lang, "换个目录新开,带上本段记录…", "New in another directory, carrying this one…") }
    static func dirLockedTitle(_ name: String, _ lang: PromptLanguage = .current) -> String { t(lang, "这段对话已经在 " + name + " 里了", "This conversation already lives in " + name) }
    static func dirLockedBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "目录就是它的工作目录,记录也按它归档,中途换不了。换目录 = 新开一段,可以把本段记录当背景带过去。",
          "The directory is its working directory and where its record is filed; it cannot move. Switching = a new conversation, which can carry this one along as background.")
    }
    static func dirNewChatCarry(_ lang: PromptLanguage = .current) -> String { t(lang, "新开一段,带上本段记录", "New conversation, carrying this one") }
    static func dirNewChatPlain(_ lang: PromptLanguage = .current) -> String { t(lang, "新开一段,不带", "New conversation, clean") }
    static func homeChipNewChatIn(_ lang: PromptLanguage = .current) -> String { t(lang, "在别的目录开新对话…", "New chat in another directory…") }
    /// The transcript's way back down after the reader scrolled up to reread.
    static func newBelow(_ lang: PromptLanguage = .current) -> String { t(lang, "新内容", "New below") }
    static func groupModeParallel(_ lang: PromptLanguage = .current) -> String { t(lang, "头脑风暴", "Brainstorm") }
    static func groupModeWatch(_ lang: PromptLanguage = .current) -> String { t(lang, "监督", "Watch") }
    static func groupModeDuo(_ lang: PromptLanguage = .current) -> String { t(lang, "双窗", "Two windows") }
    static func groupBrainstormHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "同一个问题同时问两家,各答各的,两个答案并排看;主再汇总分歧和结论,放进单独的框。默认大家只读;要让谁动手,建好后在成员设置里开。",
          "One question to both at once, each answers on its own, both in view; the primary then sums up the disagreements and a conclusion into its own box. Everyone starts read-only; to let one edit, open it in member settings.")
    }
    static func groupDuoHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "两段平等的对话并排,叫伙伴 1 和伙伴 2。可以分开说、同时说,或让一边点评另一边的回复;两边不自动互通。已有的那段保持原来的权限,新开的那段只读,成员设置里可改。",
          "Two equal conversations side by side, Partner 1 and Partner 2. Talk to one, to both, or have one critique the other's reply; nothing crosses on its own. The existing conversation keeps its permissions, the new one starts read-only; change it in member settings.")
    }
    static func groupSynthRunning(_ lang: PromptLanguage = .current) -> String { t(lang, "主在汇总…", "Primary summing up…") }
    static func groupSynthTitle(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "第 \(n) 轮结论", "Round \(n) conclusion") }
    static func groupHandToPrimary(_ lang: PromptLanguage = .current) -> String { t(lang, "交给主去做", "Hand to the primary") }
    static func groupWritableWarn(_ lang: PromptLanguage = .current) -> String {
        t(lang, "两边都可写,可能同时改同一目录", "Both can edit — they may change the same directory at once")
    }
    static func groupCritique(_ by: String, _ of: String, _ lang: PromptLanguage = .current) -> String { t(lang, "让" + by + "点评" + of, by + " critiques " + of) }
    static func groupMemberBusy(_ lang: PromptLanguage = .current) -> String { t(lang, "它还在答上一条,等它完或按停。", "Still answering the last one — wait, or stop it.") }
    static func groupNothingToCritique(_ lang: PromptLanguage = .current) -> String { t(lang, "对方还没回复,没有可点评的。", "Nothing to critique yet — the other side has not replied.") }
    static func groupInGroupRunning(_ lang: PromptLanguage = .current) -> String { t(lang, "这段对话正在组里跑,等它完再单聊。", "This conversation is busy in its group — wait for it to finish.") }
    static func groupInjectedLine(_ what: String, _ lang: PromptLanguage = .current) -> String { t(lang, "系统:" + what + " · 点开看", "System: " + what + " · tap to read") }
    static func groupPillRunning(_ lang: PromptLanguage = .current) -> String { t(lang, "双开进行中", "Duet running") }
    static func groupSectionTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "双开", "Duets") }
    static func groupToBoth(_ lang: PromptLanguage = .current) -> String { t(lang, "两边", "Both") }
    static func groupAskBoth(_ lang: PromptLanguage = .current) -> String { t(lang, "同时问两边…", "Ask both…") }
    static func groupDuoAnswering(_ who: String, _ lang: PromptLanguage = .current) -> String { t(lang, who + "在答", who + " answering") }
    static func groupDuoAnsweringWord(_ lang: PromptLanguage = .current) -> String { t(lang, "在答…", "answering…") }
    static func groupDuoIdle(_ who: String, _ lang: PromptLanguage = .current) -> String { t(lang, who + "空闲", who + " idle") }
    static func diagYou(_ lang: PromptLanguage = .current) -> String { t(lang, "你", "You") }
    static func diagVerdict(_ lang: PromptLanguage = .current) -> String { t(lang, "判决", "verdict") }
    static func diagConclusion(_ lang: PromptLanguage = .current) -> String { t(lang, "结论", "conclusion") }
    static func diagAsk(_ lang: PromptLanguage = .current) -> String { t(lang, "问", "ask") }
    static func diagAnswer(_ lang: PromptLanguage = .current) -> String { t(lang, "答", "answer") }
    static func diagTask(_ lang: PromptLanguage = .current) -> String { t(lang, "任务", "task") }
    static func diagResult(_ lang: PromptLanguage = .current) -> String { t(lang, "结果", "result") }
    static func diagFeedback(_ lang: PromptLanguage = .current) -> String { t(lang, "意见", "feedback") }
    static func diagSay(_ lang: PromptLanguage = .current) -> String { t(lang, "说", "say") }
    static func diagCritique(_ lang: PromptLanguage = .current) -> String { t(lang, "点评 · 你按一下", "critique · on your tap") }
    static func groupWatcher(_ lang: PromptLanguage = .current) -> String { t(lang, "监督者", "Watcher") }
    static func groupWatchHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "主负责做,监督者看结果、给意见,意见回给主再做,一个任务最多 3 轮。它判「通过」或「需要你」、或满 3 轮,都会推送你。中途只有你能停。",
          "The primary does the work; the watcher reviews each round and its feedback goes back to the primary — at most 3 rounds per task. 通过 (pass), 需要你 (needs you) and the 3-round cap each push you. Only you can stop midway.")
    }
    static func groupWatchRounds(_ r: Int, _ cap: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "第 \(r)/\(cap) 轮", "round \(r)/\(cap)") }
    static func groupTaskN(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "任务 \(n)", "Task \(n)") }
    static func groupWatchNoTask(_ lang: PromptLanguage = .current) -> String { t(lang, "等你给任务", "waiting for a task") }
    static func groupWatchWorking(_ lang: PromptLanguage = .current) -> String { t(lang, "主在做", "primary working") }
    static func groupWatchReviewing(_ lang: PromptLanguage = .current) -> String { t(lang, "监督者在看", "watcher reviewing") }
    static func groupWatchPassed(_ r: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "已通过 · \(r) 轮", "passed · \(r) rounds") }
    static func groupWatchWaiting(_ lang: PromptLanguage = .current) -> String { t(lang, "等你拍板", "needs you") }
    static func groupWatchCapped(_ cap: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "停在第 \(cap) 轮", "stopped at round \(cap)") }
    static func groupWatchFailed(_ lang: PromptLanguage = .current) -> String { t(lang, "主运行失败", "primary run failed") }
    static func groupWatchStopped(_ r: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "已停在第 \(r) 轮", "stopped at round \(r)") }
    static func groupStop(_ lang: PromptLanguage = .current) -> String { t(lang, "停", "Stop") }
    static func groupPassedTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "通过", "Passed") }
    static func groupNeedsYou(_ lang: PromptLanguage = .current) -> String { t(lang, "需要你", "Needs you") }
    static func groupCappedTitle(_ cap: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "\(cap) 轮未通过", "\(cap) rounds, not passed") }
    static func groupCappedLast(_ lang: PromptLanguage = .current) -> String { t(lang, "最后意见", "last feedback") }
    static func groupAgain(_ cap: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "再来 \(cap) 轮", "\(cap) more rounds") }
    static func groupAgainText(_ lang: PromptLanguage = .current) -> String { t(lang, "按监督者最后一轮的意见继续做。", "Carry on per the watcher's last feedback.") }
    static func groupDismiss(_ lang: PromptLanguage = .current) -> String { t(lang, "算了", "Leave it") }
    static func groupAnswerIt(_ lang: PromptLanguage = .current) -> String { t(lang, "回答它…", "Answer it…") }
    static func groupLoopRunning(_ lang: PromptLanguage = .current) -> String { t(lang, "循环进行中:要插话先按停,再重新发。", "Loop running: stop it first, then resend.") }
    static func groupSendFailed(_ lang: PromptLanguage = .current) -> String { t(lang, "没发出去,再试一次。", "Not sent — try again.") }
    static func groupAskWorker(_ lang: PromptLanguage = .current) -> String { t(lang, "交给主去做…", "Give the primary a task…") }
    static func groupVerdictPass(_ lang: PromptLanguage = .current) -> String { t(lang, "通过", "pass") }
    static func groupVerdictGo(_ lang: PromptLanguage = .current) -> String { t(lang, "继续", "go on") }
    static func groupVerdictAsk(_ lang: PromptLanguage = .current) -> String { t(lang, "需要你", "needs you") }
    static func groupSynthCell(_ lang: PromptLanguage = .current) -> String { t(lang, "汇总", "synthesis") }
    static func groupPermWarn(_ lang: PromptLanguage = .current) -> String {
        t(lang, "主现在是\"每步问我\"权限,后台运行弹不出审批;开始时会切成 acceptEdits。",
          "The primary is on \"ask before edits\"; a background run cannot ask. It will start as acceptEdits.")
    }
    static func groupPartner(_ lang: PromptLanguage = .current) -> String { t(lang, "伙伴", "Partner") }
    static func groupPartnerNew(_ backend: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "新开一段 " + backend + " 对话", "New " + backend + " conversation")
    }
    static func groupPartnerExisting(_ lang: PromptLanguage = .current) -> String { t(lang, "选一段已有对话", "Pick an existing conversation") }
    static func groupAutoSynth(_ lang: PromptLanguage = .current) -> String { t(lang, "每轮自动汇总", "Synthesize every round") }
    static func groupStart(_ lang: PromptLanguage = .current) -> String { t(lang, "开始", "Start") }
    static func groupPrimary(_ lang: PromptLanguage = .current) -> String { t(lang, "主", "Primary") }
    static func groupAskAll(_ lang: PromptLanguage = .current) -> String { t(lang, "问全组…", "Ask everyone…") }
    static func groupRound(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "第 \(n) 轮", "Round \(n)") }
    static func groupStateAnswering(_ done: Int, _ total: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "已答 \(done)/\(total)", "\(done)/\(total) answered")
    }
    static func groupStateSynth(_ lang: PromptLanguage = .current) -> String { t(lang, "汇总中", "Synthesizing") }
    static func groupStateRelay(_ lang: PromptLanguage = .current) -> String { t(lang, "结论回流中", "Relaying") }
    static func groupStateDone(_ lang: PromptLanguage = .current) -> String { t(lang, "本轮完成", "Round done") }
    static func groupStateIdle(_ lang: PromptLanguage = .current) -> String { t(lang, "等你开口", "Waiting for you") }
    static func groupPaneAnswering(_ lang: PromptLanguage = .current) -> String { t(lang, "正在作答,回复到了就显示", "Answering — the reply appears when it lands") }
    static func groupRoundBusy(_ lang: PromptLanguage = .current) -> String { t(lang, "这一轮还没跑完,等它结束再问。", "This round is still running — wait for it to finish.") }
    static func groupSplit(_ lang: PromptLanguage = .current) -> String { t(lang, "分屏", "Split") }
    static func groupPager(_ lang: PromptLanguage = .current) -> String { t(lang, "滑动", "Swipe") }
    static func groupClose(_ lang: PromptLanguage = .current) -> String { t(lang, "解散", "Disband") }
    static func groupCloseConfirm(_ lang: PromptLanguage = .current) -> String {
        t(lang, "解散后两段对话都保留,只是不再互传。", "Both conversations stay; they just stop exchanging.")
    }
    static func groupViaHuman(_ lang: PromptLanguage = .current) -> String { t(lang, "来自组", "From the Duet") }
    static func groupBackTo(_ lang: PromptLanguage = .current) -> String { t(lang, "这段对话在一个组里 · 回到组", "Part of a Duet · back to it") }
    static func groupToAll(_ lang: PromptLanguage = .current) -> String { t(lang, "全组", "Everyone") }
    static func groupToOne(_ who: String, _ lang: PromptLanguage = .current) -> String { t(lang, "只给" + who, "Only " + who) }
    static func groupMemberSettings(_ who: String, _ lang: PromptLanguage = .current) -> String { t(lang, who + " 的参数…", who + " settings…") }
    static func groupMemberSettingsHint(_ lang: PromptLanguage = .current) -> String { t(lang, "改动从这位成员的下一条消息起生效;对话本身不变。", "Applies from this member's next message; the conversation itself stays.") }
    static func groupRowTitle(_ names: String, _ lang: PromptLanguage = .current) -> String { t(lang, "组 · " + names, "Duet · " + names) }
    static func groupLiveTitle(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "组 · 第 \(n) 轮", "Duet · round \(n)") }
    static func groupViaSynth(_ lang: PromptLanguage = .current) -> String { t(lang, "汇总请求", "Synthesis request") }
    static func groupViaRelay(_ lang: PromptLanguage = .current) -> String { t(lang, "本轮结论", "Round conclusion") }
    static func groupViaWatcher(_ lang: PromptLanguage = .current) -> String { t(lang, "监督者的意见", "Watcher's feedback") }
    static func groupViaReview(_ lang: PromptLanguage = .current) -> String { t(lang, "审一轮", "Review request") }
    static func groupViaFix(_ lang: PromptLanguage = .current) -> String { t(lang, "补结论", "Verdict line") }
    static func groupViaCritique(_ lang: PromptLanguage = .current) -> String { t(lang, "点评请求", "Critique request") }
    static func groupPrimaryNeedsTurn(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这段对话还没开始,先在这里聊一句再双开。", "Say something here first, then pair up.")
    }
    // Server-file preview: a reply linked an absolute path on the Mac.
    static func previewLoading(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正在从 Mac 取文件…", "Fetching the file from the Mac…")
    }
    static func previewMissing(_ path: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "Mac 上没有这个文件:" + path, "No such file on the Mac: " + path)
    }
    static func previewTooBig(_ maxBytes: Int, _ lang: PromptLanguage = .current) -> String {
        let mb = maxBytes / 1_000_000
        return t(lang, "文件超过 \(mb) MB,手机上不预览;请在 Mac 上打开。",
                 "The file is over \(mb) MB — not previewed on the phone; open it on the Mac.")
    }
    static func previewFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "文件没取回来,请重试。", "The file didn't come through — try again.")
    }
    static func previewTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Mac 上的文件", "File on the Mac")
    }
    static func takeoverHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这段对话正在别处运行(终端、VS Code 或另一部手机)", "This conversation is open elsewhere (a terminal, VS Code or another phone)")
    }
    static func cancel(_ lang: PromptLanguage = .current) -> String {
        t(lang, "取消", "Cancel")
    }
    static func takeoverButton(_ lang: PromptLanguage = .current) -> String {
        t(lang, "强制接管", "Take over")
    }
    static func takeoverConfirmTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "强制接管这段对话?", "Take over this conversation?")
    }
    static func takeoverConfirmBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "另一边的这段对话会被断开,历史不会丢;接管后自动重发你刚才那句话。",
          "The other side of this conversation is disconnected; nothing in the history is lost. Your last message is resent automatically.")
    }
    static func takeoverFailed(_ reason: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "接管失败:" + reason, "Takeover failed: " + reason)
    }
    static func issuePrinting(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这一期正在印制 — 稍后见首页卡片",
          "Printing this issue — watch for its home-screen card shortly")
    }

    // MARK: - Publication badge / editor notice card

    static func publicationBadge(_ lang: PromptLanguage = .current) -> String {
        t(lang, "刊物", "Publication")
    }
    static func publicationCardTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这个工作流会产出首页刊物卡片",
          "This workflow produces a home-screen publication card")
    }
    static func publicationCardWhere(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "每天运行后归档到下面这个目录,首页出卡片、可翻旧刊。",
          "Archived to the directory below after each daily run — a home-screen card, "
            + "with back issues you can browse.")
    }
    static func publicationCardStep(_ stepId: String,
                                    _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "「\(stepId)」这一步的结果就是刊物正文,",
          "The output of the \"\(stepId)\" step is the publication's body — ")
    }

    // MARK: - Workflows list: delete confirmations (irreversible — say what goes)

    /// These were authored in English; the English branch is that original text,
    /// verbatim. The Chinese branch is the shipped default now that the switch
    /// governs the whole UI.
    static func deleteRunTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "删除这次运行?它的转录和会话会被永久移除。",
          "Delete this run? Its transcript and conversations are removed permanently.")
    }
    static func deleteRunConfirm(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除运行", "Delete run")
    }
    static func deleteSubscriptionTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "删除这个订阅?每日运行会停止,首页也不再收到新的一期,除非你重新添加。",
          "Delete this subscription? The daily run stops and no new issue reaches your "
            + "home screen until you re-add it.")
    }
    static func deleteSubscriptionConfirm(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除订阅", "Delete subscription")
    }
    static func deleteScheduleTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "删除这个日程?每日运行会停止,除非你重新添加。",
          "Delete this schedule? The daily run stops until you re-add it.")
    }
    static func deleteScheduleConfirm(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除日程", "Delete schedule")
    }
    /// Fallback confirm verb for the dialog (matches the enum's default).
    static func delete(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除", "Delete")
    }

    // MARK: - Pin a conversation to the top (leading swipe, both session lists)
    //
    // A phone-local preference (no server round-trip): the leading swipe on a
    // conversation row — in the home "Recent" list and in a project's history —
    // pins it above the time-sorted rest, or unpins it back. Green swipe like
    // the Workflows "Run now" leading action; the same one verb switches.

    static func pin(_ lang: PromptLanguage = .current) -> String {
        t(lang, "置顶", "Pin")
    }
    static func unpin(_ lang: PromptLanguage = .current) -> String {
        t(lang, "取消置顶", "Unpin")
    }

    // MARK: - "Task finished" banner (the app's own, Tier-1 notification)
    //
    // The banner the app posts itself when it catches a task finishing while it
    // is still alive — the fallback for a Mac that cannot push (no APNs key, no
    // registered token). Its title was hard-coded English while the rest of the
    // app followed the Settings toggle, so a Chinese user's lock screen read
    // "Task finished". The words are also deliberately parallel to the Mac's own
    // push (`pervio-run` `_push_text`): whichever channel delivers, the user reads
    // the same sentence — WHICH project, and how it went.

    static func taskFinishedTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "任务完成", "Task finished")
    }
    static func taskFailedTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "任务失败", "Task failed")
    }
    /// Body for a finished task that left nothing quotable (no reply text, no
    /// prompt preview) — never leave the banner blank.
    static func taskFinishedBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一轮跑完了。", "This run is done.")
    }
    static func taskFailedBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一轮以错误结束。", "Ended with an error.")
    }
    /// A workflow with no name of its own — the banner still needs a subject.
    static func workflowFallbackName(_ lang: PromptLanguage = .current) -> String {
        t(lang, "工作流", "Workflow")
    }
    /// Bodies for a workflow completion. The step count is used where it is known
    /// (the monitor watches the ledger); the list poll only has the summary, so it
    /// gets the plain form rather than an invented number.
    static func workflowStepsFinishedBody(_ steps: Int,
                                          _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(steps) 步全部完成", "\(steps) steps finished")
    }
    static func workflowFinishedBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这条工作流跑完了", "This workflow finished")
    }
    static func workflowFailedBody(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这条工作流失败了", "This workflow failed")
    }

    // MARK: - Settings

    static func settingsTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "设置", "Settings")
    }
    static func done(_ lang: PromptLanguage = .current) -> String {
        t(lang, "完成", "Done")
    }
    /// The picker's own label — the setting now governs the whole UI, so it is
    /// "App language", not "Prompt language".
    static func settingsLanguageLabel(_ lang: PromptLanguage = .current) -> String {
        t(lang, "App 语言", "App language")
    }
    static func settingsLanguageFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "App 界面以及它写给模型的提示词(构建工作流的引导语、讨论开场白、附带背景的包装、"
            + "工作流指针)都用这个语言。服务器端的工作流模板(如晨报)保留它们原本的语言。",
          "The language of the app's interface and of the prompts it writes for the "
            + "model (build-a-workflow seeds, discussion openers, attached-context "
            + "wrappers, workflow pointers). Server-side workflow templates (e.g. the "
            + "morning report) keep the language they were written in.")
    }

    // MARK: - Permission approval sheet (Group 1 — safety-critical, precise wording)

    /// The verb the sheet leads with, per pervio tool. Safety copy: an approval
    /// that starts a run or edits a schedule must read unambiguously.
    static func permStartWorkflow(_ lang: PromptLanguage = .current) -> String {
        t(lang, "启动工作流", "Start workflow")
    }
    static func permRerunWorkflow(_ lang: PromptLanguage = .current) -> String {
        t(lang, "重跑工作流", "Re-run workflow")
    }
    static func permEditSubscription(_ lang: PromptLanguage = .current) -> String {
        t(lang, "修改订阅", "Edit subscription")
    }
    static func permRecordFeedback(_ lang: PromptLanguage = .current) -> String {
        t(lang, "记录论文反馈", "Record paper feedback")
    }

    /// The orange spend warning shown when start / rerun / schedule-create burn
    /// model quota — it must say so plainly before the user allows.
    static func permSpendsQuota(_ lang: PromptLanguage = .current) -> String {
        t(lang, "将消耗模型额度", "Will spend model quota")
    }

    // Argument-row labels (the left column of the plain-words breakdown).
    static func permLabelTemplate(_ lang: PromptLanguage = .current) -> String {
        t(lang, "模板", "Template")
    }
    static func permLabelDir(_ lang: PromptLanguage = .current) -> String {
        t(lang, "目录", "Directory")
    }
    static func permLabelSourceRun(_ lang: PromptLanguage = .current) -> String {
        t(lang, "原运行", "Source run")
    }
    static func permLabelSubscription(_ lang: PromptLanguage = .current) -> String {
        t(lang, "订阅", "Subscription")
    }
    static func permLabelAction(_ lang: PromptLanguage = .current) -> String {
        t(lang, "操作", "Action")
    }
    static func permLabelTime(_ lang: PromptLanguage = .current) -> String {
        t(lang, "时间", "Time")
    }
    static func permLabelDays(_ lang: PromptLanguage = .current) -> String {
        t(lang, "周几", "Days")
    }
    static func permLabelKeepRuns(_ lang: PromptLanguage = .current) -> String {
        t(lang, "保留期数", "Keep runs")
    }
    static func permLabelStatus(_ lang: PromptLanguage = .current) -> String {
        t(lang, "状态", "Status")
    }
    static func permLabelPaper(_ lang: PromptLanguage = .current) -> String {
        t(lang, "论文", "Paper")
    }
    static func permLabelVerdict(_ lang: PromptLanguage = .current) -> String {
        t(lang, "评价", "Verdict")
    }
    static func permLabelNote(_ lang: PromptLanguage = .current) -> String {
        t(lang, "备注", "Note")
    }

    // Action-value names (schedule create/update/pause/resume/delete). Safety
    // copy: "delete" must never blur into "pause".
    static func permActionUpdate(_ lang: PromptLanguage = .current) -> String {
        t(lang, "更新", "Update")
    }
    static func permActionPause(_ lang: PromptLanguage = .current) -> String {
        t(lang, "暂停", "Pause")
    }
    static func permActionResume(_ lang: PromptLanguage = .current) -> String {
        t(lang, "恢复", "Resume")
    }
    static func permActionDelete(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除", "Delete")
    }
    static func permActionCreate(_ lang: PromptLanguage = .current) -> String {
        t(lang, "新建", "Create")
    }

    // The `enabled` value rendered as a status word.
    static func permStatusEnabled(_ lang: PromptLanguage = .current) -> String {
        t(lang, "启用", "Enabled")
    }
    static func permStatusPaused(_ lang: PromptLanguage = .current) -> String {
        t(lang, "暂停", "Paused")
    }

    /// ISO weekday number → its short name, for the "days" row.
    static func permWeekday(_ iso: Int, _ lang: PromptLanguage = .current) -> String {
        let zh = [1: "周一", 2: "周二", 3: "周三", 4: "周四",
                  5: "周五", 6: "周六", 7: "周日"]
        let en = [1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu",
                  5: "Fri", 6: "Sat", 7: "Sun"]
        return (lang == .chinese ? zh : en)[iso] ?? "\(iso)"
    }

    /// spec_b64 summarized as the workflow's own name (decoded locally).
    static func permSpecNamed(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "自定义工作流「\(name)」", "Custom workflow \"\(name)\"")
    }
    /// A saved workflow the Mac looked up (a template, a named tool, a past run).
    static func permSpecSaved(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "工作流「\(name)」", "Workflow \"\(name)\"")
    }
    // What a submitted workflow would do, row by row (WorkflowSpecDigest).
    static func permSpecStep(_ id: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "步骤 \(id)", "Step \(id)")
    }
    static func permSpecRuns(_ line: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "在 Mac 上运行:\(line)", "Runs on the Mac: \(line)")
    }
    static func permSpecBefore(_ lang: PromptLanguage = .current) -> String { t(lang, "开始前", "Before it starts") }
    static func permSpecMenu(_ lang: PromptLanguage = .current) -> String { t(lang, "报告菜单", "Report menu") }
    static func permSpecPublishes(_ target: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "结果由 Mac 写到:\(target)", "The Mac writes its result to: \(target)")
    }
    static func permSpecShelf(_ lang: PromptLanguage = .current) -> String { t(lang, "刊物存档", "the publications shelf") }
    // What cannot be shown whole cannot be allowed.
    static func permSpecUnreadable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "手机读不出这份工作流要做什么,所以不能允许。可以拒绝。",
          "The phone cannot read what this workflow would do, so it cannot be allowed. You can deny it.")
    }
    static func permSpecTooLong(_ lang: PromptLanguage = .current) -> String {
        t(lang, "有一行命令太长,这里显示不全,所以不能允许。可以拒绝。",
          "One command line is too long to show in full here, so this cannot be allowed. You can deny it.")
    }
    static func permSpecTooMany(_ lang: PromptLanguage = .current) -> String {
        t(lang, "步骤太多,这里列不全,所以不能允许。可以拒绝,或者在工作流页面自己启动。",
          "Too many steps to list here, so this cannot be allowed. Deny it, or start it yourself from the Workflows page.")
    }
    static func permTierRead(_ lang: PromptLanguage = .current) -> String { t(lang, "只读", "read-only") }
    static func permTierAsk(_ lang: PromptLanguage = .current) -> String { t(lang, "改之前要问,没人答就不改", "asks before changing; unanswered = no change") }
    static func permTierWrite(_ lang: PromptLanguage = .current) -> String { t(lang, "可以直接改文件", "may change files unasked") }
    static func permTierAuto(_ lang: PromptLanguage = .current) -> String { t(lang, "自己判断要不要问", "decides itself when to ask") }
    static func permTierFull(_ lang: PromptLanguage = .current) -> String { t(lang, "不受限制,什么都不问", "unrestricted, asks nothing") }
    /// spec_b64 with no readable name → a size note.
    static func permSpecSize(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "自定义 spec(\(n) 字符)", "Custom spec (\(n) chars)")
    }

    // MARK: - Composer menu + rewind (Group 1 — ChatView chrome)

    /// ＋ menu entry: attach a photo from the phone's library.
    static func attachPhoto(_ lang: PromptLanguage = .current) -> String {
        t(lang, "照片", "Photo")
    }
    /// ＋ menu entry: attach a file from the phone (the Files app).
    static func attachFile(_ lang: PromptLanguage = .current) -> String {
        t(lang, "文件", "File")
    }
    /// ＋ menu entry: browse the SERVER's file system and attach a file (or hand
    /// a directory over) — the browser the 背景 sheet embeds, surfaced.
    static func attachServerFile(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器文件…", "Server file…")
    }
    /// ＋ menu entry: attach a past conversation as background context.
    static func attachContext(_ lang: PromptLanguage = .current) -> String {
        t(lang, "背景…", "Context…")
    }
    /// The user-bubble edit-menu verb: fork the conversation and reword from here.
    static func settingsTextSize(_ lang: PromptLanguage = .current) -> String { t(lang, "文字大小", "Text size") }
    static func settingsTextSizeFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang, "整个 App 的文字一起缩放,层级不变;终端字号同步。跟随系统 = 用手机的\"文字大小\"设置。",
          "All text in the app scales together, hierarchy intact; the terminal follows. System = the phone's own Text Size setting.")
    }
    static func renameConversation(_ lang: PromptLanguage = .current) -> String { t(lang, "重命名对话", "Rename conversation") }
    static func renamePrompt(_ lang: PromptLanguage = .current) -> String { t(lang, "给这个对话起个名字(留空恢复默认)", "Name this conversation (empty restores the default)") }
    static func save(_ lang: PromptLanguage = .current) -> String { t(lang, "保存", "Save") }
    static func stopUsingFolder(_ lang: PromptLanguage = .current) -> String { t(lang, "这个对话不再带上这个文件夹", "Stop using this folder in this conversation") }
    /// A folder the conversation's text names but the person has not handed
    /// over (a conversation from before folders were kept as a list).
    static func formerFolderTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这个文件夹现在没有带上", "This folder is not in use now")
    }
    static func formerFolderBody(_ path: String, _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "\(path)\n\n这段对话以前带过它。现在只认你用 ＋ 选过的文件夹,所以它没有被带上,agent 不能在里面改文件。"
            + "需要的话:＋ → 服务器文件… → 找到它 → 把此目录交给对话。",
          "\(path)\n\nThis conversation used it before. Only folders you pick with ＋ count now, so it is not "
            + "handed over and the agent cannot change files in it. To use it again: ＋ → Server files… → "
            + "open it → hand the folder to the conversation.")
    }
    static func gotIt(_ lang: PromptLanguage = .current) -> String { t(lang, "知道了", "OK") }
    static func branchToNewChat(_ lang: PromptLanguage = .current) -> String { t(lang, "分支到新对话", "Branch in new chat") }
    static func branchedHere(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已从这里分支出新对话;原对话还在列表里。", "Branched into a new conversation from here; the original stays in the list.")
    }
    static func branchFailed(_ why: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没能分支:\(why)", "Couldn't branch: \(why)")
    }
    static func restateFromHere(_ lang: PromptLanguage = .current) -> String {
        t(lang, "从这里重新说", "Restate from here")
    }

    // MARK: - Context picker + server file browser (Group 2)

    /// Navigation title of the ＋ → Context sheet.
    static func contextTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "背景", "Context")
    }
    /// Entry row into the server file browser.
    static func browseServerFiles(_ lang: PromptLanguage = .current) -> String {
        t(lang, "浏览服务器文件…", "Browse server files…")
    }
    static func noConversationsOnServer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这台服务器上还没有历史会话。",
             "No past conversations on this server yet.")
    }
    /// Footer under the project list: pick a conversation → its transcript rides
    /// as an attachment.
    static func contextProjectsFooter(_ turns: Int,
                                      _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "进一个项目,勾选要带上的:历史对话、它的 CLAUDE.md / AGENTS.md / 规则文件、Claude 的记忆。都会作为附件进入当前消息,发送前可删除。",
          "Open a project and tick what to bring: past conversations, its CLAUDE.md / AGENTS.md / rules files, Claude's memory. "
            + "They attach to the current message, and you can remove them before sending.")
    }
    static func contextNotesSection(_ lang: PromptLanguage = .current) -> String { t(lang, "项目说明", "Project notes") }
    static func contextMemorySection(_ lang: PromptLanguage = .current) -> String { t(lang, "Claude Code 自带的记忆", "Claude Code's own memory") }
    /// The one word beside Claude's mark on the memory row.
    static func contextMemoryWord(_ lang: PromptLanguage = .current) -> String { t(lang, "记忆", "memory") }
    static func contextMemoryFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Claude Code 自己跨会话记的笔记索引。它自己每次都会读,不用为 Claude Code 勾;勾它是给 Codex、Cursor 或别的对话看。", "The index of notes Claude Code keeps for itself across sessions. It reads them on its own, so there is no need to tick it for Claude Code; tick it for Codex, Cursor or another conversation.")
    }
    static func contextConversationsSection(_ lang: PromptLanguage = .current) -> String { t(lang, "对话", "Conversations") }
    static func contextAttachCount(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        n == 0 ? t(lang, "勾选要带上的", "Tick what to bring") : t(lang, "带上 \(n) 项", "Bring \(n)")
    }
    static func contextDocKind(_ kind: String, _ lang: PromptLanguage = .current) -> String {
        switch kind {
        case "claude-md": return t(lang, "人写的指令 · Claude Code 读", "written by people · Claude Code reads it")
        case "agents-md": return t(lang, "人写的指令 · Codex / Cursor 读", "written by people · Codex and Cursor read it")
        case "rules": return t(lang, "人写的规则 · Claude Code 读", "rules written by people · Claude Code reads them")
        case "cursor-rules": return t(lang, "人写的规则 · Cursor 读", "rules written by people · Cursor reads them")
        case "memory": return t(lang, "Claude Code 自带的记忆(索引)", "Claude Code's own memory (the index)")
        default: return kind
        }
    }
    /// Placeholder in the cross-project search box.
    static func searchAllProjects(_ lang: PromptLanguage = .current) -> String {
        t(lang, "搜索所有项目的会话内容", "Search all projects' conversations")
    }
    /// Empty-search-result line.
    static func noConversationMentions(_ query: String,
                                       _ lang: PromptLanguage = .current) -> String {
        t(lang, "没有会话提到「\(query)」。",
             "No conversation mentions \"\(query)\".")
    }
    /// Footer under flat search results.
    static func contextSearchFooter(_ turns: Int,
                                    _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "跨所有项目按内容匹配;点选后其文稿(最近 \(turns) 轮)会作为附件进入当前消息,发送前可删除。",
          "Matched by content across every project; pick one and its transcript "
            + "(the latest \(turns) turns) attaches to the current message, "
            + "removable before sending.")
    }
    /// Chip on the row that IS the conversation being typed into (not selectable).
    static func currentConversation(_ lang: PromptLanguage = .current) -> String {
        t(lang, "当前对话", "This conversation")
    }
    /// Chip on the project that matches the current conversation's directory.
    static func thisProject(_ lang: PromptLanguage = .current) -> String {
        t(lang, "本项目", "This project")
    }
    /// A project row's session count.
    static func sessionCount(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(n) 条会话", "\(n) conversations")
    }
    /// Empty-state for a project with no sessions.
    static func noConversationsInProject(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这个项目还没有会话。", "No conversations in this project yet.")
    }
    /// Footer under one project's session list.
    static func contextSessionFooter(_ turns: Int,
                                     _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "对话按最近的内容导出(最多约 300KB),文档里写明共几条、含第几到第几条,模型可以用里面给的命令自己翻更早的。",
          "A conversation exports its latest turns (up to about 300KB); the document says how many there are and which it holds, "
            + "and the model can page further back with the command inside it.")
    }
    /// Fallback error when the search call fails.
    static func searchFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "搜索失败,请重试。", "Search failed — please try again.")
    }

    // Server file browser
    /// Navigation title of the file browser.
    static func serverFilesTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器文件", "Server files")
    }
    /// The header "go up one level" button.
    static func goUpOneLevel(_ lang: PromptLanguage = .current) -> String {
        t(lang, "上一级", "Up one level")
    }
    /// The action that hands the current directory over to the conversation.
    static func handOffDirectory(_ lang: PromptLanguage = .current) -> String {
        t(lang, "把此目录交给对话", "Hand this directory to the chat")
    }
    /// Footer under the hand-off-directory button.
    static func handoffDirFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "不打包内容——这个目录以 📁 胶囊挂在输入框上,发送时把路径和阅读指引一起交给 agent(你看不到那段指引);可续写后发送,读什么由 agent 自行决定。",
          "Nothing is packed — the directory hangs on the composer as a 📁 chip; on send its path and a reading hint go to the agent (you never see that hint). "
            + "You can keep typing before sending, and the agent decides what to read.")
    }
    static func directoryEmpty(_ lang: PromptLanguage = .current) -> String {
        t(lang, "此目录为空。", "This directory is empty.")
    }
    static func onlyHiddenItems(_ lang: PromptLanguage = .current) -> String {
        t(lang, "只有隐藏项(用下方开关显示)。",
             "Hidden items only (show them with the toggle below).")
    }
    /// Footer when the listing was capped at 500 entries.
    static func directoryCapped(_ total: Int,
                                _ lang: PromptLanguage = .current) -> String {
        t(lang, "目录共 \(total) 项,仅显示前 500 项。",
             "The directory has \(total) items; only the first 500 are shown.")
    }
    static func showHiddenItems(_ lang: PromptLanguage = .current) -> String {
        t(lang, "显示隐藏项", "Show hidden items")
    }
    /// Footer under the whole browse list.
    static func fileBrowserFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "点文件附加其内容(UTF-8 文本,≤60KB,超限截断);目录可进入。",
          "Tap a file to attach its contents (UTF-8 text, ≤60KB, truncated past "
            + "that); tap a directory to enter it.")
    }
    /// Fallback error when a directory listing fails.
    static func directoryReadFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "无法读取该目录,请重试。",
             "Couldn't read this directory — please try again.")
    }

    // MARK: - ChatStore system bubbles (Group 3 — the ⚠️ centered notices)

    static func bubbleNotConnectedContext(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Not connected — 无法取回背景会话。",
             "Not connected — couldn't retrieve the background conversation.")
    }
    static func bubbleContextEmpty(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这条会话导不出内容(可能为空或已被删除)。",
             "This conversation exports nothing (it may be empty or deleted).")
    }
    static func bubbleContextFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "取回背景会话失败,请重试。",
             "Couldn't retrieve the background conversation — please try again.")
    }
    static func bubbleNotConnectedFile(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Not connected — 无法读取服务器文件。",
             "Not connected — couldn't read the server file.")
    }
    static func bubbleFileUnparseable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器返回了无法解析的结果,请重试。",
             "The server returned an unparseable result — please try again.")
    }
    static func bubbleFileNoPath(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器没有返回附件路径,请重试。",
             "The server didn't return an attachment path — please try again.")
    }
    static func bubbleFileReadFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "读取服务器文件失败,请重试。",
             "Couldn't read the server file — please try again.")
    }
    // Removed with the inline 背景 route: bubbleCodexOneContext (the
    // one-document-per-message cap) and bubbleBackendSwitched (the drop on a
    // backend switch). Both notices could only fire for an inlined document;
    // a path attachment has neither limit.

    // MARK: - SSHService user-facing errors (Group 3)

    /// The fs script's in-band error codes → user-facing copy (shared by the
    /// browser rows and the attach paths).
    static func fsErrorNotFound(_ lang: PromptLanguage = .current) -> String {
        t(lang, "路径不存在(可能已被移动或删除)。",
             "The path doesn't exist (it may have moved or been deleted).")
    }
    static func fsErrorNotDir(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这不是目录。", "This isn't a directory.")
    }
    static func fsErrorNotFile(_ lang: PromptLanguage = .current) -> String {
        t(lang, "暂只支持文本文件(这不是普通文件)。",
             "Only text files are supported for now (this isn't a regular file).")
    }
    static func fsErrorPermission(_ lang: PromptLanguage = .current) -> String {
        t(lang, "没有权限读取该路径。",
             "You don't have permission to read this path.")
    }
    static func fsErrorBinary(_ lang: PromptLanguage = .current) -> String {
        t(lang, "暂只支持文本文件(该文件不是 UTF-8 文本)。",
             "Only text files are supported for now (this file isn't UTF-8 text).")
    }
    static func fsErrorUnreadable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "无法读取该路径,请重试。",
             "Couldn't read this path — please try again.")
    }
    static func fsErrorGeneric(_ code: String,
                               _ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器脚本报告了错误(\(code))。",
             "The server script reported an error (\(code)).")
    }
    /// decodeList: the server returned nothing usable.
    static func listNoContent(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器没有返回任何内容(命令可能不存在或连接中断),请重试。",
             "The server returned nothing (the command may be missing or the "
            + "connection dropped) — please try again.")
    }
    /// decodeList: the answer didn't parse; the last-good rows were kept.
    static func listUnparseable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器返回了无法解析的列表,已保留上一次的结果,请重试。",
             "The server returned an unparseable list; the previous result was "
            + "kept — please try again.")
    }
    /// startDesktopView: no loopback address came back.
    static func desktopViewNoAddress(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器没有返回可用的地址(pervio-view 可能未安装)。",
             "The server didn't return a usable address (pervio-view may not be "
            + "installed).")
    }

    // MARK: - Connect refusals (Group 3 — the copy the OTHER language authored)

    /// These seven sentences run the other way round: they were authored in
    /// ENGLISH, so here the English branch is that original text, verbatim, and
    /// the Chinese branch is the new one. They are what `pervioErrorText` shows
    /// when the app refuses to talk to a server, which makes them the only
    /// security copy in the app a user reads at exactly the wrong moment —
    /// under the shipped default, a Chinese-speaking user was being handed an
    /// English man-in-the-middle warning and the natural response (tap again)
    /// is the one thing they must not do. Every branch keeps the actionable
    /// part — the fingerprint command, the authorized_keys path, the address
    /// and port — because that is the whole difference between a refusal and a
    /// shrug.
    static func connErrHostKeyMismatch(_ host: String, _ port: Int,
                                       _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这台服务器出示的主机密钥不是本配置里固定的那一把 —— 连接已拒绝。"
            + "可能是服务器重装换了新主机密钥,也可能在 \(host):\(port) 上应答的根本是别人。"
            + "在你亲自到那台服务器上核对指纹之前,不要重新固定:"
            + "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub",
          "This server presented a host key that is NOT the one pinned in this profile — "
            + "connection refused. Either the server was rebuilt with a new host key, or "
            + "something else is answering at \(host):\(port). Do NOT re-pin "
            + "until you have read the fingerprint ON the server itself: "
            + "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
    }
    static func connErrAuthRejected(_ host: String, _ username: String,
                                    _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "\(host) 拒绝了「\(username)」的这份凭据。网络和主机密钥都没问题,"
            + "所以请检查用户名,以及这把密钥的公钥是否已经写进服务器上该账号的 "
            + "~/.ssh/authorized_keys。",
          "\(host) refused these credentials for ‘\(username)’. The network "
            + "and the host key were fine, so check the username, and that this key's public "
            + "half is in that account's ~/.ssh/authorized_keys on the server.")
    }
    static func connErrHostNotFound(_ host: String,
                                    _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "找不到名为「\(host)」的主机。先检查地址有没有打错 —— "
            + "如果这个名字只有你家里或公司的网络认得,你就得连在那个网络上(或者改用它的 IP)。",
          "No host called ‘\(host)’ could be found. Check the address for a "
            + "typo — if it is a name only your home/office network knows, you have to be "
            + "on that network (or use its IP address).")
    }
    static func connErrPortClosed(_ host: String, _ port: Int,
                                  _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "\(host) 的 \(port) 端口上没有任何东西在监听。地址是解析得到的,"
            + "所以要么机器或 SSH 服务没在跑,要么端口填错了,要么被防火墙挡了。",
          "Nothing is listening on \(host) port \(port). The address "
            + "resolved, so the machine or the SSH service is down, the port is wrong, or a "
            + "firewall is dropping it.")
    }
    static func connErrNoPin(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "没有固定主机密钥 —— 拒绝连接(不固定就等于信任任何一台应答的服务器,"
            + "中间人可以直接接管)。把服务器的主机密钥填进这个配置:在服务器上跑  "
            + "ssh-keyscan -t ed25519 <host>  ,把 \"ssh-ed25519 AAAA…\" 那一行"
            + "粘进「Pinned host key」。",
          "No pinned host key — refusing to connect (an unpinned key trusts any "
            + "server and allows man-in-the-middle). Add your server's host key to "
            + "this profile: on the server run  ssh-keyscan -t ed25519 <host>  and "
            + "paste the \"ssh-ed25519 AAAA…\" line into ‘Pinned host key’.")
    }
    static func connErrUnusablePin(_ rejected: Int,
                                   _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "固定的主机密钥里没有一行能解析"
            + (rejected > 0 ? "(\(rejected) 行被跳过)" : "")
            + "。请重新从服务器取回主机密钥,再信任一次。",
          "None of the pinned host-key lines could be parsed"
            + (rejected > 0 ? " (\(rejected) rejected)" : "")
            + ". Re-fetch the host key from the server and trust it again.")
    }
    static func connErrBadPrivateKey(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这把私钥解析不了。请用未加密的 OpenSSH 私钥(ed25519 或 RSA),不要带口令。",
          "Couldn't parse the private key. Use an unencrypted OpenSSH key "
            + "(ed25519 or RSA), no passphrase.")
    }
    /// Prefix on a refusal that happened on ONE HOP of a route.
    ///
    /// On a route there are three or more machines and only one of them is
    /// broken; "host key mismatch" without a hop number sends the user to go
    /// stare at the wrong box. The NUMBER is what makes it actionable (it is the
    /// row they can see in the editor) and the address is what makes it
    /// checkable, so both are said, in the user's language. `index` is 1-based
    /// for the same reason: the editor's rows are labelled 第 1 跳 / Hop 1.
    static func connErrRouteHopPrefix(_ index: Int, _ endpoint: String,
                                      _ lang: PromptLanguage = .current) -> String {
        t(lang, "第 \(index) 跳(\(endpoint)) — ", "Hop \(index) (\(endpoint)) — ")
    }
    /// Prefix on a refusal that happened at the END of a route. Deliberately not
    /// "第 N 跳": the destination is not a hop, and numbering it would send the
    /// user to the last bastion instead of to the machine they were trying to
    /// reach.
    static func connErrRouteTargetPrefix(_ endpoint: String,
                                         _ lang: PromptLanguage = .current) -> String {
        t(lang, "终点(\(endpoint)) — ", "Target (\(endpoint)) — ")
    }
    /// A leg of the route that could not be opened at all. The overwhelmingly
    /// common cause is the one named first: a locked-down bastion whose
    /// PermitOpen does not list the next machine — which is also what a route
    /// written in the wrong ORDER looks like from here.
    static func connErrRouteLegUnopenable(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这一段通道打不开。多半是上一跳不允许开到这台机器的通道"
            + "(sshd 的 PermitOpen / AllowTcpForwarding),也可能这台机器没在监听,"
            + "或者这条路线的顺序排错了。",
          "This leg of the route could not be opened. Most likely the hop before it does "
            + "not allow a channel to this machine (its sshd's PermitOpen / "
            + "AllowTcpForwarding), or nothing is listening there, or the hops are in the "
            + "wrong order.")
    }
    /// A hop configured to use its OWN key/password, but with nothing stored on
    /// THIS phone. Before this string, the empty secret fell through to the key
    /// parser and the user read「私钥无法解析」— pointing them at a corrupted
    /// key when nothing was stored at all (secrets live in the phone's
    /// Keychain, so a second device or a reinstall starts without them). The
    /// message must say WHAT is missing, WHERE that is normal, and the ONE
    /// place to fix it: this hop's row in the server editor.
    /// A hop on "same as the server" under a password login: connecting would
    /// hand the jump host the target's password. Says what would happen and
    /// the one place to change it.
    static func connErrHopWouldGetTargetPassword(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这一跳设的是「同主凭据」,而服务器用密码登录:这样连,跳板机会拿到目标机的密码,所以没有连。"
            + "到 服务器 → 编辑 → 这一跳,给它单独填密码或私钥(和目标机一样的密码也要在这里再填一次)。",
          "This hop is set to \"Same as the server\" while the server logs in with a password: "
            + "connecting would hand the jump host the target's password, so nothing was dialed. "
            + "Open Servers → Edit → this hop and give it a password or key of its own "
            + "(type the password there even when it is the same).")
    }
    /// The same rule, said in the editor before the route is saved.
    static func routeHopSharedPassword(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "服务器用密码登录时,跳板不能用「同主凭据」:那样跳板机会拿到目标机的密码。请给这一跳单独填密码或私钥。",
          "With a password login, a hop cannot use \"Same as the server\": the jump host would be handed "
            + "the target's password. Give this hop a password or key of its own.")
    }
    static func connErrHopSecretMissing(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这一跳设了用自己的密钥/密码,但这台手机上没有存它"
            + "(换了手机或重装过 app 都会这样)。到 服务器 → 编辑 → 这一跳,"
            + "重新填一次即可。",
          "This hop is set to use its own key/password, but none is stored on "
            + "this phone (normal after a new device or a reinstall). Open "
            + "Servers → edit → this hop and enter it once more.")
    }

    // MARK: - The route editor (经由)

    static func routeSectionTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "经由(可选)", "Route (optional)")
    }
    static func routeBlurb(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "要连的是上面那台「目标」机器;这里按顺序列出中途要经过的机器。"
            + "手机先连第 1 跳,再从第 1 跳穿到第 2 跳,依次到目标。"
            + "每一跳都要单独钉主机密钥——任何一跳没钉或对不上,整条连接都会被拒。"
            + "留空 = 直连。一条路线一个配置:另一条路走法就再建一个条目。",
          "The machine you are connecting to is the Target above; list here, in "
            + "order, the machines to pass through on the way. The phone dials hop 1, "
            + "tunnels from hop 1 to hop 2, and so on to the target. Every hop is "
            + "pinned separately — if any hop is unpinned or answers with the wrong "
            + "key, the whole connection is refused. Leave empty to connect directly. "
            + "One route per server entry: for another way in, add another entry.")
    }
    /// Row title in the editor — the same numbering the refusals use.
    static func routeHopTitle(_ index: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "第 \(index) 跳", "Hop \(index)")
    }
    static func routeAddHop(_ lang: PromptLanguage = .current) -> String {
        t(lang, "加一跳", "Add a hop")
    }
    static func routeEmpty(_ lang: PromptLanguage = .current) -> String {
        t(lang, "没有经由 —— 直接连目标。", "No hops — connecting straight to the target.")
    }
    static func routeHopHostField(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳的地址(IP 或域名)", "This hop's address (IP or domain)")
    }
    static func routeHopPortField(_ lang: PromptLanguage = .current) -> String {
        t(lang, "端口", "Port")
    }
    static func routeHopUserField(_ lang: PromptLanguage = .current) -> String {
        t(lang, "用户名(留空 = 同目标)", "Username (blank = same as the target)")
    }
    static func routeHopFetchKey(_ lang: PromptLanguage = .current) -> String {
        t(lang, "取这一跳的主机密钥", "Fetch this hop's host key")
    }
    static func routeHopFetching(_ lang: PromptLanguage = .current) -> String {
        t(lang, "取密钥中…", "Fetching…")
    }
    /// Shown above the fingerprints, before the user commits to trusting them.
    static func routeHopVerify(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳出示了这些密钥 —— 核对指纹后再钉:",
             "This hop presented these keys — verify the fingerprint, then trust:")
    }
    static func routeHopTrust(_ lang: PromptLanguage = .current) -> String {
        t(lang, "信任并钉住这一跳", "Trust & pin this hop")
    }
    static func routeHopUnpinned(_ lang: PromptLanguage = .current) -> String {
        t(lang, "未钉密钥 —— 这条路线无法连接", "Not pinned — this route cannot connect")
    }
    static func routeHopPinned(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已钉", "Pinned")
    }
    static func routeHopNoKeys(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳没有亮出本 app 能钉的主机密钥 —— 请手动粘一行。",
             "This hop presented no host key this app can pin — paste one manually.")
    }
    static func routeHopUnreachable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "连不上这一跳。", "Couldn't reach this hop.")
    }
    /// Why "Fetch" is disabled on a hop whose earlier hops are not pinned yet:
    /// the machine that CARRIES an unknown key must itself already be trusted.
    static func routeHopBlockedByEarlier(_ index: Int,
                                         _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "先把第 \(index) 跳钉好 —— 取密钥要经过它,一条还没验明的跳板递过来的密钥不能信。",
          "Pin hop \(index) first — the key you are about to trust travels through it, "
            + "and a key handed over by an unverified machine proves nothing.")
    }
    /// Save gate: a half-filled row would silently be skipped at connect time.
    static func routeBlankRow(_ lang: PromptLanguage = .current) -> String {
        t(lang, "有一跳还没填地址 —— 填好或删掉这一行再保存。",
             "A hop has no address yet — fill it in or delete the row before saving.")
    }

    // MARK: - Per-hop credentials (逐跳凭据)
    //
    // A route is not always uniform: a machine in the middle may accept only
    // another key, or only a password. These label the choice and the field it
    // opens; the default choice opens no field at all, so an ordinary route's
    // editor is exactly as long as it was.

    static func routeHopAuthField(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳的凭据", "This hop's credential")
    }
    static func routeHopAuthProfile(_ lang: PromptLanguage = .current) -> String {
        t(lang, "同主凭据", "Same as the server")
    }
    static func routeHopAuthKey(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳自己的私钥", "Its own private key")
    }
    static func routeHopAuthPassword(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳自己的密码", "Its own password")
    }
    /// Above the paste box — the same promise the main private-key field makes.
    static func routeHopKeyHint(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "粘贴只有这一跳认的那把私钥(未加密的 OpenSSH,ed25519 或 RSA)。"
            + "只存在 iOS 钥匙串里,不会写进服务器配置。",
          "Paste the private key this hop accepts (unencrypted OpenSSH, ed25519 or RSA). "
            + "Stored only in the iOS Keychain, never in the saved profile.")
    }
    static func routeHopKeySaved(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳已存了一把私钥(钥匙串)。留空 = 不动它;要换就粘一把新的。",
             "A private key is saved for this hop (Keychain). Leave blank to keep it; "
             + "paste a new one only to replace.")
    }
    static func routeHopPasswordField(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这一跳的密码", "This hop's password")
    }
    static func routeHopPasswordSaved(_ lang: PromptLanguage = .current) -> String {
        t(lang, "密码已存 —— 输入即替换", "Password saved — type to replace")
    }
    /// Collapsed-row badge: this hop does NOT use the server's own credential.
    /// It rides in the line that already carries 已钉/未钉, so it costs no row.
    static func routeHopOwnCredential(_ lang: PromptLanguage = .current) -> String {
        t(lang, "独立凭据", "Own credential")
    }
    /// Save gate: a hop set to its own credential with nothing behind it cannot
    /// authenticate, and the route would fail on that hop at connect time.
    static func routeHopNoCredential(_ lang: PromptLanguage = .current) -> String {
        t(lang, "有一跳选了独立凭据但还没填 —— 填好,或改回「同主凭据」再保存。",
             "A hop is set to its own credential but has none — enter it, or switch the hop "
             + "back to the server's credential, before saving.")
    }

    // MARK: - Archive reader (Group 4)

    /// Toolbar button: hand this issue to a desktop browser.
    static func openOnComputer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "在电脑上打开", "Open on computer")
    }
    /// Title of the desktop-address handoff sheet.
    static func desktopReady(_ lang: PromptLanguage = .current) -> String {
        t(lang, "报告已就绪 · 在电脑浏览器打开这个地址",
             "Report ready · open this address in your computer's browser")
    }
    static func copyAddress(_ lang: PromptLanguage = .current) -> String {
        t(lang, "拷贝地址", "Copy address")
    }
    static func copied(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已拷贝", "Copied")
    }
    /// The desktop-address footnote: loopback-only, self-closes, scoring writes back.
    static func desktopAddressNote(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这个地址只在那台电脑上有效(127.0.0.1),闲置约 10 分钟后自动关闭。"
            + "在报告里点评分按钮,结果会直接写回服务器的记忆文件。",
          "This address only works on that computer (127.0.0.1) and closes itself "
            + "after about 10 idle minutes. Tap a rating button in the report and "
            + "the result is written straight back to the server's memory file.")
    }

    // MARK: - Playbook detail (Group 4)

    /// The one-line note on what a playbook IS.
    static func playbookNature(_ lang: PromptLanguage = .current) -> String {
        t(lang, "纯文本方法论 — 不含可执行步骤,不能被启动或订阅。",
             "Plain-text methodology — no executable steps; it can't be started or "
            + "subscribed.")
    }
    /// The paragraph explaining what "Use in chat" does.
    static func playbookUseExplainer(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "「在对话中用」只是把正文填进新对话的输入框,由你过目后亲自发送;正文会成为对话要遵循的指令,发送前先读一遍。",
          "\"Use in chat\" only drops the body into a new conversation's composer "
            + "for you to review and send yourself; the body becomes instructions "
            + "the conversation follows, so read it once before sending.")
    }
    /// Warning header when a playbook file smuggled in workflow steps.
    static func playbookSmuggledSteps(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这个剧本文件里还夹带了 workflow 步骤",
             "This playbook file also smuggles in workflow steps")
    }
    /// Section label above the playbook's body.
    static func bodyLabel(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正文", "Body")
    }
    /// Footnote under the "Use in chat" button.
    static func playbookUseFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "打开新对话,首条消息已填好「载入剧本」前缀 + 正文,可先编辑再发送。",
          "Opens a new conversation with the first message prefilled — the "
            + "\"load playbook\" prefix plus the body — editable before you send.")
    }

    // MARK: - RichMessageText folds (Group 4)

    /// Legacy collapse hint: a folded section summary, "expand N entries".
    static func expandEntries(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "展开 \(n) 篇", "Expand \(n) entries")
    }
    /// Default summary for a <details> block with no <summary>.
    static func detailsDefaultSummary(_ lang: PromptLanguage = .current) -> String {
        t(lang, "详情", "Details")
    }

    // MARK: - The entry page (greeting, composer, publications, recent, servers)
    //
    // The redesigned home is the app's front door, so every word on it switches:
    // the greeting, the composer's placeholder, the three chips, the publication
    // strip's cues, the recent header and the servers footer. Before the
    // redesign this page was English-only chrome that ignored the toggle.

    static func greetingMorning(_ lang: PromptLanguage = .current) -> String {
        t(lang, "早上好", "Good morning")
    }
    static func greetingAfternoon(_ lang: PromptLanguage = .current) -> String {
        t(lang, "下午好", "Good afternoon")
    }
    static func greetingEvening(_ lang: PromptLanguage = .current) -> String {
        t(lang, "晚上好", "Good evening")
    }
    static func greetingLate(_ lang: PromptLanguage = .current) -> String {
        t(lang, "还没睡?", "Up late?")
    }

    /// The formatting locale for dates the entry page prints (the greeting's
    /// date line, a recent thread's relative time). These are NOT `L` strings —
    /// Foundation formats them — so without this they would follow the PHONE's
    /// locale and print "Wed, Aug 12" under a Chinese app, which is exactly the
    /// split the one-toggle rule exists to prevent.
    static func locale(_ lang: PromptLanguage = .current) -> Locale {
        lang == .chinese ? Locale(identifier: "zh_Hans_CN") : Locale(identifier: "en_US")
    }

    /// Placeholder in the home composer's hairline field.
    static func homeComposerPlaceholder(_ lang: PromptLanguage = .current) -> String {
        t(lang, "问点什么,或让 Claude 开工…", "Ask, or put Claude to work…")
    }
    /// The three capsule chips under the composer.
    /// The plus is FULLWIDTH in Chinese and ASCII in English on purpose: ＋ is a
    /// CJK-width character in its own right, so an English chip that wears it is
    /// still half-Chinese — the same boundary `listSeparator` draws for 、.
    static func homeChipNewChat(_ lang: PromptLanguage = .current) -> String {
        t(lang, "＋ 新对话", "+ New chat")
    }
    static func homeChipWorkflows(_ lang: PromptLanguage = .current) -> String {
        t(lang, "工作流", "Workflows")
    }
    static func homeChipBuild(_ lang: PromptLanguage = .current) -> String {
        t(lang, "搭建工作流", "Build")
    }

    /// The publication strip's "open this issue" cue.
    static func readCue(_ lang: PromptLanguage = .current) -> String {
        t(lang, "阅读 →", "Read →")
    }
    /// Teaser line of the loading skeleton (redacted, but it sets the shape).
    static func publicationLoadingTeaser(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正在取这份刊物的最新一期…", "Loading the latest issue of this publication…")
    }
    /// The missed-issue warning on a publication strip.
    static func missedIssue(_ lang: PromptLanguage = .current) -> String {
        t(lang, "今天这一期没印出来", "Today's issue didn't print")
    }
    static func reprint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "重印", "Reprint")
    }
    static func reprinting(_ lang: PromptLanguage = .current) -> String {
        t(lang, "印制中…", "Printing…")
    }
    /// Fallbacks handed to `pervioErrorText` when the home loads fail.
    static func homeUnreachable(_ lang: PromptLanguage = .current) -> String {
        t(lang, "连不上服务器。", "Couldn't reach the server.")
    }

    // MARK: 聊天 wf 候选条(双叉按钮)
    static func wfCtxToggle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "工作流上下文注入", "Workflows context")
    }

    // MARK: 搭建选择单(主页 chip)
    static func buildPickTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "搭建工作流", "Build a workflow")
    }
    static func buildPickScratch(_ lang: PromptLanguage = .current) -> String {
        t(lang, "从零新建", "Start from scratch")
    }
    static func buildPickExisting(_ lang: PromptLanguage = .current) -> String {
        t(lang, "改现有的", "Revise an existing one")
    }
    static func buildPickLoading(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正在读服务器上的模板…", "Reading templates on the server…")
    }
    static func buildPickError(_ lang: PromptLanguage = .current) -> String {
        t(lang, "拿不到模板清单——仍可从零新建。", "Couldn't fetch templates — you can still start from scratch.")
    }

    /// Under a page's "cannot reach the Mac" line while it tries again by itself (MacProblemRow).
    static func macRetrying(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正在自动重试,连上后这里会自己更新。", "Trying again by itself — this page updates when the Mac answers.")
    }
    /// Under a refusal (a rejected key or password, a host key that does not match): the way to fix it.
    static func macOpenSettings(_ lang: PromptLanguage = .current) -> String { t(lang, "去设置", "Open server settings") }
    static func homePaving(_ lang: PromptLanguage = .current) -> String {
        t(lang, "首次连接:正在为你的 Mac 铺设服务器组件…", "First connect: paving server components on your Mac…")
    }

    // MARK: 存储(设置页)
    static func settingsStorageSection(_ lang: PromptLanguage = .current) -> String {
        t(lang, "存储", "Storage")
    }
    static func settingsFigureCache(_ lang: PromptLanguage = .current) -> String {
        t(lang, "图片缓存", "Figure cache")
    }
    static func settingsClearFigureCache(_ lang: PromptLanguage = .current) -> String {
        t(lang, "清理图片缓存", "Clear figure cache")
    }
    static func settingsStorageFooter(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "晨报里的方法图存在本机,翻旧刊秒开。超过 500MB 或 90 天没看过的图会在启动时自动清理;清空后下次翻刊会自动重新拉取。",
          "Method figures are cached on-device so old issues open instantly. Figures over 500MB total or unviewed for 90 days are trimmed at launch; after clearing, issues re-fetch on demand.")
    }

    // MARK: 隐私政策(设置页)
    static func settingsPrivacyPolicy(_ lang: PromptLanguage = .current) -> String {
        t(lang, "隐私政策", "Privacy Policy")
    }

    // MARK: 首连体检(roadmap 3.3)
    static func doctorTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "连接体检", "Connection checkup")
    }
    static func doctorOpen(_ lang: PromptLanguage = .current) -> String {
        t(lang, "运行连接体检", "Run connection checkup")
    }
    static func doctorRunning(_ lang: PromptLanguage = .current) -> String {
        t(lang, "逐项检查中…", "Checking…")
    }
    static func doctorRerun(_ lang: PromptLanguage = .current) -> String {
        t(lang, "重新体检", "Re-run")
    }
    static func doctorClose(_ lang: PromptLanguage = .current) -> String {
        t(lang, "完成", "Done")
    }
    static func doctorSkipped(_ lang: PromptLanguage = .current) -> String {
        t(lang, "上一步没过,这步没法查。", "Skipped — the previous step failed.")
    }
    static func doctorSSHTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "SSH 连接", "SSH connection")
    }
    static func doctorSSHPass(_ lang: PromptLanguage = .current) -> String {
        t(lang, "手机能连上这台电脑。", "The phone can reach this machine.")
    }
    static func doctorSSHRefused(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "电脑拒绝了连接——多半是「远程登录」没开。到 Mac:系统设置 → 通用 → 共享 → 打开「远程登录」。",
          "Connection refused — Remote Login is probably off. On the Mac: System Settings → General → Sharing → enable Remote Login.")
    }
    static func doctorSSHTimeout(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "连接超时——手机和电脑多半不在同一个网络。连同一个 Wi-Fi,或用你自己的 VPN/Tailscale 把两台设备接通,再确认地址填的对。",
          "Timed out — the phone and the Mac are probably not on the same network. Join the same Wi-Fi (or your own VPN/Tailscale) and double-check the address.")
    }
    static func doctorSSHAuth(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "电脑认得这个地址但不认这份凭据——用户名、密码或密钥有一样不对。对照 Mac 的登录用户名重填一次。",
          "The machine answered but rejected the credentials — username, password, or key is wrong. Re-check against the Mac's login user.")
    }
    static func doctorSSHGeneric(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "没分类出常见病。先确认:地址与端口、同一网络、远程登录已开。",
          "Not a known pattern. Check: address & port, same network, Remote Login enabled.")
    }
    static func doctorExecFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "连上了,但命令执行失败。", "Connected, but running a command failed.")
    }
    static func doctorClaudeTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Claude Code 安装", "Claude Code installed")
    }
    static func doctorClaudeMissing(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "这台电脑上没找到 claude 命令。到 Mac 终端装一下:npm install -g @anthropic-ai/claude-code(或见 claude.com/claude-code)。",
          "No claude command found. Install on the Mac: npm install -g @anthropic-ai/claude-code (see claude.com/claude-code).")
    }
    static func doctorCredsTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Claude 登录", "Claude signed in")
    }
    static func doctorCredsPass(_ lang: PromptLanguage = .current) -> String {
        t(lang, "似乎已登录(找到了凭据文件)。", "Looks signed in (credentials found).")
    }
    static func doctorCredsMissing(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "似乎还没登录。到 Mac 终端跑一次 claude,按提示完成登录。",
          "Doesn't look signed in. Run claude once in the Mac terminal and finish sign-in.")
    }
    static func doctorPythonTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "python3 环境", "python3 available")
    }
    static func doctorPythonMissing(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "没找到 python3(工作流引擎需要)。装 Xcode 命令行工具即可:xcode-select --install。",
          "No python3 (the workflow engine needs it). Install Xcode command line tools: xcode-select --install.")
    }
    static func doctorScriptsTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器脚本", "Server scripts")
    }
    static func doctorScriptsWillPave(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "还没铺设——下次正常连接时 app 会自动把脚本装好,不用你动手。",
          "Not installed yet — the app paves them automatically on the next healthy connect.")
    }
    static func homeReprintFailed(_ lang: PromptLanguage = .current) -> String {
        t(lang, "重印今天这一期失败。", "Couldn't reprint today's issue.")
    }

    /// Run mode: the reply is on screen but the Mac-side process has not exited yet.
    static func runReplyLanded(_ lang: PromptLanguage = .current) -> String {
        t(lang, "回复已完成", "Reply done")
    }
    /// Over a user bubble sent while the reply was still being worked out: it
    /// went into the running turn, not a turn of its own.
    static func midTurnTag(_ lang: PromptLanguage = .current) -> String {
        t(lang, "插入本轮", "Added to this turn")
    }
    /// A message on its way into a running turn: tapped, the Mac not heard from yet.
    static func sendingTag(_ lang: PromptLanguage = .current) -> String {
        t(lang, "发送中…", "Sending…")
    }
    /// …and with the Mac, waiting for the engine to get to it.
    static func awaitingTag(_ lang: PromptLanguage = .current) -> String {
        t(lang, "已送达,等当前这步做完", "Delivered — after the current step")
    }

    // MARK: - Web preview (the Mac's dev server on the phone, 2026-11-06)
    static func webPreview(_ lang: PromptLanguage = .current) -> String { t(lang, "网页预览", "Web preview") }
    static func webPreviewListening(_ lang: PromptLanguage = .current) -> String { t(lang, "Mac 上正在监听", "Listening on the Mac") }
    static func webPreviewNone(_ lang: PromptLanguage = .current) -> String { t(lang, "没有正在监听的网页服务。先在 Mac 上把它跑起来。", "Nothing is listening. Start the server on the Mac first.") }
    static func webPreviewPortField(_ lang: PromptLanguage = .current) -> String { t(lang, "端口", "Port") }
    static func webPreviewOpen(_ lang: PromptLanguage = .current) -> String { t(lang, "打开", "Open") }
    static func webPreviewOnlyMac(_ lang: PromptLanguage = .current) -> String { t(lang, "仅本机", "Mac only") }
    static func webPreviewConnecting(_ lang: PromptLanguage = .current) -> String { t(lang, "连接中…", "Connecting…") }
    static func webPreviewTunnelOn(_ port: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "隧道已连 · \(port) ↔ Mac", "Tunnel up · \(port) ↔ Mac") }
    static func webPreviewTunnelOff(_ lang: PromptLanguage = .current) -> String { t(lang, "隧道断了 · 点此重连", "Tunnel down · tap to reconnect") }
    static func webPreviewPaused(_ lang: PromptLanguage = .current) -> String { t(lang, "退后台时已断开 · 重连中…", "Closed while in the background · reconnecting…") }
    static func webPreviewForwardRefused(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Mac 不允许端口转发(sshd 的 AllowTcpForwarding 被关了),预览开不了。", "The Mac refuses port forwarding (sshd's AllowTcpForwarding is off), so the preview cannot open.")
    }
    static func webPreviewShot(_ lang: PromptLanguage = .current) -> String { t(lang, "截图到对话", "Screenshot to chat") }
    static func webPreviewShotDone(_ lang: PromptLanguage = .current) -> String { t(lang, "截图已放进输入框", "Screenshot added to the composer") }
    static func webPreviewOpenSafari(_ lang: PromptLanguage = .current) -> String { t(lang, "在 Safari 打开", "Open in Safari") }
    static func webPreviewLoadFailed(_ lang: PromptLanguage = .current) -> String { t(lang, "页面没打开", "The page did not load") }
    static func webPreviewRetry(_ lang: PromptLanguage = .current) -> String { t(lang, "重试", "Retry") }
    static func webPreviewLoading(_ lang: PromptLanguage = .current) -> String { t(lang, "正在看 Mac 上有什么…", "Looking at the Mac…") }
    /// The pill when a background run is blocked on this phone's Allow/Deny.
    static func runWaitingApproval(_ agent: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(agent) 在等你批准", "\(agent) is waiting for your approval")
    }
    /// Under a finished reply whose process is still alive: it may speak again.
    static func runLingeringNote(_ lang: PromptLanguage = .current) -> String {
        t(lang, "后台任务还在运行,完成后会接着说", "A background task is still running; the reply continues when it finishes")
    }
    // MARK: - The living run's background tasks (2026-10-20)
    static func bgCardTitle(_ lang: PromptLanguage = .current) -> String { t(lang, "后台任务", "Background task") }
    static func bgCardRunning(_ elapsed: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "已悄悄跑了 \(elapsed)", "quietly running for \(elapsed)")
    }
    static func bgCardDone(_ took: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "完成 · 用时 \(took)", "done · took \(took)")
    }
    static func bgCardFailed(_ took: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "出错了 · 跑了 \(took)", "failed · after \(took)")
    }
    static func bgCardHint(_ lang: PromptLanguage = .current) -> String {
        t(lang, "可以接着聊——问它\"卡住了吗\",回答的是同一个进程。", "You can keep chatting — ask it whether it is stuck; the same process answers.")
    }
    static func bgCardStopped(_ took: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "已停止 · 跑了 \(took)", "stopped · after \(took)")
    }
    // MARK: - Sub-agents and background tasks: one line, and the list behind it (2026-11-22)
    /// What is going, by kind — "2 个子 agent · 1 个后台命令". A kind with none is left out.
    static func bgCount(_ n: BackgroundCount, _ lang: PromptLanguage = .current) -> String {
        var parts: [String] = []
        if n.agents > 0 { parts.append(t(lang, "\(n.agents) 个子 agent", n.agents == 1 ? "1 subagent" : "\(n.agents) subagents")) }
        if n.commands > 0 { parts.append(t(lang, "\(n.commands) 个后台命令", n.commands == 1 ? "1 background command" : "\(n.commands) background commands")) }
        if n.others > 0 { parts.append(t(lang, "\(n.others) 个其他任务", n.others == 1 ? "1 other task" : "\(n.others) other tasks")) }
        return parts.joined(separator: " · ")
    }
    /// The line above the composer while anything runs.
    static func bgBar(_ n: BackgroundCount, _ elapsed: String, _ lang: PromptLanguage = .current) -> String {
        "\(bgCount(n, lang)) · \(elapsed)"
    }
    /// The line left in the conversation once everything has ended.
    static func bgEnded(completed: Int, failed: Int, stopped: Int, _ lang: PromptLanguage = .current) -> String {
        var parts: [String] = []
        if completed > 0 { parts.append(t(lang, "\(completed) 个完成", "\(completed) done")) }
        if failed > 0 { parts.append(t(lang, "\(failed) 个出错", "\(failed) failed")) }
        if stopped > 0 { parts.append(t(lang, "\(stopped) 个已停止", "\(stopped) stopped")) }
        return t(lang, "后台已结束:", "Background ended: ") + parts.joined(separator: " · ")
    }
    static func bgOpenList(_ lang: PromptLanguage = .current) -> String { t(lang, "查看全部", "Show all") }
    static func bgSheetTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "子 agent 和后台任务", "Subagents and background tasks")
    }
    static func bgSectionRunning(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "进行中 · \(n)", "Running · \(n)") }
    static func bgSectionEnded(_ n: Int, _ lang: PromptLanguage = .current) -> String { t(lang, "已结束 · \(n)", "Ended · \(n)") }
    static func bgTokens(_ amount: String, _ lang: PromptLanguage = .current) -> String { "\(amount) tokens" }
    static func bgToolUses(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(n) 次工具", n == 1 ? "1 tool use" : "\(n) tool uses")
    }
    static func bgSheetEmpty(_ lang: PromptLanguage = .current) -> String {
        t(lang, "现在没有子 agent 或后台任务。", "No subagents or background tasks right now.")
    }
    // Stopping one of them (2026-11-22)
    static func bgStop(_ lang: PromptLanguage = .current) -> String { t(lang, "停止", "Stop") }
    static func bgStopAsk(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "停止「\(name)」?", "Stop “\(name)”?")
    }
    static func bgStopNote(_ lang: PromptLanguage = .current) -> String {
        t(lang, "只停这一个:它自己开的后台命令会一起停,对话和其他任务不受影响。",
             "Only this one: commands it started itself stop with it; the conversation and the other tasks go on.")
    }
    static func bgStopping(_ lang: PromptLanguage = .current) -> String { t(lang, "正在停止…", "stopping…") }
    static func bgStopRefused(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没能停止「\(name)」:它所在的进程已经不接收指令了。", "Couldn't stop “\(name)”: its process is no longer taking requests.")
    }
    /// A row whose task gave no description of its own.
    static func bgUnnamed(_ kind: BackgroundTask.Kind, _ lang: PromptLanguage = .current) -> String {
        switch kind {
        case .agent: return t(lang, "子 agent", "Subagent")
        case .command: return "Bash"
        case .other: return t(lang, "任务", "Task")
        }
    }
    static func bgPill(_ agent: String, _ elapsed: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(agent) 后台任务中 · \(elapsed)", "\(agent) background task · \(elapsed)")
    }
    /// Header above the recent-threads block.
    static func recentHeader(_ lang: PromptLanguage = .current) -> String {
        t(lang, "最近", "Recent")
    }
    /// Header above the home page's folders block (each folder with its newest chats).
    static func homeProjectsHeader(_ lang: PromptLanguage = .current) -> String {
        t(lang, "项目", "Projects")
    }
    /// Under an opened folder's newest chats: the way to its whole history.
    static func homeSeeAll(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        lang == .chinese ? "查看全部 \(n) 条" : "See all \(n)"
    }
    /// A folder row's caption: how many conversations it holds.
    static func homeProjectCount(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        lang == .chinese ? "\(n) 条对话" : (n == 1 ? "1 conversation" : "\(n) conversations")
    }

    /// The quiet "there's work running on the home server" line (an otter +
    /// this count) that sits between the publications strip and Recent. Restores
    /// the old entry page's at-a-glance "something is running" signal; tapping it
    /// opens the running-tasks list (RunListView — running workflows AND detached
    /// runs), the same sheet the pill raises elsewhere. `n` is always ≥ 1 (the row
    /// is hidden at zero). English keeps a singular so "1 running" doesn't read as
    /// "1 runnings".
    static func runningCount(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(n) 个在跑", n == 1 ? "1 running" : "\(n) running")
    }

    // MARK: - Servers (the home footer line + the page it pushes)

    /// The footer's trailing word AND the pushed page's title.
    static func serversTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "服务器", "Servers")
    }
    static func noServersTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang, "还没有服务器", "No servers yet")
    }
    static func noServersBody(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "填入你服务器的 SSH 信息,就能在它上面和 Claude Code 对话。",
          "Add your server's SSH details to start chatting with Claude Code on it.")
    }
    /// The first-run button into ServersListView (where the + to add one lives).
    static func addServer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "添加服务器", "Add a server")
    }
    static func edit(_ lang: PromptLanguage = .current) -> String {
        t(lang, "编辑", "Edit")
    }
    static func setAsHomeServer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "设为首页服务器", "Set as home server")
    }
    /// The marker riding the name of whichever server the entry page leads with.
    /// A WORD, not a star: every other screen in the app uses a star for rating,
    /// and "the one my home page talks to" is not a rating.
    static func homeServerBadge(_ lang: PromptLanguage = .current) -> String {
        t(lang, "主服务器", "Home")
    }
    static func editServer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "编辑服务器", "Edit server")
    }
    static func deleteServer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "删除服务器", "Delete server")
    }
    /// Irreversible, so it says exactly what goes and what does not.
    static func deleteServerTitle(_ lang: PromptLanguage = .current) -> String {
        t(lang,
          "删除这台服务器?手机上保存的 SSH 配置会被移除(服务器本身不受影响)。",
          "Delete this server? Its saved SSH config is removed from the phone "
            + "(nothing on the server itself is touched).")
    }

    // MARK: - Bringing a file or a conversation over from another computer (2026-11-22)

    /// The strip above the composer, one line per stage (TransferStage).
    static func transferPreparing(_ lang: PromptLanguage = .current) -> String {
        t(lang, "正在准备…", "Preparing…")
    }
    static func transferUploading(_ percent: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "上传 \(percent)%", "Uploading \(percent)%")
    }
    static func transferConnecting(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "正在连接 \(name)…", "Connecting to \(name)…")
    }
    /// Waiting for one reply from the other computer: no percentage to show.
    static func transferAsking(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "正在从 \(name) 读取…", "Reading from \(name)…")
    }
    /// The ✕ on the strip (its accessibility label).
    static func transferStop(_ lang: PromptLanguage = .current) -> String {
        t(lang, "停止传输", "Stop the transfer")
    }
    static func transferReading(_ name: String, _ percent: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "从 \(name) 读取 \(percent)%", "Reading from \(name) \(percent)%")
    }
    static func transferDelivering(_ name: String, _ percent: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "传到 \(name) \(percent)%", "Sending to \(name) \(percent)%")
    }

    /// The row at the top of ＋ → 服务器文件… / 背景… when more than one
    /// computer is saved: whose files / conversations the page lists.
    static func sourceLabel(_ lang: PromptLanguage = .current) -> String {
        t(lang, "来自", "From")
    }
    /// The conversation's own computer in that menu.
    static func sourceHere(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(name)(这段对话所在)", "\(name) (this conversation's)")
    }
    static func remoteFilesNote(_ target: String, _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "点一个文件,把它带到 \(target):经手机中转,单个不超过 8 MB,传完之前别离开 Pervio。那台电脑上的目录不能交给这段对话。",
          "Tap a file to bring it to \(target): it travels through the phone, 8 MB at most each, and Pervio has to stay open until it is there. "
            + "A directory on that computer cannot be handed to this conversation.")
    }
    static func remoteContextNote(_ target: String, _ lang: PromptLanguage = .current) -> String {
        t(lang,
          "选中的会带到 \(target):对话的文稿经手机中转,文稿放不下的部分作为一份完整记录一起带过去(不超过 8 MB);说明和记忆文件带的是开头 60 KB 的文字。传完之前别离开 Pervio。带过去的是此刻的副本。",
          "What you pick is brought to \(target): a conversation's transcript travels through the phone, and what the transcript cannot hold comes along as one full record "
            + "(8 MB at most); notes and memory files bring their first 60 KB of text. Pervio has to stay open until it is there. What arrives is a copy as of now.")
    }
    /// Beside a file too large to bring.
    static func remoteFileOverCap(_ lang: PromptLanguage = .current) -> String {
        t(lang, "超过 8 MB", "over 8 MB")
    }

    static func bubbleNotConnectedTransfer(_ lang: PromptLanguage = .current) -> String {
        t(lang, "Not connected — 这台电脑没连上,收不了另一台带过来的内容。",
             "Not connected — this computer can't take what the other one is sending.")
    }
    static func remoteConnectFailed(_ name: String, _ why: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "连不上 \(name):\(why)", "Couldn't connect to \(name): \(why)")
    }
    static func remoteConnectGeneric(_ lang: PromptLanguage = .current) -> String {
        t(lang, "请确认它开着、手机够得着它。", "check that it is on and the phone can reach it.")
    }
    static func remoteFileMissing(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(name) 在那台电脑上找不到了。", "\(name) is no longer on that computer.")
    }
    /// A folder, a socket, a device: there, but not something to copy.
    static func remoteNotAFile(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(name) 不是普通文件,带不过来。", "\(name) is not a regular file — it cannot be brought over.")
    }
    /// Cut short by the app leaving the foreground, a Stop on the turn, the page being left.
    static func remoteInterrupted(_ source: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "从 \(source) 带过来的传输被打断了,没有完成;需要的话再选一次。",
             "The transfer from \(source) was interrupted before it finished — pick it again if you still need it.")
    }
    static func remoteFileUnreadable(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "那台电脑不让读 \(name)(没有权限)。", "That computer would not let \(name) be read (no permission).")
    }
    static func remoteFileEmpty(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(name) 是空文件,没有带过来。", "\(name) is empty — nothing was brought over.")
    }
    /// The file's size is written the way its row in the browser writes it
    /// (ByteCountFormatter, file style), so the refusal and the list agree.
    /// Anything over the limit reads as at least 8.4 MB there, never "8 MB".
    static func remoteFileTooBig(_ name: String, bytes: Int, cap: Int, _ lang: PromptLanguage = .current) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let capMB = cap / 1_048_576
        return t(lang, "\(name) 有 \(size),超过 \(capMB) MB 的上限,没有带过来。",
                 "\(name) is \(size), over the \(capMB) MB limit — not brought over.")
    }
    /// Follow-ups an older build left waiting, shown instead of sent (several computers saved).
    static func queueNotResent(_ n: Int, _ lang: PromptLanguage = .current) -> String {
        t(lang, "这段对话有 \(n) 条在旧版本里排队、还没发出的消息。手机里存着不止一台电脑,无法确认它们当时是发给哪一台的,所以没有自动发送。原文在下面,需要的话请重新发:",
             "\(n) message(s) were waiting to be sent in this conversation under an older version. More than one computer is saved on this phone and there is no telling which one they were meant for, so they were not sent. Here they are, to send again if you wish:")
    }
    // A picked name that is a link to a file outside its folder (asked before reading).
    static func remoteLinkTitle(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "「\(name)」是一个链接", "\"\(name)\" is a link")
    }
    static func remoteLinkBody(_ real: String, _ computer: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "它指向这个文件夹之外的另一个文件:\n\(real)\n\n要从 \(computer) 把那个文件带过来吗?",
             "It points to another file, outside this folder:\n\(real)\n\nBring that file over from \(computer)?")
    }
    static func remoteLinkBring(_ lang: PromptLanguage = .current) -> String { t(lang, "带过来", "Bring it") }
    static func remoteLinkSkip(_ lang: PromptLanguage = .current) -> String { t(lang, "不带", "Skip") }
    static func remoteLinkSkipped(_ name: String, _ real: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没有带上「\(name)」:它是一个链接,指向 \(real)。",
             "\"\(name)\" was not brought over: it is a link to \(real).")
    }
    static func remoteFileChanged(_ name: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "\(name) 在读取过程中变了,没有带过来;请再试一次。",
             "\(name) changed while it was being read — not brought over; please try again.")
    }
    static func remoteContextChanged(_ lang: PromptLanguage = .current) -> String {
        t(lang, "这段对话在读取过程中变了,没有带过来;请再试一次。",
             "The conversation changed while it was being read — not brought over; please try again.")
    }
    static func remoteFileFailed(_ name: String, _ source: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没能把 \(name) 从 \(source) 带过来,请重试。",
             "Couldn't bring \(name) over from \(source) — please try again.")
    }
    static func remoteContextFailed(_ source: String, _ lang: PromptLanguage = .current) -> String {
        t(lang, "没能把背景对话从 \(source) 带过来,请重试。",
             "Couldn't bring the conversation over from \(source) — please try again.")
    }
}
