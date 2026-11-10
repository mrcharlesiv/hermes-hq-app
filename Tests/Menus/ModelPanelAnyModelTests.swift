// [model-panel] The model bubble and panel hold for any model and provider (owner 2026-10-31: "We need to guarantee this
// works no matter the model and provider someone uses"): real ids from every kind of provider, the hard panel states,
// four phone widths and four text sizes. Every label's words sit inside its frame (nothing clipped, nothing "…"), no
// two pieces overlap, and the names read as names. No network.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// Ids as providers send them: hosted APIs, aggregators, clouds, local servers, fine-tunes, and nonsense.
private let corpus: [(id: String, provider: String, providerName: String?)] = [
    ("claude-opus-5-5[1m]", "anthropic", "Anthropic"),
    ("us.anthropic.claude-3-7-sonnet-20250219-v1:0", "bedrock", nil),
    ("amazon.nova-pro-v1:0", "bedrock", "AWS Bedrock"),
    ("claude-3-5-sonnet@20240620", "vertex", "Google Vertex AI"),
    ("google/gemini-3-pro-preview", "gemini", "Google AI Studio"),
    ("meta-llama/Llama-3.1-405B-Instruct-Turbo:free", "openrouter", "OpenRouter"),
    ("accounts/fireworks/models/llama-v3p1-405b-instruct", "fireworks", "Fireworks AI"),
    ("qwen2.5-coder:32b-instruct-q4_K_M", "ollama", nil),
    ("unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M", "custom", "Custom OpenAI-compatible endpoint (http://192.168.1.20:8080/v1)"),
    ("lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF", "lmstudio", "LM Studio"),
    ("Qwen/Qwen3-235B-A22B-Instruct-2507-FP8", "huggingface", "Hugging Face"),
    ("ft:gpt-4o-mini-2024-07-18:acme::9abcDEF", "openai-api", "OpenAI API"),
    ("gpt-5.5-fast", "openai-codex", "ChatGPT or Codex Subscription"),
    ("x-ai/grok-4-fast", "xai-oauth", "xAI Grok OAuth (SuperGrok / Premium+)"),
    ("moonshotai/kimi-k2-instruct-0905", "kimi-coding", "Kimi / Kimi Coding Plan"),
    ("Hermes-4-405B", "nous", "Nous Portal"),
    ("deepseek-chat", "claude-code", "Anthropic OAuth: Required Extra Usage Credits to Use Subscription"),
    ("my_lab_model_v2_final_really_final_this_time", "my-lab-box", nil),
    ("ThisIsAModelNameWithNoBreaksAnywhereAtAllReally", "vertex_ai", nil),
    ("x", "x", nil),
    ("", "custom", nil),
]

private func choice(_ entry: (id: String, provider: String, providerName: String?)) -> ModelChoice {
    ModelChoice(id: entry.id, name: ModelNames.displayModelName(entry.id), provider: entry.provider, providerName: entry.providerName)
}

private func input(_ current: ModelChoice, favorites: [ModelChoice] = [], levels: [String] = ModelNames.reasoningEfforts,
                   effort: String = "high", canTurnOff: Bool = true, fast: Bool = true, offline: Bool = false) -> ModelMenuInput {
    ModelMenuInput(current: current, recents: [], favorites: favorites, reasoningLevels: levels, reasoningCurrent: effort,
                   canTurnOff: canTurnOff, fastSupported: fast, fastOn: false, offline: offline)
}

/// Every hard state: each corpus model as the current one (with the next three to switch to), plus panels with no
/// thinking, one level, no Fast, no facts but Status, no favourites, offline, and odd prices and plans.
@MainActor private func states() -> [(String, ModelPanelState)] {
    var out: [(String, ModelPanelState)] = []
    let models = corpus.map(choice)
    for (index, model) in models.enumerated() {
        let next = (1...3).map { models[(index + $0) % models.count] }
        out.append((model.id.isEmpty ? "(empty)" : model.id,
                    ModelPanelModel.build(input(model, favorites: next), contextMax: 1_000_000, contextUsed: 412_000,
                                          price: "$0.075 in · $0.30 out", limit: "Rate limited · back in 2h 40m")))
    }
    out.append(("no thinking, nothing else", ModelPanelModel.build(input(models[17], levels: [], fast: false))))
    out.append(("one level", ModelPanelModel.build(input(models[11], favorites: [models[1]], levels: ["high"], canTurnOff: false))))
    out.append(("odd levels", ModelPanelModel.build(input(models[0], favorites: Array(models[1...2]),
                                                        levels: ["low", "extra_deep_reasoning_budget_maximum"], effort: "extra_deep_reasoning_budget_maximum"))))
    out.append(("offline", ModelPanelModel.build(input(models[5], favorites: Array(models[6...8]), offline: true), price: "Included")))
    out.append(("odd plan", ModelPanelModel.build(input(models[2], favorites: [models[3]]), listedContext: 300_000,
                                                  price: "Free", limit: "Monthly allowance · resets on the 14th of next month")))
    for name in ["long", "bare", "onestop", "offline", "tag", "yolo"] {
        if let state = ModelPanelModel.debugCase(name) { out.append(("debug \(name)", state)) }
    }
    return out
}

