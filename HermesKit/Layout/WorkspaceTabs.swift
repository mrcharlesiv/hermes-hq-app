import Foundation

/// Pure state & persistence rules for browser-style workspace tabs on Mac:
/// - Opened sessions and bot chats append on the right and stay until explicitly closed (no auto-eviction cap).
/// - Closing the active tab selects the neighboring tab (right if present, otherwise left; nil if last tab).
/// - Closing an inactive tab leaves the current view untouched.
/// - Open tabs persist per gateway account across app launches.
nonisolated public struct WorkspaceTabRecord: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case session
        case bot
    }

    public var kind: Kind
    public var profile: String
    public var id: String
    public var title: String

    public init(kind: Kind, profile: String, id: String, title: String) {
        self.kind = kind
        self.profile = profile
        self.id = id
        self.title = title
    }

    public var tabId: String {
        switch kind {
        case .session: "session:\(profile):\(id)"
        case .bot: "bot:\(id)"
        }
    }
}

nonisolated public struct WorkspaceTabList: Equatable, Sendable {
    public private(set) var tabs: [WorkspaceTabRecord]

    public init(tabs: [WorkspaceTabRecord] = []) {
        self.tabs = tabs
    }

    /// Ensures `record` is present in the strip. If already open, updates its title in place without moving it;
    /// otherwise appends it on the right (stable spatial order, no cap).
    @discardableResult
    public mutating func open(_ record: WorkspaceTabRecord) -> Bool {
        if let idx = tabs.firstIndex(where: { $0.tabId == record.tabId }) {
            if !record.title.isEmpty, tabs[idx].title != record.title {
                tabs[idx].title = record.title
                return true
            }
            return false
        }
        tabs.append(record)
        return true
    }

    /// Updates title in place for an already-open tab. Returns true if changed.
    @discardableResult
    public mutating func updateTitle(tabId: String, title: String) -> Bool {
        guard !title.isEmpty, let idx = tabs.firstIndex(where: { $0.tabId == tabId }), tabs[idx].title != title else {
            return false
        }
        tabs[idx].title = title
        return true
    }

    /// Closes the tab with `tabId`. When closing the active tab, returns the adjacent tab to activate next
    /// (the tab that shifts into the same slot on the right, or the tab to its left if it was rightmost, or nil if empty).
    public mutating func close(tabId: String, activeTabId: String?) -> (removed: Bool, nextActive: WorkspaceTabRecord?) {
        guard let idx = tabs.firstIndex(where: { $0.tabId == tabId }) else {
            return (false, nil)
        }
        tabs.remove(at: idx)
        guard activeTabId == tabId else {
            return (true, nil)
        }
        guard !tabs.isEmpty else {
            return (true, nil)
        }
        let nextIdx = idx < tabs.count ? idx : tabs.count - 1
        return (true, tabs[nextIdx])
    }

    /// Closes every tab except `tabId`. Returns true if any tab was removed.
    @discardableResult
    public mutating func closeOthers(keeping tabId: String) -> Bool {
        let before = tabs.count
        tabs.removeAll { $0.tabId != tabId }
        return tabs.count != before
    }

    /// Closes every tab to the right of `tabId`. Returns true if any tab was removed.
    @discardableResult
    public mutating func closeToRight(of tabId: String) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.tabId == tabId }), idx + 1 < tabs.count else {
            return false
        }
        tabs.removeSubrange((idx + 1)...)
        return true
    }

    /// Closes all open tabs. Returns true if any tab was removed.
    @discardableResult
    public mutating func closeAll() -> Bool {
        guard !tabs.isEmpty else { return false }
        tabs.removeAll()
        return true
    }

    // MARK: - Persistence (per gateway)

    public static let storagePrefix = "HQMacWorkspaceTabs."

    public static func storageKey(for gatewayId: String?) -> String {
        let clean = (gatewayId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return storagePrefix + (clean.isEmpty ? "default" : clean)
    }

    public static func load(gatewayId: String?, defaults: UserDefaults = .standard) -> WorkspaceTabList {
        let key = storageKey(for: gatewayId)
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WorkspaceTabRecord].self, from: data) else {
            return WorkspaceTabList()
        }
        // Deduplicate defensively while preserving order.
        var seen = Set<String>()
        let unique = decoded.filter { seen.insert($0.tabId).inserted }
        return WorkspaceTabList(tabs: unique)
    }

    public func save(gatewayId: String?, defaults: UserDefaults = .standard) {
        let key = Self.storageKey(for: gatewayId)
        if tabs.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: key)
        }
    }
}
