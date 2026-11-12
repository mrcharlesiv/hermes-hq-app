// [onboarding] The native guide's words against the web app's own (WebGuideStrings.swift, generated from build 240's
// source): a drift in either direction fails. docs/spec/3x-onboarding.md §5, §9.1.
//
// Two screens are the native app's own since the 2026-11-11 simplification (§19): "Where is your Hermes?" and "Get
// Hermes first." have no web page, and the chooser behind Set It Up Myself ("where") lists only the computers under its
// own heading. `SimpleStartCopyTests` pins those; everything else still has to say the web's words.

import Foundation
import Testing
@testable import HermesHQNative

/// Every string a screen shows, as plain words, by the web's step name.
enum NativeGuideStrings {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    static func quick(_ kind: OnboardingCopy.QuickKind) -> [String: [String]] {
        let c = OnboardingCopy.quick(kind), k = kind.rawValue
        return [
            "\(k)-1": [c.eyebrow1, c.heading1, c.lead1, OnboardingCopy.connectCommand, c.copy, c.share, c.footnote1, c.next],
            "\(k)-2": [c.eyebrow2, c.heading2] + c.steps2 + [c.note2, c.troubleTitle] + c.trouble.flatMap { [$0.problem, $0.fix] } + [c.next],
            "\(k)-3": [c.eyebrow3, c.heading3, c.lead3] + c.steps3 + [c.note3, c.typeAddress],
        ]
    }

    static var all: [String: [String]] {
        let w = OnboardingCopy.Welcome.self, wh = OnboardingCopy.Where.self, h = OnboardingCopy.LetHermes.self
        let o = OnboardingCopy.Windows.self, m = OnboardingCopy.Manual.self, s = OnboardingCopy.Setup.self
        var all: [String: [String]] = [
            "welcome": [w.headingLine1, w.headingLine2, w.lead, w.start, w.haveAddress] + w.points.flatMap { [$0.title, $0.text] },
            "where": [wh.eyebrow, wh.lead] + wh.choices(onMac: false).flatMap { [$0.title, $0.text] },
            "hermes": [h.heading, h.lead, h.copy, h.share, h.showMessage, OnboardingCopy.hermesConnectPrompt] + h.steps
                + [h.footnote, h.haveAddress, h.myself],
            "other-1": [o.eyebrow1, o.heading1, o.lead1] + o.steps1 + [o.getTailscale, o.next],
            "other-2": [o.eyebrow2, o.heading2, o.lead2, o.copy, o.showMessage, OnboardingCopy.hermesSetupPrompt, o.after, o.myself, o.signIn],
            "manual": [m.eyebrow, m.heading, m.lead, m.copyAll, m.title1, s.serve, m.text1, m.link1, m.title2, m.secretLead, s.secret,
                       m.envLead, s.env, m.text2, m.link2, m.title3, m.text3, s.start, m.signIn],
        ]
        for kind in OnboardingCopy.QuickKind.allCases { all.merge(quick(kind)) { a, _ in a } }
        return all.mapValues { $0.map { normalized(GuideText.plain($0)) } }
    }
}

struct OnboardingCopyTests {
    @Test func everyScreenSaysTheWebsWords() {
        #expect(Set(NativeGuideStrings.all.keys) == Set(WebGuideStrings.sections.keys), "the same twelve screens")
        for (step, strings) in NativeGuideStrings.all {
            let web = WebGuideStrings.sections[step] ?? ""
            // Letter case may differ: the native buttons are in title case (UX study #79), the web's are not all.
            for string in strings {
                #expect(web.range(of: string, options: .caseInsensitive) != nil, "\(step): the web does not say “\(string)”")
            }
        }
    }

