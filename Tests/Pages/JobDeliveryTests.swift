// [jobs] Where a job delivers (docs/spec/3x-jobs.md §6.8): the comma-joined value, the last-one rule, the rows.

import Foundation
import Testing
@testable import HermesHQNative

struct JobDeliveryTests {
    static let targets = DeliveryTarget.list(["targets": [
        ["id": "local", "name": "Local (save only)", "home_target_set": true],
        ["id": "telegram", "name": "Telegram", "home_target_set": true, "home_env_var": "TELEGRAM_HOME_CHANNEL"],
        ["id": "discord", "name": "Discord", "home_target_set": false],
        ["id": "bot-chat:default", "name": "Bot Chat (default)"],
        ["id": "bot-chat:research", "name": "Bot Chat (research)"],
    ]])
    static let bots = ["default": "Hermes", "research": "Research"]

    @Test func parseDropsBlanksAndRepeatsAndFallsBackToLocal() {
        #expect(JobDelivery.parse("") == ["local"])
        #expect(JobDelivery.parse(" , ,") == ["local"])
        #expect(JobDelivery.parse("local,local,,telegram") == ["local", "telegram"])
        #expect(JobDelivery.parse(" telegram:-100123:7 , origin ") == ["telegram:-100123:7", "origin"])
    }

    @Test func toggleChecksUnchecksAndKeepsTheLastOne() {
        #expect(JobDelivery.toggle("local", "telegram", checked: true) == "local,telegram")
        #expect(JobDelivery.toggle("local,telegram", "telegram", checked: true) == "local,telegram")
        #expect(JobDelivery.toggle("local,telegram", "local", checked: false) == "telegram")
        #expect(JobDelivery.toggle("local", "local", checked: false) == "local", "the last checked one stays")
        #expect(JobDelivery.toggle("", "local", checked: false) == "local")
        #expect(JobDelivery.toggle("local", "discord", checked: false) == "local")
        #expect(JobDelivery.same("local,telegram", "local, telegram,local"))
        #expect(!JobDelivery.same("local", "telegram"))
    }

    @Test func lenientTargets() {
        let list = DeliveryTarget.list(["targets": [
            ["name": "no id"], ["id": "x"], ["id": "x", "name": "again"], ["id": "slack", "home_target_set": "false"],
            ["id": "email", "home_target_set": 0], ["id": "sms", "home_target_set": "yes"], "junk", 4,
        ]])
        #expect(list.map(\.id) == ["x", "slack", "email", "sms"])
        #expect(list.map(\.homeTargetSet) == [true, false, false, true])
        #expect(DeliveryTarget.list(["nothing": true]).isEmpty)
        #expect(DeliveryTarget.list(.null).isEmpty)
    }

    @Test func rowsNameTheTargetsAndDimAPlatformWithoutAHomeChannel() {
        let rows = JobDelivery.rows(targets: Self.targets, value: "local", botNames: Self.bots)
        #expect(rows.map(\.title) == ["Run History Only", "Telegram", "Discord", "Bot Chat (Hermes)", "Bot Chat (Research)"])
        #expect(rows.map(\.checked) == [true, false, false, false, false])
        let discord = rows[2]
        #expect(discord.note == "Set a home channel first" && !discord.selectable)
        #expect(rows[1].note == nil && rows[1].selectable)
    }

    @Test func localIsAlwaysOfferedFirstEvenWhenTheReadFailed() {
        let none = JobDelivery.rows(targets: [], value: "")
        #expect(none.map(\.id) == ["local"] && none[0].checked)
        let late = JobDelivery.rows(targets: [DeliveryTarget(id: "telegram", name: "Telegram"), DeliveryTarget(id: "local", name: "Local")], value: "telegram")
        #expect(late.map(\.id) == ["local", "telegram"])
    }

    @Test func aSavedTargetTheGatewayNoLongerListsIsKept() {
        let origin = CronOrigin(json: ["platform": "telegram", "chat_id": "-100123", "chat_name": "Family"])
        let rows = JobDelivery.rows(targets: Self.targets, value: "telegram:-100123:7", origin: origin, botNames: Self.bots)
        #expect(rows.last?.id == "telegram:-100123:7")
        #expect(rows.last?.title == "Telegram · Family (topic 7)")
        #expect(rows.last?.checked == true && rows.last?.selectable == true)
        #expect(rows.filter(\.checked).count == 1)
        let fromOrigin = JobDelivery.rows(targets: Self.targets, value: "origin", origin: origin)
        #expect(fromOrigin.last?.title == "Where it was created · Telegram · Family")
    }

