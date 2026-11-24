#if DEBUG
import Foundation

// [asks] `-HQDemoAskCard`: a chat that ends with a bot's ask-to-act card (a made-up Slack DM from Dana Reyes, with
// her words, a file and a link). `-HQDemoAskState waiting|answered|other|sent` adds your answer after it (waiting by
// default): Yes, then the bot's draft card; your own words, then the bot's line; or (v2) Yes with its ready reply
// approved, then the bot's line. [asks v2] Yes carries a ready reply to Dana (No has none); `-HQDemoAskPick 1` picks
// it (ChatDemo.swift). Made-up names and example.com links only.

extension FakeChatSession {
    static var askArgs: [String: JSONValue] {
        // `-HQDemoAskQuestion <words>`: a longer question (the owner's 2026-11-23 strip wrapped to three lines)
        ["question": .string(ChatDemo.argument("-HQDemoAskQuestion") ?? "Start with the pilot group?"),
         "then": .string("Nothing goes to Dana until you tap Send."),
         "app": .string("Slack"), "from": .string("Dana Reyes"), "where": .string("DM"), "when": .string("11:03 AM"),
         "quote": .string("We're ready to go live for the first wave. Do you think we should just start with the pilot group?"),
         "attachments": .array([.object(["name": .string("Q3_Plan"), "note": .string("This is what I have so far.")])]),
         "link": .object(["title": .string("Open Dana's DM"), "url": .string("https://example.com/slack/dm/dana")]),
         "replies": .array([.string("Yes — let's start with the pilot group. Once they're through it we'll open it to everyone."), .string("")]),
         "reply_to": .object(["app": .string("Slack"), "to": .string("Dana Reyes")])]
    }

    static var askMessages: [ChatMessage] {
        let t = Date().addingTimeInterval(-600)
        func call(_ id: String, _ name: String, _ args: [String: JSONValue], title: String) -> ChatPart {
            .tool(ToolCall(id: id, name: name, title: title, argsText: ChatJSON.stringify(.object(args)), summary: nil, state: .done,
                           durationSeconds: 0.1))
        }
        var out = [
            ChatMessage(id: "ask-u1", role: .user, parts: [.text("Check my Slack and handle anything that needs me.")],
                        timestamp: t, rowId: 9301),
            ChatMessage(id: "ask-a1", role: .assistant, parts: [
                .text("One DM needs your call before I answer it."),
                call("ask-c1", AskCards.tool, askArgs, title: "Ask to act"),
            ], timestamp: t.addingTimeInterval(30), rowId: 9302),
        ]
        guard let ask = AskCards.parse(askArgs) else { return out }
        switch ChatDemo.argument("-HQDemoAskState") ?? "waiting" {
        case "answered":
            if let text = AskCards.choiceMessage(ask, index: 0) {
                out.append(ChatMessage(id: "ask-u2", role: .user, parts: [.text(text)], timestamp: t.addingTimeInterval(60), rowId: 9303))
            }
            out.append(ChatMessage(id: "ask-a2", role: .assistant, parts: [
                call("ask-c2", DraftCards.tool, ["app": .string("Slack"), "to": .string("Dana Reyes"),
                                                 "body": .string("Yes, let's start with the pilot group. Once they're through it, we'll open it up to everyone else.")],
                     title: "Draft message"),
                .text("Here's the reply. Send it when it reads right."),
            ], timestamp: t.addingTimeInterval(80), rowId: 9304))
        case "other":
            out.append(ChatMessage(id: "ask-u2", role: .user, parts: [.text(AskCards.otherMessage(ask, text: "Only the two team leads first, then the pilot group next week."))],
                                   timestamp: t.addingTimeInterval(60), rowId: 9303))
            out.append(ChatMessage(id: "ask-a2", role: .assistant, parts: [.text("Got it. I'll draft that for Dana.")],
                                   timestamp: t.addingTimeInterval(80), rowId: 9304))
        case "sent":   // [asks v2] Yes, with its ready reply approved
            if let reply = AskCards.reply(ask, index: 0), let text = AskCards.sendMessage(ask, index: 0, reply: reply) {
                out.append(ChatMessage(id: "ask-u2", role: .user, parts: [.text(text)], timestamp: t.addingTimeInterval(60), rowId: 9303))
            }
            out.append(ChatMessage(id: "ask-a2", role: .assistant, parts: [.text("Sent it to Dana on Slack.")],
                                   timestamp: t.addingTimeInterval(80), rowId: 9304))
        default:
            break
        }
        return out
    }
}
#endif