    /// The other direction: nothing the web says on a screen is missing natively (its words, in order, are all covered
    /// by native strings; only the web's own "Back" label is not, by DECISION D3).
    @Test func nothingTheWebSaysIsMissing() {
        for (step, web) in WebGuideStrings.sections {
            var rest = web
            for string in (NativeGuideStrings.all[step] ?? []).sorted(by: { $0.count > $1.count }) {
                rest = rest.replacingOccurrences(of: string, with: " ", options: .caseInsensitive)
            }
            // "where": the web's question, its "Someone gave me an address" row and its "No Hermes yet?" footnote moved to
            // the screens before it (the welcome's second button and "Where is your Hermes?"; `SimpleStartCopyTests`).
            if step == "where" { continue }
            let left = rest.split(separator: " ").map(String.init).filter { $0 != "Back" }
            #expect(left.isEmpty, "\(step): the web also says \(left)")
        }
    }

    @Test func commandsAndMessagesAreByteForByte() {
        #expect(OnboardingCopy.connectCommand == WebGuideStrings.connectCommand)
        #expect(OnboardingCopy.connectPage == WebGuideStrings.connectPage)
        #expect(OnboardingCopy.hermesConnectPrompt == WebGuideStrings.hermesConnectPrompt)
        #expect(OnboardingCopy.setupStepsText == WebGuideStrings.setupStepsText)
        #expect(OnboardingCopy.setupStepsText.hasSuffix("web-dashboard\n"), "the trailing newline is the web's")
        #expect(OnboardingCopy.hermesSetupPrompt == WebGuideStrings.hermesSetupPrompt)
        #expect(OnboardingCopy.Setup.serve == WebGuideStrings.setupCommands["serve"])
        #expect(OnboardingCopy.Setup.secret == WebGuideStrings.setupCommands["secret"])
        #expect(OnboardingCopy.Setup.env == WebGuideStrings.setupCommands["env"])
        #expect(OnboardingCopy.Setup.start == WebGuideStrings.setupCommands["start"])
        #expect(OnboardingCopy.Links.hermes == WebGuideStrings.links["hermes"])
        #expect(OnboardingCopy.Links.dashboard == WebGuideStrings.links["dashboard"])
        #expect(OnboardingCopy.Links.tailscaleServe == WebGuideStrings.links["tailscale"])
        #expect(OnboardingCopy.Links.tailscaleApp == WebGuideStrings.links["tailscaleApp"])
        #expect(OnboardingCopy.hermesConnectPrompt.contains(OnboardingCopy.connectCommand + " -s -- --agent"))
    }

    /// The four `.env` lines appear in the same order in the manual page, the copied steps and the message for Hermes.
    @Test func envLinesKeepTheirOrderEverywhere() {
        #expect(OnboardingCopy.Setup.envLines.count == 4)
        for text in [OnboardingCopy.Setup.env, OnboardingCopy.setupStepsText, OnboardingCopy.hermesSetupPrompt] {
            var cursor = text.startIndex
            for line in OnboardingCopy.Setup.envLines {
                let found = text.range(of: line, range: cursor..<text.endIndex)
                #expect(found != nil, "missing or out of order: \(line)")
                if let found { cursor = found.upperBound }
            }
        }
    }

