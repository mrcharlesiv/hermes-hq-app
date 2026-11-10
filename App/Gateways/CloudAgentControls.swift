// Managing a Hermes Cloud agent that exists, from its own page (CloudAgentScreens.swift): stop, start, restart, rename,
// resize, update Hermes, environment variables, disk, Team Gateway and delete. Each is one call to Portal's `agent` tool
// (HermesKit/Cloud/HermesCloudClient.swift), then the agent's live status is watched until it settles (Nous stops and
// starts the machine for most of them), with what Nous says shown under the agent's name. Costs come from the same
// table as the New Agent form (HermesKit/Cloud/CloudPrices.swift). Deleting an agent also removes its saved gateway on
// this phone (unless HQ is using it); renaming one renames its gateway if it still had the agent's old name.

import SwiftUI
import UIKit

/// What's being done to one agent, for its row and its page.
struct CloudBusy: Equatable {
    var action: CloudAction
    var words: String
    var started: Date
}

/// The page of one agent: a hosting controller that knows which, so a rename can retitle it.
final class CloudAgentHost: UIHostingController<HQScaledRoot<CloudAgentPage>> {
    let agentId: String

    init(rootView: HQScaledRoot<CloudAgentPage>, agentId: String) {
        self.agentId = agentId
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Names of the variables this phone set on an agent (never their values): Nous's agent row may not list them.
nonisolated enum CloudEnvNames {
    static func key(_ id: String) -> String { "hqn.cloud.env.\(id)" }

    static func load(_ id: String, _ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(id)) ?? []
    }

    static func save(_ names: [String], for id: String, _ defaults: UserDefaults = .standard) {
        if names.isEmpty { defaults.removeObject(forKey: key(id)) } else { defaults.set(Array(Set(names)).sorted(), forKey: key(id)) }
    }

    /// A shell variable name: letters, digits and underscores, not starting with a digit.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }
    }
}

extension CloudGatewayModel {
    /// Tapping an agent: its page, and what the page needs that the list doesn't carry.
    func open(_ agent: CloudAgent) {
        onRoute?(.agent(agent.id))
        loadDetails(agent)
    }

    /// The actions offered, the sizes resize takes, Team Gateway's state and a live row.
    func loadDetails(_ agent: CloudAgent) {
        guard !demo else { return }
        let client = self.client
        Task {
            if offered.isEmpty { offered = await client.offered() }
            if sizeChoices.isEmpty { sizeChoices = await client.sizeChoices() }
            if let found = await client.teamGateway(agent.id) { teamGateways[agent.id] = found }
            if busy[agent.id] == nil, let fresh = try? await client.agent(agent.id, live: true) { update(fresh) }
        }
    }

    /// Whether this Portal offers an action (everything shows until its schema is read).
    func can(_ action: CloudAction) -> Bool { offered.isEmpty || offered.contains(action) }

    /// HQ is signed in to this agent right now: stopping or deleting it quiets the app.
    func isCurrent(_ agent: CloudAgent) -> Bool { savedGateway(agent)?.isCurrent ?? false }

    /// The variable names known for an agent: Nous's row, and the ones this phone set.
    func envNames(_ agent: CloudAgent) -> [String] {
        Array(Set(agent.envNames + CloudEnvNames.load(agent.id))).sorted()
    }

    /// Disk sizes to offer: Nous's when it has said, else the usual steps, all larger than the disk it has.
    func diskOffers(_ agent: CloudAgent) -> [Int] {
        let known = !agent.diskChoices.isEmpty ? agent.diskChoices : !diskChoices.isEmpty ? diskChoices : [10, 20, 40, 80, 160]
        return known.filter { $0 > (agent.diskGB ?? 0) }.sorted()
    }

    /// Pull to refresh on an agent's page.
    func refreshAgent(_ agent: CloudAgent) async {
        guard !demo, busy[agent.id] == nil else { return }
        do {
            if let fresh = try await client.agent(agent.id, live: true) { update(fresh) }
        } catch let error as PortalError where error.kind == .signedOut {
            handle(error)
        } catch {
            AppLog.trace("cloud", "refresh \(agent.id) failed: \(Self.words(error))")
        }
        if let found = await client.teamGateway(agent.id) { teamGateways[agent.id] = found }
        if let now = self.agent(agent.id) { loadSpend([now]) }
    }

    // MARK: Asking first

