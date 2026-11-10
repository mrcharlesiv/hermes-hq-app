// [moods] What a bot is up to right now, as its face acts it out (owner, 2026-10-28: "MUCH better animations for the
// bot faces to showcase what they are doing"). Worked out from the gateway's turn events by `BotMoods` (App/Heads) and
// drawn by `HeadView`; the tool rules here are pure, so they are tested on their own.

import Foundation

nonisolated enum BotMood: String, CaseIterable, Hashable, Sendable {
    /// Between steps, or before the first: chin up, eyes up and to the side, turning it over; a light running round the
    /// outline.
    case thinking
    /// A file, a page, an image: head down, narrowed eyes reading along line by line; a line of light down the face.
    case reading
    /// The web, files, past chats: looking this way and that, eyes first, leaning in to peer; a radar sweep.
    case searching
    /// A command or code: bobbing away at the work, a look at what came out; code raining down the LEDs.
    case running
    /// A file, a patch, memory, a schedule: eyes and head following each line as it's typed, LED by LED.
    case writing
    /// Its browser or its screen: a pointer the eyes and head follow, a peck and a ripple where it clicks.
    case browsing
    /// Another bot, an email, a hand-off: turned to the side, winding up and sending; waves going out.
    case messaging
    /// An image, a video, a voice: eyes up at it, wiggling, bouncing, admiring it; sparkles.
    case making
    /// Its answer is coming in: it nods and sways along as it talks, glowing softly with each nod.
    case replying
    /// It waits for your answer or approval: head on one side, looking at you, little hops; a flash as it lands.
    case asking
    /// The turn just finished (once): a jump, eyes up (a cartwheel now and then), two blinks at you and a burst of light.
    case done
    /// The turn failed (once): eyes screwed shut, a shake of the head, then a droop, eyes down; a glitch.
    case failed

    /// Shown once and then gone (the others last while the bot is at it).
    var once: Bool { self == .done || self == .failed }

    /// How long a once-only mood plays.
    var length: TimeInterval { self == .failed ? 1.9 : self == .done ? 2.4 : 0 }

    /// A step's mood stays at least this long, so a step that ends at once still shows (owner, 2026-10-27: on the phone
    /// 60% of steps ended in under a second).
    static let dwell: TimeInterval = 2.2

    /// The step a tool is (nil: a tool that says nothing, as the chat hides it).
    init?(tool raw: String?) {
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if name.hasPrefix("functions.") { name.removeFirst("functions.".count) }
        if let known = Self.tools[name] {
            self = known
            return
        }
        if ScreenTools.isBrowserTool(name) || ScreenTools.isScreenTool(name) { self = .browsing; return }
        self = Self.guess(name.lowercased())
    }

    private static let tools: [String: BotMood] = [
        "terminal": .running, "execute_code": .running, "process_manage": .running, "close_terminal": .running,
        "read_terminal": .reading, "read_file": .reading, "web_extract": .reading, "skill_view": .reading,
        "vision_analyze": .reading, "video_analyze": .reading,
        "web_search": .searching, "search_files": .searching, "session_search": .searching, "x_search": .searching,
        "skills_list": .searching,
        "write_file": .writing, "patch": .writing, "memory": .writing, "todo": .writing, "todo_list": .writing,
        "cronjob_manage": .writing, "skill_manage": .writing,
        "message_agent": .messaging, "send_message": .messaging, "delegate_task": .messaging,
        "image_generate": .making, "video_generate": .making, "text_to_speech": .making,
        "clarify": .asking,
    ]

    /// A connector's tool by its words ("GMAIL_SEND_EMAIL", "notion_search_pages"): what it does, else running.
    private static func guess(_ name: String) -> BotMood {
        let words = Set(name.split(whereSeparator: { !$0.isLetter }).map(String.init))
        func any(_ list: [String]) -> Bool { list.contains { words.contains($0) } }
        if any(["search", "find", "query", "lookup", "list"]) { return .searching }
        if any(["send", "reply", "post", "message", "email", "mail", "notify", "invite", "share", "forward", "comment"]) { return .messaging }
        if any(["image", "video", "audio", "speech", "generate", "render", "draw"]) { return .making }
        if any(["create", "update", "write", "edit", "add", "insert", "patch", "upload", "delete", "remove", "set", "save", "move"]) {
            return .writing
        }
        if any(["get", "read", "fetch", "view", "open", "download", "retrieve", "describe", "show"]) { return .reading }
        if any(["browse", "navigate", "click", "scroll", "screenshot", "screen"]) { return .browsing }
        return .running
    }
}
