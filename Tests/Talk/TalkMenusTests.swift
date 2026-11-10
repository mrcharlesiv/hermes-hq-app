// The ways into voice that are menus (docs/spec/3x-talk.md §5.2, §5.4, §5.5, §5.6): the voice options menu, the +
// menu's two items, the bot row's tiles and the empty chat's lines.

import Testing
import UIKit
@testable import HermesHQNative

@Suite("Talk menus")
@MainActor
struct TalkMenusTests {
    private func flat(_ nodes: [BotMenuNode]) -> [BotMenuNode] {
        nodes.flatMap { node -> [BotMenuNode] in
            switch node.kind {
            case .inline(let children), .tiles(let children), .submenu(let children), .palette(let children): flat(children)
            default: [node]
            }
        }
    }

    @Test func theVoiceOptionsInTheWebsOrder() {
        var picked: [TalkMenus.Option] = []
        let nodes = TalkMenus.optionNodes(readsAloud: false, dictation: .on) { picked.append($0) }
        #expect(TalkMenus.optionsTitle(name: "Ivy") == "Voice with Ivy")
        // Three groups: start alone, the two switches, the two help items.
        #expect(nodes.count == 3)
        let items = flat(nodes)
        #expect(items.map(\.title) == ["Start Voice Conversation", "Read Replies Aloud", "Dictate with Hermes", "How Voice Works", "Voice Settings…"])
        #expect(items.map(\.image) == ["waveform", "speaker.wave.2", "mic", "info.circle", "gearshape"])
        #expect(items.map(\.identifier) == ["voice.options.start", "voice.options.read-replies", "voice.options.dictate", "voice.options.how",
                                            "voice.options.settings"])
        #expect(items.allSatisfy { !$0.disabled })
        // Read Replies Aloud keeps the menu open; nothing else does.
        #expect(items.map(\.keepsOpen) == [false, true, false, false, false])
        #expect(!items[1].checked)
        for item in items { if case .action(let run) = item.kind { run() } }
        #expect(picked == [.start, .readReplies, .dictate, .how, .settings])
    }

    @Test func readRepliesAloudShowsItsCheckmark() {
        let on = flat(TalkMenus.optionNodes(readsAloud: true, dictation: .on) { _ in })
        #expect(on[1].checked)
        // VoiceOver's list has no checkmarks: the row says what a tap will do.
        let list = flat(TalkMenus.optionNodes(readsAloud: true, dictation: .on, asList: true) { _ in })
        #expect(list[1].title == "Turn Off Read Replies Aloud")
        #expect(!list[1].keepsOpen)
        let off = flat(TalkMenus.optionNodes(readsAloud: false, dictation: .on, asList: true) { _ in })
        #expect(off[1].title == "Turn On Read Replies Aloud")
    }

    @Test func dictationIsOffWithItsReasonWhenSpeechToTextIsOff() {
        let items = flat(TalkMenus.optionNodes(readsAloud: false, dictation: .speechToTextOff) { _ in })
        let dictate = items.first { $0.identifier == "voice.options.dictate" }
        #expect(dictate?.disabled == true)
        #expect(dictate?.subtitle == "Speech to Text is off")
        // The UIKit menu carries the subtitle and the disabled state.
        let menu = BotMenuNode.uiMenu(TalkMenus.optionNodes(readsAloud: true, dictation: .speechToTextOff) { _ in }, title: "Voice with Ivy").menu
        #expect(menu.title == "Voice with Ivy")
        let actions = menu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { $0 as? UIAction }
        let action = actions.first { $0.accessibilityIdentifier == "voice.options.dictate" }
        #expect(action?.subtitle == "Speech to Text is off")
        #expect(action?.attributes.contains(.disabled) == true)
        let read = actions.first { $0.accessibilityIdentifier == "voice.options.read-replies" }
        #expect(read?.state == .on)
        #expect(read?.attributes.contains(.keepsMenuPresented) == true)
    }

    @Test func dictationIsLeftOutWhereItCannotStart() {
        let items = flat(TalkMenus.optionNodes(readsAloud: false, dictation: .hidden) { _ in })
        #expect(items.map(\.title) == ["Start Voice Conversation", "Read Replies Aloud", "How Voice Works", "Voice Settings…"])
    }

    @Test func thePlusMenuLeavesOutWhatCannotWork() {
        var memos = 0, talks = 0
        let both = TalkMenus.plusItems(micAvailable: true, talkAllowed: true, name: "Ivy", memo: { memos += 1 }, talk: { talks += 1 })
        let memo = both.memo.first as? UIAction, talk = both.talk.first as? UIAction
        #expect(memo?.title == "Voice Memo")
        #expect(memo?.accessibilityIdentifier == "composer.plus.memo")
        #expect(talk?.title == "Talk with Ivy")
        #expect(talk?.accessibilityIdentifier == "composer.plus.talk")
        let none = TalkMenus.plusItems(micAvailable: false, talkAllowed: false, name: "Ivy", memo: {}, talk: {})
        #expect(none.memo.isEmpty)
        #expect(none.talk.isEmpty)
        let room = TalkMenus.plusItems(micAvailable: true, talkAllowed: false, name: "Ivy", memo: {}, talk: {})
        #expect(room.memo.count == 1)
        #expect(room.talk.isEmpty)
        // The + menu orders them after the pickers and before Paste Image.
        #expect(ComposerPlusMenu.Slot.pickers < .memo && ComposerPlusMenu.Slot.memo < .talk && ComposerPlusMenu.Slot.talk < .paste)
    }

    @Test func theEmptyChatShowsTheRoleOnlyWhenItSaysMoreThanTheName() {
        typealias Intro = ChatPlaceholderView.Intro
        #expect(Intro.lines(name: "Ivy", role: "Research", about: "Finds papers and sums them up.") == ("Research", "Finds papers and sums them up."))
        #expect(Intro.lines(name: "Ivy", role: "ivy ", about: nil).role == nil)
        #expect(Intro.lines(name: "Ivy", role: "  ", about: "  ").about == nil)
        // A description that only repeats the role is not shown twice.
        #expect(Intro.lines(name: "Ivy", role: "Research", about: "Research").about == nil)
        #expect(Intro.lines(name: "Ivy", role: nil, about: "Helps with email.") == (nil, "Helps with email."))
    }

    @Test func theSubtitleOfAnUnreachableBot() {
        #expect(TalkWiring.unreachable == "Can’t reach this bot")
        var node = BotMenuNode.action("Talk", "waveform", disabled: true) {}
        node.subtitle = TalkWiring.unreachable
        let action = UIMenuBuilderResult.elements([node]).first as? UIAction
        #expect(action?.subtitle == "Can’t reach this bot")
        #expect(action?.attributes.contains(.disabled) == true)
    }

    /// Mac stress #42: the intro no longer says the conversation stops when the app goes away (it carries on since
    /// 3x-talk-background.md), and the info form's pause row no longer counts leaving the app.
    @Test func theIntroSaysTalkGoesOnInTheBackground() {
        let intro = TalkIntroSheet.rows(.intro, name: "Ivy", app: "Hermes HQ", sendOnRelease: true)
        #expect(intro.count == 4)
        #expect(intro[3] == .init(symbol: "iphone", title: "Keeps going in the background",
                                  body: "Lock your iPhone or switch apps and the conversation carries on. Quitting Hermes HQ ends it."))
        let info = TalkIntroSheet.rows(.info, name: "Ivy", app: "Hermes HQ", sendOnRelease: true)
        #expect(info.last?.body.hasPrefix("A call, Siri or 2 minutes of silence pauses the conversation.") == true)
        #expect(!(intro + info).contains { $0.body.contains("stops if") || $0.body.contains("leaving") })
    }

    /// Mac stress #41: on a phone without a camera, Camera stays in the row, greyed with "Unavailable" (the Mac leaves
    /// it out instead).
    @Test func theCameraWithoutACameraOnAPhone() {
        let row = ComposerPlusMenu.pickers(count: 0, camera: {}, photos: {}, files: {}, hasCamera: false)
        let camera = row.children.first as? UIAction
        #expect(row.children.count == 3)
        #expect(camera?.title == "Camera" && camera?.subtitle == "Unavailable" && camera?.attributes.contains(.disabled) == true)
        #expect(ComposerPlusMenu.pickers(count: 0, camera: {}, photos: {}, files: {}, hasCamera: true).children.first?.title == "Camera")
    }
}

private func == (a: (role: String?, about: String?), b: (String?, String?)) -> Bool { a.role == b.0 && a.about == b.1 }