    func askStop(_ agent: CloudAgent) {
        onConfirm?(CloudCopy.stopTitle(agent.name), CloudCopy.stopMessage(agent.name, size: CloudPrices.size(agent.size), current: isCurrent(agent)),
                   CloudCopy.stopWord, true) { [weak self] in self?.stop(agent) }
    }

    func askRestart(_ agent: CloudAgent) {
        onConfirm?(CloudCopy.restartTitle(agent.name), CloudCopy.restartMessage, CloudCopy.restartWord, true) { [weak self] in self?.restart(agent) }
    }

    /// [update-flow] The shared Update sheet: it reads the agent's own Hermes version, asks, then follows Nous's update
    /// to the version it answers with afterwards.
    func askUpdate(_ agent: CloudAgent) {
        HermesUpdateCenter.shared.updateCloud(id: agent.id, name: agent.name, read: { [weak self] in await self?.hermesVersion(agent) },
                                              go: { [weak self] run in self?.updateHermes(agent, run: run) }, from: nil)
    }

    /// [update-flow] The agent's Hermes version from its own `/api/status`: through its saved gateway's sign-in when
    /// this device has one, else the public status route at its dashboard address. Nil when neither answers. (Portal's
    /// agent rows carry no version key.)
    func hermesVersion(_ agent: CloudAgent) async -> String? {
        #if DEBUG
        if demo { return agent.version.isEmpty ? "0.22.5" : agent.version }
        #endif
        if let saved = savedGateway(agent), let endpoint = HermesUpdateCenter.endpoint(for: saved.account) {
            let version = await HermesUpdateAPI(endpoint: endpoint).version()
            endpoint.finish()
            if let version { return version }
        }
        guard let base = agent.dashboardURL, let url = try? GatewayAddress.endpoint(base: base, path: "/api/status") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONValue.parse(data) else { return nil }
        return json["version"]?.pgString.flatMap { $0.isEmpty ? nil : $0 }
    }

