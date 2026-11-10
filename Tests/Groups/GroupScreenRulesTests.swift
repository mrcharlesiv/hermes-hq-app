import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Rules the screens read (docs/spec/3x-groups.md §7.1, §7.5–§7.12): a sender name's colour, deliveries from another
/// bot, where rooms go in the Bots list, the Show filter, the pickers' limits and the room photo's size.
@Suite struct GroupScreenRulesTests {
    // MARK: Name colours (name-color.ts)

    @Test func theWebExamplesReadAtFourPointFiveToOne() throws {
        let light = NameColor.webLightBubble, dark = NameColor.webDarkBubble
        // Yellow and cyan are too pale for the light bubble: darkened until they read.
        for hex in ["#FFD60A", "#64D2FF"] {
            let raw = try #require(NameColor.parse(hex))
            #expect(NameColor.contrast(raw, light) < 4.5)
            let made = try #require(NameColor.readable(hex, light: light, dark: dark))
            #expect(NameColor.contrast(made.light, light) >= 4.5, "\(hex) on the light bubble")
            #expect(NameColor.contrast(made.dark, dark) >= 4.5, "\(hex) on the dark bubble")
            #expect(made.light != raw && made.dark == raw, "\(hex): darker in light, itself in dark")
        }
        // Deep violet already reads on the web's light bubble: unchanged there, lightened in dark.
        let violet = try #require(NameColor.readable("#5E5CE6", light: light, dark: dark))
        #expect(violet.light == NameColor.RGB(94, 92, 230))
        #expect(violet.dark != NameColor.RGB(94, 92, 230) && NameColor.contrast(violet.dark, dark) >= 4.5)
    }

    @Test func everyHeadColourReadsOnBothOfThisAppsBubbles() throws {
        #expect(HeadTones.tones.count == 24)
        for (name, tone) in HeadTones.tones {
            let hex = HeadRGB(tone.accent).description
            let made = try #require(NameColor.readable(hex), "\(name) \(hex)")
            #expect(NameColor.contrast(made.light, NameColor.lightBubble) >= 4.5, "\(name) on the light bubble")
            #expect(NameColor.contrast(made.dark, NameColor.darkBubble) >= 4.5, "\(name) on the dark bubble")
            // The native dark bubble is darker than the web's, so the same colour reads there too.
            #expect(NameColor.contrast(made.dark, NameColor.RGB(38, 40, 44)) >= 4.5, "\(name) on the native dark bubble")
        }
    }

    @Test func anyColourAStoredHeadCanCarryIsReadableOrFallsBack() throws {
        for color in ["#fff", "#000", "#FFFFFF", "rgb(255, 214, 10)", "rgba(10,20,30,0.5)", "hsl(200, 100%, 70%)", "hsl(50deg 100% 50%)"] {
            let made = try #require(NameColor.readable(color), "\(color)")
            #expect(NameColor.contrast(made.light, NameColor.lightBubble) >= 4.5 && NameColor.contrast(made.dark, NameColor.darkBubble) >= 4.5, "\(color)")
        }
        #expect(NameColor.parse("#abc") == NameColor.RGB(170, 187, 204))
        #expect(NameColor.parse("hsl(0, 100%, 50%)") == NameColor.RGB(255, 0, 0))
        for junk in ["", "teal", "#12", "#gggggg", "url(x)", "rgb(a,b,c)"] {
            #expect(NameColor.readable(junk) == nil, "\(junk) → the label colour")
            #expect(ChatSenderPalette.nameColor(hex: junk) == UIColor.label)
        }
        #expect(ChatSenderPalette.nameColor(hex: nil) == UIColor.label)
        let yellow = ChatSenderPalette.nameColor(hex: "#FFD60A")
        #expect(yellow.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) != yellow.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        #expect(NameColor.contrast(NameColor.RGB(0, 0, 0), NameColor.RGB(255, 255, 255)) == 21)
    }

    // MARK: Deliveries from another bot (run.ts)