    @Test func feedbackLinesAreTheWebs() {
        let names: [OnboardingCopy.FeedbackKind: String] = [.agent: "agent", .connect: "connect", .connectLinux: "connect-linux",
                                                            .prompt: "prompt", .steps: "steps"]
        #expect(WebGuideStrings.copies.count == OnboardingCopy.FeedbackKind.allCases.count)
        for kind in OnboardingCopy.FeedbackKind.allCases {
            let web = WebGuideStrings.copies[names[kind]!] ?? []
            #expect(web == [kind.text, kind.copied, kind.couldNotCopy], "\(kind)")
        }
        #expect(OnboardingCopy.couldNotShare == "Couldn’t open sharing. Tap Copy instead.")
        #expect(OnboardingCopy.couldNotOpen("https://x.example") == "Couldn’t open it. Open this address in Safari: https://x.example")
        #expect(OnboardingCopy.couldNotOpenGuide(OnboardingCopy.Links.hermes)
                == "Couldn’t open the guide. Open this address in Safari: https://hermes-agent.nousresearch.com/docs/")
    }

    @Test func macWordsNeverShowOnTheLinuxPath() {
        let mac = NativeGuideStrings.quick(.mac).values.flatMap { $0 }.map { GuideText.plain($0) }
        let linux = NativeGuideStrings.quick(.linux).values.flatMap { $0 }.map { GuideText.plain($0) }
        for line in linux {
            #expect(!line.contains("your Mac") && !line.contains("this Mac") && !line.contains("⌘") && !line.contains("Return"), "\(line)")
        }
        #expect(mac.contains { $0.contains("⌘ Space") } && linux.contains { $0.contains("SSH") })
        #expect(OnboardingCopy.quick(.mac).trouble.map(\.problem) == [
            "“Hermes isn’t installed”", "“Hermes didn’t start in the background”", "“Needs Node.js 20 or newer”",
            "“Turn on MagicDNS and HTTPS Certificates”", "“Restart Hermes now”", "Anything else"])
        #expect(OnboardingCopy.quick(.linux).trouble.map(\.problem) == [
            "“Hermes isn’t installed”", "“Hermes didn’t start in the background”", "“Tailscale is installed but not signed in”",
            "“systemd user services … can’t reach”", "“Turn on MagicDNS and HTTPS Certificates”", "“Restart Hermes now”", "Anything else"])
    }

    /// The owner's rules: the forbidden word appears nowhere, and "gateway" is not used on the welcome or the guide
    /// (in Hermes it means the Telegram bridge).
    @Test func forbiddenWords() {
        let guide = NativeGuideStrings.all.values.flatMap { $0 }
            + OnboardingCopy.FeedbackKind.allCases.flatMap { [$0.copied, $0.couldNotCopy] } + [OnboardingCopy.couldNotShare]
        let unreadable = OfflineCopy.screen(reason: OfflineCopy.keychainUnreadable, hasAddress: false)
        let other = [OnboardingCopy.needHelp, OnboardingCopy.nameLabel, OnboardingCopy.namePlaceholder, unreadable.title, unreadable.recovery,
                     OfflineCopy.signInAgain, OfflineCopy.signInAgainTitle, OfflineCopy.signInAgainMessage, OutdatedCopy.title,
                     OutdatedCopy.recovery(canUpdate: true), OutdatedCopy.recovery(canUpdate: false), OutdatedCopy.stillOlder]
            + Array(SignInCopy.messages.values)
        for line in guide + other { #expect(!line.lowercased().contains("dispatch"), "\(line)") }
        for line in guide { #expect(!line.lowercased().contains("gateway"), "\(line)") }
    }

    @Test func formAndUnreadableCopyAreTheWebs() {
        #expect(OnboardingCopy.needHelp == "Need help connecting?")
        #expect(OnboardingCopy.namePlaceholder == "Optional, like Home Mac" && OnboardingCopy.nameLabel == "Name for this Hermes")
        #expect(SignInCopy.subtitle(.password) == "This Hermes uses a username and password. To sign in with your Nous account instead, it needs a one-time setup on its computer: tap Need help connecting? below.")
        let nous = "This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password, or finish the Mac setup: tap Need help connecting? below."
        #expect(SignInCopy.messages["nous-unavailable"] == nous && GatewayFailure.nousUnavailable.message == nous)
        // The unreadable sign-in is the offline screen's now (spec D27): its words are still the web's (`W:src/main.ts:44,362`).
        #expect(OfflineCopy.signInAgain == "Sign In Again")
        #expect(OfflineCopy.signInAgainTitle + " " + OfflineCopy.signInAgainMessage
                == "Sign In Again? Hermes HQ couldn’t read your saved sign-in. Drafts on this \(DeviceWord.name) are kept aside and won’t move to the account you sign in with.")
        #expect(OnboardingCopy.device == DeviceWord.name && SignInCopy.device == DeviceWord.name)
    }

    @Test func markupReadsAsWordsAndKeyNames() {
        let line = "Open **Terminal**: press [[⌘ Space]], type `hermes serve`, see <<the guide|https://x.example/a>>."
        #expect(GuideText.plain(line) == "Open Terminal: press ⌘ Space, type hermes serve, see the guide.")
        #expect(GuideText.spoken(line) == "Open Terminal: press Command Space, type hermes serve, see the guide.")
        #expect(GuideText.pieces(line).contains(.link("the guide", "https://x.example/a")))
        #expect(GuideText.spoken("[[⌘ V]] [[⌘ N]] [[Control C]] [[Return]] [[Enter]]") == "Command V Command N Control C Return Enter")
        #expect(GuideText.plain("a ** b [[ c ` d << e") == "a ** b [[ c ` d << e", "an unclosed mark is plain text")
    }
}

