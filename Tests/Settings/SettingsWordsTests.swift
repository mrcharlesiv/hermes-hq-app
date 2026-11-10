// UX study 2026-10-19 #62, #64, #92, #110 and 2026-10-21 #119, #186: the words the Settings pages choose from state.

import Foundation
import Testing
@testable import HermesHQNative

struct SettingsWordsTests {
    @Test func kanbanFooterSaysWhatAutomaticChose() {
        // On and Off start with the web's words; [kanban-tab-one] each says where Artifacts goes.
        #expect(SettingsWords.kanbanFooter(automatic: false, showsTab: true, mac: false)
                == "A task board your bots work from. It’s the Kanban tab, and Artifacts is in More › Workspace.")
        #expect(SettingsWords.kanbanFooter(automatic: false, showsTab: false, mac: false)
                == "A task board your bots work from. Turn it on to add a Kanban tab in Artifacts’ place.")
        // Automatic never says "Turn it on" while the picker shows Automatic.
        #expect(SettingsWords.kanbanFooter(automatic: true, showsTab: true, mac: false)
                == "A task board your bots work from. It’s the Kanban tab (Automatic: on), and Artifacts is in More › Workspace.")
        let off = SettingsWords.kanbanFooter(automatic: true, showsTab: false, mac: false)
        #expect(off.contains("Automatic:") && off.contains("Choose On") && !off.contains("Turn it on"))
    }

    /// [kanban-tab-one] The Mac has a sidebar, not a tab bar: its words say "sidebar" and never "tab".
    @Test func kanbanFooterOnTheMacSaysSidebar() {
        for automatic in [false, true] {
            for showsTab in [false, true] {
                let words = SettingsWords.kanbanFooter(automatic: automatic, showsTab: showsTab, mac: true)
                #expect(words.contains("sidebar") && !words.contains(" tab") && !words.contains("More"), "\(automatic) \(showsTab): \(words)")
                #expect(words.hasPrefix(SettingsWords.kanbanLead))
            }
        }
    }

    /// [kanban-tab-one] With the tab they share turned off on Tabs, neither has it: the footer says so, not "the Kanban tab".
    @Test func kanbanFooterWithTheTabTurnedOff() {
        for mac in [false, true] {
            let on = SettingsWords.kanbanFooter(automatic: false, showsTab: true, tabHidden: true, mac: mac)
            // Mac polish #131: the Mac shows no More; its pages are the sidebar's Tools.
            #expect(on.contains("turned off above") && on.contains(mac ? "under Tools in the sidebar" : "open from More") && !on.contains("It’s the Kanban tab"))
            #expect(SettingsWords.kanbanFooter(automatic: true, showsTab: false, tabHidden: true, mac: mac) == on, "Automatic says the same: neither has a tab")
            let off = SettingsWords.kanbanFooter(automatic: false, showsTab: false, tabHidden: true, mac: mac)
            #expect(off == (mac ? "A task board your bots work from. Off: Kanban isn’t shown, and Artifacts is under Tools in the sidebar."
                                : "A task board your bots work from. Off: Kanban isn’t shown, and Artifacts opens from More."))
        }
        #expect(SettingsWords.kanbanFooter(automatic: true, showsTab: true, tabHidden: true, mac: true).contains("sidebar"))
    }

    /// [kanban-tab-one] The one-time tip and How Kanban Works name the one real path (it said "Settings › Kanban Tab",
    /// then "Settings › Bots & Tools"), on the iPhone, iPad and Mac alike.
    @Test func kanbanWordsNameTheRealPath() {
        #expect(SettingsWords.kanbanTabPath(mac: false) == "Settings › Appearance › Tabs")
        let phone = SettingsWords.kanbanTookTab(mac: false)
        #expect(phone.label == "Kanban Took Artifacts’ Tab")
        #expect(phone.detail == "Artifacts is in More › Workspace. Change this in Settings › Appearance › Tabs.")
        // Mac polish #131: the Mac's page is Sidebar, and Artifacts goes under Tools (the Mac shows no More).
        let mac = SettingsWords.kanbanTookTab(mac: true)
        #expect(mac.label == "Kanban Took Artifacts’ Place")
        #expect(mac.detail == "Artifacts is under Tools in the sidebar. Change this in Settings › Appearance › Sidebar.")
        #expect(SettingsWords.kanbanAboutTab(mac: false).hasSuffix("To choose, use Kanban Tab in Settings › Appearance › Tabs."))
        #expect(SettingsWords.kanbanAboutTab(mac: true).hasSuffix("To choose, use Kanban in Settings › Appearance › Sidebar."))
        for mac in [false, true] {
            let about = SettingsWords.kanbanAboutTab(mac: mac)
            #expect(!about.contains("Bots & Tools") && !about.contains("Settings › Kanban Tab"))
            #expect(about.contains("sidebar") == mac)
            #expect(about.contains("More") != mac)
        }
    }

    @Test func gatewayCardSaysTheAddressOnce() {
        #expect(SettingsWords.gatewayCardLabel(name: "studio.local:9119", status: "Connected · 6 Bots", host: "studio.local:9119")
                == "studio.local:9119, Connected · 6 Bots", "an unnamed gateway's name is its address")
        #expect(SettingsWords.gatewayCardLabel(name: "Studio", status: "Offline", host: "studio.local:9119") == "Studio, Offline, studio.local:9119")
        #expect(SettingsWords.gatewayCardLabel(name: "Studio", status: "Offline", host: "") == "Studio, Offline")
        #expect(!SettingsWords.gatewayCardLabel(name: "Studio", status: "Offline", host: "x").contains("Gateway settings"), "where it goes is the hint")
        #expect(SettingsWords.gatewayCardHint == "Opens gateway settings")
    }

    @Test func toolCallsSummaryReads() {
        #expect(SettingsWords.toolCallsSummary(style: "Rows", hidesAfterReply: false) == "Rows")
        #expect(SettingsWords.toolCallsSummary(style: "At the Bottom", hidesAfterReply: true) == "At the Bottom", "one line: no \"hidden after reply\"")
        #expect(!SettingsWords.toolCallsSummary(style: "Rows", hidesAfterReply: true).contains("·"))
    }

    @Test func unopenedAlertsIsASentenceOnlyWhenThereAreSome() {
        #expect(SettingsWords.unopenedAlerts(0) == nil)
        #expect(SettingsWords.unopenedAlerts(1) == "1 alert couldn’t be opened.")
        #expect(SettingsWords.unopenedAlerts(3) == "3 alerts couldn’t be opened.")
    }

    @Test func notificationsRowSaysWhyItIsOff() {
        #expect(SettingsWords.notificationsSummary(enabled: false, denied: true, undetermined: false, plugin: .ready) == "Off")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: true, undetermined: false, plugin: .ready) == "Off in iOS Settings")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: false, undetermined: true, plugin: .ready) == nil, "iOS hasn't asked yet")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: false, undetermined: false, plugin: .missing) == "Add-on Needed")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: false, undetermined: false, plugin: .outdated) == "Update Needed")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: false, undetermined: false, plugin: .unknown) == "On")
        #expect(SettingsWords.notificationsSummary(enabled: true, denied: false, undetermined: false, plugin: nil) == "On")
    }

    @Test func gatewayFooterNamesWhoseSettingsTheseAre() {
        let named = SettingsWords.gatewayFooter(defaultBot: "Ada", otherBots: true)
        #expect(named.hasPrefix("Ada’s settings, saved on the computer running Hermes") && named.contains("Other bots keep their own."))
        #expect(!SettingsWords.gatewayFooter(defaultBot: "Ada", otherBots: false).contains("Other bots"))
        let unnamed = SettingsWords.gatewayFooter(defaultBot: nil, otherBots: true)
        #expect(unnamed.hasPrefix("Saved on the computer running Hermes") && !unnamed.contains("Other bots"))
        #expect(unnamed.contains("default project folder") && unnamed.contains("Read Replies Aloud"), "the rows kept on this device")
    }
}
