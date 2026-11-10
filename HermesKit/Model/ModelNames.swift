// Model and provider names as people read them (spec 1x §2.2): ports of the web's `model-status-label.ts`
// (V:lib/model-status-label.ts:6-234) and `title-menu.ts` (S:ui-chat/title-menu.ts:17-25). Pure functions.

import Foundation

nonisolated enum ModelNames {
    /// Hermes' reasoning levels in ascending order (SH:reasoning-effort.ts:4). `none` is thinking off, not a level.
    static let reasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    /// The scale plus the off state.
    static let reasoningEffortValues = ["none"] + reasoningEfforts
    static let defaultReasoningEffort = "medium"

    /// A profile's configured effort as a `config.set reasoning` value (`normalizeConfigEffort`,
    /// V:app/session/hooks/use-hermes-config.ts:42-54): `false`/"false"/"disabled" → "none"; nil when unset or unreadable.
    static func normalizeConfigEffort(_ value: JSONValue?) -> String? {
        if case .bool(false)? = value { return "none" }
        guard case .string(let raw)? = value else { return nil }
        let effort = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if effort.isEmpty { return nil }
        return effort == "false" || effort == "disabled" ? "none" : effort
    }

    // MARK: Model ids

    /// Text after the last `/`.
    static func modelBaseId(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    private static let variantTags: [(NSRegularExpression, String)] = [
        (rx("-fast$", .caseInsensitive), "Fast"),
        (rx("-flash$", .caseInsensitive), "Flash"),
        (rx("-thinking$", .caseInsensitive), "Thinking"),
        (rx("-preview$", .caseInsensitive), "Preview"),
        (rx("-latest$", .caseInsensitive), "Latest"),
    ]
    private static let quant = rx(#"-(?:UD-)?(Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$"#, .caseInsensitive)
    private static let instructTail = rx(#"-(?:Instruct|Chat)(?:-\d{4})?$"#, .caseInsensitive)
    private static let contextWindow = rx(#"\[(\d+[mk])\]$"#, .caseInsensitive)
    private static let datePin = rx(#"-\d{8}$"#)
    private static let wordStart = rx(#"\b\w"#)
    private static let parameterCount = rx(#"\b(a?)(\d+(?:\.\d+)?)b\b"#, .caseInsensitive)
    private static let vendorCasing: [(NSRegularExpression, String)] = [
        (rx(#"\bDeepseek\b"#), "DeepSeek"), (rx(#"\bGlm\b"#), "GLM"), (rx(#"\bMinimax\b"#), "MiniMax"),
        (rx(#"\bOpenai\b"#), "OpenAI"), (rx(#"\bErnie\b"#), "ERNIE"), (rx(#"\bMimo\b"#), "MiMo"), (rx(#"\bBge\b"#), "BGE"),
        (rx(#"\bVl\b"#), "VL"), (rx(#"\bIt\b"#), "IT"), (rx(#"\bFp8\b"#), "FP8"), (rx(#"\bAi\b"#), "AI"),
    ]
    private static let claudePrefix = rx("^claude-", .caseInsensitive)
    private static let digitHyphenDigit = rx(#"(\d)-(?=\d)"#)
    private static let gptPrefix = rx("^gpt-", .caseInsensitive)
    private static let geminiPrefix = rx("^gemini-", .caseInsensitive)

    /// Upper-cases the first character of every word (JS `\b\w`), then trims.
    static func titleCase(_ text: String) -> String {
        Rx.replace(wordStart, in: text) { match, _ in match.uppercased() }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyVendorCasing(_ text: String) -> String {
        var cased = Rx.replace(parameterCount, in: text) { _, groups in "\(groups[1].uppercased())\(groups[2])B" }
        for (pattern, replacement) in vendorCasing { cased = Rx.replace(pattern, in: cased, with: replacement) }
        return cased
    }

    private static func prettifyBase(_ base: String) -> String {
        if Rx.matches(claudePrefix, base) {
            var s = Rx.replace(claudePrefix, in: base, with: "")
            s = Rx.replace(digitHyphenDigit, in: s, with: "$1.")
            s = s.replacingOccurrences(of: "-", with: " ")
            return applyVendorCasing(titleCase(s))
        }
        if Rx.matches(gptPrefix, base) { return Rx.replace(gptPrefix, in: base, with: "GPT-") }
        if Rx.matches(geminiPrefix, base) {
            let s = Rx.replace(geminiPrefix, in: base, with: "Gemini ").replacingOccurrences(of: "-", with: " ")
            return applyVendorCasing(titleCase(s))
        }
        return applyVendorCasing(titleCase(base.replacingOccurrences(of: "-", with: " ")))
    }

    /// A variant tag and a GGUF quant, in either order (`…-flash-Q4_K_XL`, `…-Q4_K_XL-flash`).
    static func splitTrailingTags(_ input: String) -> (base: String, variant: String, quant: String) {
        var base = input, variant = "", quantLabel = ""
        var progress = true
        while progress {
            progress = false
            if variant.isEmpty {
                for (pattern, label) in variantTags where Rx.matches(pattern, base) {
                    variant = label
                    base = Rx.replace(pattern, in: base, with: "")
                    progress = true
                    break
                }
            }
            if quantLabel.isEmpty, let match = Rx.firstMatch(quant, base) {
                quantLabel = (match.groups[1].split(separator: "_", omittingEmptySubsequences: false).first.map(String.init) ?? "").uppercased()
                base = String(base.dropLast(match.whole.count))
                base = Rx.replace(instructTail, in: base, with: "")
                progress = true
            }
        }
        return (base, variant, quantLabel)
    }

    // [model-panel] Native additions (2026-10-31, owner: "guarantee this works no matter the model and provider someone
    // uses"): the wrappers cloud providers put round a model's own id, which the web's rules read as words
    // ("us.anthropic.claude-3-7-sonnet-20250219-v1:0" → "Us.Anthropic.Claude 3 7 Sonnet 20250219 V1:0"). None of the
    // §2.2 vectors carries one, so they all read as before.
    private static let fineTune = rx(#"^ft:([^:]+):"#)
    private static let routeSuffix = rx(#":(free|beta|extended|nitro|floor|online|thinking|exacto)$"#, .caseInsensitive)
    private static let bedrockVendor = rx(#"^(?:(?:us|eu|apac|ap|au|ca|jp|global|us-gov)\.)?(?:anthropic|amazon|meta|cohere|ai21|mistral|deepseek|qwen|openai|writer|twelvelabs|stability|luma|minimax|moonshot|moonshotai|google|nvidia)\."#, .caseInsensitive)
    private static let bedrockVersion = rx(#"-v\d+(?::\d+)?$"#, .caseInsensitive)
    private static let vertexPin = rx(#"@(?:\d{8}|\d{3}|latest|default)$"#, .caseInsensitive)
    private static let dashedDate = rx(#"-\d{4}-\d{2}-\d{2}$"#)
    private static let ggufWord = rx(#"-GGUF$"#, .caseInsensitive)
    /// A Hugging Face pull's quant after a colon (`unsloth/Qwen3-30B-A3B-GGUF:Q4_K_M`), read as the dashed one.
    private static let colonQuant = rx(#":(?=(?:UD-)?(?:Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$)"#, .caseInsensitive)

    /// The model's own id inside a cloud provider's wrapping, and the tags the wrapping carried: a fine-tune
    /// (`ft:gpt-4o-mini-2024-07-18:acme::9ab` → Fine-tuned), an OpenRouter route (`…:free` → Free), Bedrock's region,
    /// maker and version (`us.anthropic.…-v1:0`), and Vertex's pin (`…@20240620`).
    private static func unwrap(_ id: String) -> (id: String, tags: [String]) {
        var id = id, tags: [String] = []
        if let match = Rx.firstMatch(fineTune, id) {
            id = match.groups[1]
            tags.append("Fine-tuned")
        }
        if let match = Rx.firstMatch(routeSuffix, id) {
            id = String(id.dropLast(match.whole.count))
            tags.append(match.groups[1].prefix(1).uppercased() + match.groups[1].dropFirst().lowercased())
        }
        if Rx.matches(bedrockVendor, id) {
            id = Rx.replace(bedrockVersion, in: Rx.replace(bedrockVendor, in: id, with: ""), with: "")
        }
        id = Rx.replace(vertexPin, in: id, with: "")
        id = Rx.replace(colonQuant, in: id, with: "-")
        return (id, tags)
    }

    /// A clean display name plus an optional tag ("Fast", "Q4", "1M"), so distinct ids don't collapse.
    static func modelDisplayParts(_ model: String) -> (name: String, tag: String) {
        let unwrapped = unwrap(modelBaseId(model))
        var (base, variant, quantLabel) = splitTrailingTags(unwrapped.id)
        var tags = [variant, quantLabel].filter { !$0.isEmpty }
        if let window = Rx.firstMatch(contextWindow, base) {
            tags.append(window.groups[1].uppercased())
            base = String(base.dropLast(window.whole.count))
        }
        tags += unwrapped.tags.filter { !tags.contains($0) }
        base = Rx.replace(datePin, in: base, with: "")
        base = Rx.replace(dashedDate, in: base, with: "")
        base = Rx.replace(ggufWord, in: base, with: "")
        let pretty = prettifyBase(base)
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return (pretty.isEmpty ? (trimmed.isEmpty ? "No model" : trimmed) : pretty, tags.joined(separator: " "))
    }

    /// "Opus 4.5", "GPT-5.5 Fast", "Sonnet 5 1M"; "No model" for "".
    static func displayModelName(_ model: String) -> String {
        // [provider-manager] A name the owner gave this model (Settings › Providers), when it is the only one given it.
        if let own = ProviderPrefs.active.modelName(anyProvider: model) { return own }
        return builtInModelName(model)
    }

    /// [provider-manager] A model's name under one provider: the owner's for it there, else the usual one.
    static func displayModelName(_ model: String, provider: String) -> String {
        ProviderPrefs.active.modelName(provider: provider, model: model) ?? displayModelName(model)
    }

    /// The name made from the id alone (no owner's name): the original a rename goes back to.
    static func builtInModelName(_ model: String) -> String {
        let parts = modelDisplayParts(model)
        return parts.tag.isEmpty ? parts.name : "\(parts.name) \(parts.tag)"
    }

    /// The variant tag a model id carries (Fast, Flash, Thinking, Preview, Latest).
    static func modelVariantTag(_ model: String) -> String {
        splitTrailingTags(modelBaseId(model)).variant
    }

    /// "GPT-5.5 · Fast" — the switch notices' label (`formatModelPillLabel`).
    static func formatModelPillLabel(_ model: String, fastMode: Bool = false) -> String {
        let name = modelDisplayParts(model).name
        let blank = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tag = blank ? "" : (fastMode ? "Fast" : modelVariantTag(model))
        return tag.isEmpty ? name : "\(name) · \(tag)"
    }

    /// The words a name can do without in a narrow place, read whole and in any case: a tuning ("Instruct", "Chat", "It"),
    /// a release number ("2507"), and a format ("FP8", "AWQ", "4bit").
    private static let fillerWord = rx(#"^(?:instruct|chat|it|hf|\d{4}|fp\d+|bf16|nvfp4|int\d+|w\d+a\d+|awq|gptq|gguf|mlx|exl\d|\d+-?bit)$"#, .caseInsensitive)

    /// A name for the model bubble when even the bare name won't fit on its line (owner 2026-10-31: one line only):
    /// the name without its filler words, and without Meta before Llama. "Qwen3 235B A22B Instruct 2507 FP8" →
    /// "Qwen3 235B A22B"; "Meta Llama 3.1 8B Instruct" → "Llama 3.1 8B". The name itself when less than two words
    /// would be left, where the filler is what tells it apart ("DeepSeek Chat" beside "DeepSeek Reasoner").
    static func compactModelName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init).filter { !Rx.matches(fillerWord, $0) }
        if words.count > 1, words[0].lowercased() == "meta", words[1].lowercased().hasPrefix("llama") { words.removeFirst() }
        return words.count < 2 ? name : words.joined(separator: " ")
    }

    // MARK: Providers

    static let providerDisplayNames: [String: String] = [
        "anthropic": "Anthropic Account",
        "claude-code": "Anthropic OAuth: Required Extra Usage Credits to Use Subscription",
        "minimax-oauth": "MiniMax",
        "nous": "Nous Portal",
        "openai-codex": "ChatGPT or Codex Subscription",
        "qwen-oauth": "Qwen Code",
        "xai": "xAI",
        "xai-oauth": "xAI Grok",
    ]

    static func providerDisplayName(_ provider: String) -> String {
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own = ProviderPrefs.active.providerName(trimmed) { return own }   // [provider-manager]
        return providerDisplayNames[trimmed.lowercased()] ?? trimmed
    }

    /// Hermes' own names for its providers (hermes_cli/models_catalog_static.py `CANONICAL_PROVIDERS`, 2026-10-31,
    /// without their notes in brackets), for a model whose provider the catalog hasn't named yet.
    static let hermesProviderNames: [String: String] = [
        "nous": "Nous Portal", "fireworks": "Fireworks AI", "openrouter": "OpenRouter", "moa": "Mixture of Agents",
        "novita": "NovitaAI", "lmstudio": "LM Studio", "anthropic": "Anthropic", "openai-codex": "ChatGPT or Codex Subscription",
        "openai-api": "OpenAI API", "openai": "OpenAI", "alibaba": "Qwen Cloud", "xai-oauth": "xAI Grok OAuth", "xiaomi": "Xiaomi MiMo",
        "tencent-tokenhub": "Tencent TokenHub", "tencent-tokenplan": "Tencent TokenPlan", "nvidia": "NVIDIA NIM",
        "copilot": "GitHub Copilot", "copilot-acp": "GitHub Copilot ACP", "huggingface": "Hugging Face",
        "gemini": "Google AI Studio", "vertex": "Google Vertex AI", "deepseek": "DeepSeek", "xai": "xAI", "zai": "Z.AI / GLM",
        "kimi-coding": "Kimi / Kimi Coding Plan", "kimi-coding-cn": "Kimi / Moonshot", "stepfun": "StepFun Step Plan",
        "minimax": "MiniMax", "minimax-oauth": "MiniMax", "minimax-cn": "MiniMax", "ollama-cloud": "Ollama Cloud",
        "ollama": "Ollama", "arcee": "Arcee AI", "gmi": "GMI Cloud", "kilocode": "Kilo Code", "opencode-zen": "OpenCode Zen",
        "opencode-go": "OpenCode Go", "bedrock": "AWS Bedrock", "azure-foundry": "Azure Foundry",
        "ai-gateway": "Vercel AI Gateway", "qwen-oauth": "Qwen OAuth", "claude-code": "Claude Code", "custom": "Custom endpoint",
    ]

    private static let slugSeparators = rx("[_-]+")

    /// A provider as people read it, given the catalog's name when it has one: that name without its notes, else
    /// Hermes' own name for the slug, else the slug in words ("vertex_ai" → "Vertex AI"). Never the bare slug.
    static func readableProviderName(slug: String, catalogName: String?) -> String {
        let named = plainProviderName(catalogName ?? "")
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty, named != trimmed { return named }
        if let known = hermesProviderNames[trimmed.lowercased()] { return known }
        let words = Rx.matches(bareSlug, trimmed) ? plainProviderName(trimmed)
            : applyVendorCasing(titleCase(Rx.replace(slugSeparators, in: trimmed, with: " ")))
        return words.isEmpty ? (named.isEmpty ? "Provider" : named) : words
    }

    /// A provider's name for a narrow place (a Switch To tile): its first clause, without "Subscription" or "Account"
    /// at the end, and an address as its host. "Anthropic OAuth: Required Extra Usage Credits to Use Subscription" →
    /// "Anthropic OAuth"; "Kimi / Kimi Coding Plan" → "Kimi"; "http://192.168.1.20:8080/v1" → "192.168.1.20:8080".
    static func shortProviderName(_ name: String) -> String {
        var short = plainProviderName(name)
        if let url = URL(string: short), url.scheme != nil, let host = url.host, !host.isEmpty {
            return url.port.map { "\(host):\($0)" } ?? host
        }
        for separator in [": ", " / ", " — ", " – ", " | "] {
            guard let range = short.range(of: separator) else { continue }
            let head = short[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { short = head }
            break
        }
        for word in [" Subscription", " Account"] where short.hasSuffix(word) && short.count > word.count {
            short = String(short.dropLast(word.count))
        }
        return short.isEmpty ? name : short
    }

    private static let bracketGroup = rx(#"\s*[(\[][^)\]]*[)\]]\s*"#)
    private static let sdkWord = rx(#"\b(?:Direct)?SDK\b"#, .caseInsensitive)
    private static let spaces = rx(#"\s+"#)

    private static let bareSlug = rx(#"^[A-Za-z0-9]+(?:[_-]+[A-Za-z0-9]+)+$"#)
    private static let slugNotes: Set<String> = ["sdk", "directsdk", "experimental"]

    /// The catalog's provider name without its build notes: "Claude Subscription DirectSDK (Experimental)" →
    /// "Claude Subscription"; the whole name when nothing would be left. A bare slug reads as Hermes names it, else as
    /// its words without the notes: "claude-subscription-directsdk-experimental" → "Claude Subscription" (owner
    /// 2026-11-01, build 581: cutting "DirectSDK" out of the slug itself drew "claude-subscription- -experimental").
    static func plainProviderName(_ name: String) -> String {
        let bare = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if Rx.matches(bareSlug, bare) {
            if let known = hermesProviderNames[bare.lowercased()] { return known }
            let words = bare.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            let kept = words.filter { !slugNotes.contains($0.lowercased()) }
            return applyVendorCasing(titleCase((kept.isEmpty ? words : kept).joined(separator: " ")))
        }
        var plain = Rx.replace(bracketGroup, in: name, with: " ")
        plain = Rx.replace(sdkWord, in: plain, with: " ")
        plain = Rx.replace(spaces, in: plain, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : plain
    }

    // MARK: Reasoning

    private static let effortNames = ["none": "Off", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High",
                                      "xhigh": "Extra High", "max": "Max", "ultra": "Ultra"]
    private static let separators = rx("[_-]+")

    /// "Off", "Extra High"; anything else in words ("extra_deep" → "Extra Deep").
    static func effortLabel(_ level: String) -> String {
        if let known = effortNames[level] { return known }
        return Rx.replace(wordStart, in: Rx.replace(separators, in: level, with: " ")) { match, _ in match.uppercased() }
    }

    private static let effortShortNames = ["none": "Off", "minimal": "Min", "low": "Low", "medium": "Med", "high": "High",
                                           "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"]

    /// The composer bubble's short form when the long one doesn't fit ("Med", "XHigh").
    static func effortShortLabel(_ level: String) -> String { effortShortNames[level] ?? effortLabel(level) }

    // MARK: Current pick

    /// Which pair a picker marks current (`currentPickerSelection`): the chat's own complete pair, else the catalog's,
    /// else whichever parts exist.
    static func currentPickerSelection(store: (model: String, provider: String), options: (model: String, provider: String)?)
        -> (model: String, provider: String) {
        if !store.model.isEmpty && !store.provider.isEmpty { return store }
        if let options, !options.model.isEmpty, !options.provider.isEmpty { return options }
        return (store.model.isEmpty ? (options?.model ?? "") : store.model,
                store.provider.isEmpty ? (options?.provider ?? "") : store.provider)
    }
}

// MARK: - Regex helpers (ICU, used like JavaScript's String.replace)

nonisolated private func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Patterns are literals in this file: a bad one is a programming error caught by the unit tests.
    try! NSRegularExpression(pattern: pattern, options: options)
}

nonisolated enum Rx {
    struct Match {
        var whole: String
        /// Capture groups by index (0 = the whole match); "" for a group that didn't take part.
        var groups: [String]
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func firstMatch(_ regex: NSRegularExpression, _ text: String) -> Match? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return match(m, in: text)
    }

    private static func match(_ m: NSTextCheckingResult, in text: String) -> Match {
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location != NSNotFound, let range = Range(r, in: text) { groups.append(String(text[range])) } else { groups.append("") }
        }
        return Match(whole: groups.first ?? "", groups: groups)
    }

    /// Template replacement (`$1` refers to a group), every match.
    static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replacement computed per match (JavaScript's replace with a function), every match.
    static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String, [String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let found = match(m, in: text)
            out += transform(found.whole, found.groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
