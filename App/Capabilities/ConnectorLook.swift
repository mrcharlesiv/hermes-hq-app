// [connectors-ux] The pieces every Connectors row and page share (owner 2026-10-31: "The connectors page needs a lot
// of UI UX work"): one status line (a coloured dot, then the words), one header for a connector's, a catalog app's and
// a managed app's page, and one stand-in for a missing logo (a symbol on a quiet tile, never a letter:
// `mem:composio-connectors.md`, "never letter tiles").

import SwiftUI
import UIKit

/// How a connector is doing, as the dot (and, for trouble, the words) show it.
enum ConnectorTone {
    case good, quiet, busy, warn, bad

    var dot: Color {
        switch self {
        case .good: .green
        case .quiet: Color.hqLabel3
        case .busy: .gray
        case .warn: .orange
        case .bad: .red
        }
    }

    /// Trouble is said in its colour; everything else in the row's second ink.
    var words: Color {
        switch self {
        case .warn: .orange
        case .bad: .red
        default: Color.hqLabel2
        }
    }

    var isTrouble: Bool { self == .warn || self == .bad }

    static func of(_ server: McpServer) -> ConnectorTone {
        if !server.enabled { return .quiet }
        if ServerIssues.kind(of: server) == .needsAuth { return .warn }
        switch server.status {
        case "connected": return .good
        case "failed": return .bad
        case "connecting": return .busy
        default: return .quiet
        }
    }

    static func of(_ app: ManagedApp, connecting: Bool = false) -> ConnectorTone {
        if connecting { return .warn }
        switch app.state {
        case .connected: return .good
        case .broken: return .bad
        case .expired, .connecting: return .warn
        default: return .quiet
        }
    }
}

/// "● Connected · 12 tools": the row's second line.
struct ConnectorStatusLine: View {
    var words: String
    var tone: ConnectorTone
    /// The dot grows with the words, up to 10 pt.
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 7

    var body: some View {
        let dot = min(side, 10)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(tone.dot).frame(width: dot, height: dot)
                // centred on the first line's lowercase letters, not sitting on its baseline
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + dot * 0.32 }
                .accessibilityHidden(true)
            Text(words).font(Font.hq(.subheadline)).foregroundStyle(tone.words)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The state word in a tinted capsule, for a page's header.
struct ConnectorStateBadge: View {
    var words: String
    var tone: ConnectorTone

    var body: some View {
        let tint = tone == .quiet || tone == .busy ? Color.hqLabel2 : tone.dot
        Text(words).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// The top of a connector's, a catalog app's or a managed app's page: its logo, its name, its state and where it comes
/// from, and what it does. One layout for the three, so they read as one family.
struct ConnectorHeader<Logo: View>: View {
    var title: String
    var state: (words: String, tone: ConnectorTone)?
    /// Where it comes from ("Managed", "From the Browser plugin", "Hermes app catalog").
    var kind: String?
    var description: String = ""
    var stateID = "connector-header-state"
    @ViewBuilder var logo: () -> Logo

    var body: some View {
        Section {
            // One row: what it does sits under the name and logo, not in a row of its own under a rule that started
            // at the name.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    logo()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(Font.hq(.title3).weight(.bold)).foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        if state != nil || kind != nil {
                            // A long kind goes under the badge rather than squeezing it.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { badge; kindText }
                                VStack(alignment: .leading, spacing: 4) { badge; kindText }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !description.isEmpty {
                    Text(description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var badge: some View {
        if let state { ConnectorStateBadge(words: state.words, tone: state.tone).accessibilityIdentifier(stateID) }
    }

    @ViewBuilder private var kindText: some View {
        if let kind { Text(kind).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).lineLimit(1) }
    }
}

/// A connector with no logo of its own: a symbol for what it does (a folder for files, a globe for a browser), else the
/// Connectors plug, on a quiet tile. The same on the iPhone and the Mac.
struct ConnectorSymbolTile: View {
    var name: String
    /// A symbol of its own (More Ways to Connect's rows); else one read from the name.
    var symbol: String? = nil
    var size: CGFloat = 34

    var body: some View {
        let size = HQFont.scaled(self.size)   // [ui-sizing] × UI Scale, as the row's text beside it
        Image(systemName: symbol ?? ConnectorSymbol.of(name))
            .font(Font.system(size: size * 0.46, weight: .regular))
            .foregroundStyle(Color.hqLabel2)
            .frame(width: size, height: size)
            .background(Color.hqFill3, in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

enum ConnectorSymbol {
    /// Words in a connector's name and the symbol each one suggests; the first that appears wins.
    private static let words: [(String, String)] = [
        ("browser", "globe"), ("chrome", "globe"), ("web", "globe"), ("fetch", "arrow.down.circle"),
        ("file", "folder"), ("drive", "folder"), ("memory", "brain"), ("terminal", "terminal"), ("shell", "terminal"),
        ("git", "arrow.triangle.branch"), ("sql", "cylinder"), ("postgres", "cylinder"), ("database", "cylinder"),
        ("db", "cylinder"), ("time", "clock"), ("calendar", "calendar"), ("mail", "envelope"), ("search", "magnifyingglass"),
        ("map", "map"), ("weather", "cloud.sun"), ("image", "photo"), ("photo", "photo"), ("voice", "waveform"),
        ("audio", "waveform"), ("note", "note.text"), ("think", "brain"),
    ]

    static func of(_ name: String) -> String {
        let lower = name.lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // A short word counts only at either end of one of the name's words ("github", "mysql", "duckdb"), not inside
        // one ("digital", "feedback", "runtime").
        func has(_ word: String) -> Bool {
            word.count > 4 ? lower.contains(word) : tokens.contains { $0.hasPrefix(word) || $0.hasSuffix(word) }
        }
        return words.first { has($0.0) }?.1 ?? "powerplug"
    }
}

extension McpCatalogEntry {
    /// The description without the name it often starts with ("GitLab: issues, merge requests…" → "Issues, merge
    /// requests…"): the row already says whose it is.
    var shortDescription: String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [title, DisplayName.title(name)] where !prefix.isEmpty {
            for joiner in [": ", " — ", " - "] where text.lowercased().hasPrefix((prefix + joiner).lowercased()) {
                let rest = String(text.dropFirst(prefix.count + joiner.count))
                return rest.prefix(1).uppercased() + rest.dropFirst()
            }
        }
        return text
    }
}

/// "See All Apps   64 ›": the row under a short list that opens the whole one (Popular's, Managed Apps').
struct BrowseRowLabel: View {
    var title: String
    var count: Int

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.hqTint)
            Spacer()
            Text("\(count)").foregroundStyle(Color.hqLabel2)
            SettingsChevron()
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
