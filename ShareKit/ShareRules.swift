// [share] The pure rules of a share (docs/spec/3x-share.md §5.1, §7.6, §7.7). Port of build 240's `ShareRules`
// (DispatchShareKit.swift:136-180). Copies of HermesKit rules are pinned to them by Tests/Share/ShareRulesTests.swift.

import Foundation

nonisolated enum ShareRules {
    // MARK: Ids

    /// The ids a link, a notification or a route may carry: a stored session id.
    static func validSession(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 160 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    static func validProfile(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
    /// A face file in `avatars/`: hex and an extension, nothing that could leave the folder.
    static func validAvatarName(_ name: String) -> Bool {
        name.range(of: "^[a-f0-9]{16,64}\\.(png|jpg)$", options: .regularExpression) != nil
    }

    // MARK: Caps

    /// The most items one share carries (the extension's activation rule says the same).
    static let maxImages = 10
    static let maxFiles = 10
    /// The most shared text (characters) one share reads and sends.
    static let maxSharedText = 256 * 1024
    /// The largest attachment when the roster names no limit (spec D5: `AttachmentStaging.maxItemBytes`).
    static let defaultLimitBytes = 100 * 1024 * 1024
    /// The most bots a roster holds, and the longest name.
    static let maxBots = 200
    static let maxNameLength = 80
    /// The roster key of one of this gateway's own bots (spec D6).
    static let keyPrefix = "ios-direct::"
    static func key(profile: String) -> String { keyPrefix + profile }
    /// The profile a roster key names: what follows its last `::` (`legacy::ivy` → `ivy`).
    static func profile(ofKey key: String) -> String {
        guard let range = key.range(of: "::", options: .backwards) else { return key }
        return String(key[range.upperBound...])
    }

    /// A file fits when it holds something and is no larger than the limit.
    static func fits(bytes: Int, limit: Int) -> Bool { bytes > 0 && bytes <= limit }
    static func megabytes(_ bytes: Int) -> String { "\(max(1, bytes / (1024 * 1024))) MB" }

    // MARK: Prompt

    /// The question a share of photos alone asks (the composer's own, `AttachmentSender.defaultQuestion`).
    static let defaultQuestion = "What do you see in this image?"

    /// What the prompt says: the person's own words first, then what was shared (text, links), each once. File
    /// references from file.attach go first, as the composer puts them. A share of images alone asks the question.
    static func promptText(message: String, shared: [String], fileRefs: [String], hasImages: Bool) -> String {
        let words = ([message] + shared).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let body = words.reduce(into: [String]()) { list, text in if !list.contains(text) { list.append(text) } }.joined(separator: "\n\n")
        let refs = fileRefs.filter { !$0.isEmpty }.joined(separator: "\n")
        let text = [refs, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty && hasImages ? defaultQuestion : text
    }

    // MARK: Account key

    /// `StoredAccount.key` (`GatewayAddress.accountKey`): the gateway address with its scheme and host lowercased and no
    /// trailing slash, a newline, the username.
    static func accountKey(url: String, username: String) -> String {
        var normalized = url
        if var parts = URLComponents(string: url) {
            parts.scheme = parts.scheme?.lowercased()
            if let host = parts.percentEncodedHost { parts.percentEncodedHost = host.lowercased() }
            normalized = parts.string ?? url
        }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized + "\n" + username
    }

    // MARK: Names

    /// The name a file is stored under (`AttachmentStaging.safeName`): no path, no control characters, none of
    /// `" \ / :`, at most 180 bytes keeping the extension.
    static func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        let filtered = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !"\"\\/:".unicodeScalars.contains($0)
        }))
        if filtered.isEmpty || filtered == "." || filtered == ".." { return "attachment" }
        if filtered.utf8.count <= 180 { return filtered }
        let ext = (filtered as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        let stem = suffix.isEmpty ? filtered : String(filtered.dropLast(suffix.count))
        var cleaned = ""
        for scalar in stem.unicodeScalars {
            guard cleaned.utf8.count + scalar.utf8.count + suffix.utf8.count <= 180 else { break }
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned + suffix
    }

    /// `safeName`, and a name without an extension takes `fallbackExtension` (the provider file's own).
    static func safeName(_ raw: String, fallbackExtension: String) -> String {
        let name = safeName(raw)
        guard (name as NSString).pathExtension.isEmpty, !fallbackExtension.isEmpty else { return name }
        return safeName(name + "." + fallbackExtension)
    }

    /// A name's stem (no extension), for "<stem>.jpg".
    static func stem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? "photo" : stem
    }

    // MARK: Gateway staging

    /// A staged file.attach copy can go once the gateway stored its own copy elsewhere; a file it references in place
    /// (uploaded false, or its path still inside the staging folder) must stay (`AttachmentStager.stagedCopyReleased`).
    static func stagedCopyReleased(uploaded: Bool?, storedPath: String?, folder: String) -> Bool {
        guard uploaded == true, let storedPath, !storedPath.isEmpty else { return false }
        return !(storedPath == folder || storedPath.hasPrefix(folder + "/"))
    }

    /// `profile=<p>` and the like, percent-encoded, keys in order.
    static func query(_ items: [String: String]) -> String {
        var parts = URLComponents()
        parts.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
}