    func askRename(_ agent: CloudAgent) {
        onPrompt?(CloudCopy.renameTitle(agent.name), CloudCopy.renameMessage, agent.name, CloudCopy.renameWord, nameLimit) { [weak self] name in
            guard let self else { return }
            // Names stay unique: a create that outlasts its wait finds its agent by name.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if agents.contains(where: { $0.id != agent.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                actionFailure[agent.id] = CloudCopy.nameTaken
                Haptics.play(.error)
                return
            }
            rename(agent, to: trimmed)
        }
    }

    func askResize(_ agent: CloudAgent, to size: String) {
        let up = agent.isReady || agent.isRunning || agent.isSleeping
        onConfirm?(CloudCopy.resizeTitle(agent.name, to: size), CloudCopy.resizeMessage(from: agent.size, to: size, running: up), "Change", false) {
            [weak self] in
            self?.resize(agent, to: size)
            self?.onRoute?(.back)
        }
    }

    func askDisk(_ agent: CloudAgent, _ gb: Int) {
        onConfirm?(CloudCopy.diskTitle(gb), CloudCopy.diskMessage, "Grow", false) { [weak self] in self?.growDisk(agent, to: gb) }
    }

    func askSetVariable(_ agent: CloudAgent, name: String, value: String, done: @escaping () -> Void) {
        onConfirm?(CloudCopy.setVariableTitle(name, agent.name), CloudCopy.restartsToApply(agent.name), "Set", false) { [weak self] in
            self?.setVariable(agent, name: name, value: value)
            done()
        }
    }

    func askRemoveVariable(_ agent: CloudAgent, name: String) {
        onConfirm?(CloudCopy.removeVariableTitle(name), CloudCopy.restartsToApply(agent.name), "Remove", true) { [weak self] in
            self?.removeVariable(agent, name: name)
        }
    }

    // MARK: Actions

    func stop(_ agent: CloudAgent) { perform(.stop, on: agent) }
    func startOnly(_ agent: CloudAgent) { perform(.start, on: agent) }
    func restart(_ agent: CloudAgent) { perform(.restart, on: agent) }
    /// [update-flow] `update_image`, with a "latest" version or image only when Portal's schema clearly offers one.
    func updateHermes(_ agent: CloudAgent, run: HermesUpdate? = nil) {
        guard busy[agent.id] == nil else {
            run?.cloud(.failed("\(agent.name) is busy with something else. Try again when it’s done."))
            return
        }
        Task {
            var extra: [String: JSONValue] = [:]
            if !demo { extra = CloudUpdateImage.latest(await client.fields(for: .updateImage)) }
            perform(.updateImage, on: agent, extra) { run?.cloud($0) }
        }
    }
    func destroy(_ agent: CloudAgent) { perform(.destroy, on: agent) }

    func rename(_ agent: CloudAgent, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
        guard !trimmed.isEmpty, trimmed != agent.name else { return }
        perform(.rename, on: agent, ["name": .string(trimmed)])
    }

    func resize(_ agent: CloudAgent, to size: String) {
        guard size.lowercased() != agent.size.lowercased() else { return }
        perform(.resize, on: agent, ["size": .string(size)])
    }

    func growDisk(_ agent: CloudAgent, to gb: Int) {
        perform(.growDisk, on: agent, ["disk_gb": .number(Double(gb))])
    }

    func setTeamGateway(_ agent: CloudAgent, on: Bool) {
        perform(.setFeature, on: agent, ["feature_key": "relay", "enabled": .bool(on)])
    }

    func setVariable(_ agent: CloudAgent, name: String, value: String) {
        perform(.updateEnv, on: agent, ["env": .object([name: .string(value)])])
    }

    func removeVariable(_ agent: CloudAgent, name: String) {
        perform(.updateEnv, on: agent, ["deleted_keys": .array([.string(name)])])
    }

    /// One action: sent once (a timed-out answer is never re-sent, the action carries on at Nous), then the agent is
    /// watched until it settles. The row and the page show what Nous says meanwhile.
    /// `progress` ([update-flow]): what Nous says, for the Update sheet.
    func perform(_ action: CloudAction, on agent: CloudAgent, _ extra: [String: JSONValue] = [:],
                 progress: ((CloudUpdateSignal) -> Void)? = nil) {
        guard busy[agent.id] == nil else { return }
        let enabling = extra["enabled"]?.bool
        busy[agent.id] = CloudBusy(action: action, words: CloudCopy.doing(action, enabling: enabling), started: Date())
        actionFailure[agent.id] = nil
        // Names of fields only: variable values never reach the log.
        AppLog.trace("cloud", "\(action.rawValue) \(agent.id) status=\(agent.status) fields=\(extra.keys.sorted().joined(separator: ","))")
        #if DEBUG
        if demo { debugPerform(action, agent, extra, progress: progress); return }
        #endif
        let client = self.client
        let wasUp = agent.isReady || agent.isRunning || agent.isSleeping
        let saved = savedGateway(agent)
        actionTasks[agent.id] = Task {
            do {
                do {
                    if let row = try await client.act(action, on: agent.id, extra) { update(row) }
                } catch let error as PortalError where error.mayHaveRun {
                    AppLog.trace("cloud", "\(action.rawValue) \(agent.id) unanswered (\(error.message)); watching it")
                }
                progress?(.asked)
                try await settle(action, agent, wasUp: wasUp, extra: extra, progress: progress)
                AppLog.trace("cloud", "\(action.rawValue) \(agent.id) done after \(Int(Date().timeIntervalSince(busy[agent.id]?.started ?? Date())))s")
                finished(action, agent, extra, saved: saved)
                progress?(.ready)
            } catch {
                busy[agent.id] = nil
                actionTasks[agent.id] = nil
                if error is CancellationError || Task.isCancelled { return }
                if let error = error as? PortalError, error.kind == .signedOut { handle(error); return }
                if action == .growDisk, let offers = Self.diskSizes(in: Self.words(error)) { diskChoices = offers }
                AppLog.trace("cloud", "\(action.rawValue) \(agent.id) failed: \(Self.words(error))")
                actionFailure[agent.id] = Self.words(error)
                progress?(.failed(Self.words(error)))
                // What it got to, so the card doesn't keep a half-done state ("Stopping · Pro") under the error.
                Task { if let fresh = try? await client.agent(agent.id) { update(fresh) } }
                Haptics.play(.error)
                AccessibilityNotification.Announcement(Self.words(error)).post()
                return
            }
            busy[agent.id] = nil
            actionTasks[agent.id] = nil
        }
    }

    /// Until the action shows: stopped for stop; up and answering for start and restart (and for a resize, update or
    /// variables on an agent that was up); gone from the list for delete. Up to 5 minutes for a stop or delete, 20 for the rest.
    private func settle(_ action: CloudAction, _ agent: CloudAgent, wasUp: Bool, extra: [String: JSONValue],
                        progress: ((CloudUpdateSignal) -> Void)? = nil) async throws {
        switch action {
        case .rename:
            if let name = extra["name"]?.string { renamed(agent.id, to: name) }
            if let fresh = try? await client.agent(agent.id) { update(fresh) }
            return
        case .setFeature:
            try await Task.sleep(for: .seconds(1))
            if let found = await client.teamGateway(agent.id) { teamGateways[agent.id] = found }
            else if let on = extra["enabled"]?.bool { teamGateways[agent.id] = CloudTeamGateway(enabled: on, platforms: teamGateways[agent.id]?.platforms ?? []) }
            if let fresh = try? await client.agent(agent.id, live: true) { update(fresh) }
            return
        case .destroy:
            let deadline = Date().addingTimeInterval(5 * 60)
            while Date() < deadline {
                do {
                    let listed = try await client.listAgents()
                    if !listed.contains(where: { $0.id == agent.id }) { return }
                } catch let error as PortalError where error.kind == .network {
                    AppLog.trace("cloud", "list while deleting \(agent.id): \(error.message)")
                }
                try await Task.sleep(for: .seconds(3))
            }
            throw CloudToolError(message: CloudCopy.stillWorking(agent.name))
        default:
            break
        }
        let wantsUp = action == .start || action == .restart || (wasUp && action != .stop)
        let deadline = Date().addingTimeInterval((action == .stop ? 5 : 20) * 60)
        let started = Date()
        var sawChange = false
        var last: CloudAgent?
        try await Task.sleep(for: .seconds(2))
        while Date() < deadline {
            // Portal's live status reads the machine, and can drop while Nous stops and starts it (a resize to Max,
            // 2026-11-04, came back fine but HQ gave up on "The connection to Nous Portal dropped"): keep watching.
            let read: CloudAgent?
            do {
                read = try await client.agent(agent.id, live: true)
            } catch let error as PortalError where error.kind == .network {
                AppLog.trace("cloud", "\(action.rawValue) \(agent.id) status unanswered (\(error.message)); still watching")
                try await Task.sleep(for: .seconds(4))
                continue
            }
            guard let now = read else {
                throw CloudToolError(message: "Nous Portal doesn’t list \(agent.name) any more.")
            }
            if now.status != last?.status || now.gatewayState != last?.gatewayState {
                AppLog.trace("cloud", "\(action.rawValue) \(now.id) status=\(now.status) gateway=\(now.gatewayState) at \(Int(Date().timeIntervalSince(started)))s")
            }
            last = now
            update(now)
            if now.isChanging || !now.isReady { sawChange = true }
            busy[agent.id]?.words = CloudCopy.settling(action, now, wantsUp: wantsUp)
            progress?(.settling(CloudCopy.settling(action, now, wantsUp: wantsUp)))
            if now.isFailed { throw CloudToolError(message: "\(now.name) didn’t come back on Nous’s side. Check it on Nous Portal.") }
            if action == .stop {
                if now.isStopped { return }
            } else if wantsUp {
                // A restart can answer before the machine goes down: settled once it was seen down, or after 15 s up.
                if now.isReady, !action.restarts || sawChange || Date().timeIntervalSince(started) > 15 { return }
            } else if now.isStopped || now.isReady {
                return
            }
            try await Task.sleep(for: .seconds(4))
        }
        throw CloudToolError(message: CloudCopy.stillWorking(agent.name))
    }

    private func finished(_ action: CloudAction, _ agent: CloudAgent, _ extra: [String: JSONValue], saved: GatewayAccountRow?) {
        let name = extra["name"]?.string ?? self.agent(agent.id)?.name ?? agent.name
        busy[agent.id] = nil
        actionTasks[agent.id] = nil
        switch action {
        case .destroy:
            drop(agent.id)
            CloudEnvNames.save([], for: agent.id)
            if CloudPending.load()?.matches(agent) == true { CloudPending.clear() }
            onRoute?(.root)
            forgetGateway(saved)
        case .rename:
            // The saved gateway keeps a name given on the phone; one that was still the agent's old name follows it.
            if let saved, saved.label == nil || saved.label == agent.name || saved.title == agent.name {
                try? gateways?.rename(saved.id, name)
            }
        case .updateEnv:
            var names = CloudEnvNames.load(agent.id)
            names += extra["env"]?.object?.keys.map { $0 } ?? []
            let gone = Set(extra["deleted_keys"]?.array?.compactMap(\.string) ?? [])
            names.removeAll { gone.contains($0) }
            edit(agent.id) { $0.envNames.removeAll { gone.contains($0) } }
            CloudEnvNames.save(names, for: agent.id)
        default:
            break
        }
        if action != .destroy, let now = self.agent(agent.id) { loadSpend([now]) }
        Haptics.play(.success)
        AccessibilityNotification.Announcement(CloudCopy.did(action, name, enabling: extra["enabled"]?.bool)).post()
    }

    /// The deleted agent's saved gateway goes too, unless HQ is using it (that one is removed after switching away).
    private func forgetGateway(_ saved: GatewayAccountRow?) {
        guard let saved, !saved.isCurrent, let gateways else { return }
        Task {
            do { try await gateways.remove(saved.id); AppLog.trace("cloud", "removed saved gateway \(saved.hostAndPort)") }
            catch { AppLog.trace("cloud", "couldn’t remove saved gateway \(saved.hostAndPort): \(error)") }
        }
    }

    /// Disk sizes a grow_disk refusal lists ("one of 10, 20, 50 GB"): offered next time instead of the usual steps.
    nonisolated static func diskSizes(in message: String) -> [Int]? {
        guard message.lowercased().contains("gb") || message.lowercased().contains("disk") else { return nil }
        let numbers = message.split { !$0.isNumber }.compactMap { Int($0) }.filter { $0 >= 1 && $0 <= 4096 }
        let unique = Array(Set(numbers)).sorted()
        return unique.count >= 2 ? unique : nil
    }

    #if DEBUG
    /// Screenshots and videos: the action plays out on the made-up agent, no Portal.
    private func debugPerform(_ action: CloudAction, _ agent: CloudAgent, _ extra: [String: JSONValue],
                              progress: ((CloudUpdateSignal) -> Void)? = nil) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            progress?(.asked)
            try? await Task.sleep(for: .seconds(1.5))
            switch action {
            case .stop: edit(agent.id) { $0.status = "stopped"; $0.gatewayState = "down" }
            case .start, .restart, .updateImage, .updateEnv: edit(agent.id) { $0.status = "running"; $0.gatewayState = "active" }
            case .resize: edit(agent.id) { $0.size = extra["size"]?.string ?? $0.size }
            case .rename: if let name = extra["name"]?.string { renamed(agent.id, to: name) }
            case .growDisk: edit(agent.id) { $0.diskGB = extra["disk_gb"]?.int }
            case .setFeature: teamGateways[agent.id] = CloudTeamGateway(enabled: extra["enabled"]?.bool ?? false)
            case .destroy: break
            }
            finished(action, agent, extra, saved: nil)
            progress?(.ready)
        }
    }
    #endif
}