/// docs/spec/3x-onboarding.md §5.17: the sentences that say what Tailscale is for and where it runs.
struct TailscaleCopyTests {
    @Test func everySentenceIsWhereTheWebHasIt() {
        func has(_ step: String, _ sentence: String) -> Bool {
            (NativeGuideStrings.all[step] ?? []).contains { $0.contains(sentence) } && (WebGuideStrings.sections[step] ?? "").contains(sentence)
        }
        #expect(has("where", "Uses Tailscale, a free app, on that computer and this iPhone, with a password."))                       // T1
        #expect(has("hermes", "both free: Nous, so only you can get in, and Tailscale, which gives that computer an address your iPhone can reach from anywhere."))   // T2
        #expect(has("hermes", "Tailscale runs only on that computer: nothing to install on this iPhone. Works when Hermes runs on a Mac or Linux, servers included."))   // T3
        #expect(has("mac-2", "It signs this Mac in to Nous, so only you can get in, and to Tailscale, which gives your Mac an address this iPhone can reach from anywhere (both free)"))   // T4
        #expect(has("mac-2", "Tailscale runs only on your Mac: your iPhone doesn’t need it"))                                         // T5
        #expect(has("linux-2", "It signs that computer in to Nous, so only you can get in, and to Tailscale, which gives it an address this iPhone can reach from anywhere (both free)"))   // T6
        #expect(has("linux-2", "Tailscale runs only on that computer: your iPhone doesn’t need it"))                                  // T7
        #expect(has("other-1", "Tailscale is a free app that privately links this iPhone and the computer running Hermes, wherever you are."))   // T8
        #expect(has("manual", "Tailscale should already be on both, signed in to the same account, with MagicDNS and HTTPS Certificates turned on in its admin console."))   // T9
        #expect(OnboardingCopy.hermesConnectPrompt.contains("It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale."))   // T10
        #expect(has("linux-2", "“Tailscale is installed but not signed in”") && has("linux-2", "Type sudo tailscale up, open the link it shows and sign in, then run the command again."))   // T11
        #expect(SignInCopy.messages["unreachable"]!.hasSuffix("If you use Tailscale, check that it’s on here too."))                  // T12
        #expect(SignInCopy.messages["timeout"]!.hasSuffix("and that Tailscale is on if you use it."))                                 // T13
        #expect(SignInCopy.messages["tailscale-off"] == "Turn on Tailscale to reach your Hermes, then try again.")                   // T14
        #expect(SignInCopy.messages["tailscale-ip"] == "iPhone allows plain http:// to a Tailscale machine only by its name. Use the Tailscale name of the computer running Hermes (in the Tailscale app, like mac-mini.tailnet-name.ts.net) instead of its 100.x address, or use https://.")   // T15
    }

