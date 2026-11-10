// ⋯ › Model Prices: what each model of the signed-in providers costs per million tokens. The gateway's own prices first
// (`model.options` rows' `pricing`, H:hermes_cli/inventory.py `_apply_pricing`: OpenRouter, Nous, endpoints that serve
// them); a provider it has none for (Anthropic, OpenAI, Google… direct) takes the list prices Hermes itself bills by,
// models.dev's catalog (H:agent/usage_pricing.py `_models_dev_pricing_entry`). Subscriptions say "Included".

import Foundation

/// One model's prices as the gateway formats them (`ModelPricing`): "$3.00", "free", or "" when unknown.
nonisolated struct ModelPrice: Hashable, Sendable {
    var input: String
    var output: String
    var cache: String?
    var free: Bool

    init(input: String, output: String, cache: String? = nil, free: Bool = false) {
        self.input = input; self.output = output; self.cache = cache; self.free = free
    }

    init?(json: JSONValue) {
        guard json.object != nil else { return nil }
        input = json["input"]?.string ?? ""
        output = json["output"]?.string ?? ""
        cache = json["cache"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        free = json["free"]?.bool ?? false
    }

    /// Per-million prices in dollars, formatted as the gateway does (`_format_price_per_mtok`).
    init(perMillionInput: Double?, output: Double?, cacheRead: Double?) {
        self.input = perMillionInput.map(Self.format) ?? ""
        self.output = output.map(Self.format) ?? ""
        self.cache = cacheRead.flatMap { $0 > 0 ? Self.format($0) : nil }
        self.free = perMillionInput == 0 && (output ?? 0) == 0
    }

    /// "$3.00"; "free" at 0; below a cent, as many places as it takes to show a digit ("$0.0042").
    static func format(_ perMillion: Double) -> String {
        guard perMillion.isFinite, perMillion > 0 else { return "free" }
        if perMillion >= 0.01 { return "$" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), perMillion) }
        var places = 3
        while places < 12, (perMillion * pow(10, Double(places))).rounded() == 0 { places += 1 }
        var text = String(format: "%.\(min(places + 1, 12))f", locale: Locale(identifier: "en_US_POSIX"), perMillion)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "$" + text
    }

    var known: Bool { free || !input.isEmpty || !output.isEmpty }

    /// "$3.00 in · $15.00 out · $0.30 cached", "Free".
    var line: String {
        if free { return "Free" }
        var parts: [String] = []
        if !input.isEmpty { parts.append("\(input == "free" ? "Free" : input) in") }
        if !output.isEmpty { parts.append("\(output == "free" ? "Free" : output) out") }
        if let cache { parts.append("\(cache) cached") }
        return parts.joined(separator: " · ")
    }
}

/// One model on the page.
nonisolated struct PriceRow: Hashable, Sendable, Identifiable {
    var id: String
    var model: String
    var name: String
    /// "$3.00 in · $15.00 out", "Included", "No price listed".
    var detail: String
    var priced: Bool
    var current: Bool
}

/// One provider on the page.
nonisolated struct PriceSection: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var rows: [PriceRow]
    /// Under the section: where the prices come from, or why there are none.
    var footer: String?
}