// MARK: - Words

extension CloudCopy {
    static let power = "Power"
    static let settingsLabel = "Settings"
    static let detailsLabel = "Details"
    static let variables = "Variables"
    static let disk = "Disk"
    static let version = "Hermes"
    static let teamGateway = "Team Gateway"
    static let teamGatewayDetail = "Reach it from Discord, Telegram, Slack and WhatsApp. It sleeps while idle and wakes for a message."
    static let teamGatewayLink = "On. Link chat accounts on Nous Portal."
    static func teamGatewayLinked(_ platforms: [String]) -> String { "Linked: \(platforms.map(CloudToolSchema.title).joined(separator: ", "))" }
    static let deleteTitle = "Delete Agent"
    static let stopWord = "Stop"
    static let startWord = "Start"
    static let restartWord = "Restart"
    static let updateWord = "Update Hermes"
    static let renameWord = "Rename"
    static let changeSize = "Change Size"
    static let growDiskWord = "Grow Disk"
    static let moreWord = "More"
    static let details = "Details"
    static let unknownDisk = "Not shown"

    static func doing(_ action: CloudAction, enabling: Bool? = nil) -> String {
        switch action {
        case .start: "Starting…"
        case .stop: "Stopping…"
        case .restart: "Restarting…"
        case .destroy: "Deleting…"
        case .rename: "Renaming…"
        case .resize: "Changing size…"
        case .updateImage: "Updating Hermes…"
        case .updateEnv: "Applying variables…"
        case .growDisk: "Growing the disk…"
        case .setFeature: enabling == false ? "Turning off Team Gateway…" : "Turning on Team Gateway…"
        }
    }