    @Test func aPlatformWithoutAHomeChannelIsLeftOutWhenOneOfItsChatsIsChosen() {
        let chat = JobDelivery.rows(targets: Self.targets, value: "discord:99", botNames: Self.bots)
        #expect(!chat.contains { $0.id == "discord" })
        #expect(chat.contains { $0.id == "discord:99" && $0.checked })
        let origin = CronOrigin(json: ["platform": "discord", "chat_id": "99", "chat_name": "Ops"])
        let created = JobDelivery.rows(targets: Self.targets, value: "origin", origin: origin)
        #expect(!created.contains { $0.id == "discord" })
        let elsewhere = JobDelivery.rows(targets: Self.targets, value: "telegram:5")
        #expect(elsewhere.contains { $0.id == "discord" }, "another platform's chat does not hide it")
    }

    @Test func aPlatformSavedWithoutAHomeChannelCanStillBeUnchecked() {
        let rows = JobDelivery.rows(targets: Self.targets, value: "local,discord")
        let discord = rows.first { $0.id == "discord" }
        #expect(discord?.checked == true && discord?.selectable == true && discord?.note == "Set a home channel first")
    }

    @Test func botChatNames() {
        #expect(JobDelivery.title(DeliveryTarget(id: "bot-chat:research", name: "Bot Chat (research)"), botNames: Self.bots) == "Bot Chat (Research)")
        #expect(JobDelivery.title(DeliveryTarget(id: "bot-chat:default", name: "Bot Chat (default)"), botNames: [:]) == "Bot Chat (Hermes)")
        #expect(JobDelivery.title(DeliveryTarget(id: "bot-chat:maple-revenue-operator", name: "Bot Chat (maple-revenue-operator)"), botNames: [:])
                == "Bot Chat (Maple Revenue Operator)")
        #expect(JobDelivery.title(DeliveryTarget(id: "local", name: "Local (save only)"), botNames: [:]) == "Run History Only")
        #expect(JobWords.humanDeliver("local", labels: JobDelivery.labels) == "Run History Only")
        #expect(JobWords.humanDeliver("local,telegram", labels: JobDelivery.labels) == "Telegram")
    }

    // MARK: The editor's rows (redesign 2026-10-31)

    @Test func runHistoryOnlyIsAChoiceOfItsOwn() {
        #expect(JobDelivery.pick("local", "telegram") == "telegram")
        #expect(JobDelivery.pick("telegram", "bot-chat:inbox") == "telegram,bot-chat:inbox")
        #expect(JobDelivery.pick("telegram,bot-chat:inbox", "telegram") == "bot-chat:inbox")
        #expect(JobDelivery.pick("telegram", "telegram") == "local", "the last place off leaves Run History Only")
        #expect(JobDelivery.pick("telegram,discord", "local") == "local")
        #expect(JobDelivery.pick("local,telegram", "telegram") == "local")
        #expect(JobDelivery.pick("local,telegram", "discord") == "telegram,discord")
    }

    @Test func rowsFallIntoPlacesBotsAndNeedsAHome() {
        let targets = [DeliveryTarget(id: "local", name: "Local"), DeliveryTarget(id: "telegram", name: "Telegram"),
                       DeliveryTarget(id: "discord", name: "Discord", homeTargetSet: false),
                       DeliveryTarget(id: "slack", name: "Slack", homeTargetSet: false),
                       DeliveryTarget(id: "bot-chat:inbox", name: "Bot Chat (inbox)")]
        let groups = JobDelivery.groups(JobDelivery.rows(targets: targets, value: "local", botNames: ["inbox": "Inbox"]))
        #expect(groups.places.map(\.id) == ["local", "telegram"])
        #expect(groups.bots.map(\.id) == ["bot-chat:inbox"])
        #expect(groups.needsHome == ["Discord", "Slack"])
        #expect(JobDelivery.needsHomeNote(groups.needsHome) == "Discord and Slack need a home channel first: send /sethome in the chat that should get results.")
        #expect(JobDelivery.needsHomeNote(["Discord"]) == "Discord needs a home channel first: send /sethome in the chat that should get results.")
        #expect(JobDelivery.needsHomeNote([]) == nil)
        // A platform already saved on the job stays a row (it can be unchecked).
        let saved = JobDelivery.groups(JobDelivery.rows(targets: targets, value: "discord"))
        #expect(saved.places.map(\.id).contains("discord") && saved.needsHome == ["Slack"])
    }

    @Test func runHistoryOnlyShowsUncheckedBesideAPlace() {
        let targets = [DeliveryTarget(id: "local", name: "Local"), DeliveryTarget(id: "telegram", name: "Telegram")]
        let shown = JobDelivery.historyOnlyBeside(JobDelivery.rows(targets: targets, value: "local,telegram"))
        #expect(shown.filter(\.checked).map(\.id) == ["telegram"])
        let alone = JobDelivery.historyOnlyBeside(JobDelivery.rows(targets: targets, value: "local"))
        #expect(alone.filter(\.checked).map(\.id) == ["local"])
    }
}
