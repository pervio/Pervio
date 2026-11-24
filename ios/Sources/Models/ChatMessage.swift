import Foundation

/// One bubble in the chat transcript.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, system }

    /// One ordered piece of an assistant turn. Keeping these in execution order
    /// (thinking → text → tool → text → tool …) is what makes the transcript read
    /// naturally, instead of "all tools clumped, then all text".
    enum Segment: Equatable {
        case thinking(String)
        case text(String)
        case tool(ToolCall)      // a tool call (chip label + tap-for-diff detail)
    }

    // `var` (not `let`) so loadHistory can carry an unchanged row's id across a
    // reload — that stable identity is what stops SwiftUI rebuilding the whole
    // transcript on every reconnect. New messages still get a fresh UUID by default.
    var id = UUID()
    var role: Role
    var text: String
    /// The model's streamed reasoning (extended thinking), shown collapsed.
    var thinking: String = ""
    /// Tool-call rows attached to an assistant turn (rendered as compact chips).
    var tools: [String] = []
    /// Ordered content of an assistant turn. When non-empty the view renders these
    /// in order; `text`/`tools`/`thinking` remain for copy and as a fallback.
    var segments: [Segment] = []
    /// True while the assistant turn is still streaming.
    var isStreaming: Bool = false
    var isError: Bool = false
    var costUSD: Double? = nil
    /// A user turn that came through a group rather than from the person:
    /// "human" (the shared message), "synth", "relay" — rendered as a small
    /// badge over the bubble. nil for the user's own words.
    var via: String? = nil
    /// The server-side session-file line uuid of a USER message — the anchor
    /// `pervio-sessions fork --before` rewinds at. Neither the live stream (its
    /// `user` events are tool results, never an echo of the typed prompt) nor the
    /// transcript reload JSON carries it, so ChatStore back-fills it after each
    /// turn / history load (refreshUserUuids). nil = unknown → the 「从这里重新说」
    /// menu item stays hidden for this bubble.
    var serverUuid: String? = nil
    /// What was actually SENT for a live user turn when it differs from the
    /// displayed text (attachment turns show 📎 chips; the wire carries the file
    /// paths). Only used to verify uuid alignment against the server's file.
    var wireText: String? = nil
    /// What a user turn carried besides its words — files, images, a 背景
    /// conversation, a handed-over directory — as chip labels. Shown as chips;
    /// the agent gets the wire text, the person never sees that injection
    /// (2026-10-15: "不要做成显示 injection").
    var chips: [String] = []
    /// A user turn sent while the reply was still being worked out (插话,
    /// 2026-10-21): fed into the running turn, which the engine absorbs at its
    /// next step — tagged so it never reads as a turn of its own.
    var interjected: Bool = false
    /// Where a message sent into a running turn stands before the engine has
    /// made it part of the conversation (2026-11-21). It is on screen from the
    /// tap: `sending` until the Mac says it has it, `awaiting` until the engine
    /// takes it — which codex 0.160 does only once the running command or the
    /// answer being written is done, and until then the message is in nobody's
    /// record. nil once it is taken (then `interjected`), and for every
    /// ordinary message.
    enum Delivery: Equatable { case sending, awaiting }
    var delivery: Delivery? = nil

    /// serverUuid/wireText are render-invisible bookkeeping: excluding them
    /// keeps the uuid back-fill (after every turn's result) from reading as a
    /// "messages changed" event — ChatView's onChange(of: messages) animates a
    /// scroll-to-bottom on any array change, and a phantom one yanks the user
    /// down right after they scrolled up to reread.
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.text == rhs.text
            && lhs.thinking == rhs.thinking && lhs.tools == rhs.tools
            && lhs.segments == rhs.segments && lhs.isStreaming == rhs.isStreaming
            && lhs.isError == rhs.isError && lhs.costUSD == rhs.costUSD
            && lhs.via == rhs.via && lhs.chips == rhs.chips && lhs.interjected == rhs.interjected
            && lhs.delivery == rhs.delivery
    }

    /// Append streamed text, extending the current trailing text segment so a run
    /// of deltas coalesces into one prose block (until a tool interrupts it).
    mutating func appendText(_ t: String) {
        if case .text(let s)? = segments.last { segments[segments.count - 1] = .text(s + t) }
        else { segments.append(.text(t)) }
    }

    mutating func appendThinking(_ t: String) {
        if case .thinking(let s)? = segments.last { segments[segments.count - 1] = .thinking(s + t) }
        else { segments.append(.thinking(t)) }
    }

    static func user(_ t: String) -> ChatMessage { .init(role: .user, text: t) }
    static func system(_ t: String) -> ChatMessage { .init(role: .system, text: t) }
}
