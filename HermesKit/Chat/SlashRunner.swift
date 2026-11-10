// The slash dispatcher (spec 1x §8): a sent "/command" runs here instead of `prompt.submit` — the web's `runSlash`,
// `runExec`, `runRpc` and the action handlers (V:app/session/hooks/use-prompt-actions/slash.ts:230-1320), with the
// phone's decisions (§8.2): /help opens the Commands sheet, /model the Models sheet, desktop-only actions answer
// "isn't available in HQ Native yet". Output lands as slash rows (LiveChatSession+Menus.swift); /btw and /bg results
// land later (SideTasks.swift).

import Foundation

nonisolated enum SlashResults {
    /// `renderRpcResult` (V:…/use-prompt-actions/utils.ts:525-600) for the RPCs the phone routes to.
    static func render(_ response: JSONValue) -> String {
        guard let r = response.object else { return "" }
        if let summary = r["summary"]?.object, let headline = summary["headline"]?.string, !headline.isEmpty {
            var lines = ["\(summary["noop"]?.bool == true ? "" : "✓ ")\(headline)"]
            if let token = summary["token_line"]?.nonEmptyString { lines.append("  \(token)") }
            if let note = summary["note"]?.nonEmptyString { lines.append("  \(note)") }
            return lines.joined(separator: "\n")
        }
        if let status = r["status"]?.string, status == "queued" || status == "rejected" {
            let text = r["text"]?.string ?? ""
            if status == "queued" { return text.isEmpty ? "Steered next tool call" : "Steered · \"\(text)\" queued for next tool call" }
            return "Steer rejected — agent declined input"
        }
        if case .number(let killed)? = r["killed"] {
            let n = Int(killed)
            return n > 0 ? "Stopped \(n) background process\(n == 1 ? "" : "es")." : "No background processes to stop."
        }
        if let file = r["file"]?.string, !file.isEmpty { return "Saved transcript to \(file)" }
        if let output = r["output"]?.string, !output.isEmpty { return output }
        if r["total"] != nil || r["input"] != nil || r["output"] != nil || r["calls"] != nil {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            func n(_ key: String) -> String { f.string(from: NSNumber(value: r[key]?.double ?? 0)) ?? "0" }
            var lines = ["Usage: \(n("calls")) calls · \(n("input")) in / \(n("output")) out · \(n("total")) total"]
            for extra in [r["account_lines"], r["credits_lines"]] {
                for line in extra?.array ?? [] { if let s = line.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty { lines.append(s) } }
            }
            return lines.joined(separator: "\n")
        }
        return ""
    }

    /// `/reasoning <arg>`'s `config.set` value and scope (V:lib/reasoning-slash.ts:20-41); nil = nothing to set.
    static func reasoningParams(_ arg: String) -> (value: String, scope: String?)? {
        var scope: String?
        var values: [String] = []
        for part in arg.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            switch part.lowercased() {
            case "--global", "-g", "global": scope = "global"
            case "--session", "-s", "session": scope = "session"
            default: values.append(part)
            }
        }
        return values.isEmpty ? nil : (values.joined(separator: " "), scope)
    }

    /// `parseCommandDispatch` (SH:slash.ts:85-116): a directive, or nil for a malformed or plain answer.
    static func directive(_ raw: JSONValue) -> JSONValue? {
        guard let row = raw.object, let type = row["type"]?.string else { return nil }
        switch type {
        case "alias": return row["target"]?.string != nil ? raw : nil
        case "exec", "plugin": return raw
        case "prefill", "send": return row["message"]?.string != nil ? raw : nil
        case "skill": return row["name"]?.string != nil ? raw : nil
        default: return nil
        }
    }

    static func isMissingMethod(_ error: any Error) -> Bool { (error as? RPCError)?.code == -32601 }

    static let notACommand = try! NSRegularExpression(pattern: #"not a quick/plugin/(?:bundle/)?skill command"#, options: [.caseInsensitive])
    static let queuedLine = "session busy — message queued to send when the current turn finishes"
    static let botChatTitle = "A bot's own chat keeps its name. Rename the bot instead."

    // MARK: /new, /compress (docs/spec/3x-composer.md §8.2, §8.3)

    static let newChatFailed = "Couldn’t start a new chat with this bot."
    static let compressWait = "Wait for this reply to finish, then compress."
    static let compressPending = "Compression is still running in the background."
    static let compressTimedOut = "Couldn’t compress: your gateway didn’t answer in time."
    /// Above the gateway's own wait for a compute host's compress (its ceiling + 30 s, capped at 630 s), after which it
    /// answers `pending` rather than an error; the desktop waits as long (V:…/use-prompt-actions/slash.ts:88-95).
    static let compressTimeout: Duration = .seconds(660)

    /// The running row: "Compressing context…" or "Compressing context for: <topic>…".
    static func compressing(topic: String) -> String {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return topic.isEmpty ? "Compressing context…" : "Compressing context for: \(topic)…"
    }

    /// `session.compress`'s answer as the result row (H:tui_gateway/methods_session.py `_compress_live`,
    /// `_compress_via_compute_host`; the summary from agent/manual_compression_feedback.py).
    static func compressText(_ result: JSONValue) -> String {
        let r = result.object ?? [:]
        let status = r["status"]?.string
        if status == "pending" { return compressPending }
        if r["lock_held"]?.bool == true { return r["message"]?.nonEmptyString ?? "Another compression is already running for this chat." }
        let summary = r["summary"]?.object
        let headline = summary?["headline"]?.nonEmptyString
        if status == "aborted" || summary?["aborted"]?.bool == true { return headline ?? "Compression was stopped." }
        let removed = r["removed"]?.int
        if summary?["noop"]?.bool == true || (headline == nil && removed == 0) { return headline ?? "Nothing to compress." }
        if let headline {
            return [headline, summary?["token_line"]?.nonEmptyString, summary?["note"]?.nonEmptyString].compactMap { $0 }.joined(separator: "\n")
        }
        if let output = r["host_ack"]?["output"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty { return output }
        let n = removed ?? 0
        return n > 0 ? "Compressed \(n) message\(n == 1 ? "" : "s")." : "Nothing to compress."
    }

    /// A failed `session.compress` (−32601 goes to the exec path before this).
    static func compressError(_ error: any Error) -> String {
        if let rpc = error as? RPCError {
            if rpc.code == 4009 { return compressWait }
            if rpc.isTimeout { return compressTimedOut }
        }
        let message = MenusError.text(error)
        return "Couldn’t compress: \(message.count > 160 ? String(message.prefix(159)) + "…" : message)"
    }
}

extension LiveChatSession: ChatSlashRunning {
    var slashHooks: ChatSlashHooks {
        get { menus.hooks }
        set { menus.hooks = newValue }
    }

    func runSlash(_ text: String) {
        Task { [weak self] in await self?.performSlash(text, recordInput: true) }
    }

    /// The whole dispatcher: resolve the command's surface, then act on it (spec 1x §8.2). `recordInput` false for an
    /// alias's re-run: its output rows carry no command.
    func performSlash(_ commandText: String, recordInput: Bool) async {
        let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        let (name, arg) = SlashCommand.parse(command)
        guard !name.isEmpty else {
            // "/" or "/ words": hand the words back, and say why nothing ran.
            if !command.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                menus.hooks.prefill?(command)
            }
            appendSlashRow(command: nil, output: "empty slash command")
            return
        }
        let shown: String? = recordInput ? "/\(name)" : nil
        let catalog = latestCommandsCatalog
        if SlashCatalog.nativeUnsupported.contains(name) {
            appendSlashRow(command: shown, output: "/\(name) isn't available in \(AppIdentity.current.displayName) yet.")
            return
        }
        // A bot's own chat keeps its "Bot Chat" title: renaming it would start the bot over in a new, empty chat (the
        // reason ⋯ offers no Rename there, spec 1x §4.1).
        if name == "title", !arg.isEmpty, isBotChat {
            appendSlashRow(command: shown, output: SlashResults.botChatTitle)
            return
        }
        let spec = SlashCatalog.resolve("/\(name)", catalog: catalog)
        let label = spec != nil ? "/\(name)" : "an unknown command"
        AppLog.trace("chat", "slash \(label) in \(logIds): surface \(spec.map { "\($0.surface)" } ?? "exec"), arg \(arg.isEmpty ? "none" : "\(arg.count) chars")")
        switch spec?.surface {
        case .unavailable(let reason)?:
            appendSlashRow(command: shown, output: SlashCatalog.unavailableMessage(reason, command: SlashCatalog.canonical("/\(name)", catalog: catalog)))
            return
        case .picker("model")?:
            menus.hooks.openModels?(arg.isEmpty ? nil : arg)
            return
        case .action("help")?:
            menus.hooks.openCommands?()
            return
        case .action("btw")? where arg.isEmpty:
            appendSlashRow(command: shown, output: SideTaskKind.btw.usage)
            return
        case .action("background")? where arg.isEmpty:
            appendSlashRow(command: shown, output: SideTaskKind.background.usage)
            return
        case .action("new")?:
            // A new chat with this bot in this one's place, the words after the command in its field; no output row.
            if menus.hooks.newChat?(arg) != true {
                appendSlashRow(command: shown, output: SlashResults.newChatFailed)
            }
            return
        case .action("compress")? where isRunning:
            appendSlashRow(command: shown, output: SlashResults.compressWait)
            return
        case .action("compress")? where menus.compressing:
            AppLog.trace("chat", "slash /\(name) in \(logIds): a compress is already running here; ignored")
            return
        case .picker?, .action("branch")?, .action("profile")?, .action("skin")?,
             .action("wake")?, .action("handoff")?, .action("browser")?, .action("journey")?, .action("pet")?, .action("hatch")?:
            appendSlashRow(command: shown, output: "/\(name) isn't available in \(AppIdentity.current.displayName) yet.")
            return
        default:
            break
        }
        let compress = spec?.surface == .action("compress")
        if compress { menus.compressing = true }
        defer { if compress { menus.compressing = false } }
        let out = SlashOutput(session: self, command: shown, placeholderAfter: menus.runningPlaceholderAfter,
                              running: compress ? SlashResults.compressing(topic: arg) : SlashOutput.running)
        out.logLabel = label
        // Every path from here talks to the chat's live session: resume it first (spec 1x §8.1).
        if runtimeSessionId == nil {
            do { try await resumeNow() } catch {
                AppLog.note("chat", "slash \(label): resume failed (\(LiveChatSession.logError(error)))")
                out.finish("error: Couldn’t reach this chat.")
                return
            }
        }
        switch spec?.surface {
        case .action("stop")?: await slashStop(out)
        case .action("title")? where !arg.isEmpty: await slashTitle(arg, out)
        case .action("reasoning")?: await slashReasoning(name: name, arg: arg, command: command, out)
        case .action("yolo")?: await slashYolo(out)
        case .action("btw")?: await slashSide(.btw, name: name, arg: arg, command: command, out)
        case .action("background")?: await slashSide(.background, name: name, arg: arg, command: command, out)
        case .action("compress")?: await slashCompress(name: name, arg: arg, command: command, out)
        case .rpc(let method)?: await slashRPC(method, name: name, arg: arg, command: command, out)
        default: await runExec(name: name, arg: arg, command: command, out)
        }
    }

    // MARK: exec (`runExec`)

    private func runExec(name: String, arg: String, command: String, _ out: SlashOutput) async {
        var execError: (any Error)?
        do {
            let line = String(command.drop(while: { $0 == "/" }))
            let result = try await sessionCall("slash.exec", timeout: .seconds(60), runtime: .resumeFirst) { _ in
                ["command": .string(line)]
            }
            if let directive = SlashResults.directive(result) {
                await handleDirective(directive, name: name, arg: arg, out)
                return
            }
            let output = result["output"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "/\(name): no output"
            if let warning = result["warning"]?.string, !warning.isEmpty {
                out.finish("warning: \(warning)\n\(output)")
            } else {
                out.finish(output)
            }
            return
        } catch {
            // Fall back to command.dispatch for skill/send/alias directives, keeping slash.exec's error.
            AppLog.trace("chat", "slash exec failed (\(LiveChatSession.logError(error))); trying command.dispatch")
            execError = error
        }
        do {
            let raw = try await sessionCall("command.dispatch", timeout: .seconds(60), runtime: .resumeFirst) { _ in
                ["name": .string(name), "arg": .string(arg)]
            }
            guard let directive = SlashResults.directive(raw) else {
                out.finish("error: invalid response: command.dispatch")
                return
            }
            await handleDirective(directive, name: name, arg: arg, out)
        } catch {
            let message = MenusError.text(error)
            if let execError, Rx.matches(SlashResults.notACommand, message) {
                out.finish("error: /\(name) failed: \(MenusError.text(execError))")
            } else {
                out.finish("error: \(message)")
            }
        }
    }

    private func handleDirective(_ d: JSONValue, name: String, arg: String, _ out: SlashOutput) async {
        let type = d["type"]?.string ?? ""
        AppLog.trace("chat", "slash directive: \(type.isEmpty ? "-" : type)")
        switch type {
        case "exec", "plugin":
            out.finish(d["output"]?.string ?? "(no output)")
            return
        case "alias":
            out.cancel()
            let target = d["target"]?.string ?? name
            await performSlash("/\(target)\(arg.isEmpty ? "" : " " + arg)", recordInput: false)
            return
        default:
            break
        }
        var noticed = false
        if type == "send" || type == "prefill", let notice = d["notice"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notice.isEmpty {
            out.finish(notice)
            noticed = true
        }
        let message = (d["message"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "prefill" {
            if !noticed { out.cancel() }
            if !message.isEmpty { menus.hooks.prefill?(message) }
            return
        }
        guard !message.isEmpty else {
            out.finish("/\(name): \(type == "skill" ? "skill payload missing message" : "empty message")")
            return
        }
        // The expanded skill body is model-facing: the bubble shows the invocation (projected, or read back from it).
        let projected = d["display"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = projected.isEmpty ? Hydration.skillInvocationText(message) : projected
        let queues = isRunning || (!queuedMessages.isEmpty && !isQueueParked)
        queuesNextSend = true      // a command's message waits behind a running reply; it is never steered into it
        send(message, display: display)
        if queues {
            out.finish(SlashResults.queuedLine)
        } else if !noticed {
            out.cancel()
        }
    }

    // MARK: rpc (`runRpc`)

    private func slashRPC(_ method: String, name: String, arg: String, command: String, _ out: SlashOutput) async {
        do {
            let result = try await sessionCall(method, timeout: .seconds(30), runtime: .resumeFirst) { _ in [:] }
            let body = SlashResults.render(result)
            out.finish(body.isEmpty ? "/\(name): no output" : body)
        } catch {
            if SlashResults.isMissingMethod(error) {
                await runExec(name: name, arg: arg, command: command, out)
                return
            }
            out.finish("error: \(MenusError.text(error))")
        }
    }

    // MARK: Actions

    /// The Stop button's own path for the turn, then `process.stop` (spec 1x §8.2).
    private func slashStop(_ out: SlashOutput) async {
        var lines: [String] = []
        if isRunning {
            stop()
            lines.append("Stopped the active turn.")
        } else {
            do {
                _ = try await sessionCall("session.interrupt", timeout: interruptTimeout, runtime: .resumeFirst) { _ in [:] }
                lines.append("Stopped the active turn.")
            } catch {
                lines.append("Couldn’t stop the active turn: \(MenusError.text(error))")
            }
        }
        do {
            let result = try await sessionCall("process.stop", timeout: .seconds(30), runtime: .resumeFirst) { _ in [:] }
            let text = SlashResults.render(result)
            if !text.isEmpty { lines.append(text) }
        } catch {
            lines.append("Couldn’t stop background processes: \(MenusError.text(error))")
        }
        out.finish(lines.joined(separator: "\n"))
    }

    /// `/title <name>`: `session.title`, then the title shows like a rename.
    private func slashTitle(_ arg: String, _ out: SlashOutput) async {
        do {
            let result = try await sessionCall("session.title", timeout: .seconds(30), runtime: .resumeFirst) { _ in
                ["title": .string(arg)]
            }
            let final = (result["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? arg).trimmingCharacters(in: .whitespacesAndNewlines)
            let queued = result["pending"]?.bool == true
            if !final.isEmpty {
                applyTitle(final, rowTitle: final)
                menus.hooks.titleApplied?(final)
            }
            out.finish(final.isEmpty ? "Session title cleared."
                       : "Session title set: \(final)\(queued ? " (queued while session initializes)" : "")")
        } catch {
            out.finish("error: \(MenusError.text(error))")
        }
    }

    private func slashReasoning(name: String, arg: String, command: String, _ out: SlashOutput) async {
        let params = SlashResults.reasoningParams(arg)
        do {
            guard let params else {
                let current = try await sessionCall("config.get", timeout: .seconds(15), runtime: .resumeFirst) { _ in ["key": "reasoning"] }
                let value = current["value"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "medium"
                let display = current["display"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "hide"
                out.finish("reasoning: \(value) · display \(display)")
                return
            }
            let result = try await sessionCall("config.set", timeout: .seconds(15), runtime: .resumeFirst) { _ in
                var p: [String: JSONValue] = ["key": "reasoning", "value": .string(params.value)]
                if let scope = params.scope { p["scope"] = .string(scope) }
                return p
            }
            let value = result["value"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? params.value
            if ModelNames.reasoningEffortValues.contains(value.lowercased()) { modelState.reasoningEffort = value.lowercased() }
            out.finish("reasoning: \(value)")
        } catch {
            if SlashResults.isMissingMethod(error) {
                await runExec(name: name, arg: arg, command: command, out)
                return
            }
            out.finish("error: \(MenusError.text(error))")
        }
    }

    /// `/btw <question>`, `/bg <prompt>` (docs/spec/3x-composer.md §8.4): the task starts beside the turn and its result
    /// lands later (SideTasks.swift). Typed while a reply runs, it runs at once like every slash command.
    private func slashSide(_ kind: SideTaskKind, name: String, arg: String, command: String, _ out: SlashOutput) async {
        do {
            let result = try await sessionCall(kind.method, timeout: .seconds(30), runtime: .resumeFirst) { _ in
                ["text": .string(arg)]
            }
            guard let taskId = result["task_id"]?.nonEmptyString else {
                AppLog.trace("chat", "side task \(kind.rawValue) started in \(logIds) without a task id (result won't be matched)")
                out.finish(kind.started)
                return
            }
            AppLog.trace("chat", "side task \(kind.rawValue) \(AppLog.tag(taskId)) started in \(logIds)\(menus.sideDone.contains(taskId) ? ", its result already landed" : "")")
            // The result can beat the answer to the call: then it is already on screen and no start line is owed.
            if menus.sideDone.contains(taskId) {
                out.cancel()
                return
            }
            out.finish(kind.started)
            menus.sideTasks[taskId] = SideTask(kind: kind, asked: arg, startRowId: out.rowId, command: out.command, startedAt: Date())
        } catch {
            if SlashResults.isMissingMethod(error) {
                await runExec(name: name, arg: arg, command: command, out)
                return
            }
            out.finish(kind.couldNotStart(MenusError.text(error)))
        }
    }

    /// `/compress [topic]` (`/compact`, docs/spec/3x-composer.md §8.3): the gateway's own `session.compress`, never
    /// `slash.exec` (a big chat's compression outlives the slash worker's pipe; the desktop's #44456). The running row
    /// reads "Compressing context…" until the result replaces it. The transcript on screen stays: the stored rows
    /// before the summary are still the chat's (read with `include_compacted`), as the desktop keeps them (#105256).
    private func slashCompress(name: String, arg: String, command: String, _ out: SlashOutput) async {
        let topic = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await sessionCall("session.compress", timeout: SlashResults.compressTimeout, runtime: .resumeFirst) { _ in
                topic.isEmpty ? [:] : ["focus_topic": .string(topic)]
            }
            AppLog.trace("chat", "compress \(logIds): status \(result["status"]?.string ?? "-"), removed \(result["removed"]?.int.map(String.init) ?? "-"), before \(result["before_messages"]?.int.map(String.init) ?? "-") → after \(result["after_messages"]?.int.map(String.init) ?? "-") messages")
            // The context meter follows the shrunk chat: the session's own usage, else the answer's.
            if result["info"]?.object != nil {
                applyModelInfo(result["info"])
            } else if let usage = SessionUsage.decode(result["usage"]) {
                menus.usage = usage
            }
            menus.contextEstimate = nil
            changes.markState()
            out.finish(SlashResults.compressText(result))
        } catch {
            if SlashResults.isMissingMethod(error) {
                await runExec(name: name, arg: arg, command: command, out)
                return
            }
            out.finish(SlashResults.compressError(error))
        }
    }

    /// `/yolo`: the session's approval bypass, toggled (V:lib/yolo-session.ts:11-27).
    private func slashYolo(_ out: SlashOutput) async {
        let next = !modelState.yolo
        do {
            let result = try await sessionCall("config.set", timeout: .seconds(15), runtime: .resumeFirst) { _ in
                ["key": "yolo", "value": .string(next ? "1" : "0")]
            }
            let active = result["value"]?.string == "1"
            modelState.yolo = active
            out.finish("YOLO \(active ? "on" : "off") for this session")
        } catch {
            out.cancel()
            menus.hooks.alert?("YOLO", "Couldn’t turn YOLO on or off.")
        }
    }
}