private let widths: [CGFloat] = [320, 375, 402, 440]
private let sizes: [UIContentSizeCategory] = [.large, .extraLarge, .extraExtraExtraLarge, .accessibilityLarge]

private func fitLabels(in view: UIView) -> [FitLabel] {
    view.subviews.flatMap { sub -> [FitLabel] in
        guard !sub.isHidden else { return [] }
        return (sub as? FitLabel).map { [$0] } ?? fitLabels(in: sub)
    }
}

@Suite("Menus · model panel for any model")
@MainActor
struct ModelPanelAnyModelTests {
    @Test func cloudWrappersReadAsTheModelsName() {
        let names = [
            "us.anthropic.claude-3-7-sonnet-20250219-v1:0": "3.7 Sonnet",
            "anthropic.claude-3-5-haiku-20241022-v1:0": "3.5 Haiku",
            "amazon.nova-pro-v1:0": "Nova Pro",
            "claude-3-5-sonnet@20240620": "3.5 Sonnet",
            "claude-sonnet-4@20250514": "Sonnet 4",
            "meta-llama/llama-3.3-70b-instruct:free": "Llama 3.3 70B Instruct Free",
            "openai/gpt-oss-20b:free": "GPT-oss-20b Free",
            "gpt-4o-2024-08-06": "GPT-4o",
            "ft:gpt-4o-mini-2024-07-18:acme::9abcDEF": "GPT-4o-mini Fine-tuned",
            "unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M": "Qwen3 30B A3B Q4",
            "lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF": "Meta Llama 3.1 8B Instruct",
        ]
        for (id, display) in names { #expect(ModelNames.displayModelName(id) == display, "\(id)") }
        // The spec's vectors stand (§2.2): an Ollama tag after a colon stays as the web reads it.
        #expect(ModelNames.displayModelName("qwen2.5-coder:14b") == "Qwen2.5 Coder:14B")
        #expect(ModelNames.displayModelName("claude-opus-4-5-20251101") == "Opus 4.5")
    }

    @Test func aProviderAlwaysHasAName() {
        #expect(ModelNames.readableProviderName(slug: "bedrock", catalogName: nil) == "AWS Bedrock")
        #expect(ModelNames.readableProviderName(slug: "openrouter", catalogName: "openrouter") == "OpenRouter")
        #expect(ModelNames.readableProviderName(slug: "vertex_ai", catalogName: nil) == "Vertex AI")
        #expect(ModelNames.readableProviderName(slug: "my-lab-box", catalogName: nil) == "My Lab Box")
        #expect(ModelNames.readableProviderName(slug: "custom", catalogName: "My GPU Box (local)") == "My GPU Box")
        #expect(ModelNames.readableProviderName(slug: "", catalogName: nil) == "Provider")
        // Owner 2026-11-01 (build 581): a provider whose catalog name is its slug read "claude-subscription- -experimental".
        let slug = "claude-subscription-directsdk-experimental"
        #expect(ModelNames.readableProviderName(slug: slug, catalogName: slug) == "Claude Subscription")
        #expect(ModelNames.readableProviderName(slug: slug, catalogName: nil) == "Claude Subscription")
        #expect(ModelNames.plainProviderName(slug) == "Claude Subscription")
        #expect(ModelNames.plainProviderName("kimi-coding") == "Kimi / Kimi Coding Plan", "Hermes' own name first")
        #expect(ModelNames.plainProviderName("sdk-experimental").lowercased() == "sdk experimental", "never nothing")
        #expect(ModelNames.shortProviderName("Anthropic OAuth: Required Extra Usage Credits to Use Subscription") == "Anthropic OAuth")
        #expect(ModelNames.shortProviderName("Kimi / Kimi Coding Plan") == "Kimi")
        #expect(ModelNames.shortProviderName("ChatGPT or Codex Subscription") == "ChatGPT or Codex")
        #expect(ModelNames.shortProviderName("http://192.168.1.20:8080/v1") == "192.168.1.20:8080")
        #expect(ModelNames.shortProviderName("Anthropic Account") == "Anthropic")
        #expect(ModelNames.shortProviderName("Subscription") == "Subscription")
    }

    @Test func wordsShrinkALittleThenWrapThenShrink() {
        let font = UIFont.systemFont(ofSize: 20)
        func text(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: font]) }
        let short = TextFit.fit(text("Opus 5.5"), width: 300, maxLines: 2)
        #expect(short == TextFit.Result(scale: 1, lines: 1))
        let long = TextFit.fit(text("Llama 3.1 405B Instruct Turbo Free"), width: 200, maxLines: 2)
        #expect(long.lines == 2 && long.scale == 1)
        let oneLine = TextFit.fit(text("Llama 3.1 405B Instruct Turbo Free"), width: 120, maxLines: 1)
        #expect(oneLine.lines == 1 && oneLine.scale < 0.5)
        // A run with no breaks that would shrink past reading wraps between letters instead, within its lines.
        let unbrokenText = text("ThisIsAModelNameWithNoBreaksAnywhere")
        let unbroken = TextFit.fit(unbrokenText, width: 150, maxLines: 2)
        let byWord = 150 / TextFit.widestWord(unbrokenText)
        #expect(unbroken.anywhere && unbroken.lines == 2 && unbroken.scale > byWord + 0.2)
        let drawn = TextFit.scaled(unbrokenText, by: unbroken.scale)
        #expect(TextFit.wrappedHeight(drawn, width: 150, anywhere: true) <= 2 * TextFit.lineHeight(drawn) + 1)
        // A short run that fits whole still breaks only between words.
        let words = TextFit.fit(text("Llama 3.1 405B Instruct Turbo"), width: 120, maxLines: 2)
        #expect(!words.anywhere)
        // Under a height: two lines shrink to sit inside it.
        let capped = TextFit.fit(text("Llama 3.1 405B Instruct Turbo Free"), width: 200, maxLines: 2, maxHeight: 30)
        #expect(capped.scale < 1)
        #expect(TextFit.wrappedHeight(TextFit.scaled(text("Llama 3.1 405B Instruct Turbo Free"), by: capped.scale), width: 200) <= 30)
    }

    @Test func theBubbleDropsFillerWordsLast() {
        #expect(ModelNames.compactModelName("Qwen3 235B A22B Instruct 2507 FP8") == "Qwen3 235B A22B")
        #expect(ModelNames.compactModelName("Meta Llama 3.1 8B Instruct") == "Llama 3.1 8B")
        #expect(ModelNames.compactModelName("Gemma 3 27B It") == "Gemma 3 27B")
        #expect(ModelNames.compactModelName("Opus 5.5") == "Opus 5.5")
        #expect(ModelNames.compactModelName("GPT-4o") == "GPT-4o")
        #expect(ModelNames.compactModelName("Llama 3.1 405B Instruct Turbo") == "Llama 3.1 405B Turbo")
        #expect(ModelNames.compactModelName("Instruct") == "Instruct")
        #expect(ModelNames.compactModelName("DeepSeek Chat") == "DeepSeek Chat")
    }

    /// Switch Model opens on every favourite, then recents, then the catalog (owner 2026-10-31: "a menu that opens all
    /// and shows the favorites first"); with no catalog it says so in place.
    @Test func theMenuOpensWithFavoritesFirst() async {
        let (panel, _) = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402)
        let titles = await panel.debugMenuTitles()
        #expect(titles.prefix(5) == ["[Favorites]", "Opus 5.5 1M", "GPT-5.5", "Grok 5", "Sonnet 5"])
        #expect(titles.firstIndex(of: "[Recent]") ?? 0 > titles.firstIndex(of: "Sonnet 5") ?? 0)
        #expect(titles.suffix(3) == ["[All Models]", ModelLoad.menuFailure, "Try Again"], "one more go, as the ⋯'s Model menu had")
    }

    /// [menu-stars] Tester 2026-11-06: the chat's model is starred from Switch Model itself. Favorites ends in Add (or
    /// Remove) for it; with nothing starred that row is Favorites, and says where the rest are starred.
    @Test func theMenuStarsTheChatsModel() async {
        var toggled = 0
        let starred = ModelPanelModel.debugSample
        #expect(starred.favorites.contains { $0.current }, "the sample's model is a favourite")
        let (panel, _) = ModelPanelView.debugLaidOut(starred, hostWidth: 402) { $0.toggleFavorite = { toggled += 1 } }
        let titles = await panel.debugMenuTitles()
        let remove = "Remove \(starred.name) from Favorites"
        #expect(titles.firstIndex(of: remove) == starred.favorites.count + 1, "after every favourite, in Favorites")
        var none = starred
        none.favorites = []
        let (bare, _) = ModelPanelView.debugLaidOut(none, hostWidth: 402) { $0.toggleFavorite = { toggled += 1 } }
        #expect(await bare.debugMenuTitles().prefix(2) == ["[Favorites]", "Add \(none.name) to Favorites"])
        #expect(ModelPanelModel.starRow(name: "Opus 5.5", favorite: false, noFavorites: true).subtitle == "Or star any model in Search All Models")
        #expect(ModelPanelModel.starRow(name: "Opus 5.5", favorite: false, noFavorites: false).subtitle == nil)
        // No way to star: no row, and no empty Favorites.
        let (plain, _) = ModelPanelView.debugLaidOut(none, hostWidth: 402)
        #expect(await plain.debugMenuTitles().contains("[Favorites]") == false)
        #expect(toggled == 0)
    }

    /// While the panel is open the page's back swipes are held (owner 2026-10-31: a drag right on the ring pulled the
    /// whole page off to go back); they come back as they were once it goes.
    @Test func thePanelHoldsThePagesBackSwipe() {
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: page)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        navigation.view.layoutIfNeeded()
        let swipes = [navigation.interactivePopGestureRecognizer, navigation.interactiveContentPopGestureRecognizer].compactMap { $0 }
        #expect(!swipes.isEmpty)
        swipes.forEach { $0.isEnabled = true }
        let state = ModelPanelModel.debugSample
        let actions = ModelPanelActions(state: { state }, pick: { _ in }, setEffort: { _ in }, setFast: { _ in },
                                        setApprovalMode: { _ in }, setYolo: { _ in }, loadApprovals: {}, openAll: {},
                                        allModels: { nil }, closed: { _ in })
        let bar = UIView(frame: CGRect(x: 0, y: 800, width: 402, height: 60))
        page.view.addSubview(bar)
        let panel = ModelPanelView.present(in: page.view, under: bar, from: ModelChip(), floor: 780, face: (nil, "default"), actions: actions)
        #expect(panel != nil)
        #expect(swipes.allSatisfy { !$0.isEnabled })
        panel?.removeFromSuperview()
        #expect(swipes.allSatisfy { $0.isEnabled })
        window.isHidden = true
    }

    /// Fast, Approval Mode and YOLO: what each row says, how far it reaches, and the Approval Mode menu with what's on
    /// checked. Owner 2026-11-01 ("Do the weak points"): the bot's rule and this chat's skip were one menu with two
    /// reaches; now the bot's rule says "Every chat with …" and the skip is its own switch, YOLO ("No prompts in this chat").
    @Test func theTilesSayFastAndApprovals() {
        let sample = ModelPanelModel.debugSample
        var panel = ModelPanelView.debugLaidOut(sample, hostWidth: 402) { $0.bot = ("Hermes", {}) }.panel
        var tiles = panel.debugTiles
        #expect(tiles.fast == "Off" && !tiles.fastLit && tiles.fastEnabled)
        #expect(tiles.approvals == "Smart" && !tiles.warning && tiles.reach == "Every chat with Hermes")
        #expect(!tiles.skip && !tiles.skipWarning && tiles.skipNote == "No prompts in this chat")
        #expect(panel.debugApprovalTitles() == ["[Every chat with Hermes]", "Manual", "Smart ✓", "Off"])
        #expect(panel.debugApprovalLabels.approvals == "Approval Mode, Every chat with Hermes")
        #expect(panel.debugApprovalLabels.skip == "YOLO, No prompts in this chat")
        #expect(panel.debugApprovalLabels.skipValue == "Off", "spoken as Fast's is")
        #expect(panel.debugApprovalLabels.skipTraits.contains(.toggleButton) && !panel.debugApprovalLabels.skipTraits.contains(.notEnabled))
        var offline = sample
        offline.offline = true
        let resting = ModelPanelView.debugLaidOut(offline, hostWidth: 402).panel
        #expect(resting.debugApprovalLabels.skipTraits.contains(.toggleButton))
        #expect(resting.debugDimmed == ["name", "thinking", "fast", "approvals", "skip"], "offline every control reads as dimmed")
        #expect(panel.debugDimmed.isEmpty)
        #expect(ModelPanelView.debugLaidOut(sample, hostWidth: 402).panel.debugTiles.reach == "Every chat with this bot", "no bot name yet")

        panel = ModelPanelView.debugLaidOut(ModelPanelModel.debugCase("yolo")!, hostWidth: 402).panel
        tiles = panel.debugTiles
        #expect(tiles.fast == "On" && tiles.fastLit)
        #expect(tiles.approvals == "Smart" && !tiles.warning, "the bot's rule is unchanged while this chat skips")
        #expect(tiles.skip && tiles.skipWarning)
        #expect(!panel.debugApprovalTitles().contains { $0.hasPrefix("Skip") })

        var other = sample
        other.fastSupported = false
        other.fastOn = false
        other.approvalMode = "off"
        tiles = ModelPanelView.debugLaidOut(other, hostWidth: 402).panel.debugTiles
        #expect(tiles.fast == "Not on this model" && !tiles.fastEnabled && !tiles.fastLit)
        #expect(tiles.approvals == "Off" && tiles.warning)

        other.approvalMode = ""
        #expect(ModelPanelView.debugLaidOut(other, hostWidth: 402).panel.debugTiles.approvals == nil, "not known yet: the name alone")
    }

    /// YOLO is a switch for this chat (/yolo): a tap flips it at once, asks the gateway, and leaves the bot's
    /// rule alone. A long bot name in the Approval Mode note wraps rather than cuts, at every width and text size.
    @Test func skipApprovalsIsThisChatsSwitch() async throws {
        final class Asked { var yolo: [Bool] = []; var modes: [String] = [] }
        let asked = Asked()
        let panel = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402) {
            $0.setYolo = { asked.yolo.append($0) }
            $0.setApprovalMode = { asked.modes.append($0) }
        }.panel
        panel.debugTapSkip()
        #expect(panel.debugTiles.skip && panel.debugTiles.skipWarning)
        for _ in 0..<50 where asked.yolo.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(asked.yolo == [true] && asked.modes.isEmpty)
        #expect(panel.debugTiles.approvals == "Smart")

        var failures: [String] = []
        for size in sizes {
            UITraitCollection(preferredContentSizeCategory: size).performAsCurrent {
                for width in widths {
                    let content = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: width) {
                        $0.bot = ("Northwind Research Assistant", {})
                    }.content
                    for label in fitLabels(in: content) where !(label.attributedText?.string ?? "").isEmpty && !label.debugFitsFrame {
                        failures.append("\(Int(width)) \(size.rawValue): \"\(label.attributedText?.string ?? "")\" spills out of \(label.frame)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// The panel is how this chat thinks, nothing else (owner 2026-11-01 on the cut that held the whole ⋯: "cramming
    /// everything into one thing"): no Prompts (the whole app's), no chat actions (the ⋯'s). The Price and Plan facts
    /// are the way to Model Prices and Usage & Limits (a chevron each, a button to VoiceOver); offline they rest.
    @Test func theFactsOpenPricesAndPlan() {
        let panel = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402).panel
        let facts = Dictionary(panel.debugFacts.map { ($0.title, $0.opens) }, uniquingKeysWith: { a, _ in a })
        #expect(facts["Price"] == true && facts["Plan"] == true, "\(facts)")
        #expect(facts["Context window"] == false && facts["Context used"] == false, "nothing to change it with: a plain fact")
        // [context-window] Where the chat's bot's window can be changed, its fact opens Context Window (owner 2026-11-01
        // had to ask where max context was set).
        let changeable = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402) { $0.openContextWindow = {} }.panel
        let opening = Dictionary(changeable.debugFacts.map { ($0.title, $0.opens) }, uniquingKeysWith: { a, _ in a })
        #expect(opening["Context window"] == true && opening["Context used"] == false, "\(opening)")
        let names = Set(panel.debugPieces.map(\.name))
        #expect(names == ["name", "maker", "chevrons", "face", "facts", "thinking", "settings"], "\(names.sorted())")

        var offline = ModelPanelModel.debugSample
        offline.offline = true
        let rested = ModelPanelView.debugLaidOut(offline, hostWidth: 402).panel.debugFacts
        #expect(!rested.contains { $0.opens }, "offline: the pages need the gateway")
    }

    /// The compact panel (owner 2026-11-01: the face "in the top right because that space is unused", thinking "a lot
    /// less room"): on a 402 pt phone at Large and XL text the whole card fits the room above the bar (593 pt on the
    /// iPhone 17 Pro) with nothing to scroll, the face beside the name and the thinking bar one row.
    @Test func theCompactPanelFitsWithoutScrolling() {
        for size in [UIContentSizeCategory.large, .extraLarge] {
            UITraitCollection(preferredContentSizeCategory: size).performAsCurrent {
                let (panel, _) = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402, floor: 593 + 12)
                let rest = panel.debugResting
                #expect(rest.content <= rest.card, "\(size.rawValue): \(rest)")
                let pieces = Dictionary(uniqueKeysWithValues: panel.debugPieces.map { ($0.name, $0.view.frame) })
                if let face = pieces["face"], let name = pieces["name"], let thinking = pieces["thinking"] {
                    #expect(abs(face.minY - name.minY) <= 4 && face.minX > name.maxX, "the face beside the name, at its top")
                    #expect(thinking.height < 90, "thinking is one slim row (\(thinking.height))")
                }
            }
        }
    }

    /// A tap on the face opens the bot's Bot Info (its default, fallback and auxiliary models): a button named for the
    /// bot when there is one to open, else a picture only.
    @Test func theFaceOpensBotInfo() {
        var opened = 0
        let panel = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402) { actions in
            actions.bot = ("Hermes", { opened += 1 })
        }.panel
        #expect(panel.debugFace.opens && panel.debugFace.label == "Hermes")
        let bare = ModelPanelView.debugLaidOut(ModelPanelModel.debugSample, hostWidth: 402).panel
        #expect(!bare.debugFace.opens, "no Bot Info: the face is only a picture")
        #expect(opened == 0)
    }

    /// The whole matrix: every state × width × text size. Words inside their frames, pieces apart and inside the card,
    /// nothing smaller than half its size.
    @Test func everyPanelFitsEveryPhoneAndTextSize() {
        let all = states()
        var failures: [String] = []
        var smallest: (scale: CGFloat, where: String) = (1, "")
        for size in sizes {
            UITraitCollection(preferredContentSizeCategory: size).performAsCurrent {
                for width in widths {
                    for (name, state) in all {
                        let (panel, content) = ModelPanelView.debugLaidOut(state, hostWidth: width)
                        let place = "\(name) @ \(Int(width)) \(size.rawValue)"
                        let cardWidth = content.bounds.width
                        let pieces = panel.debugPieces
                        for (piece, view) in pieces {
                            // [ui-sizing 2026-11-09] The card's margin is 16 pt (was 20).
                            if view.frame.minX < 15.5 || view.frame.maxX > cardWidth - 15.5 {
                                failures.append("\(place): \(piece) leaves the card's margins \(view.frame)")
                            }
                        }
                        for (i, a) in pieces.enumerated() {
                            for b in pieces[(i + 1)...] where a.view.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.view.frame) {
                                failures.append("\(place): \(a.name) overlaps \(b.name)")
                            }
                        }
                        for label in fitLabels(in: content) where !(label.attributedText?.string ?? "").isEmpty {
                            if !label.debugFitsFrame { failures.append("\(place): \"\(label.attributedText?.string ?? "")\" spills out of \(label.frame)") }
                            let scale = label.fit(width: label.bounds.width).scale
                            // The 47-letter run with no breaks can't be whole and large at 320; it only has to stay inside.
                            let unbreakable = (label.attributedText?.string ?? "").hasPrefix("ThisIsAModelName")
                            if !unbreakable && scale < smallest.scale { smallest = (scale, "\(place): \"\(label.attributedText?.string ?? "")\"") }
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(30).joined(separator: "\n"))")
        #expect(smallest.scale >= 0.5, "smallest words: \(smallest.scale) at \(smallest.where)")
    }

    /// The bubble: every corpus name, in the room it has from a 375 pt iPhone to an iPad. Always one line (owner: two
    /// "would be busy"); the tag, then the filler words, give way before the type shrinks past 86 %. The effort is never
    /// drawn (owner 2026-11-01: "it only shows the model name"), only spoken.
    @Test func theBubbleFitsAnyNameOnOneLine() {
        var failures: [String] = []
        var sizes: [(scale: CGFloat, place: String)] = []
        // The room between ☰ and the mic: 130 pt on a 375 pt iPhone, 157 on a 402 pt one, 190 on a 440 pt one, more
        // on an iPad or the Mac.
        for width: CGFloat in [130, 157, 190, 300] {
            for entry in corpus {
                for effort in ["xhigh", ""] {
                    let name = ModelNames.displayModelName(entry.id)
                    let bare = ModelNames.modelDisplayParts(entry.id).name
                    let chip = ModelChip(frame: .zero)
                    chip.title = ModelChip.Title(name: name, effort: effort.isEmpty ? nil : ModelNames.effortLabel(effort),
                                                 bareName: bare == name ? nil : bare)
                    // As the composer lays it out: fitted to the name, at most the room.
                    let fitted = chip.fittedWidth(in: width, height: 36)
                    if fitted > width { failures.append("\(name) @ \(Int(width)): \(fitted) wide, wider than the room") }
                    chip.frame = CGRect(x: 0, y: 0, width: fitted, height: 36)
                    chip.layoutIfNeeded()
                    let label = chip.debugLabel
                    let fit = label.fit(width: label.bounds.width)
                    let words = label.attributedText?.string ?? ""
                    let place = "\"\(words)\" (\(name), \(effort)) @ \(Int(width))"
                    if !label.debugFitsFrame { failures.append("\(place) spills out") }
                    if fit.lines != 1 { failures.append("\(place) takes \(fit.lines) lines") }
                    if !effort.isEmpty, words.hasSuffix(ModelNames.effortLabel(effort)), !name.hasSuffix(ModelNames.effortLabel(effort)) {
                        failures.append("\(place) draws the effort")
                    }
                    // The name whole whenever it fits the room.
                    let whole = NSAttributedString(string: name, attributes: [.font: HQFont.system(ofSize: 15)])
                    if TextFit.oneLineWidth(whole) * TextFit.oneLineFloor <= label.bounds.width, words != name {
                        failures.append("\(place) shortened a name that fit")
                    }
                    sizes.append((fit.scale, place))
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(30).joined(separator: "\n"))")
        // How small one line gets, for the notes: written beside the tests (the runner's console is quiet).
        let under = sizes.filter { $0.scale < TextFit.oneLineFloor - 0.001 }.sorted { $0.scale < $1.scale }
        let report = (["\(under.count) of \(sizes.count) under 86 %"] + under.map { "\(String(format: "%.1f", $0.scale * 15)) pt  \($0.place)" })
            .joined(separator: "\n")
        try? report.write(toFile: "/tmp/hq-bubble-sizes.txt", atomically: true, encoding: .utf8)
    }

    /// Option B (owner 2026-11-01): the bubble is only as wide as the name, 22 pt either side, never narrower than twice
    /// its height and never wider than its room.
    @Test func theBubbleHugsTheName() {
        let chip = ModelChip(frame: .zero)
        #expect(chip.fittedWidth(in: 157, height: 36) == 0, "no title, no bubble")
        chip.title = ModelChip.Title(name: "Opus 5.5", effort: "High")
        let words = ceil(TextFit.oneLineWidth(NSAttributedString(string: "Opus 5.5", attributes: [.font: HQFont.system(ofSize: 15)])))
        #expect(chip.fittedWidth(in: 157, height: 36) == (words + 44).rounded(), "the name and 22 pt either side")
        chip.title = ModelChip.Title(name: "o3", effort: nil)
        #expect(chip.fittedWidth(in: 157, height: 36) == 72, "a short name keeps a capsule's shape")
        chip.title = ModelChip.Title(name: "Llama 4 Maverick 17B 128E Instruct FP8", effort: nil)
        #expect(chip.fittedWidth(in: 157, height: 36) == 157, "a long name takes the whole room")
        chip.title = ModelChip.Title(name: "Opus 5.5", effort: "High")
        chip.frame = CGRect(x: 0, y: 0, width: chip.fittedWidth(in: 157, height: 36), height: 36)
        chip.layoutIfNeeded()
        #expect(chip.debugLabel.attributedText?.string == "Opus 5.5", "the name alone")
        #expect(chip.accessibilityValue == "Opus 5.5, High", "the effort is still spoken")
    }
}