nonisolated enum ModelPricesModel {
    static let perMillion = "Per million tokens."
    static let noPrice = "No price listed"
    static let included = "Included"

    /// Plans paid by subscription, not by the token (H:agent/usage_pricing.py `subscription_included`, and the other
    /// sign-in-with-your-plan routes): their models say "Included".
    static func isSubscription(_ slug: String) -> Bool {
        let s = slug.lowercased()
        return s == "openai-codex" || s == "copilot" || s == "copilot-acp" || s.hasSuffix("-oauth") || s.hasPrefix("claude-subscription")
            || s == "claude-code" || s == "moa"
    }

    /// What a section needing list prices says when models.dev couldn't be reached.
    static let fallbackFailedFooter = "Couldn’t reach models.dev for list prices."

    /// The sections, the chat's provider first; `fallback` fills providers the gateway has no prices for.
    /// `fallbackFailed`: models.dev was asked and couldn't be reached (with nothing kept), so the sections it would
    /// have filled say so rather than looking like models with no price.
    static func sections(_ options: ModelOptions, fallback: ModelsDevPrices?, fallbackFailed: Bool = false, query: String = "",
                         current: (model: String, provider: String)?) -> [PriceSection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [PriceSection] = []
        for row in options.providers where row.authenticated != false && !row.models.isEmpty {
            let title = UsageLimitsModel.providerTitle(row)
            let subscription = isSubscription(row.slug) || row.plan != nil
            let listed = !subscription && row.pricing.isEmpty ? fallback?.prices(provider: row.slug, models: row.models) ?? [:] : [:]
            var twins: [String: Int] = [:]   // one row per id or display name, as on the Model sheet
            var rows: [PriceRow] = []
            for id in row.models {
                let name = ModelNames.displayModelName(id)
                if !words.isEmpty {
                    let text = "\(id) \(name) \(title) \(row.slug)".lowercased()
                    if !words.allSatisfy({ text.contains($0) }) { continue }
                }
                let price = row.pricing[id] ?? listed[id]
                let detail = subscription ? included : (price?.known == true ? price!.line : noPrice)
                let isCurrent = current.map { $0.model == id && row.matches($0.provider) } ?? false
                let priceRow = PriceRow(id: "\(row.slug)::\(id)", model: id, name: name.isEmpty ? id : name, detail: detail,
                                        priced: subscription || price?.known == true, current: isCurrent)
                let keys = ["id:" + id, "name:" + priceRow.name.lowercased()]
                if let twin = keys.lazy.compactMap({ twins[$0] }).first {
                    // The chat's model wins its name's place, then a priced row over an unpriced one.
                    let held = rows[twin]
                    if (isCurrent && !held.current) || (!held.current && priceRow.priced && !held.priced) { rows[twin] = priceRow }
                } else {
                    for key in keys { twins[key] = rows.count }
                    rows.append(priceRow)
                }
            }
            guard !rows.isEmpty else { continue }
            let footer: String?
            if subscription {
                footer = row.plan != nil ? "Included in your plan’s allowance (see Usage & Limits)." : "Included with your subscription."
            } else if !row.pricing.isEmpty {
                footer = perMillion
            } else if !listed.isEmpty {
                footer = "\(perMillion) List prices from models.dev."
            } else if row.pricingPending {
                footer = "Prices are still loading on \(HostWord.phrase)."
            } else if fallbackFailed, fallback == nil, ModelsDevPrices.catalogId(for: row.slug) != nil {
                footer = fallbackFailedFooter
            } else {
                footer = nil
            }
            out.append(PriceSection(id: row.slug, title: title, rows: rows, footer: footer))
        }
        guard let current else { return out }
        return out.filter { options.row(matching: current.provider)?.slug == $0.id }
            + out.filter { options.row(matching: current.provider)?.slug != $0.id }
    }

    /// Providers whose prices only models.dev knows (so the page asks it): signed in, paid by the token, none from
    /// the gateway, and named in the map.
    static func needsFallback(_ options: ModelOptions) -> Bool {
        options.providers.contains { row in
            row.authenticated != false && !row.models.isEmpty && row.pricing.isEmpty && row.plan == nil
                && !isSubscription(row.slug) && ModelsDevPrices.catalogId(for: row.slug) != nil
        }
    }

    /// The gateway warms its prices in the background after a read: a priced-by-the-gateway provider with none yet is
    /// asked once more a moment later.
    static func worthAskingAgain(_ options: ModelOptions) -> Bool {
        options.providers.contains { row in
            row.authenticated != false && row.pricing.isEmpty && row.plan == nil
                && (row.pricingPending || row.slug == "openrouter" || row.slug == "nous" || row.slug.hasPrefix("custom"))
        }
    }

    /// The ⋯ row's subtitle: the chat's model's price ("$5.00 in · $25.00 out"), "Included", or nil. `fallback`: the
    /// models.dev list prices already on the device, for a provider Hermes doesn't price (as the page does).
    static func menuSubtitle(_ options: ModelOptions?, model: String, provider: String, fallback: ModelsDevPrices? = nil) -> String? {
        guard let options, let row = options.row(matching: provider) else { return nil }
        if isSubscription(row.slug) || row.plan != nil { return included }
        let listed = row.pricing.isEmpty ? fallback?.prices(provider: row.slug, models: [model])[model] : nil
        guard let price = row.pricing[model] ?? listed, price.known else { return nil }
        if price.free { return "Free" }
        return [price.input.isEmpty ? nil : "\(price.input) in", price.output.isEmpty ? nil : "\(price.output) out"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - models.dev

/// models.dev's list prices (https://models.dev/api.json, the catalog Hermes bills direct providers by), reduced to
/// what the page reads: per provider, per model, dollars per million tokens.
nonisolated struct ModelsDevPrices: Sendable {
    nonisolated struct Cost: Codable, Sendable, Hashable {
        var input: Double?
        var output: Double?
        var cache_read: Double?
        /// The model's context window in tokens (models.dev's `limit.context`); the composer's model panel shows it.
        var context: Int?
    }

    private nonisolated struct Limit: Decodable { var context: Double? }
    private nonisolated struct Model: Decodable { var cost: Cost?; var limit: Limit? }
    private nonisolated struct Provider: Decodable { var models: [String: Model]? }

    /// [models.dev provider id: [model id: cost]]
    var costs: [String: [String: Cost]]

    init(costs: [String: [String: Cost]]) { self.costs = costs }

    /// The catalog file as models.dev serves it; nil when it isn't one.
    init?(data: Data) {
        guard let providers = try? JSONDecoder().decode([String: Provider].self, from: data) else { return nil }
        var costs: [String: [String: Cost]] = [:]
        for (id, provider) in providers {
            var models: [String: Cost] = [:]
            for (model, value) in provider.models ?? [:] {
                var cost = value.cost ?? Cost()
                if let context = value.limit?.context, context.isFinite, context > 0 { cost.context = Int(context) }
                if cost.input != nil || cost.output != nil || cost.context != nil { models[model] = cost }
            }
            if !models.isEmpty { costs[id] = models }
        }
        guard !costs.isEmpty else { return nil }
        self.costs = costs
    }

    /// The reduced catalog as stored on the device (a few hundred KB, not the 6 MB file).
    func encoded() -> Data? { try? JSONEncoder().encode(costs) }

    static func decodeStored(_ data: Data) -> ModelsDevPrices? {
        (try? JSONDecoder().decode([String: [String: Cost]].self, from: data)).map(ModelsDevPrices.init(costs:))
    }

    /// Hermes's provider ids as models.dev names them (H:agent/models_dev.py `PROVIDER_TO_MODELS_DEV`).
    static let catalogIds: [String: String] = [
        "openrouter": "openrouter", "novita": "novita-ai", "anthropic": "anthropic", "openai": "openai", "openai-api": "openai",
        "zai": "zai", "kimi": "kimi-for-coding", "kimi-coding": "kimi-for-coding", "moonshot": "kimi-for-coding",
        "stepfun": "stepfun", "kimi-coding-cn": "kimi-for-coding", "minimax": "minimax", "minimax-cn": "minimax-cn",
        "deepseek": "deepseek", "alibaba": "alibaba", "ai-gateway": "vercel", "opencode-zen": "opencode",
        "opencode-go": "opencode-go", "kilocode": "kilo", "fireworks": "fireworks-ai", "huggingface": "huggingface",
        "gemini": "google", "google": "google", "xai": "xai", "xiaomi": "xiaomi", "nvidia": "nvidia", "meta-ai": "meta",
        "meta": "meta", "groq": "groq", "mistral": "mistral", "togetherai": "togetherai", "together": "togetherai",
        "perplexity": "perplexity", "cohere": "cohere", "ollama-cloud": "ollama-cloud",
    ]

    static func catalogId(for slug: String) -> String? { catalogIds[slug.lowercased()] }

    /// List prices for a provider's models: the id as is, then without a vendor prefix ("anthropic/claude-…"), then
    /// without a context suffix ("claude-opus-5-5[1m]").
    func prices(provider slug: String, models: [String]) -> [String: ModelPrice] {
        guard let table = table(slug) else { return [:] }
        var out: [String: ModelPrice] = [:]
        for model in models {
            guard let cost = Self.entry(table, model) else { continue }
            let price = ModelPrice(perMillionInput: cost.input, output: cost.output, cacheRead: cost.cache_read)
            if price.known { out[model] = price }
        }
        return out
    }

    /// The model's context window in tokens, matched as `prices` matches; a provider models.dev doesn't name (a
    /// subscription's, Nous's) reads the first maker that lists the same id. nil when nobody lists it.
    func contextWindow(provider slug: String, model: String) -> Int? {
        if let own = table(slug).flatMap({ Self.entry($0, model) })?.context { return own }
        for id in ["anthropic", "openai", "google", "xai", "deepseek", "mistral", "openrouter"] {
            if let found = table(id).flatMap({ Self.entry($0, model) })?.context { return found }
        }
        return nil
    }

    /// Whether any model has its context window (a copy stored before they were kept has none).
    var hasContextWindows: Bool { costs.values.contains { $0.values.contains { $0.context != nil } } }

    private func table(_ slug: String) -> [String: Cost]? {
        guard let id = Self.catalogId(for: slug), let table = costs[id] else { return nil }
        return Dictionary(table.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private static func entry(_ lower: [String: Cost], _ model: String) -> Cost? {
        let bare = String(model.split(separator: "/").last ?? Substring(model))
        let noSuffix = bare.replacingOccurrences(of: #"\[[^\]]*\]$"#, with: "", options: .regularExpression)
        return [model, bare, noSuffix].lazy.compactMap { lower[$0.lowercased()] }.first
    }
}

/// The device's copy of models.dev's prices: kept a day in Caches (reduced to the costs), fetched when missing or old;
/// an old copy answers when a fetch fails. ⋯ › Model Prices asks for providers the gateway can't price; the composer's
/// model panel asks for context windows.
@MainActor final class ModelsDevCache {
    static let shared = ModelsDevCache()
    static let url = URL(string: "https://models.dev/api.json")!
    static let freshFor: TimeInterval = 24 * 3600

    private var memory: (prices: ModelsDevPrices, at: Date)?
    private var inFlight: Task<ModelsDevPrices?, Never>?

    private var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("models-dev-prices.json")
    }

    /// What the device has now (memory, else the file), with no network.
    func stored() -> ModelsDevPrices? {
        if let memory { return memory.prices }
        guard let data = try? Data(contentsOf: file), let prices = ModelsDevPrices.decodeStored(data) else { return nil }
        let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        // A copy from before context windows were kept is fetched again on the next load.
        memory = (prices, prices.hasContextWindows ? at : .distantPast)
        return prices
    }

    /// The prices, fetched when there are none or they are a day old.
    func load() async -> ModelsDevPrices? {
        let old = stored()
        if let memory, Date().timeIntervalSince(memory.at) < Self.freshFor { return memory.prices }
        if let inFlight { return await inFlight.value ?? old }
        let file = self.file, url = Self.url
        let task = Task<ModelsDevPrices?, Never>.detached(priority: .utility) {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let prices = ModelsDevPrices(data: data) else { return nil }
            if let reduced = prices.encoded() { try? reduced.write(to: file, options: .atomic) }
            return prices
        }
        inFlight = task
        let fresh = await task.value
        inFlight = nil
        if let fresh { memory = (fresh, Date()) } else { AppLog.note("menus", "model prices: models.dev didn’t answer") }
        return fresh ?? old
    }
}