    /// "This iPhone already uses Tailscale" (native only): the same setup with `--private`, and no line saying the phone
    /// doesn't need Tailscale.
    @Test func tailnetOnlyCopy() {
        let t = OnboardingCopy.Tailnet.self
        #expect(t.command == "curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh -s -- --private")
        #expect(t.prompt.contains(OnboardingCopy.connectCommand + " -s -- --agent --private\n"))
        #expect(t.prompt.contains("only devices on my Tailscale network can reach it. My phone already runs Tailscale, so sign this computer in to the same Tailscale account."))
        #expect(t.prompt.contains("so I can reach you from my phone over Tailscale"))
        #expect(!t.prompt.contains("doesn't need Tailscale") && t.prompt.hasSuffix("If it says it can't run on this computer, tell me why."))
        #expect(t.letHermesSteps.count == OnboardingCopy.LetHermes.steps.count && t.letHermesSteps[1].contains("same account as this \(DeviceWord.name)"))
        for kind in OnboardingCopy.QuickKind.allCases {
            let plain = OnboardingCopy.quick(kind), same = OnboardingCopy.quick(kind, tailnetOnly: false), priv = OnboardingCopy.quick(kind, tailnetOnly: true)
            #expect(same.steps2 == plain.steps2 && same.note2 == plain.note2 && same.note3 == plain.note3)
            #expect(priv.steps2[2] != plain.steps2[2] && priv.steps2[2].contains("with the same Tailscale account as this \(DeviceWord.name) (both free)"), "\(kind)")
            #expect(!priv.note2.contains("doesn’t need") && priv.note2.contains("same account as this \(DeviceWord.name)"))
            #expect(priv.note3.hasPrefix(plain.note3) && priv.note3.hasSuffix("the address works only on your Tailscale network."))
            #expect(priv.steps2[0] == plain.steps2[0] && priv.heading1 == plain.heading1)
        }
        for line in [t.toggleTitle, t.toggleText, t.letHermesFootnote, t.prompt] + t.letHermesSteps {
            #expect(!line.lowercased().contains("gateway") && !line.lowercased().contains("dispatch"), "\(line)")
        }
    }

    /// The rule no copy may contradict: Mac, Linux and "Let Hermes set it up" never ask for Tailscale on the phone.
    @Test func quickPathsNeverPutTailscaleOnThePhone() {
        for step in ["hermes", "mac-1", "mac-2", "mac-3", "linux-1", "linux-2", "linux-3"] {
            for line in NativeGuideStrings.all[step] ?? [] where line != NativeGuideStrings.normalized(OnboardingCopy.hermesConnectPrompt) {
                #expect(!line.contains("install Tailscale") && !line.contains("Get Tailscale"), "\(step): \(line)")
            }
        }
    }
}

/// [mac] The guide as the Mac app shows it (stress test 2026-10-28 #29, #43): no Camera app or QR scan, "On a Mac" is
/// another Mac, a Hermes on this Mac goes straight to the form, and the phone keeps the web's words.
struct MacOnboardingCopyTests {
    @Test func thePhoneKeepsItsWords() {
        for kind in OnboardingCopy.QuickKind.allCases {
            let phone = OnboardingCopy.quick(kind, onMac: false), plain = OnboardingCopy.quick(kind)
            #expect(phone.heading3 == plain.heading3 && phone.steps3 == plain.steps3 && phone.steps2 == plain.steps2 && phone.typeAddress == plain.typeAddress)
        }
        #expect(OnboardingCopy.Where.choices(onMac: false).map(\.id) == ["mac", "linux", "windows"])
        #expect(OnboardingCopy.Start.choices(onMac: false).map(\.id) == [OnboardingCopy.Start.computerID])
    }