    /// What Nous says while an action settles.
    static func settling(_ action: CloudAction, _ agent: CloudAgent, wantsUp: Bool) -> String {
        let status = agent.status.lowercased()
        if status.contains("stopping") || (status.contains("stop") && agent.isChanging) { return "Nous is stopping it…" }
        if ["resiz", "scal"].contains(where: status.contains) { return "Moving to the new size…" }
        if ["deploy", "image", "pull", "install", "updat", "migrat"].contains(where: status.contains) { return "Installing Hermes…" }
        if ["start", "boot", "launch", "restart"].contains(where: status.contains) { return "Starting Hermes…" }
        if wantsUp, agent.isStopped { return "Stopped. Starting it again…" }
        if wantsUp, agent.isRunning, !agent.isReady { return "Running. Waiting for it to answer…" }
        return doing(action)
    }

    static func did(_ action: CloudAction, _ name: String, enabling: Bool?) -> String {
        switch action {
        case .start: "\(name) is running"
        case .stop: "\(name) is stopped"
        case .restart: "\(name) restarted"
        case .destroy: "\(name) is deleted"
        case .rename: "Renamed to \(name)"
        case .resize: "\(name) has its new size"
        case .updateImage: "\(name) is updated"
        case .updateEnv: "Variables applied"
        case .growDisk: "The disk is bigger"
        case .setFeature: enabling == false ? "Team Gateway is off" : "Team Gateway is on"
        }
    }