    @Test func theThreeDeliveryShapes() {
        #expect(DeliverySender.parse("Message from Inbox (@inbox): Three new emails need a reply.")
            == .init(name: "Inbox", handle: "inbox", body: "Three new emails need a reply."))
        #expect(DeliverySender.parse("Message from Billing Bot: Invoice sent.") == .init(name: "Billing Bot", handle: "billing bot", body: "Invoice sent."))
        #expect(DeliverySender.parse("[Message from agent 'research'] Findings are in the doc.")
            == .init(name: "research", handle: "research", body: "Findings are in the doc."))
        #expect(DeliverySender.parse("Message from 🤖 Ops (@ops):\nline one\nline two") == .init(name: "Ops", handle: "ops", body: "line one\nline two"))
        // A handle with its gateway: the handle alone names the sender.
        #expect(DeliverySender.parse("Message from Ivy (@ivy@studio-mac): hi") == .init(name: "Ivy", handle: "ivy", body: "hi"))
    }

    @Test func whatIsNotADelivery() {
        let long = String(repeating: "n", count: 65)
        for text in ["I got a Message from Inbox (@inbox): hi", "message from Inbox: hi", "Message from : hi", "Message from \(long): hi",
                     "Message from Inbox", " Message from Inbox: hi", "[Message from agent ''] hi", "Message from A\nB: hi"] {
            #expect(DeliverySender.parse(text) == nil, "\(text)")
            #expect(!DeliveryMessages.hasDelivery([ChatMessage(id: "m", role: .user, parts: [.text(text)], timestamp: nil, rowId: nil)]), "\(text)")
        }
        #expect(DeliverySender.parse("Message from \(String(repeating: "n", count: 64)): hi")?.name.count == 64)
        #expect(!DeliveryMessages.mayBeDelivery("Hello") && DeliveryMessages.mayBeDelivery("Message from x"))
    }

    private let roster = [DeliveryMessages.Seat(profile: "default", name: "Hermes", head: nil),
                          DeliveryMessages.Seat(profile: "inbox", name: "Inbox", head: ["theme": "shape", "color": "grape", "v": 6]),
                          DeliveryMessages.Seat(profile: "research", name: "Research", head: ["theme": "shape", "color": "teal", "v": 6])]

    @Test func aDeliveryFindsItsBotByHandleThenNameThenHermes() {
        func sender(_ text: String) -> ChatSender { DeliveryMessages.sender(for: DeliverySender.parse(text)!, roster: roster) }
        let inbox = sender("Message from Mailroom (@inbox): hi")
        #expect(inbox.profile == "inbox" && inbox.name == "Inbox" && inbox.key == "delivery:inbox" && inbox.colorHex == "#7C3AED")
        #expect(sender("[Message from agent 'research'] hi").name == "Research")
        #expect(sender("Message from research: hi").profile == "research")
        #expect(sender("Message from Hermes: hi").profile == "default" && sender("Message from Anything (@hermes): hi").name == "Hermes")
        // An unknown sender keeps the name as written, the default head and the label colour.
        let unknown = sender("Message from Billing Bot: Invoice sent.")
        #expect(unknown.name == "Billing Bot" && unknown.head == nil && unknown.colorHex == nil && unknown.key == "delivery:?billing bot")
    }

    @Test func deliveriesBecomeIncomingMessagesWithoutTheirPrefix() {
        func row(_ id: String, _ role: ChatMessage.Role, _ text: String) -> ChatMessage {
            ChatMessage(id: id, role: role, parts: [.text(text)], timestamp: nil, rowId: nil)
        }
        let messages = [row("1", .user, "Message from Inbox (@inbox): Three new emails need a reply."), row("2", .user, "A message of mine"),
                        row("3", .assistant, "Message from Inbox (@inbox): quoted by the bot"), row("4", .user, "Message from Billing Bot: Invoice sent.")]
        let made = DeliveryMessages.resolve(messages, roster: roster)
        #expect(made.found)
        #expect(made.messages[0].sender?.name == "Inbox" && made.messages[0].parts == [.text("Three new emails need a reply.")])
        #expect(made.messages[1] == messages[1] && made.messages[2] == messages[2], "your own message and the bot's reply are untouched")
        #expect(made.messages[3].sender?.name == "Billing Bot" && made.messages[3].parts == [.text("Invoice sent.")])
        #expect(made.messages.map(\.id) == ["1", "2", "3", "4"] && made.messages.allSatisfy { $0.role == messages[Int($0.id)! - 1].role })
        // Resolving again changes nothing (the prefix is gone and the sender is set).
        let again = DeliveryMessages.resolve(made.messages, roster: roster)
        #expect(!again.found && again.messages == made.messages)
        #expect(!DeliveryMessages.resolve([messages[1], messages[2]], roster: roster).found)
    }

    // MARK: Rooms in the Bots list

    private func row(_ name: String, pinned: Bool = false, pinnedAt: Double? = nil, section: String? = nil, order: Int? = nil, lastAt: Double = 0,
                     running: Bool = false, search: String? = nil) -> GroupRowModel {
        GroupRowModel(id: "id:\(name)", name: name, image: nil, faces: [], line: "2 bots", tone: .secondary, time: nil, unread: false, pinned: pinned,
                      muted: false, memberCount: 2, running: running, sectionId: section, order: order, pinnedAt: pinnedAt, lastAt: lastAt,
                      search: search ?? name.lowercased(), online: true)
    }

    @Test func pinnedRoomsAreTilesInPinOrderAndTheRestAreNewestFirst() {
        let rooms = [row("Old", lastAt: 10), row("New", lastAt: 90), row("B pin", pinned: true, pinnedAt: 2), row("A pin", pinned: true, pinnedAt: 5),
                     row("Filed", section: "s1", lastAt: 50), row("Orphan", section: "deleted", lastAt: 70)]
        let plan = GroupList.plan(rooms, freeTiles: 9, sections: [("s1", "Work"), ("s2", "Home")], draggingRoom: false)
        #expect(plan.tiles.map(\.name) == ["B pin", "A pin"])
        #expect(plan.loose.map(\.name) == ["New", "Orphan", "Old"], "a room whose section is gone is in no section again")
        #expect(plan.filed.map(\.name) == ["Work"] && plan.filed[0].rooms.map(\.name) == ["Filed"] && !plan.filed[0].hint)
        #expect(plan.count == 4 && !plan.isEmpty)
        // The grid is full: pins it cannot take lead the block. An empty section shows only while a room is dragged.
        let full = GroupList.plan(rooms, freeTiles: 1, sections: [("s1", "Work"), ("s2", "Home")], draggingRoom: true)
        #expect(full.tiles.map(\.name) == ["B pin"] && full.loose.first?.name == "A pin")
        #expect(full.overflow.map(\.name) == ["A pin"], "with sections the list files it under Pinned (audit 05-6)")
        #expect(plan.overflow.isEmpty)
        #expect(full.filed.map(\.name) == ["Work", "Home"] && full.filed[1].hint && full.filed[1].rooms.isEmpty)
        #expect(GroupList.plan([], freeTiles: 9, sections: [], draggingRoom: false).isEmpty)
    }

    /// UX study #254: a hidden room leaves the tiles and the block for Hidden.
    @Test func hiddenRoomsGoUnderHidden() {
        var hiddenPin = row("Hidden pin", pinned: true, pinnedAt: 1)
        hiddenPin.hidden = true
        var hiddenFiled = row("Hidden filed", section: "s1", lastAt: 40)
        hiddenFiled.hidden = true
        let plan = GroupList.plan([row("Shown", lastAt: 10), hiddenPin, hiddenFiled], freeTiles: 9, sections: [("s1", "Work")], draggingRoom: false)
        #expect(plan.tiles.isEmpty && plan.loose.map(\.name) == ["Shown"] && plan.filed.isEmpty)
        #expect(plan.hidden.map(\.name) == ["Hidden filed", "Hidden pin"] && plan.count == 1)
    }

    @Test func aUserOrderBeatsRecencyAndNamesBreakTies() {
        let rooms = [row("b", lastAt: 5), row("a", lastAt: 5), row("second", order: 2, lastAt: 1), row("first", order: 1, lastAt: 0), row("newest", lastAt: 99)]
        #expect(GroupList.sorted(rooms).map(\.name) == ["first", "second", "newest", "a", "b"])
    }

    @Test func searchAndActivityFilterRooms() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let nowMs = now.timeIntervalSince1970 * 1000
        let rooms = [row("Launch Room", lastAt: nowMs - 60_000, search: "launch room hermes ivy research"),
                     row("Archive", lastAt: nowMs - 9 * 24 * 3_600_000, search: "archive notes ops"),
                     row("Busy", lastAt: nowMs, running: true, search: "busy ivy"), row("Silent", search: "silent writer")]
        func names(_ query: String, _ activity: BotActivityFilter) -> [String] { GroupList.results(rooms, query: query, activity: activity, now: now).map(\.name) }
        #expect(names("", .all) == ["Busy", "Launch Room", "Archive", "Silent"])
        #expect(names("ivy", .all) == ["Busy", "Launch Room"], "a member's name finds its rooms")
        #expect(names("LAUNCH rés", .all) == ["Launch Room"])
        #expect(names("", .active) == ["Busy"])
        #expect(names("", .recent) == ["Busy", "Launch Room"])
        #expect(names("", .older) == ["Archive", "Silent"])
        #expect(names("nothing", .all).isEmpty)
    }

    @Test func aDraggedRoomDropsOnlyInTheGroupChatsBlock() {
        #expect(GroupList.drop(room: true, over: .groups) == .section(nil))
        #expect(GroupList.drop(room: true, over: .groupSection("s1")) == .section("s1"))
        // [bots-groupby] With sections in use, rooms are filed among the bots: a section files, Unassigned unfiles.
        #expect(GroupList.drop(room: true, over: .user("s1")) == .section("s1"))
        #expect(GroupList.drop(room: true, over: .unassigned) == .section(nil))
        for section in [BotListSectionID.tiles, .pinned, .hidden, .results, .everything] {
            #expect(GroupList.drop(room: true, over: section) == nil, "\(section)")
        }
        #expect(GroupList.drop(room: true, over: nil) == nil)
        #expect(GroupList.drop(room: false, over: .groups) == nil, "a bot is not filed among rooms")
        #expect(GroupList.dropHint == "Drop a group chat here.")
    }

    // MARK: Show › and the Filter button

    @Test func showFilterWordsAndTokens() {
        #expect(BotKindFilter.allCases.map(\.title) == ["All", "Bots", "Group Chats"])
        #expect(BotsBar.token(kind: .all, activity: .all) == nil)
        #expect(BotsBar.token(kind: .groups, activity: .all) == "Group Chats")
        #expect(BotsBar.token(kind: .bots, activity: .active) == "Bots · Active Now")
        #expect(BotsBar.token(kind: .all, activity: .recent) == "Recently Active")
        #expect(!BotsBar.filtersActive(kind: .all, activity: .all) && BotsBar.filtersActive(kind: .groups, activity: .all)
            && BotsBar.filtersActive(kind: .all, activity: .older))
    }

    // [filters-only] `filterShowsWithARoomAndWhileShowIsOn` went with `BotsBar.filterShown`: Filter is always on the bar
    // (owner 2026-11-03), so a room or Show › no longer has to keep it there.

    // MARK: New Group Chat, the picker and Add to Group Chat…

    private func bot(_ id: String, hidden: Bool = false, role: String? = nil) -> Bot {
        Bot(id: id, name: id.capitalized, role: role, preview: nil, lastActive: nil, isWorking: false, unread: false, pinned: false, pinOrder: nil,
            sectionName: nil, hidden: hidden, canonicalSessionId: nil, head: nil)
    }

    @Test func newGroupChatNeedsTwoBotsAndAGateway() {
        #expect(GroupActions.newGroupDisabledReason(bots: [bot("default"), bot("ivy")], online: true) == nil)
        #expect(GroupActions.newGroupDisabledReason(bots: [bot("default"), bot("deploys", hidden: true)], online: true) == "Needs at least 2 bots")
        #expect(GroupActions.newGroupDisabledReason(bots: [], online: true) == "Needs at least 2 bots")
        #expect(GroupActions.newGroupDisabledReason(bots: [bot("default"), bot("ivy")], online: false) == "Your gateway is offline")
    }

    @Test func thePickerHoldsTwoToSixBots() {
        var picked: [String] = []
        for name in ["a", "b", "c", "d", "e", "f"] {
            let next = GroupPickRules.tap(name, picked: picked, editing: false)
            #expect(next.result == .added)
            picked = next.picked
        }
        #expect(picked == ["a", "b", "c", "d", "e", "f"], "chips keep the order picked")
        let seventh = GroupPickRules.tap("g", picked: picked, editing: false)
        #expect(seventh.result == .full && seventh.picked == picked)
        #expect(GroupPickRules.tap("c", picked: picked, editing: true) == (["a", "b", "d", "e", "f"], .removed))
        // Editing a room: its last two cannot be taken away; a new room's picks can.
        #expect(GroupPickRules.tap("a", picked: ["a", "b"], editing: true) == (["a", "b"], .locked))
        #expect(GroupPickRules.tap("a", picked: ["a", "b"], editing: false) == (["b"], .removed))
        #expect((0...7).map(GroupPickRules.canCreate) == [false, false, true, true, true, true, true, false])
        #expect(GroupPickRules.placeholder([]) == "Group name" && GroupPickRules.placeholder(["Ivy", "Research"]) == "Ivy, Research")
        #expect(GroupPickRules.limitFooter == "A group chat can have up to 6 bots.")
        #expect(GroupPickRules.floorFooter == "A group chat needs at least 2 bots, so none can be removed.")
        let ivy = bot("ivy", role: "Books travel")
        #expect(GroupPickRules.matches(ivy, query: "") && GroupPickRules.matches(ivy, query: " IV ") && GroupPickRules.matches(ivy, query: "travel"))
        #expect(!GroupPickRules.matches(ivy, query: "ops"))
    }

    @Test func aRoomsSwitchFollowsItsLimits() {
        #expect(GroupJoinRules.state(member: false, count: 6) == .full && GroupJoinRules.subtitle(member: false, count: 6) == "Full (6 bots)")
        #expect(GroupJoinRules.state(member: true, count: 6) == .open && GroupJoinRules.subtitle(member: true, count: 6) == "6 bots")
        #expect(GroupJoinRules.state(member: true, count: 2) == .floor && GroupJoinRules.subtitle(member: true, count: 2) == "Needs at least 2 bots")
        #expect(GroupJoinRules.state(member: false, count: 2) == .open && GroupJoinRules.subtitle(member: false, count: 1) == "1 bot")
        #expect(GroupJoinRules.canRemoveAll(memberCounts: [3, 4]) && !GroupJoinRules.canRemoveAll(memberCounts: [3, 2]) && !GroupJoinRules.canRemoveAll(memberCounts: []))
        #expect(GroupJoinRules.emptyLine(bot: "Inbox", anyRooms: true) == "Inbox isn’t in any of these group chats yet. Turn one on, or name a new one.")
        #expect(GroupJoinRules.emptyLine(bot: "Inbox", anyRooms: false) == "Inbox isn’t in any group chats yet. Name one below to create it.")
    }

    // MARK: Avatars and photos

    @Test func facesSitWhereTheWebPutsThem() {
        #expect(GroupAvatarLayout.placements(0).isEmpty)
        #expect(GroupAvatarLayout.placements(1).map(\.scale) == [1])
        #expect(GroupAvatarLayout.placements(2).map(\.scale) == [0.64, 0.64] && GroupAvatarLayout.placements(2)[1].x == 0.36)
        for count in [3, 4, 6] {
            let three = GroupAvatarLayout.placements(count)
            #expect(three.map(\.scale) == [0.54, 0.46, 0.42], "at most three faces")
            #expect(three.allSatisfy { $0.x + $0.scale <= 1.0001 && $0.y + $0.scale <= 1.0001 }, "every face stays inside the avatar")
        }
        #expect(GroupAvatarLayout.imageData("data:image/jpeg;base64,aGVsbG8=") == Data("hello".utf8))
        #expect(GroupAvatarLayout.imageData("https://example.com/a.png") == nil && GroupAvatarLayout.imageData(nil) == nil)
    }

    @Test func aRoomPhotoFitsTheMirror() throws {
        // A noisy 3000 × 2000 picture (noise is the worst case for JPEG).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let noisy = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 2_000), format: format).image { context in
            var seed: UInt64 = 42
            for y in stride(from: 0, to: 2_000, by: 20) {
                for x in stride(from: 0, to: 3_000, by: 20) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    UIColor(red: CGFloat(seed >> 56) / 255, green: CGFloat((seed >> 48) & 0xFF) / 255, blue: CGFloat((seed >> 40) & 0xFF) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 20, height: 20))
                }
            }
        }
        let url = try #require(GroupPhoto.dataURL(from: noisy))
        #expect(url.hasPrefix("data:image/jpeg;base64,") && url.count <= 24_000)
        let image = try #require(GroupAvatarLayout.imageData(url).flatMap(UIImage.init(data:)))
        #expect(image.size.width == image.size.height && image.size.width <= 256, "a square, at most 256 px")
        #expect(GroupPhoto.square(noisy, side: 64).size == CGSize(width: 64, height: 64))
        // A limit nothing fits: no photo, never an oversized one.
        #expect(GroupPhoto.dataURL(from: noisy, limit: 200) == nil)
    }
}