    @Test func stepThreeCopiesTheAddressInsteadOfScanning() {
        for kind in OnboardingCopy.QuickKind.allCases {
            let mac = OnboardingCopy.quick(kind, onMac: true)
            let words = ([mac.heading3, mac.lead3, mac.note3, mac.typeAddress] + mac.steps3).map { GuideText.plain($0) }
            for line in words {
                #expect(!line.contains("Camera") && !line.contains("Scan") && !line.contains("iPhone") && !line.contains("Open in Hermes HQ"), "\(kind): \(line)")
            }
            #expect(mac.typeAddress == "Next: Sign In" && mac.steps3.contains { $0.contains("**Next: Sign In**") }, "\(kind)")
            #expect(GuideText.plain(mac.lead3).contains("Can’t scan it?"), "the setup's own line under its QR code")
        }
    }

    @Test func stepsOneAndTwoAreAboutAnotherMac() {
        let mac = OnboardingCopy.quick(.mac, onMac: true)
        let words = ([mac.heading1, mac.lead1, mac.share, mac.footnote1, mac.heading2, mac.note2, mac.note3] + mac.steps2).map { GuideText.plain($0) }
        for line in words {
            #expect(!line.contains("your Mac") && !line.contains("iPhone") && !line.contains("this Mac in to"), "\(line)")
        }
        #expect(mac.heading1 == "Get the setup command onto the other Mac." && mac.heading2 == "Run it in Terminal on the other Mac.")
        #expect(mac.steps2[2].contains("which gives it an address this Mac can reach from anywhere"))
        for line in OnboardingCopy.quick(.linux, onMac: true).steps2 + [OnboardingCopy.quick(.linux, onMac: true).note2] {
            #expect(!line.contains("iPhone"), "\(line)")
        }
        for kind in OnboardingCopy.QuickKind.allCases {
            let priv = OnboardingCopy.quick(kind, tailnetOnly: true, onMac: true)
            #expect(priv.steps2[2].contains("with the same Tailscale account as this Mac (both free)"), "\(kind)")
            #expect(priv.note2.contains("same account as this Mac") && priv.note3.hasSuffix("the address works only on your Tailscale network."))
        }
    }

    @Test func theFirstQuestionOffersThisMac() {
        let choices = OnboardingCopy.Start.choices(onMac: true)
        #expect(choices.map(\.id) == [OnboardingCopy.Start.localID, OnboardingCopy.Start.computerID])
        #expect(choices[0].title == "On this Mac" && choices[0].step == .connect && choices[1].title == "On another computer")
        #expect(!choices.contains { $0.text.contains("iPhone") })
        let local = try? GatewayAddress.validated(GatewayAddress.normalizeTyped(OnboardingCopy.Start.localAddress))
        #expect(local?.absoluteString == "http://127.0.0.1:9119", "plain http is allowed to this Mac itself")
        let computers = OnboardingCopy.Where.choices(onMac: true)
        #expect(computers.map(\.id) == ["mac", "linux", "windows"] && computers[0].title == "On another Mac")
        #expect(!computers.contains { $0.text.contains("iPhone") })
    }
}