    static func stillWorking(_ name: String) -> String {
        // [mac] Mac polish #144: the Mac's Your Agents refreshes with ⌘R (`KeyCommands.sheetRefresh`), not a pull.
        let refresh = DeviceWord.isMac ? "Press Command-R on Your Agents" : "Pull down on Your Agents"
        return "Nous is still working on \(name). \(refresh) in a minute to see where it is."
    }

    // Power rows
    // [app-store-review] Guideline 3.1.1: no dollar amount, saved or spent, in the App Store build.
    #if APP_STORE
    static func stopDetail(_ size: CloudSize?) -> String { "Everything on it is kept. \(costNote)" }
    static func startDetail(_ size: CloudSize?) -> String { costNote }
    #else
    static func stopDetail(_ size: CloudSize?) -> String {
        guard let size else { return "Everything on it is kept. \(CloudPrices.dollars(CloudPrices.stoppedPerDay)) a day while stopped." }
        return "Saves about \(CloudPrices.dollars(size.perDay - size.stoppedPerDay)) a day. Everything on it is kept."
    }
    static func startDetail(_ size: CloudSize?) -> String {
        size.map { "About \(CloudPrices.dollars($0.perDay)) a day while it runs." } ?? "Paid from your Nous credit while it runs."
    }
    #endif
    static let restartDetail = "Off and on again. Back in a minute or two."
    static func updateDetail(_ agent: CloudAgent) -> String {
        switch agent.updateAvailable {
        case true?: "A newer Hermes is ready. It restarts to update."
        case false?: "It runs the newest Hermes."
        case nil: "Moves it to Nous’s newest Hermes. It restarts."
        }
    }

