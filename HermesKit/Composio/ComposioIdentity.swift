// Connect Apps: which person each connected account is (docs/spec/3x-capabilities.md §10.12). Composio's account rows
// carry no email or name, so the app asks the app itself through one read-only "who am I" tool per app, run against
// that one account. The address is shown on the page; it never reaches the log.

import Foundation

/// The person behind one connected account, as the app itself reports it.
nonisolated struct ComposioIdentity: Sendable, Equatable, Codable {
    var email: String
    /// The name the app shows for the person ("Alex Rivera"); "" when the app gives none.
    var name: String = ""
}

/// The who-am-I table: app slug → the read-only tool that names the signed-in person, its arguments, and where the
/// address and name sit in the tool's `data`. An app not listed here shows no address (the row stays "Account <n>").
nonisolated enum ComposioWhoAmI {
    struct Entry: Sendable, Equatable {
        var tool: String
        var arguments: JSONValue = [:]
        /// Paths into `data`, tried in order; a value counts only when it looks like an address.
        var email: [[String]]
        /// Paths into `data` for the person's name, tried in order. Never searched for: some answers carry the name of
        /// an integration or a bot beside the person's.
        var name: [[String]] = []
        /// Run against a real account and read back (2026-10-27); the others are from Composio's tool list and schema.
        var checkedLive = false
    }

    static let table: [String: Entry] = [
        // {"user":{"displayName","emailAddress","photoLink","me":true,…}}
        "googledrive": Entry(tool: "GOOGLEDRIVE_GET_ABOUT", arguments: ["fields": "user"],
                             email: [["user", "emailAddress"]], name: [["user", "displayName"]], checkedLive: true),
        // {"response_data":{"type":"bot","name":<integration>,"bot":{"owner":{"user":{"name","person":{"email"}}},"workspace_name"}}}
        "notion": Entry(tool: "NOTION_GET_ABOUT_ME", email: [["response_data", "bot", "owner", "user", "person", "email"]],
                        name: [["response_data", "bot", "owner", "user", "name"]], checkedLive: true),
        // {"user":{"email","username","initials",…}}
        "clickup": Entry(tool: "CLICKUP_GET_AUTHORIZED_USER", email: [["user", "email"]], name: [["user", "username"]], checkedLive: true),
        // {"response_data":{"email","name","preferred_username",…}}
        "salesforce": Entry(tool: "SALESFORCE_GET_USER_INFO", email: [["response_data", "email"], ["response_data", "preferred_username"]],
                            name: [["response_data", "name"]], checkedLive: true),
        // Gmail's users.getProfile: {"response_data":{"emailAddress",…}}
        "gmail": Entry(tool: "GMAIL_GET_PROFILE", arguments: ["user_id": "me"],
                       email: [["response_data", "emailAddress"], ["emailAddress"]]),
        // The primary calendar's id and summary are the owner's address.
        "googlecalendar": Entry(tool: "GOOGLECALENDAR_GET_CALENDAR", arguments: ["calendar_id": "primary"],
                                email: [["calendar_data", "id"], ["calendar_data", "summary"], ["id"]]),
        // {"user":{"id","name","email",…}}
        "linear": Entry(tool: "LINEAR_GET_CURRENT_USER", email: [["user", "email"]], name: [["user", "name"]]),
        // Microsoft Graph /me: {"response_data":{"mail","userPrincipalName","displayName"}}
        "outlook": Entry(tool: "OUTLOOK_OUTLOOK_GET_PROFILE", arguments: ["user_id": "me"],
                         email: [["response_data", "mail"], ["response_data", "userPrincipalName"]], name: [["response_data", "displayName"]]),
        // GitHub /user: the public email is often null; the name is then the only thing shown.
        "github": Entry(tool: "GITHUB_GET_THE_AUTHENTICATED_USER", email: [["email"], ["response_data", "email"]],
                        name: [["name"], ["login"], ["response_data", "name"], ["response_data", "login"]]),
    ]

    static func entry(_ slug: String) -> Entry? { table[slug.lowercased()] }

    /// "a@b.co": something@something.something, no spaces, at most 254 characters.
    static func looksLikeEmail(_ text: String) -> Bool {
        text.count <= 254 && JSRegex(#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#).test(text)
    }

    /// The identity in a tool's answer (`{"successful":true,"data":{…}}`), nil when it failed or names nobody.
    /// When none of the listed paths give an address, the answer is searched (a few levels deep) for a key named like
    /// one ("emailAddress", "email", "mail", "userPrincipalName") holding an address.
    static func read(_ answer: JSONValue, entry: Entry) -> ComposioIdentity? {
        guard answer["successful"]?.bool != false, let data = answer["data"], data.object != nil else { return nil }
        func at(_ path: [String]) -> String? {
            var value: JSONValue? = data
            for key in path { value = value?[key] }
            return RosterText.trimmed(value)
        }
        let email = entry.email.lazy.compactMap(at).first(where: looksLikeEmail) ?? search(data, depth: 0) ?? ""
        let name = entry.name.lazy.compactMap(at).first { !$0.isEmpty && $0.count <= 120 } ?? ""
        guard !email.isEmpty || !name.isEmpty else { return nil }
        return ComposioIdentity(email: email, name: name == email ? "" : name)
    }

    private static let emailKeys: Set<String> = ["emailaddress", "email", "mail", "userprincipalname", "primary_email"]

    private static func search(_ value: JSONValue, depth: Int) -> String? {
        guard depth < 5 else { return nil }
        if let object = value.object {
            for key in object.keys.sorted() where emailKeys.contains(key.lowercased()) {
                if let text = RosterText.trimmed(object[key]), looksLikeEmail(text) { return text }
            }
            for key in object.keys.sorted() { if let found = search(object[key]!, depth: depth + 1) { return found } }
        } else if let array = value.array {
            for item in array.prefix(5) { if let found = search(item, depth: depth + 1) { return found } }
        }
        return nil
    }
}

extension ComposioAccount {
    /// The row's name (§10.12): the owner's alias ("Work"), else the account's address, else "Account <n>".
    func title(number: Int, identity: ComposioIdentity?) -> String {
        if !alias.isEmpty { return ComposioAlias.shown(alias) }
        if let email = identity?.email, !email.isEmpty { return email }
        return "Account \(number)"
    }

    /// The address under the name, when the name is the alias (an address as the title isn't repeated).
    func emailLine(identity: ComposioIdentity?) -> String? {
        guard !alias.isEmpty, let email = identity?.email, !email.isEmpty else { return nil }
        return email
    }
}

extension ComposioAlias {
    /// Mail services whose addresses say nothing about whose account it is: their accounts are "personal".
    static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
        "yahoo.com", "ymail.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net", "fastmail.com",
        "hey.com", "zoho.com", "yandex.com", "mail.com",
    ]

    /// A name to offer for an unnamed account, from its address: the company ("c…@work.com" → "work",
    /// "a@mail.acme.co.uk" → "acme"), "personal" for a mail service, and the address's own name when that is taken
    /// already ("personal" used by another account → "jane-doe"). nil when nothing usable is left or all are taken.
    static func suggestion(email: String, taken: Set<String> = []) -> String? {
        let parts = email.lowercased().split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, ComposioWhoAmI.looksLikeEmail(email) else { return nil }
        let (local, domain) = (parts[0], parts[1])
        var first: String?
        if personalDomains.contains(domain) {
            first = "personal"
        } else {
            var labels = domain.split(separator: ".").map(String.init)
            if labels.count > 1 { labels.removeLast() }   // the top-level domain
            if labels.count > 1, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(labels.last!) { labels.removeLast() }
            first = labels.last.flatMap(normalized)
        }
        let local0 = normalized((local.split(separator: "+").first.map(String.init) ?? local).replacingOccurrences(of: ".", with: "-"))
        return [first, local0].compactMap { $0 }.first { !taken.contains($0) }
    }
}
