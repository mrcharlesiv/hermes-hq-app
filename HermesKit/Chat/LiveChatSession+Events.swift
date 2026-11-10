// Folding gateway events into the open chat (spec 04 §3–§4, §5.4, §8, §9). One assistant `ChatMessage` per turn;
// text, reasoning and tool parts interleave in arrival order exactly like history hydration produces them.

import Foundation

extension LiveChatSession {
    private static let cancelledBeforeReady = try! NSRegularExpression(
        pattern: "^(Turn cancelled|Session no longer running) before the agent was ready", options: [.caseInsensitive])

    /// Entry point for every event frame from the client.
    func receive(_ event: GatewayEvent) {
        switch event.type {
        case "gateway.ready":
            handleReady(event.payload)
            return
        case "sessions.changed":
            LeftChatProbe.of(self).changed += 1   // [diagnostics]
            scheduleChangedPass()
            return
        case "session.reclaimed":
            if let rid = runtimeSessionId, event.payload["session_id"]?.string == rid || event.sessionId == rid { reclaimed() }
            else { AppLog.trace("turn", "reclaimed for another runtime, ignored by \(logIds)") }
            return
        case "btw.complete", "background.complete":
            sideTaskFinished(event)   // /btw, /bg: by task id, beside the turn (SideTasks.swift)
            return
        default: break
        }
        if let retired = retiredRuntimeId, event.sessionId == retired, event.type == "error" {
            // The `error` that follows a failed resume hydration (03 §3.1.2) still belongs to this chat.
            AppLog.trace("turn", "error frame from retired rt \(AppLog.tag(retired)) taken by \(AppLog.tag(storedSessionId)) (failed hydration)")
            retiredRuntimeId = nil
            if parking { parked.append(event) } else { dispatch(event) }
            return
        }
        guard let rid = runtimeSessionId else { holdForResume(event); return }
        let inFlight = turn.busy || turn.awaitingResponse || turn.streamId != nil
        let mine = event.sessionId == rid || (event.sessionId.isEmpty && event.type == "error" && inFlight)
        guard mine else { holdForResume(event); return }
        if parking { parked.append(event); return }
        dispatch(event)
    }

    /// While a `session.resume` is in flight, frames for a runtime we don't know yet may be for the runtime it is about
    /// to bind (the gateway rebinds before it answers). Held (bounded) and dispatched after the bind.
    /// A reconnect's `session.activate` can answer with a new runtime id too, and the gateway streams to it before it
    /// answers: those frames are held the same way (owner, 2026-10-15: "I was already in the same chat … its response is
    /// not showing"; the log showed 14 frames set aside on the open chat).
    private func holdForResume(_ event: GatewayEvent) {
        guard resumeFlight != nil || activating, !event.sessionId.isEmpty, resumeHeld.count < 512 else {
            if !event.sessionId.isEmpty {
                LeftChatProbe.of(self).foreign += 1   // [diagnostics]
                if resumeHeld.count >= 512 && (resumeFlight != nil || activating) && event.type != "message.delta" {
                    AppLog.trace("turn", "resume hold full (512) on \(logIds): \(event.type) for rt \(AppLog.tag(event.sessionId)) dropped")
                }
                if event.type == "message.complete" {
                    AppLog.trace("turn", "complete on foreign rt \(AppLog.tag(event.sessionId)) seen by \(logIds): tail read soon")
                    readAfterForeignReply()
                }
            }
            return
        }
        resumeHeld.append(event)
    }

    /// A reply finished on a runtime this chat isn't bound to (another of this chat's runtimes, or another chat's): one
    /// cheap tail probe 1.2 s on, so a reply saved to this chat shows without leaving and coming back. The probe reads one
    /// row and stops when the newest row is the one shown.
    func readAfterForeignReply() {
        LeftChatProbe.of(self).foreignReads += 1   // [diagnostics]
        probeTailSoon()
    }