    // Confirmations
    static func stopTitle(_ name: String) -> String { "Stop \(name)?" }
    static func stopMessage(_ name: String, size: CloudSize?, current: Bool) -> String {
        var text = "It stops answering until you start it again. Its chats, files and settings are kept."
        // [app-store-review] Guideline 3.1.1: no dollar amount in the App Store build.
        #if !APP_STORE
        if let size {
            text += " Stopped, it costs \(CloudPrices.dollars(size.stoppedPerDay)) a day instead of \(CloudPrices.dollars(size.perDay))."
        }
        #endif
        if current { text += " HQ is using it now: its chats go quiet until it’s back." }
        return text
    }
    static func restartTitle(_ name: String) -> String { "Restart \(name)?" }
    static let restartMessage = "Anything it’s doing stops. It’s back in a minute or two, with everything kept."
    static func updateTitle(_ name: String) -> String { "Update \(name)?" }
    static let updateMessage = "Nous moves it to the newest Hermes and restarts it. This can take a few minutes. Chats, files and settings are kept."
    static func resizeTitle(_ name: String, to size: String) -> String { "Change \(name) to \(sizeWord(size))?" }
    static func resizeMessage(from: String, to: String, running: Bool) -> String {
        // [app-store-review] Guideline 3.1.1: no dollar price difference in the App Store build.
        #if APP_STORE
        let price = ""
        #else
        let price = priceChange(from: CloudPrices.size(from), to: CloudPrices.size(to)).map { $0 + " " } ?? ""
        #endif
        return price + (running ? "It restarts to change, which takes a minute or two. Everything on it is kept." : "It takes the new size when it next starts.")
    }
    #if !APP_STORE
    static func priceChange(from: CloudSize?, to: CloudSize?) -> String? {
        guard let from, let to else { return nil }
        let diff = to.perDay - from.perDay
        if abs(diff) < 0.005 { return "The same price." }
        return diff > 0
            ? "About \(CloudPrices.dollars(diff)) more a day: \(CloudPrices.dollars(to.perDay)) instead of \(CloudPrices.dollars(from.perDay))."
            : "Saves about \(CloudPrices.dollars(-diff)) a day: \(CloudPrices.dollars(to.perDay)) instead of \(CloudPrices.dollars(from.perDay))."
    }
    #endif
    static func diskTitle(_ gb: Int) -> String { "Grow the disk to \(gb) GB?" }
    #if APP_STORE
    // [app-store-review] Guideline 3.1.1: no mention of Nous Portal's pricing in the App Store build.
    static let diskMessage = "A disk can grow but never shrink. \(costNote)"
    #else
    static let diskMessage = "A disk can grow but never shrink. A bigger one can cost more, running or stopped: see Prices on Nous Portal."
    #endif
    static let resizeLead = "More memory runs more chats at once. Its chats, files and settings come along."
    static let now = "Now"
    static func changeTo(_ size: String) -> String { "Change to \(sizeWord(size))" }

    // Variables
    static let variablesLead = "Settings Hermes reads when it starts, like API keys. Nous keeps the values; HQ shows only the names. Changing one restarts the agent."
    static let variablesNone = "None yet."
    static var variablesFoot: String { "Nous may not list every name. Ones you set from this \(DeviceWord.name) show here." }
    static let addVariable = "Add or Replace"
    static let variableName = "Name"
    static let variableValue = "Value"
    static let variableNamePlaceholder = "OPENAI_API_KEY"
    static let variableValuePlaceholder = "Value"
    static let setVariable = "Set Variable"
    static let variableBadName = "Letters, digits and _ only, and not starting with a digit."
    static func setVariableTitle(_ key: String, _ name: String) -> String { "Set \(key) on \(name)?" }
    static func removeVariableTitle(_ key: String) -> String { "Remove \(key)?" }
    static func restartsToApply(_ name: String) -> String { "\(name) restarts to apply it, which takes a minute or two." }

    // Delete
    static func deleteHeading(_ name: String) -> String { "Delete \(name)?" }
    static let deleteLead = "This can’t be undone. Its chats, memory, files, jobs and settings on Nous are deleted, and Nous stops billing for it."
    static func deleteType(_ name: String) -> String { "Type “\(name)” to confirm" }
    static var deleteAlsoGateway: String { "It’s removed from your gateways on this \(DeviceWord.name) too." }
    static let deleteCurrent = "HQ is using it now. Afterwards, switch to another gateway from the name at the top of Bots."
    static func renameTitle(_ name: String) -> String { "Rename \(name)" }
    static let renameMessage = "The name on Nous Portal and in HQ."

    /// "Open Research Bot", "Start and Connect", "Connect".
    static func connectTitle(_ agent: CloudAgent, saved: Bool) -> String {
        if saved { return openAgent(agent.name) }
        return agent.isStopped && !agent.isSleeping ? "Start and Connect" : connect
    }

    /// "$3.24 so far", "About $33 a month if it never stops".
    static func spendLine(_ spend: CloudSpend?) -> String? {
        var parts: [String] = []
        if let spent = spend?.toDate { parts.append("\(CloudPrices.dollars(spent)) so far") }
        if let month = spend?.monthly { parts.append("about \(CloudPrices.dollars(month)) a month") }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
