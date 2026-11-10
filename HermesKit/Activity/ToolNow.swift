// [toolnow] What the bot is doing this moment, to follow "<Bot> is " on the thinking row (owner, 2026-10-27: show the
// running tool there instead of "is thinking…"). A few words that fit one line beside the face and the dots: the
// verb of the tool's line (ToolLines) in lower case and its subject made short. A path is its file name, an address
// its site, a command its program and arguments without the `cd … &&` in front or the folders, and any subject is cut
// at `subjectLimit` characters.

import Foundation

nonisolated enum ToolNow {
    /// The longest subject kept whole; longer ones end in "…" (the row cuts what still doesn't fit).
    static let subjectLimit = 36

    /// Tools whose subject reads badly after the verb: their own words, nothing after.
    private static let plain: [String: String] = [
        "image_generate": "making an image", "video_generate": "making a video", "text_to_speech": "recording audio",
        "vision_analyze": "looking at an image", "video_analyze": "watching a video", "browser_click": "clicking in the browser",
        "browser_scroll": "scrolling the page", "browser_snapshot": "looking at the page", "browser_back": "going back a page",
        "browser_press": "pressing a key", "browser_vision": "looking at the page", "browser_console": "reading the console",
        "browser_get_images": "looking at the page's images", "cronjob_manage": "updating a scheduled job",
        "execute_code": "running code", "process_manage": "checking a background task", "read_terminal": "reading the terminal",
        "close_terminal": "closing the terminal", "memory": "updating memory", "todo_list": "updating tasks", "todo": "updating tasks",
        "skills_list": "looking through skills", "session_search": "searching past chats", "clarify": "asking you something",
        "x_search": "searching X",
    ]

    /// "running npm test", "reading package.json", "searching the web for swift actors" (no capital, no ellipsis).
    static func phrase(_ call: ToolCall) -> String {
        phrase(call.name, args: ToolArgs.parse(call.argsText))
    }

    static func phrase(_ name: String, args: [String: JSONValue]) -> String {
        let tool = name.hasPrefix("functions.") ? String(name.dropFirst("functions.".count)) : name
        if let inner = unwrap(tool, args: args) { return phrase(inner.name, args: inner.args) }
        if tool == "tool_call", case .array(let calls)? = args["calls"], calls.count > 1 { return "running \(calls.count) tools" }
        if let words = plain[tool] { return words }
        switch tool {
        case "terminal":
            // Masked first: these words reach the Lock Screen's live card, and a password typed into a command must not.
            let command = args["command"]?.string.map { Self.command(NotificationText.redact($0)) } ?? ""
            return command.isEmpty ? "running a command" : "running " + short(command)
        case "delegate_task":
            if case .array(let tasks)? = args["tasks"], tasks.count > 1 { return "handing off \(tasks.count) tasks" }
            return "handing off a task"
        case BotDMs.tool:
            let target = args["target"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
            return target.isEmpty ? "messaging another bot" : "messaging " + short(target)
        case "browser_navigate", "web_extract":
            let url = ToolLines.preview(tool, args)
            let host = url.split(separator: "/").first.map(String.init) ?? ""
            let verb = tool == "web_extract" ? "reading " : "opening "
            return host.isEmpty ? (tool == "web_extract" ? "reading a page" : "opening a page") : verb + short(host)
        default:
            if let words = mcp(tool, args: args) { return words }
        }
        guard let verb = ToolLines.verb[tool] else {
            return "using " + short(humanName(tool))
        }
        let lead = verb.prefix(1).lowercased() + verb.dropFirst()
        let subject = ToolLines.noPreview.contains(tool) ? "" : ToolLines.preview(tool, args)
        guard !subject.isEmpty else { return lead }
        return lead + (ToolLines.forConnector.contains(tool) ? " for " : " ") + short(subject)
    }

    /// A command as a few words: its first line, without leading `cd <dir> &&`, `VAR=value` and `env`, each word that
    /// is a path as its last part ("python3 /a/b/run.py --fast" → "python3 run.py --fast"). `sudo` stays, once, in front:
    /// the row says when a bot runs as root.
    static func command(_ raw: String) -> String {
        let first = raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        var line = first.trimmingCharacters(in: .whitespaces)
        // Keep the last of a `cd x && y && z` chain's commands that isn't a cd, else the line as it is.
        let steps = line.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let real = steps.first(where: { !$0.hasPrefix("cd ") && $0 != "cd" }) { line = real }
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var root: [String] = []
        while let head = words.first, head == "sudo" || head == "env" || (head.contains("=") && !head.hasPrefix("-")) {
            if words.removeFirst() == "sudo" { root = ["sudo"] }
        }
        words = root + words
        words = words.map { word in
            guard word.contains("/"), !word.contains("://") else { return word }
            let trimmed = word.hasSuffix("/") ? String(word.dropLast()) : word
            return trimmed.split(separator: "/").last.map(String.init) ?? word
        }
        return words.joined(separator: " ")
    }

    /// The gateway's `tool_call` wrapper (how bots reach Composio, 2026-10-29: 400 of 400 Composio calls on this Mac came
    /// in one): the call inside it, so the row names that and not "tool call". Nil when it holds none or several.
    static func unwrap(_ tool: String, args: [String: JSONValue]) -> (name: String, args: [String: JSONValue])? {
        guard tool == "tool_call", case .array(let calls)? = args["calls"], calls.count == 1,
              let inner = calls[0].object, let name = inner["name"]?.string, !name.isEmpty else { return nil }
        var innerArgs = inner["arguments"]?.object ?? [:]
        if innerArgs.isEmpty, let text = inner["arguments"]?.string { innerArgs = ChatJSON.parse(string: text)?.object ?? [:] }
        return (name, innerArgs)
    }

    /// An MCP server's tool (owner, 2026-10-28: "using composio COMPOSIO MULTI EXE…" ran off the row). Composio's say the
    /// action inside the app (`composio`); any other server's are its name and the tool's words without the server
    /// repeated, in lower case ("linear search issues").
    static func mcp(_ tool: String, args: [String: JSONValue]) -> String? {
        guard tool.hasPrefix("mcp_") else { return nil }
        let words = humanName(tool).split(separator: " ").map(String.init)
        guard let server = words.first?.lowercased() else { return nil }
        var rest = Array(words.dropFirst())
        if rest.first?.lowercased() == server { rest.removeFirst() }
        let action = rest.joined(separator: "_").uppercased()
        if server == "composio" { return composio(action, args: args) }
        let plain = rest.map { $0 == $0.uppercased() ? $0.lowercased() : $0 }.joined(separator: " ")
        return "using " + short(plain.isEmpty ? server : server + " " + plain)
    }

    /// A Composio tool by what it does in the app, never "Composio" (owner, 2026-10-29: "it should say what inside
    /// composio that it's calling"): "running SOQL query in Salesforce", "finding file in Google Drive", "running 3
    /// actions in Gmail", "reading how to use download file in Google Drive", "checking the Gmail connection".
    static func composio(_ action: String, args: [String: JSONValue]) -> String {
        if action.contains("SEARCH_TOOLS") {
            // The use case it looks for, when short enough to read ("looking for a tool to upload a file to Drive").
            if case .array(let queries)? = args["queries"], queries.count == 1,
               let use = queries[0]["use_case"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !use.isEmpty {
                return short("looking for a tool to " + use.prefix(1).lowercased() + use.dropFirst())
            }
            return "looking for the right tool"
        }
        var slugs: [String] = []
        if case .array(let tools)? = args["tools"] { slugs += tools.compactMap { $0["tool_slug"]?.string } }
        if case .array(let list)? = args["tool_slugs"] { slugs += list.compactMap(\.string) }
        if let one = args["tool_slug"]?.string { slugs.append(one) }
        if action.contains("WORKBENCH"), let code = args["code_to_execute"]?.string ?? args["code"]?.string {
            slugs += workbenchSlugs(code)
        }
        if action.contains("GET_TOOL_SCHEMAS") {
            guard !slugs.isEmpty else { return "reading how to use a tool" }
            return short("reading how to use " + (slugs.count == 1 ? actionWords(slugs[0], ing: false) + " in " + appName(slugs[0])
                                                  : "\(slugs.count) tools"))
        }
        if action.contains("MANAGE_CONNECTIONS") || action.contains("WAIT_FOR_CONNECTION") {
            var apps: [String] = []
            if case .array(let kits)? = args["toolkits"] { apps = kits.compactMap(\.string).map(appName) }
            let what = apps.count == 1 ? "the \(apps[0]) connection" : "app connections"
            return short((action.contains("WAIT") ? "waiting for " : "checking ") + what)
        }
        if action.contains("BASH") { return "running a command" }
        guard !slugs.isEmpty else { return action.contains("WORKBENCH") ? "running a script" : "using a connected app" }
        var apps: [String] = []
        for slug in slugs {
            let app = appName(slug)
            if !app.isEmpty, !apps.contains(app) { apps.append(app) }
        }
        let place = apps.count == 1 ? apps[0] : apps.count == 2 ? "\(apps[0]) and \(apps[1])" : "\(apps.count) apps"
        let lead = action.contains("WORKBENCH") ? "running a script that does " : ""
        if Set(slugs).count == 1 { return short(lead + actionWords(slugs[0], ing: lead.isEmpty) + " in " + place) }
        return short((lead.isEmpty ? "running " : lead) + "\(slugs.count) actions in " + place)
    }

    private static let workbenchCall = try! NSRegularExpression(pattern: #"run_composio_tool\(\s*['"]([A-Z0-9_]+)['"]"#)

    /// The tool slugs a workbench script runs (`run_composio_tool('GOOGLEDRIVE_DOWNLOAD_FILE', …)`), each once, in order.
    static func workbenchSlugs(_ code: String) -> [String] {
        let range = NSRange(code.startIndex..., in: code)
        var out: [String] = []
        for match in workbenchCall.matches(in: code, range: range) {
            guard let r = Range(match.range(at: 1), in: code) else { continue }
            let slug = String(code[r])
            if !out.contains(slug) { out.append(slug) }
        }
        return out
    }

    /// Words kept in capitals in an action ("run SOQL query").
    private static let acronyms: Set<String> = ["soql", "sql", "url", "urls", "id", "ids", "pdf", "api", "csv", "html", "sms", "crm"]
    /// Verbs that double their last letter before "-ing".
    private static let doubles: Set<String> = ["run", "get", "set", "put", "stop", "plan", "chat", "tag", "pin", "ship", "scan"]

    /// A slug's action without its app: "NOTION_SEARCH_NOTION_PAGE" → "searching page" (`ing`) or "search page".
    static func actionWords(_ slug: String, ing: Bool) -> String {
        let parts = slug.lowercased().split(separator: "_").map(String.init)
        guard let head = parts.first else { return "" }
        var words = Array(parts.dropFirst()).filter { $0 != head }
        if words.isEmpty { return "using it" }
        if ing { words[0] = gerund(words[0]) }
        return words.map { acronyms.contains($0) ? $0.uppercased() : $0 }.joined(separator: " ")
    }

    static func gerund(_ verb: String) -> String {
        if verb.hasSuffix("ing") { return verb }
        if doubles.contains(verb), let last = verb.last { return verb + String(last) + "ing" }
        if verb.hasSuffix("e"), !verb.hasSuffix("ee"), verb.count > 2 { return verb.dropLast() + "ing" }
        return verb + "ing"
    }

    private static let appNames = [
        "gmail": "Gmail", "googlecalendar": "Google Calendar", "googledrive": "Google Drive", "googledocs": "Google Docs",
        "googlesheets": "Google Sheets", "github": "GitHub", "gitlab": "GitLab", "hubspot": "HubSpot", "clickup": "ClickUp",
        "youtube": "YouTube", "linkedin": "LinkedIn", "whatsapp": "WhatsApp", "one_drive": "OneDrive", "metaads": "Meta Ads",
        "googleads": "Google Ads", "googlemeet": "Google Meet", "googletasks": "Google Tasks", "googlephotos": "Google Photos",
        "outlook": "Outlook", "onedrive": "OneDrive", "quickbooks": "QuickBooks", "openai": "OpenAI", "exa": "Exa",
    ]

    /// A Composio tool slug's app: "GMAIL_FETCH_EMAILS" → "Gmail", "GOOGLECALENDAR_FIND_EVENT" → "Google Calendar".
    static func appName(_ slug: String) -> String {
        guard let head = slug.split(separator: "_").first.map({ $0.lowercased() }), !head.isEmpty else { return "" }
        return appNames[head] ?? head.prefix(1).uppercased() + head.dropFirst()
    }

    /// "mcp__linear__search_issues" → "linear search issues".
    static func humanName(_ tool: String) -> String {
        var name = tool
        if name.hasPrefix("mcp__") { name = String(name.dropFirst(5)) } else if name.hasPrefix("mcp_") { name = String(name.dropFirst(4)) }
        return name.replacingOccurrences(of: "__", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    static func short(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard one.count > subjectLimit else { return one }
        return String(one.prefix(subjectLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