    /// One tail read `after` from now while the chat is on screen and no turn of ours runs: after a foreign reply, after
    /// each reconnect (a reply that finished while the link was paused in the background has no frame to tell us), and
    /// for a tapped alert about this chat when it is already on screen (`force`: the alert says a reply is there).
    /// Owner, 2026-10-15, build 278: "It happened again. Same bot" — the alert was tapped with the chat already open.
    func probeTailSoon(after delay: Duration = .milliseconds(1200), force: Bool = false) {
        guard observing else { return }
        if force { foreignReadTask?.cancel(); foreignReadTask = nil }
        guard foreignReadTask == nil else { return }
        foreignReadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.foreignReadTask = nil
            guard self.observing, self.openSettled, force || !self.turn.busy || self.turnNotOnGateway else { return }
            self.startRefresh(force: force)
        }
    }

    /// The frames held while a reconnect's `session.activate` was out: the runtime it bound's are dispatched (parked
    /// while the reconnect runs), the rest set aside.
    func releaseActivateHeld() {
        guard activating else { return }
        activating = false
        guard resumeFlight == nil else { return }   // a resume that began meanwhile owns the hold now
        let held = resumeHeld
        resumeHeld = []
        if !held.isEmpty {
            AppLog.trace("turn", "activate hold released \(logIds): \(held.filter { $0.sessionId == runtimeSessionId }.count) of \(held.count) frames for the bound runtime, rest foreign")
        }
        for frame in held {
            if heldFrameIsMine(frame) { if parking { parked.append(frame) } else { dispatch(frame) } }
            else {
                LeftChatProbe.of(self).foreign += 1
                // [catch-up] as `holdForResume`: a reply that finished on another runtime asks for one tail read.
                if frame.type == "message.complete" { readAfterForeignReply() }
            }
        }
    }

    /// Dispatch with seq dedupe (04 §7.5); replayed and parked frames come through here too.
    func dispatch(_ event: GatewayEvent) {
        if let seq = event.seq {
            if let last = lastSeq, seq <= last {
                LeftChatProbe.of(self).stale += 1   // [diagnostics] counted
                if !event.type.hasSuffix(".delta") {
                    AppLog.trace("turn", "\(event.type) seq \(seq) ≤ last \(last) on \(logIds): already applied, dropped")
                }
                return
            }
            lastSeq = seq
        }
        turn.lastEventAt = Date()
        fold(event)
        scheduleFlush()
    }

    func releaseParked() {
        let frames = parked
        parked = []
        if !frames.isEmpty {
            AppLog.trace("turn", "parked frames released \(logIds): \(frames.count) held during open/reconnect, \(frames.filter { $0.sessionId == runtimeSessionId || $0.sessionId.isEmpty }.count) for this runtime")
        }
        for frame in frames where frame.sessionId.isEmpty || heldFrameIsMine(frame) { dispatch(frame) }
    }

    /// A frame set aside meanwhile is this chat's: its runtime's, or the `error` that follows a failed resume hydration
    /// on the runtime that failure just retired (as `receive` takes it). Held behind the `session.resume_progress
    /// failed` frame, that error was dropped once the failure had let go of the runtime, and the turn showed Working…
    /// with no error until Stop or a reopen.
    func heldFrameIsMine(_ frame: GatewayEvent) -> Bool {
        if frame.sessionId == runtimeSessionId { return true }
        guard frame.type == "error", let retired = retiredRuntimeId, frame.sessionId == retired else { return false }
        AppLog.trace("turn", "held error frame from retired rt \(AppLog.tag(retired)) taken by \(AppLog.tag(storedSessionId)) (failed hydration)")
        retiredRuntimeId = nil
        return true
    }

    private func fold(_ event: GatewayEvent) {
        let p = event.payload
        let type = event.type
        if type.hasPrefix("message.") || type.hasPrefix("tool.") || type.hasPrefix("reasoning.") || type == "error" {
            if type != "tool.generating" { turn.generatingTool = nil }
        }
        // [activity] An explained provider wait ends with the turn's next real frame (docs/spec/1x-activity.md §8.2).
        if turn.providerWait != nil, ProviderWait.clearingEvents.contains(type) { turn.providerWait = nil; changes.markState() }
        switch type {                                       // [doubled-reply] the turn's own edges
        case "message.start", "error": noteCatchUp(type)
        case "message.complete":
            let row = p["persisted_turn"]?["final_assistant_row_id"]?.positiveInt ?? p["row_id"]?.positiveInt
            noteCatchUp("complete row \(row.map(String.init) ?? "-")")
        case "session.info" where p["running"]?.bool != nil: noteCatchUp("info running \(p["running"]?.bool == true)")
        default: break
        }
        switch type {
        case "message.start": onStart()
        case "message.delta": onDelta(LiveChatSession.coerceText(p["text"]), reasoning: false)
        case "reasoning.delta": onDelta(LiveChatSession.coerceText(p["text"]), reasoning: true)
        case "thinking.delta":
            // [activity] Only the core's explained waits show; spinner rewrites clear one (§8.2).
            let wait = ProviderWait.text(p["text"]?.string)
            if (turn.providerWait ?? "") != wait { turn.providerWait = wait.isEmpty ? nil : wait; changes.markState() }
        case "reasoning.available":
            flushDeltas(); onReasoningAvailable(LiveChatSession.coerceText(p["text"]))
        case "message.interim":
            flushDeltas(); onInterim(LiveChatSession.coerceText(p["text"]))
        case "tool.generating":
            if !turn.interrupted { turn.generatingTool = p["name"]?.string }
        case "tool.start":
            flushDeltas(); onToolStart(p)
        case "tool.complete":
            flushDeltas(); onToolComplete(p)
        case "status.update":
            switch p["kind"]?.string {
            case "compacting", "compressing": turn.compacting = true
            case "compacted", "ready": turn.compacting = false
            default: break
            }
            activityStatusUpdate(p)       // [activity] the fallback-model notice line (§8.3)
            noteModelFallback(p)          // [sessions-m9] Session Info › Answered by (3x-sessions §10.3)
        case "message.complete":
            if let usage = SessionUsage.decode(p["usage"]) { menus.usage = usage }     // [sessions-m9]
            flushDeltas(); onComplete(p)
        case "session.usage":
            // [sessions-m9] A mid-turn tick: Session Info's Context, Tokens and Cost follow it.
            if let usage = SessionUsage.decode(p["usage"]) { menus.usage = usage }
        case "session.info":
            onSessionInfo(p)
        case "error":
            flushDeltas(); onError(p)
        case "session.resume_progress":
            if p["status"]?.string == "failed" {
                // Hydration failed and the gateway discarded this runtime: resume again on the next send (03 §3.1.2).
                AppLog.note("chat", "resume hydration failed on \(logIds): runtime retired, next send resumes")
                retiredRuntimeId = runtimeSessionId
                runtimeSessionId = nil
                lastSeq = nil
            }
        case "session.title":
            // The gateway's model title replaces its own instant one (the opening words), not only an empty name.
            if let t = p["title"]?.nonEmptyString, t != title, ShortTitle.isPlaceholder(title, firstMessage: firstUserText ?? "") {
                applyTitle(t, rowTitle: t)
            }
        default: break
        }
    }

    /// `message.complete.text` may be a parts list on relay paths (V:lib/chat-runtime.ts:72-100).
    static func coerceText(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .array(let items):
            return items.map { item -> String in
                if case .string(let s) = item { return s }
                return item["text"]?.string ?? item["output_text"]?.string ?? ""
            }.joined()
        case .object(let o): return o["text"]?.string ?? o["output_text"]?.string ?? ""
        default: return ""
        }
    }

    // MARK: Turn start / deltas

    private func onStart() {
        if turn.interrupted {
            AppLog.trace("turn", "start on \(logIds) ignored: turn stopped (stop pending=\(turn.stopPending))")
            if turn.stopPending { reinterrupt() }
            return
        }
        let wasLive = turn.turnLive
        AppLog.trace("turn", "start on \(logIds): \(wasLive ? "next message in the live turn" : turn.busy ? "our send's turn" : "a turn this phone didn't send"), anchor \(AppLog.tag(turn.userAnchorId)), rows=\(messages.count)")
        if wasLive { flushDeltas() } else { pendingDeltas.removeAll() }
        // A turn we didn't just send (another device, a server-drained queue, an auto-continue): no own user bubble.
        let foreign = !wasLive && !turn.busy
        if foreign { turn.userAnchorId = nil; turn.anchorPromptKey = nil }
        if !wasLive { turn.inflightUserKey = nil }
        turn.idleConfirmed = false
        turn.busy = true
        turn.awaitingResponse = true
        turn.sawAssistantPayload = false
        turn.interimBoundaryPending = false
        turn.turnLive = true
        turn.turnStartedAt = turn.turnStartedAt ?? Date()
        if !wasLive { turn.streamId = nil; turn.openPart = nil; turn.heartbeatSettledStreamId = nil }
        changes.markState()
        armWatchdog()
        if foreign { scheduleForeignPromptRead() }
    }

    /// [foreign-prompt] Owner 2026-11-03: a voice memo sent from the iPhone never showed in the same chat open on the
    /// Mac while Hermes worked on it. A turn another device started brings no prompt over the stream; only the turn-end
    /// read showed it, minutes later. Hermes stores the prompt as the turn starts, so one forced tail read now shows it
    /// (a read while a turn runs keeps the prompt and cuts the reply, which goes on streaming into its live row).
    func scheduleForeignPromptRead() {
        guard observing else { return }
        foreignPromptTask?.cancel()
        let delay = foreignPromptReadDelay
        foreignPromptTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.foreignPromptTask = nil
            guard self.observing, self.openSettled, self.turn.busy, !self.turn.interrupted else { return }
            AppLog.trace("history", "foreign prompt read \(self.logIds): a turn this device didn't send started, reading its prompt")
            self.startRefresh(force: true)
        }
    }

    private func onDelta(_ text: String, reasoning: Bool) {
        guard !turn.interrupted, !text.isEmpty else { return }
        if let last = pendingDeltas.last, last.reasoning == reasoning {
            pendingDeltas[pendingDeltas.count - 1].text += text
        } else {
            pendingDeltas.append((reasoning, text))
        }
        if !turn.busy { turn.busy = true; turn.turnLive = true; changes.markState(); armWatchdog() }
        turn.sawAssistantPayload = true
        turn.awaitingResponse = false
    }

    /// Applies coalesced deltas to the live message (once per frame, and before any non-delta event).
    func flushDeltas() {
        guard !pendingDeltas.isEmpty else { return }
        let batch = pendingDeltas
        pendingDeltas = []
        guard !turn.interrupted else { return }
        let sid = ensureLiveMessage()
        for delta in batch {
            updateMessage(sid) { m in
                if let open = turn.openPart, open.reasoning == delta.reasoning, open.index == m.parts.count - 1 {
                    switch m.parts[open.index] {
                    case .text(let t) where !delta.reasoning: m.parts[open.index] = .text(t + delta.text); return
                    case .reasoning(let t) where delta.reasoning: m.parts[open.index] = .reasoning(t + delta.text); return
                    default: break
                    }
                }
                m.parts.append(delta.reasoning ? .reasoning(delta.text) : .text(delta.text))
                turn.openPart = (m.parts.count - 1, delta.reasoning)
            }
        }
    }

    /// The live assistant message for this turn, created on first content (04 §4.2: `assistant-stream-<n>`).
    @discardableResult
    func ensureLiveMessage() -> String {
        if let sid = turn.streamId, indexById[sid] != nil { return sid }
        localCounter += 1
        var m = ChatMessage(id: "local-assistant-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
        m.isStreaming = true
        AppLog.trace("turn", "live row \(AppLog.tag(m.id)) added on \(logIds) at \(messages.count) (previous stream \(AppLog.tag(turn.streamId)))")
        appendMessage(m)
        turn.streamId = m.id
        turn.openPart = nil
        if !turn.busy { turn.busy = true; turn.turnLive = true; changes.markState() }
        return m.id
    }

    private func onReasoningAvailable(_ text: String) {
        guard !turn.interrupted, !text.isEmpty else { return }
        let sid = ensureLiveMessage()
        updateMessage(sid) { m in
            guard TranscriptMerge.texts(m.parts).isEmpty else { return }
            let at = m.parts.firstIndex { if case .reasoning = $0 { return true } else { return false } } ?? 0
            m.parts.removeAll { if case .reasoning = $0 { return true } else { return false } }
            m.parts.insert(.reasoning(text), at: min(at, m.parts.count))
        }
        turn.openPart = nil
        turn.sawAssistantPayload = true
        turn.awaitingResponse = false
    }

    private func onInterim(_ text: String) {
        guard !turn.interrupted else { return }
        defer { turn.interimBoundaryPending = true; turn.openPart = nil }
        guard !ChatText.trimmed(text).isEmpty else { return }
        turn.sawAssistantPayload = true
        turn.awaitingResponse = false
        if let sid = turn.streamId, indexById[sid] != nil {
            updateMessage(sid) { m in
                let lastTool = m.parts.lastIndex(where: TranscriptMerge.isTool) ?? -1
                let segmentStart = lastTool + 1
                var segment = Array(m.parts[segmentStart...])
                segment.removeAll(where: TranscriptMerge.isText)
                m.parts = Array(m.parts[..<segmentStart]) + segment + [.text(text)]
            }
            return
        }
        let lastUser = turnAnchorIndex()
        if messages[(lastUser + 1)...].contains(where: { ChatText.flat($0.plainText).contains(ChatText.flat(text)) }) {
            AppLog.trace("turn", "interim on \(logIds) skipped: its text is already shown in this turn")
            return
        }
        let sid = ensureLiveMessage()
        updateMessage(sid) { m in m.parts.append(.text(text)) }
    }

    // MARK: Tools (04 §4.3)

    /// The message already holding this tool call (it may be an earlier, sealed one), searched from the newest.
    func toolOwner(_ toolId: String) -> String? {
        // Only the running turn's messages: a tool id an earlier turn used (gateways that number calls per turn, like
        // the performance fixture's "performance-tool-0") must not pull this turn's call into the old reply.
        let start = max(turnAnchorIndex() + 1, messages.count - 12)
        guard start < messages.count else { return nil }
        for m in messages[start...].reversed() where m.role == .assistant {
            if m.parts.contains(where: { if case .tool(let c) = $0 { return c.id == toolId } else { return false } }) { return m.id }
        }
        return nil
    }

    /// A `tool.complete` with no `tool_id` finishes the newest call this turn started without one (filed as
    /// `live-tool-N`), so it settles that row instead of adding a second one beside it ("Result unavailable" at the end).
    private func idlessToolStart(_ p: JSONValue) -> String? {
        // Same name, unless the finish names none or only the bridge (`tool_call`, unwrapped at the start).
        let named = p["name"]?.nonEmptyString.flatMap { $0 == "tool_call" ? nil : $0 }
        func fits(_ name: String) -> Bool { named.map { $0 == name } ?? true }
        let start = max(turnAnchorIndex() + 1, 0)
        if start < messages.count {
            for m in messages[start...].reversed() where m.role == .assistant {
                for part in m.parts.reversed() {
                    if case .tool(let c) = part, c.state == .running, c.id.hasPrefix("live-tool-"), fits(c.name) { return c.id }
                }
            }
        }
        return silentTools.first { $0.key.hasPrefix("live-tool-") && fits($0.value.name) }?.key
    }

    private static func toolArgs(_ p: JSONValue) -> [String: JSONValue] {
        var args = Hydration.firstNonEmptyObject([p["args"], p["arguments"]])
        if args.isEmpty, let ctx = p["context"]?.nonEmptyString { args["context"] = .string(ctx) }
        return args
    }

    private func onToolStart(_ p: JSONValue) {
        guard !turn.interrupted else { return }
        var name = p["name"]?.nonEmptyString ?? "tool"
        let toolId = p["tool_id"]?.nonEmptyString ?? "live-tool-\(localCounter + 1)"
        var args = LiveChatSession.toolArgs(p)
        if let inner = ToolNow.unwrap(name, args: args) { name = inner.name; args = inner.args }   // as the stored call (Folder)
        // [perf] One small serialization of the arguments (strings clipped first), not full passes over a big call.
        let input = args.isEmpty ? nil : ToolArgs.inputText(args)
        let rawText = args.isEmpty ? p["args_text"]?.string : nil
        let argsText = DraftCards.wholeArgsText(name: name, args: args)   // [drafts] a draft card draws its call whole
            ?? input.map { ToolArgs.boundedText(args, input: $0) } ?? ToolArgs.boundedText(args, raw: rawText)
        turn.sawAssistantPayload = true
        turn.awaitingResponse = false
        turn.openPart = nil
        if ToolPresentation.isSilent(name) {
            silentTools[toolId] = (name, args, argsText)
            return
        }
        let title = ToolPresentation.title(for: .init(name: name, args: args, pending: true, failed: false, hasResult: false), live: true)
        // [activity] Each argument clipped, not the JSON: the line, the code block and a card still read a big call.
        let call = ToolCall(id: toolId, name: name, title: title, argsText: argsText,
                            summary: nil, state: .running, durationSeconds: nil)
        if let owner = toolOwner(toolId) {
            updateMessage(owner) { m in
                for i in m.parts.indices {
                    guard case .tool(let old) = m.parts[i], old.id == toolId else { continue }
                    // A running event for a call sealed without a result re-opens it.
                    if old.state == .running || old.summary == "Result unavailable" { m.parts[i] = .tool(call) }
                }
            }
            return
        }
        let sid = ensureLiveMessage()
        updateMessage(sid) { m in m.parts.append(.tool(call)) }
        var meta = metaById[sid] ?? MessageMeta()
        var detail = ToolDetail()
        detail.command = ToolPresentation.firstString(args, ["command", "code"]).nilIfEmpty
        detail.input = input?.prefix ?? rawText.map { ChatText.clip($0, max: 4096) }
        if name == "image_generate" {                                   // [attachments] the live card's frame (spec §7.7)
            detail.generatedImage = GeneratedImageInfo.from(args: args, result: nil, running: true)
        }
        meta.tools[toolId] = detail
        metaById[sid] = meta
    }

    private func onToolComplete(_ p: JSONValue) {
        guard !turn.interrupted else { return }
        let toolId = p["tool_id"]?.nonEmptyString ?? idlessToolStart(p) ?? ""
        let silent = silentTools.removeValue(forKey: toolId)
        var name = p["name"]?.nonEmptyString ?? silent?.name ?? "tool"
        var args = LiveChatSession.toolArgs(p)
        if args.isEmpty, let silent { args = silent.args }
        if let inner = ToolNow.unwrap(name, args: args) { name = inner.name; args = inner.args }
        let result = p["result"] ?? p["result_text"]
        let isError = p["error"].isTruthy
        let duration = p["duration_s"]?.double
        let inlineDiff = p["inline_diff"]?.string
        turn.sawAssistantPayload = true
        turn.awaitingResponse = false
        turn.openPart = nil

        let owner = toolOwner(toolId)
        var existingArgsText: String?
        if let owner, let index = indexById[owner] {
            for part in messages[index].parts {
                guard case .tool(let c) = part, c.id == toolId else { continue }
                existingArgsText = c.argsText
                if name == "tool_call" { name = c.name }   // the start already named the call inside the bridge
            }
            if args.isEmpty, let t = existingArgsText, let o = ChatJSON.parse(string: t)?.object { args = o }
        }
        // [perf] As at the start: the 4 KB input prefix without a full serialization (the detail clips it to 4 KB anyway).
        let input = args.isEmpty ? nil : ToolArgs.inputText(args)
        let argsText = input?.prefix ?? existingArgsText
        var detail = ToolPresentation.detail(args: args, argsText: argsText, result: result, isError: isError,
                                             inlineDiff: inlineDiff, payloadRef: nil)
        if name == "image_generate" {                                   // [attachments] the settled card (spec §7.7)
            detail.generatedImage = GeneratedImageInfo.from(args: args, result: result, running: false)
        }
        if ToolScreenshots.isScreenshotTool(name) {                     // [screen] the step's screenshot (spec 3x §5.3)
            detail.screenshot = ToolScreenshots.stepScreenshot(result: p["result"], resultText: p["result_text"]?.string,
                                                               summary: p["summary"]?.string,
                                                               at: Date().timeIntervalSince1970)
        }
        let failed = detail.failed
        if ToolPresentation.isSilent(name) && !failed { return }      // §8.10: successful silent calls draw nothing
        let title = ToolPresentation.title(for: .init(name: name, args: args, pending: false, failed: failed, hasResult: result != nil),
                                           live: false)
        var call = ToolCall(id: toolId.isEmpty ? "live-tool-\(localCounter + 1)" : toolId, name: name, title: title,
                            argsText: DraftCards.wholeArgsText(name: name, args: args)   // [drafts]
                                ?? input.map { ToolArgs.boundedText(args, input: $0) }
                                ?? ToolArgs.boundedText(args, raw: argsText),          // [activity] bounded per value
                            summary: ClarifySettled.summary(name: name, result: result,   // [questions] settled Q&A (1x §4.4)
                                fallback: ToolPresentation.shortSummary(payloadSummary: p["summary"]?.string, detail: detail)),
                            state: failed ? .failed : .done, durationSeconds: duration)
        if !failed { call.card = ToolCards.card(name: name, args: args, result: result) }    // [activity] §11.1
        if result != nil { call.note = ToolWords.rowNote(name: name, stdout: detail.stdout, stderr: detail.stderr, detail: detail.detail,
                                                         bytes: detail.payloadRef?["bytes"]?.double ?? ToolWords.resultBytes(result), failed: failed) }   // [transcript] §5.1
        let target = owner ?? ensureLiveMessage()
        updateMessage(target) { m in
            if let i = m.parts.firstIndex(where: { if case .tool(let c) = $0 { return c.id == call.id } else { return false } }) {
                m.parts[i] = .tool(call)
            } else {
                m.parts.append(.tool(call))
            }
        }
        var meta = metaById[target] ?? MessageMeta()
        meta.tools[call.id] = detail
        metaById[target] = meta
    }

    // MARK: Turn end (04 §4.5)

    private func onComplete(_ p: JSONValue) {
        let text = LiveChatSession.coerceText(p["text"])
        let status = p["status"]?.string
        let isError = status == "error"
        let persisted = p["persisted_turn"]
        let finalRow = persisted?["final_assistant_row_id"]?.positiveInt ?? p["row_id"]?.positiveInt
        let userRow = persisted?["user_row_id"]?.positiveInt
        // A send that went out past the stop hold: an end naming its own prompt is its own turn's (the stopped turn's
        // end never came), so it is no longer held.
        if let userRow, let anchor = turn.userAnchorId, let i = indexById[anchor], messages[i].rowId == userRow {
            releaseSendPastStop("the turn end names its prompt")
        }
        // The late end of an earlier turn (settled early by a "not running" heartbeat or the watchdog) that lands after
        // the next send: it names that earlier prompt, so it neither ends this turn nor draws the old reply under the
        // new message. The turn-end read brings the old reply's stored text.
        if let userRow, turn.busy, !turn.submitHeld, !turn.interrupted, let anchorId = turn.userAnchorId,
           let anchor = indexById[anchorId], messages[anchor].rowId != userRow,
           let earlier = messages[..<anchor].lastIndex(where: { $0.role == .user && $0.rowId == userRow }) {
            AppLog.note("turn", "complete on \(logIds) names user row \(userRow) (\(AppLog.tag(messages[earlier].id)) at \(earlier)), not the running turn's prompt at \(anchor): an earlier turn's late end, ignored")
            return
        }
        let wasStopPending = turn.stopPending
        let turnBegan = turn.turnStartedAt   // [transcript] §6.6: how long the turn took, measured here
        // A send held behind a Stop (04 §5.4) means this frame is the stopped turn's, scoped to that turn's rows.
        let heldBehindStop = turn.submitHeld
        let anchorIndex = heldBehindStop ? (turn.stoppedAnchorId.flatMap { indexById[$0] } ?? turnAnchorIndex()) : turnAnchorIndex()
        let scopeEnd = turnScopeEnd(after: anchorIndex)   // steered messages are inside the turn
        let lastInScope = scopeEnd > anchorIndex + 1 ? messages[scopeEnd - 1] : nil
        let stopFailed = wasStopPending || (!turn.interrupted && lastInScope?.interrupted == true && lastInScope?.parts.isEmpty == true)
        stopTerminalReached()
        let lids = logIds
        AppLog.trace("turn", "complete on \(lids): status \(status ?? "-"), final row \(finalRow.map(String.init) ?? "-"), user row \(userRow.map(String.init) ?? "-"), stream \(AppLog.tag(turn.streamId)), anchor at \(anchorIndex), scope end \(scopeEnd)/\(messages.count), stopped=\(turn.interrupted), held behind stop=\(heldBehindStop), \(text.count) chars")

        if turn.interrupted {
            if wasStopPending, isError, p["error_surface"]?["code"]?.string == "agent_init_failed" {
                AppLog.trace("turn", "complete on \(lids): stopped before the agent was ready; settled quietly")
                settleStoppedTurn(); changes.markState(); return                  // nothing ran; settle quietly
            }
            if wasStopPending, status != "interrupted", !isError {
                // The stop never reached the turn: never drop a completed reply (§5.6 step 4).
                AppLog.note("turn", "complete on \(lids): the stop never reached the turn; reply kept, \"Couldn't stop\" shown")
                turn.interrupted = false
                onNotice?("Couldn't stop — Hermes finished the reply.")
            } else {
                // Extend-only, and only a real interrupted partial (04 §4.5 step 3): a stand-in's bare `complete`
                // (or one racing the Stop) never adds a bubble the stored chat doesn't have.
                AppLog.trace("turn", "complete on \(lids): stopped turn's end (\(status == "interrupted" ? "partial may extend the shown bubble" : "nothing added")); end read scheduled")
                if status == "interrupted" { extendInterrupted(text) }
                settleStoppedTurn()
                changes.markState()
                scheduleTurnEndRead()
                return
            }
        }

        func inScope(_ id: String?) -> String? {
            guard let id, let i = indexById[id], i > anchorIndex, i < scopeEnd else { return nil }
            return id
        }
        var target = inScope(turn.streamId) ?? inScope(turn.heartbeatSettledStreamId)
        var targetWhy = target == nil ? "none" : inScope(turn.streamId) != nil ? "live row" : "heartbeat-settled row"
        if target == nil {
            let turnMessages = messages[(anchorIndex + 1)..<scopeEnd].filter { $0.role == .assistant }
            if let pending = turnMessages.last(where: { $0.isStreaming }) { target = pending.id; targetWhy = "streaming row in scope" }
            else if let finalRow, let m = turnMessages.first(where: { $0.rowId == finalRow }) { target = m.id; targetWhy = "row with the final row id" }
            else if !text.isEmpty, let m = turnMessages.last, m.isLocal,
                    ChatText.flat(text).hasPrefix(ChatText.flat(m.plainText)) || ChatText.flat(m.plainText).hasPrefix(ChatText.flat(text)) {
                target = m.id; targetWhy = "local row whose text is a prefix"
            }
        }
        // The row this end names is on screen already (a read landed before the turn's frames: an alert-opened chat
        // whose first page held a subagent's reply, then that turn's catch-up; an end delivered again after a
        // reconnect): that copy stays the one, and the turn's live bubble goes instead of drawing the reply twice
        // (owner 2026-10-26, "App" bot, row 6155 shown twice until the next read). A stored reply with tool steps is
        // filed under its first text row, so one whose folded rows reach the final row counts too (log study 2026-10-28).
        var alreadyShown = false
        if let finalRow, !isError,
           let shown = messages.first(where: { $0.role == .assistant && $0.id != target
               && TranscriptMerge.holds($0, metaById[$0.id], row: finalRow) }) {
            let dropLive = target.flatMap { t in t != shown.id ? indexById[t].map { messages[$0].isLocal } : nil } ?? false
            AppLog.note("merge", "complete on \(lids): final row \(finalRow) already shown as \(AppLog.tag(shown.id)) at \(indexById[shown.id] ?? -1); keeps it, \(dropLive ? "drops live row \(AppLog.tag(target))" : "no live row to drop") (no double)")
            if let t = target, t != shown.id, let i = indexById[t], messages[i].isLocal { removeMessage(t) }
            target = nil
            alreadyShown = true
        }
        if target == nil && !alreadyShown && (!ChatText.trimmed(text).isEmpty || isError) {
            localCounter += 1
            let m = ChatMessage(id: "local-assistant-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
            insertMessage(m, at: scopeEnd)
            target = m.id
            targetWhy = "new row at \(scopeEnd) (nothing in scope)"
        }
        AppLog.trace("turn", "complete on \(lids): final text → \(AppLog.tag(target)) (\(targetWhy)), error=\(isError), already shown=\(alreadyShown), live row \(AppLog.tag(turn.streamId)) sealed, warning=\(p["warning"]?.nonEmptyString != nil)")
        if let target {
            let partial = p["partial"]?.bool == true
            let errorText = (p["error"]?.nonEmptyString) ?? (ChatText.trimmed(text).isEmpty ? "Hermes couldn't finish this turn." : text)
            updateMessage(target) { m in
                m.isStreaming = false
                if stopFailed { m.interrupted = false }      // the stop never landed: this is a whole reply
                if !isError || partial { m.parts = TranscriptMerge.mergeFinalText(m.parts, text) }
                if isError {
                    if !partial { m.parts.removeAll(where: TranscriptMerge.isText) }
                    m.error = errorText
                }
                LiveChatSession.sealTools(&m, summary: "Result unavailable")
                if m.rowId == nil, let finalRow { m.rowId = finalRow }
            }
            if !turn.sawAssistantPayload && !isError { turn.heartbeatSettledStreamId = nil }
            if !isError, !turn.interrupted, let turnBegan { noteTurnDuration(messageId: target, seconds: Date().timeIntervalSince(turnBegan)) }
        }
        // The live bubble is always sealed, even when the final text landed elsewhere.
        if let sid = turn.streamId, sid != target, indexById[sid] != nil {
            updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
        }
        // `persisted_turn.user_row_id` belongs to this turn's own prompt only.
        let ownPrompt = heldBehindStop ? turn.stoppedAnchorId : turn.userAnchorId
        if let userRow, let anchor = ownPrompt, let index = indexById[anchor], messages[index].isLocal,
           messages[index].role == .user {
            updateMessage(anchor) { m in if m.rowId == nil { m.rowId = userRow }; m.isPending = false }
        }
        if let warning = p["warning"]?.nonEmptyString { onNotice?(warning) }
        // The turn's end landed: a reply sealed early by a heartbeat is done with, so a later end that comes without a
        // start of its own (a cut-short replay) never writes into it.
        turn.heartbeatSettledStreamId = nil
        if heldBehindStop { settleStoppedTurn() } else { settleFlags() }
        silentTools = [:]
        changes.markState()
        scheduleTurnEndRead()
        scheduleQueueDrain(after: turn.idleConfirmed ? .zero : queueDrainFallback)
        if !isError, status != "interrupted" { shortenTitleIfNeeded() }
    }

    /// The stopped turn reached its end. A send held behind it (04 §5.4) keeps its own busy state.
    func settleStoppedTurn() {
        if turn.submitHeld {
            turn.heartbeatSettledStreamId = nil
            releaseSendPastStop("the stopped turn ended")
        } else {
            settleFlags()
        }
    }

    /// Inserts a message inside the transcript (a stopped turn's late reply before a newer prompt); at the end it is a
    /// plain append.
    func insertMessage(_ message: ChatMessage, at index: Int) {
        guard index < messages.count else { appendMessage(message); return }
        var next = messages
        next.insert(message, at: max(0, index))
        messages = TranscriptMerge.diff(old: messages, new: next, into: &changes)
        rebuildIndex()
    }

    /// Stop's extend-only merge (V:…/interrupted-reply.ts): a persisted partial that extends what was shown wins. Scoped
    /// to the stopped turn's rows (its prompt up to the next prompt), so a send made meanwhile is never touched. It only
    /// ever extends the stopped turn's own bubble; a partial with nothing shown arrives with the turn-end read instead.
    private func extendInterrupted(_ raw: String) {
        let text = ChatText.trimmed(raw)
        guard !text.isEmpty else { return }
        let anchor = turn.stoppedAnchorId.flatMap { indexById[$0] } ?? turnAnchorIndex()
        let end = turnScopeEnd(after: anchor)
        let turnMessages = messages[(anchor + 1)..<end].filter { $0.role == .assistant }
        guard let target = turnMessages.last else { AppLog.trace("turn", "interrupted partial: no stopped bubble to extend"); return }
        let merged = TranscriptMerge.mergeFinalText(target.parts, text)
        let shown = ChatText.flat(target.plainText)
        let persisted = ChatText.flat(TranscriptMerge.texts(merged))
        guard persisted.count > shown.count, persisted.hasPrefix(shown) else {
            AppLog.trace("turn", "interrupted partial not applied to \(AppLog.tag(target.id)): \(persisted.count) vs shown \(shown.count) chars, prefix=\(persisted.hasPrefix(shown))")
            return
        }
        AppLog.trace("turn", "interrupted partial extends \(AppLog.tag(target.id)): \(shown.count) → \(persisted.count) chars")
        updateMessage(target.id) { m in m.parts = merged }
    }

    /// How long after a send held behind a stop a `running:false` snapshot is taken for the stopped turn's.
    static let stoppedTurnInfoWindow: TimeInterval = 3

    private func onSessionInfo(_ p: JSONValue) {
        applyModelInfo(p)                       // MENUS (spec 1x §2.1 rule 2): before the running guard
        guard let running = p["running"]?.bool else { return }
        if running {
            turn.idleConfirmed = false
            if turn.interrupted {
                if turn.stopPending { reinterrupt() }
                return
            }
            if !turn.busy || !turn.turnLive {
                AppLog.trace("turn", "info running on \(logIds): turn marked live (\(turn.busy ? "our send" : "a turn this phone didn't send"))")
                if !turn.busy { turn.userAnchorId = nil; turn.anchorPromptKey = nil }      // a turn this phone didn't send
                turn.busy = true
                turn.turnLive = true
                if turn.turnStartedAt == nil {
                    turn.turnStartedAt = p["turn_started_at"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date()
                }
                changes.markState()
                armWatchdog()
            }
            return
        }
        // running:false ends a stopped turn (it frees a send held behind it)…
        let wasStopPending = turn.stopTerminalPending
        stopTerminalReached()
        // …and lets go of a send that went out past the stop hold: this snapshot is the stopped turn's, not its.
        if releaseSendPastStop("the stopped turn's running:false") { return }
        // [attachments] A send still uploading or attaching hasn't reached the gateway: "not running" is true and says
        // nothing about its turn (a resume or reconnect during a long upload sends it).
        if turn.preparingSendId != nil { AppLog.trace("turn", "info not running on \(logIds) ignored: a send is still preparing"); return }
        if turn.forwarded { AppLog.trace("turn", "info not running on \(logIds) ignored: the send runs in the gateway's queue"); return }  // [desktop-forward]
        // The stopped turn's own end-of-turn snapshot, landing after the send held behind it began its turn: Hermes reads
        // `running` for it before that send is let in and emits it a moment later (`prompt_turn.py` finally →
        // `_emit_settled_session_info`, which waits on the update check). Taken as this turn's end, it ended a voice
        // request that had just replaced the stopped one: the voice was told nothing came back, and the work (34 s of
        // searches) left the screen while it ran (owner, 2026-10-28 20:49:23, seq 1019 after message.start 1018).
        if turn.busy, !turn.submitHeld, let after = turn.followsStopAt, Date().timeIntervalSince(after) < Self.stoppedTurnInfoWindow {
            turn.followsStopAt = nil
            AppLog.trace("turn", "info not running on \(logIds) ignored: the stopped turn's late snapshot, \(Int(Date().timeIntervalSince(after) * 1000)) ms after the send it held")
            return
        }
        // …but a pre-start heartbeat within 15 s of our own send never settles that send's turn (04 §4.6).
        if turn.awaitingResponse, !turn.sawAssistantPayload, !turn.turnLive, let armed = turn.armedAt,
           Date().timeIntervalSince(armed) < 15 {
            AppLog.trace("turn", "info not running on \(logIds) ignored: pre-start, \(Int(Date().timeIntervalSince(armed))) s after our send")
            return
        }
        turn.idleConfirmed = true
        guard turn.busy || turn.streamId != nil else {
            if wasStopPending { changes.markState() }
            scheduleQueueDrain(after: .zero)
            return
        }
        let wasLive = turn.turnLive
        flushDeltas()
        var survived = false
        if let sid = turn.streamId, let index = indexById[sid] {
            if messages[index].hasVisibleContent || messages[index].interrupted || messages[index].error != nil {
                updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
                turn.heartbeatSettledStreamId = sid
                survived = true
            } else {
                removeMessage(sid)
            }
        }
        AppLog.trace("turn", "info not running on \(logIds): turn settled before its complete; live row \(AppLog.tag(turn.streamId)) \(survived ? "kept (sealed)" : turn.streamId == nil ? "none" : "removed (empty)"), end read \(wasLive && !survived ? "forced" : "scheduled")")
        settleFlags()
        turn.idleConfirmed = true
        if survived, let sid = turn.heartbeatSettledStreamId { turn.heartbeatSettledStreamId = sid }
        changes.markState()
        if wasLive && !survived { scheduleTurnEndRead(force: true) } else { scheduleTurnEndRead() }
        // Settled by running:false before its message.complete: give that frame time to land before the next prompt.
        scheduleQueueDrain(after: queueDrainFallback)
    }

    private func onError(_ p: JSONValue) {
        let message = p["message"]?.string ?? p["message"]?["message"]?.string ?? "Hermes couldn't finish this turn."
        let range = NSRange(message.startIndex..., in: message)
        if LiveChatSession.cancelledBeforeReady.firstMatch(in: message, range: range) != nil {
            AppLog.trace("turn", "error on \(logIds) is a cancel-before-ready: treated as a stop (stopped=\(turn.interrupted), busy=\(turn.busy))")
            // A stop, never an error, and the turn's terminal frame (04 §5.4).
            if turn.interrupted { stopTerminalReached(); releaseSendPastStop("the stopped turn's cancel"); return }
            if turn.busy {
                if let sid = turn.streamId, indexById[sid] != nil {
                    updateMessage(sid) { m in m.isStreaming = false; m.interrupted = true; LiveChatSession.sealTools(&m, summary: "Stopped") }
                } else {
                    localCounter += 1
                    var marker = ChatMessage(id: "local-stopped-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
                    marker.interrupted = true
                    appendMessage(marker)
                }
                settleFlags()
                changes.markState()
            }
            stopTerminalReached()
            return
        }
        // [attachments] A send still uploading has no turn on the gateway yet: an error now isn't about it.
        let preparing = turn.preparingSendId != nil && turn.streamId == nil
        let inFlight = (turn.busy || turn.awaitingResponse || turn.streamId != nil) && !preparing
        guard inFlight, !turn.interrupted else {
            // A chat-level failure with no turn in flight (or from a turn the user stopped): a notice, no error card
            // (gate r3-03).
            if turn.interrupted {
                AppLog.trace("turn", "error on \(logIds) after Stop: notice only")
                stopTerminalReached(); settleStoppedTurn(); onNotice?(message); return
            }
            // [transcript] §6.2 (the web's r5-92): a problem with the chat itself is a card above the composer that
            // stays until it is dealt with, not a toast that is gone in three seconds.
            let problem = SessionProblem.make(text: message, botName: botName)
            AppLog.note("turn", "error on \(logIds) with no turn in flight (preparing=\(preparing)): \(problem != nil ? "problem card shown" : "ignored")")
            if let problem { sessionProblem = problem }
            return
        }
        AppLog.note("turn", "error on \(logIds) ends the turn: \(turn.streamId.flatMap { indexById[$0] } != nil ? "on live row \(AppLog.tag(turn.streamId))" : "new error card"); end read scheduled")
        if let sid = turn.streamId, indexById[sid] != nil {
            updateMessage(sid) { m in m.isStreaming = false; m.error = message; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
        } else {
            localCounter += 1
            var card = ChatMessage(id: "local-error-\(localCounter)", role: .assistant, parts: [], timestamp: Date(), rowId: nil)
            card.error = message
            appendMessage(card)
        }
        settleFlags()
        changes.markState()
        scheduleTurnEndRead()
        scheduleQueueDrain(after: queueDrainFallback)
    }

    private func reclaimed() {
        AppLog.note("chat", "reclaimed \(logIds): runtime dropped; busy=\(turn.busy), preparing=\(turn.preparingSendId != nil)\(turn.busy && turn.preparingSendId == nil ? ", turn settled, end read forced" : "")")
        runtimeSessionId = nil
        lastSeq = nil
        // [attachments] A send still preparing resumes a new runtime for its attaches; its turn hasn't started.
        if (turn.busy || turn.streamId != nil) && turn.preparingSendId == nil {
            flushDeltas()
            if let sid = turn.streamId, indexById[sid] != nil {
                updateMessage(sid) { m in m.isStreaming = false; LiveChatSession.sealTools(&m, summary: "Result unavailable") }
            }
            settleFlags()
            changes.markState()
            scheduleTurnEndRead(force: true)
            scheduleQueueDrain(after: queueDrainFallback)
        }
        stopTerminalReached()
    }
}