/// The Hermes Cloud rows (native only): not in the web's lists, and never a setup step or Tailscale.
struct CloudOnboardingCopyTests {
    @Test func theRowsAreNativeAndAskForNothing() {
        let c = OnboardingCopy.Cloud.self, g = OnboardingCopy.GetHermes.self
        let words = [c.title, c.text, g.cloudTitle, g.cloudText]
        for line in words {
            #expect(!line.contains("Tailscale") && !line.lowercased().contains("gateway"), "\(line)")
            for (step, strings) in NativeGuideStrings.all { #expect(!strings.contains(NativeGuideStrings.normalized(line)), "\(step): \(line)") }
        }
        #expect(!OnboardingCopy.Where.choices(onMac: false).contains { $0.id == c.id }, "the row is the view's, not the web's list")
        #expect(!OnboardingCopy.Start.choices(onMac: true).contains { $0.id == c.id })
    }
}

/// The 2026-11-11 simplification (docs/spec/3x-onboarding.md §19): one plain question after Get Started, a way on for
/// someone with no Hermes, and no jargon before a path is picked.
struct SimpleStartCopyTests {
    @Test func theFirstQuestionIsPlainAndShort() {
        let s = OnboardingCopy.Start.self, c = OnboardingCopy.Cloud.self
        #expect(s.heading == "Where is your Hermes?")
        #expect(s.choices(onMac: false).map(\.title) == ["On my computer"] && s.choices(onMac: false)[0].step == .hermes)
        #expect(c.title == "On Hermes Cloud" && s.noneTitle == "I don’t have Hermes yet")
        let rows = s.choices(onMac: false).map(\.text) + s.choices(onMac: true).map(\.text) + [c.text, s.noneText]
        for line in [s.heading, s.lead, s.noneTitle] + rows {
            for word in ["Tailscale", "address", "gateway", "terminal", "SSH", "command", "MagicDNS"] {
                #expect(!line.lowercased().contains(word.lowercased()), "“\(line)” says \(word) before a path is picked")
            }
        }
        for line in rows { #expect(line.count <= 44, "“\(line)” is one short line under its title") }
    }

    @Test func noHermesYetHasTwoWaysOn() {
        let g = OnboardingCopy.GetHermes.self
        #expect(g.heading == "Get Hermes first." && g.cloudTitle == "Start one on Hermes Cloud" && g.installTitle == "Install it on a computer")
        #expect(GuideText.plain(g.after).hasSuffix("\(DeviceWord.tap) \(g.installed).") && g.installed == "I’ve Installed Hermes", "the way on is a button, named")
        #expect(g.cloudText.contains("Nous credit") || g.cloudText.contains("Nous account"), "what it costs is said before the tap")
        #expect(OnboardingCopy.Links.hermes == WebGuideStrings.links["hermes"], "Install opens the web's own guide link")
    }

    /// The chooser behind Set It Up Myself keeps the web's rows for the computers and nothing else.
    @Test func theComputersPageListsOnlyComputers() {
        let w = OnboardingCopy.Where.self
        #expect(w.heading == "Which computer runs Hermes?" && w.heading != OnboardingCopy.Start.heading)
        #expect(w.choices(onMac: false).map(\.step) == [.mac1, .linux1, .other1])
        for choice in w.choices(onMac: false) {
            #expect((WebGuideStrings.sections["where"] ?? "").contains(choice.title + choice.text), "\(choice.title)")
        }
    }

    /// The setup message can't set up Windows: the screen says where that path starts.
    @Test func letHermesPointsWindowsAtSetItUpMyself() {
        let h = OnboardingCopy.LetHermes.self
        #expect(GuideText.plain(h.windows) == "Hermes on Windows? \(DeviceWord.Tap) \(h.myself).")
    }

    @Test func aPastedMessageGivesUpItsAddress() {
        #expect(SignInAddress.pasted("  https://my-mac.tail1234.ts.net \n") == "https://my-mac.tail1234.ts.net")
        #expect(SignInAddress.pasted("my-mac.tail1234.ts.net") == "my-mac.tail1234.ts.net")
        #expect(SignInAddress.pasted("DONE. Here it is: https://my-mac.tail1234.ts.net. Paste it into Hermes HQ and tap Sign in with Nous.")
                == "https://my-mac.tail1234.ts.net")
        #expect(SignInAddress.pasted("Your address is **https://my-mac.tail1234.ts.net:8443** (keep the Mac awake)") == "https://my-mac.tail1234.ts.net:8443")
        #expect(SignInAddress.pasted("it’s my-mac.tail1234.ts.net, paste that") == "my-mac.tail1234.ts.net")
        #expect(SignInAddress.pasted("hermes://connect?url=https%3A%2F%2Fmy-mac.tail1234.ts.net") == "hermes://connect?url=https%3A%2F%2Fmy-mac.tail1234.ts.net")
        #expect(SignInAddress.pasted("no address in here") == "no address in here", "taken as typed: the form says what is wrong")
        #expect(SignInAddress.pasted("") == "")
    }
}
