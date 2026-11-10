// A new bot's identity (spec 1x-settings §8.1–8.2): the profile id from the typed name, the display title, the
// description line and the SOUL it is born with. Ported from `HB/labels.ts` (slugify, slugifyProfileName,
// botProfileIdentity, displayName) and `HB/soul.ts` (composeSoul, messagingProtocolSection). Pure.

import Foundation

nonisolated enum BotIdentity {
    /// `hermes_cli.profiles._PROFILE_ID_RE`.
    static let profileIdPattern = JSRegex(#"^[a-z0-9][a-z0-9_-]{0,63}$"#)

    /// `slugify(value, max)`: lower-case, runs of anything but `[a-z0-9_-]` → "-", no leading or trailing "-".
    static func slugify(_ value: String, max: Int = 64) -> String {
        var out = ""
        var dash = false
        for scalar in value.lowercased().unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_" || scalar == "-"
            if ok { out.unicodeScalars.append(scalar); dash = false }
            else if !dash { out.append("-"); dash = true }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(max))
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// The profile id Hermes accepts (ASCII only) from whatever was typed: accented Latin folds to its base letters,
    /// every other letter or digit becomes `u<hex>` per NFC code point, cut at 64 on a token boundary.
    static func slugifyProfileName(_ value: String) -> String {
        var folded = ""
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard isLetterOrNumber(scalar) else { folded.unicodeScalars.append(scalar); continue }
            let base = String(String(scalar).decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !isMark($0) }
                .map(Character.init))
            let ascii = !base.isEmpty && base.unicodeScalars.allSatisfy {
                ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9")
            }
            folded += ascii ? base : "-u\(String(scalar.value, radix: 16))-"
        }
        // `.replace(/-+/g, '-')`
        var collapsed = ""
        for ch in folded where !(ch == "-" && collapsed.hasSuffix("-")) { collapsed.append(ch) }
        let slug = slugify(collapsed, max: Int.max)
        guard slug.count > 64 else { return slug }
        let chars = Array(slug)
        let cut = String(chars[0..<64])
        let boundary = chars[64] == "-" ? 64 : (cut.lastIndex(of: "-").map { cut.distance(from: cut.startIndex, to: $0) } ?? -1)
        var result = boundary > 0 ? String(chars[0..<boundary]) : cut
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    /// The typed Name split into the backend id and the display title: a non-ASCII name survives as the title when
    /// Title was left empty.
    static func profileIdentity(name: String, title: String) -> (slug: String, title: String) {
        let entered = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonASCII = entered.unicodeScalars.contains { $0.value < 0x20 || $0.value > 0x7E }
        return (slugifyProfileName(entered), !typedTitle.isEmpty ? typedTitle : (nonASCII ? entered : ""))
    }

    static func isValidProfileId(_ slug: String) -> Bool { !slug.isEmpty && profileIdPattern.test(slug) }

    /// `[title, description].filter(Boolean).join(" — ")`: the profile's description line.
    static func descriptionText(title: String, description: String) -> String {
        [title, description.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// `displayName({name, title})` (`HB/labels.ts:60-62`): the title, else the name with `-`/`_` runs as spaces and
    /// each word's first character upper-cased (`\b\w`).
    static func displayName(name: String, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" { return "Hermes" }
        return RosterRules.titleCase(name)
    }

    /// `composeSoul` for a new bot. `serverInjectsProtocol` is the last full roster's `bot_mode_protocol` (current
    /// gateways say true; the teammate section is then left out).
    static func composeSoul(slug: String, title: String, description: String, serverInjectsProtocol: Bool,
                            teammates: [(name: String, description: String?)] = []) -> String {
        let shown = displayName(name: slug, title: title)
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines: [String?] = [
            "# \(shown)",
            "",
            title.isEmpty ? nil : "**Role:** \(title)",
            desc.isEmpty ? nil : "**Mission:** \(desc)",
            "",
            "You are \(shown), a persistent named agent (profile `\(slug)`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions.",
        ]
        let identity = lines.compactMap { $0 }.joined(separator: "\n")
        return serverInjectsProtocol ? identity : identity + "\n\n" + messagingProtocolSection(slug, teammates: teammates)
    }

    /// `messagingProtocolSection` (`HB/soul.ts:19-66`), verbatim.
    static func messagingProtocolSection(_ name: String, teammates: [(name: String, description: String?)]) -> String {
        let others = teammates.filter { $0.name != name }
        let handle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default" ? "hermes" : name
        var lines = [
            "## Messaging other agents",
            "",
            "You work alongside other named agents. Every agent (including you) has",
            "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
            "so it always exists. Agent-to-agent messages are delivered straight",
            "into it, like a DM. To message a teammate, run:",
            "",
            "```",
            "hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from \u{1F916} " + handle
                + " (@" + handle + "): your message\"",
            "",
            "Run the send with background=true and notify_on_complete=true on the",
            "terminal tool, then finish your turn — the reply arrives later as a",
            "background process notification. Never block waiting for it.",
            "```",
            "",
            "(`--in ~ -c \"Bot Chat\" --create-if-missing` resumes their canonical",
            "conversation in the home workspace, creating it if the target has no",
            "\"Bot Chat\" yet. `-Q` keeps output clean. Always open with the",
            "\"Message from \u{1F916} " + handle + " (@" + handle + "):\" prefix so they know",
            "who is talking (the @handle lets the app show your avatar to them).",
            "Their reply prints to stdout — relay the relevant part back to the",
            "user, and say which agent it came from.)",
            "",
            "If a message in YOUR chat starts with \"Message from \u{1F916} <name>\", it is",
            "a teammate messaging you, not the user. Answer it directly — your reply",
            "reaches them via their own delivery — and use the same command if you",
            "need to start a conversation yourself.",
            "",
            "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
            "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
            "reply, and report back.",
            "",
            "The roster grows over time — run `hermes profile list` for the LIVE",
            "teammate list before a handoff. Teammates when you were created:",
        ]
        if others.isEmpty {
            lines.append("- (none yet)")
        } else {
            lines += others.map { mate in
                "- `\(mate.name)`" + ((mate.description?.isEmpty == false) ? " — \(mate.description!)" : "")
            }
        }
        return lines.joined(separator: "\n")
    }
}
