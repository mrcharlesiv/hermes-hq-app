#if DEBUG
import Foundation

// [asks] `-HQDemoAskCard`: ask-to-act demo transcripts.
// - `-HQDemoAskMode default|bare|rich|binary|stream|draft` picks the showcase scenario:
//   - `default`: Slack DM from Dana Reyes (compatible with `-HQDemoAskState waiting|answered|other|sent` and `-HQDemoAskPick 1`)
//   - `bare`: Bare 3-choice planning decision (no header chrome, Recommended pill + rationale)
//   - `rich`: Rich Gmail ask with real Gmail logo, clamped long quote, borderless attachment chip, and v2 inline replies
//   - `binary`: Compact Slack Yes/No ask with real Slack logo
//   - `stream`: Multi-ask timeline with collapsed stale fold, Linear receipt, live Messages ask, and sibling Slack Draft card
//   - `draft`: Answered ask receipt paired with Slack & Gmail Draft cards on the elevated decision surface
// Made-up stand-in names and example.com links only.

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

        switch ChatDemo.argument("-HQDemoAskMode") ?? "default" {
        case "bare":
            let bareArgs: [String: JSONValue] = [
                "question": .string("For Jordan's Austin trainer search, review the internal applicant first or look at the external lead at the same time?"),
                "then": .string("I'll pass your direction to Hiring for the evidence packet. Nothing goes to Jordan without your approval."),
                "choices": .array([
                    .string("Review the internal applicant first"),
                    .string("Review both candidates in parallel"),
                    .string("Hold off until Friday's sync"),
                ]),
                "recommended": .number(0),
                "why": .string("Faster path — internal notes and references are already ready to review."),
            ]
            return [
                ChatMessage(id: "ask-b-u1", role: .user, parts: [.text("Catch me up on the Austin search and tell me what needs my call.")],
                            timestamp: t.addingTimeInterval(-120), rowId: 9311),
                ChatMessage(id: "ask-b-a1", role: .assistant, parts: [
                    .text("I pulled the notes from both candidates. One quick call before I hand the packet to Hiring:"),
                    call("ask-b-c1", AskCards.tool, bareArgs, title: "Ask to act"),
                ], timestamp: t, rowId: 9312),
            ]

        case "rich":
            let richArgs: [String: JSONValue] = [
                "app": .string("Gmail"),
                "from": .string("Elena Vance"),
                "where": .string("Inbox"),
                "when": .string("10:42 AM"),
                "quote": .string("Finance updated the Q4 pacing numbers this morning before Thursday's board lock. Should I swap in the revised table or send the delta as an appendix?"),
                "attachments": .array([
                    .object(["name": .string("Q4_Board_Deck.pdf"), "note": .string("14 slides")]),
                ]),
                "link": .object(["title": .string("Open thread in Gmail"), "url": .string("https://mail.google.com/mail/u/0/#inbox/demo")]),
                "question": .string("Swap in the revised Q4 numbers or send them as an appendix?"),
                "then": .string("Pick an option to review the exact reply before anything goes out."),
                "choices": .array([
                    .string("Swap in the revised table now"),
                    .string("Keep summary locked, add appendix"),
                    .string("Wait — I'll review the deck first"),
                ]),
                "recommended": .number(0),
                "replies": .array([
                    .string("Hi Elena — let's swap the revised Q4 table directly into slide 8 so the board sees one clean set of numbers. Thanks for catching that before lock."),
                    .string("Hi Elena — let's keep the main deck locked as-is and attach the updated Q4 pacing table as a one-page appendix."),
                    .string(""),
                ]),
                "reply_to": .object([
                    "app": .string("Gmail"),
                    "to": .string("Elena Vance"),
                    "subject": .string("Re: Thursday board deck lock"),
                    "from": .string("alex@example.com"),
                ]),
            ]
            return [
                ChatMessage(id: "ask-r-u1", role: .user, parts: [.text("Check my inbox for anything time-sensitive before noon.")],
                            timestamp: t.addingTimeInterval(-120), rowId: 9321),
                ChatMessage(id: "ask-r-a1", role: .assistant, parts: [
                    call("ask-r-c1", AskCards.tool, richArgs, title: "Ask to act"),
                ], timestamp: t, rowId: 9322),
            ]

        case "binary":
            let slackArgs: [String: JSONValue] = [
                "app": .string("Slack"),
                "from": .string("Dana Reyes"),
                "where": .string("#launch"),
                "when": .string("11:03 AM"),
                "quote": .string("We're ready to flip the feature flag for the pilot workspace. Good to go live before lunch?"),
                "link": .object(["title": .string("Open in Slack"), "url": .string("https://example.com/slack/launch")]),
                "question": .string("Enable the flag for the pilot workspace now?"),
                "then": .string("I'll reply to Dana in #launch once you choose."),
                "choices": .array([.string("Yes"), .string("No")]),
                "recommended": .number(0),
            ]
            return [
                ChatMessage(id: "ask-s-u1", role: .user, parts: [.text("Any launch blockers in Slack?")],
                            timestamp: t.addingTimeInterval(-90), rowId: 9331),
                ChatMessage(id: "ask-s-a1", role: .assistant, parts: [
                    call("ask-s-c1", AskCards.tool, slackArgs, title: "Ask to act"),
                ], timestamp: t, rowId: 9332),
            ]

        case "stream":
            let staleArgs: [String: JSONValue] = [
                "app": .string("Google Calendar"),
                "from": .string("Alex Rivera"),
                "when": .string("Yesterday"),
                "question": .string("Move the Thursday design review to 3:00 PM?"),
                "choices": .array([.string("Move to 3:00 PM"), .string("Keep at 1:30 PM")]),
            ]
            let linearArgs: [String: JSONValue] = [
                "app": .string("Linear"),
                "from": .string("ENG-412"),
                "where": .string("Mobile"),
                "when": .string("9:15 AM"),
                "question": .string("Move the push-token retry ticket into Sprint 14?"),
                "choices": .array([.string("Move to Sprint 14"), .string("Keep in backlog")]),
            ]
            let linearAsk = AskCards.parse(linearArgs)!
            let linearAnswer = AskCards.choiceMessage(linearAsk, index: 0)!

            let messagesArgs: [String: JSONValue] = [
                "app": .string("Messages"),
                "from": .string("Marcus Chen"),
                "where": .string("Text"),
                "when": .string("2:18 PM"),
                "quote": .string("Landed early at SFO — want to grab coffee at 4 or still meet at 5:30?"),
                "question": .string("Meet Marcus at 4:00 PM or keep 5:30 PM?"),
                "then": .string("I'll draft the text back once you pick a time."),
                "choices": .array([.string("Meet at 4:00 PM"), .string("Keep 5:30 PM")]),
            ]
            let draftArgs: [String: JSONValue] = [
                "app": .string("Slack"),
                "to": .string("#mobile-release"),
                "body": .string("Heads up: ENG-412 is now pulled into Sprint 14 so the push-token retry ships with this week's TestFlight cut."),
            ]
            return [
                ChatMessage(id: "ask-st-a0", role: .assistant, parts: [
                    call("ask-st-c0", AskCards.tool, staleArgs, title: "Ask to act"),
                ], timestamp: t.addingTimeInterval(-3600), rowId: 9340),
                ChatMessage(id: "ask-st-u0", role: .user, parts: [.text("Skip calendar for now — check Linear and my texts.")],
                            timestamp: t.addingTimeInterval(-1800), rowId: 9341),
                ChatMessage(id: "ask-st-a1", role: .assistant, parts: [
                    call("ask-st-c1", AskCards.tool, linearArgs, title: "Ask to act"),
                ], timestamp: t.addingTimeInterval(-900), rowId: 9342),
                ChatMessage(id: "ask-st-u1", role: .user, parts: [.text(linearAnswer)],
                            timestamp: t.addingTimeInterval(-840), rowId: 9343),
                ChatMessage(id: "ask-st-a2", role: .assistant, parts: [
                    call("ask-st-d1", DraftCards.tool, draftArgs, title: "Draft message"),
                    call("ask-st-c2", AskCards.tool, messagesArgs, title: "Ask to act"),
                ], timestamp: t, rowId: 9344),
            ]

        default:
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
}
#endif
