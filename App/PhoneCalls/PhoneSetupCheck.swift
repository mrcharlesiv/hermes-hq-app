// Phone Calls (Beta) › Check my setup (item 10): reads what the owner's key can read about the account and says, row by
// row, whether a call can go out. A read that fails says "couldn't check", never a cross. Pure verdicts, unit-tested.

import SwiftUI

nonisolated struct PhoneSetupCheck: Equatable, Sendable {
    nonisolated enum State: String, Equatable, Sendable { case pass, fail, warn, unknown }
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let state: State
        let sentence: String
        var fix: String? = nil
    }

    /// What the reads answered. `nil`: not read (an earlier read failed); a failure: couldn't check.
    nonisolated struct Reads: Sendable {
        var numbers: Result<[samplehostNumber], samplehostError>?
        var app: Result<samplehostCallControlApp, samplehostError>?
        var profile: Result<samplehostVoiceProfile, samplehostError>?
        var assistant: Result<samplehostAssistantDetail, samplehostError>?
        var balance: Result<samplehostBalance, samplehostError>?
    }

    static let couldNotCheck = "Couldn't check this right now. Try again."

    /// ISO country for a number's calling code, for the profile's allowed destinations.
    static func country(of number: String) -> String? {
        let table: [(String, String)] = [("+1", "US"), ("+44", "GB"), ("+61", "AU"), ("+64", "NZ"), ("+353", "IE"), ("+49", "DE"),
                                         ("+33", "FR"), ("+34", "ES"), ("+39", "IT"), ("+31", "NL"), ("+46", "SE"), ("+47", "NO"),
                                         ("+45", "DK"), ("+41", "CH"), ("+52", "MX"), ("+55", "BR")]
        return table.sorted { $0.0.count > $1.0.count }.first { number.hasPrefix($0.0) }?.1
    }

    static func rows(setup: PhoneSetup, reads: Reads) -> [Row] {
        var rows: [Row] = []
        let from = setup.fromNumber ?? ""
        // The key.
        switch reads.numbers {
        case .success?: rows.append(Row(id: "key", state: .pass, sentence: "Your samplehost key works."))
        case .failure(.badKey)?: rows.append(Row(id: "key", state: .fail, sentence: "samplehost didn't accept your key.",
                                                 fix: "Make a new API key in the samplehost portal, then Disconnect and connect again."))
        default: rows.append(Row(id: "key", state: .unknown, sentence: "Your samplehost key: " + couldNotCheck))
        }
        // The From number.
        if case .success(let numbers)? = reads.numbers {
            if let number = numbers.first(where: { $0.phone_number == from }) {
                if number.status != nil && number.status != "active" {
                    rows.append(Row(id: "number", state: .fail, sentence: "\(from) isn't active (\(number.status ?? "")).",
                                    fix: "Wait until samplehost shows it as active, or choose another number."))
                } else if number.connection_id != setup.connectionID {
                    rows.append(Row(id: "number", state: .fail, sentence: "\(from) isn't on the voice connection you chose.",
                                    fix: "In the samplehost portal, put the number on that connection, or choose its own connection here."))
                } else {
                    rows.append(Row(id: "number", state: .pass, sentence: "\(from) is active and on your voice connection."))
                }
            } else {
                rows.append(Row(id: "number", state: .fail, sentence: "\(from.isEmpty ? "No From number" : from) isn't on this samplehost account.",
                                fix: "Choose one of your samplehost numbers above."))
            }
        } else {
            rows.append(Row(id: "number", state: .unknown, sentence: "Your From number: " + couldNotCheck))
        }
        // The connection and its outbound voice profile.
        switch reads.app {
        case .success(let app)?:
            if app.active == false {
                rows.append(Row(id: "connection", state: .fail, sentence: "The voice connection is turned off.",
                                fix: "\(DeviceWord.Tap) Fix voice connection below, or turn it on in the samplehost portal (Voice › Programmable Voice)."))
            } else if app.webhook_event_url != nil && !samplehostHasValidWebhookURL(app.webhook_event_url) {
                rows.append(Row(id: "connection", state: .fail,
                                sentence: "The voice connection has no valid https:// webhook URL, so samplehost won't place calls on it.",
                                fix: "\(DeviceWord.Tap) Fix voice connection below, or set an https:// webhook URL in the samplehost portal (Voice › Programmable Voice › Voice API)."))
            } else {
                rows.append(Row(id: "connection", state: .pass, sentence: "\(app.application_name ?? "The voice connection") is an active Call Control application."))
            }
            if (app.outbound?.outbound_voice_profile_id ?? "").isEmpty {
                rows.append(Row(id: "profile", state: .fail, sentence: "The connection has no outbound voice profile, so it can't call out.",
                                fix: "\(DeviceWord.Tap) Fix voice connection below, or attach an outbound voice profile in the samplehost portal."))
            }
        case .failure(.unexpected(404))?:
            rows.append(Row(id: "connection", state: .fail,
                            sentence: "The voice connection isn't a Voice API (Call Control) application — TeXML and SIP connections can't place calls here.",
                            fix: "\(DeviceWord.Tap) Fix voice connection below, or choose a Voice API application in Phone Calls settings."))
        default:
            rows.append(Row(id: "connection", state: .unknown, sentence: "Your voice connection: " + couldNotCheck))
        }
        switch reads.profile {
        case .success(let profile)?:
            if profile.enabled == false {
                rows.append(Row(id: "profile", state: .fail, sentence: "The outbound voice profile is turned off.",
                                fix: "Turn it on in the samplehost portal (Voice › Outbound Voice Profiles)."))
            } else {
                rows.append(Row(id: "profile", state: .pass, sentence: "The outbound voice profile is on."))
            }
            let allowed = (profile.whitelisted_destinations ?? []).map { $0.uppercased() }
            if let country = country(of: from), !allowed.isEmpty {
                rows.append(allowed.contains(country)
                    ? Row(id: "country", state: .pass, sentence: "The profile allows calls to \(country).")
                    : Row(id: "country", state: .fail, sentence: "The profile doesn't allow calls to \(country).",
                          fix: "Add \(country) to the profile's allowed destinations in the samplehost portal."))
            } else {
                rows.append(Row(id: "country", state: .unknown, sentence: "Allowed countries: " + couldNotCheck))
            }
        case .failure?:
            rows.append(Row(id: "profile", state: .unknown, sentence: "The outbound voice profile: " + couldNotCheck))
        case nil:
            if !rows.contains(where: { $0.id == "profile" }) {
                rows.append(Row(id: "profile", state: .unknown, sentence: "The outbound voice profile: " + couldNotCheck))
            }
        }
        // The assistant.
        switch reads.assistant {
        case .success(let assistant)?:
            if assistant.enabledFeatures.contains("telephony") {
                rows.append(Row(id: "assistant", state: .pass, sentence: "\(assistant.name ?? "The assistant") exists and has telephony on."))
            } else {
                rows.append(Row(id: "assistant", state: .fail, sentence: "\(assistant.name ?? "The assistant") doesn't have telephony on.",
                                fix: "Turn on telephony for it in the samplehost portal (AI Assistants)."))
            }
            if (assistant.model ?? "").lowercased().contains("gpt-live") {
                rows.append(Row(id: "model", state: .warn, sentence: "Its model is a GPT Live model: answers to its questions may not reach it.",
                                fix: "Choose another model for this assistant in the samplehost portal."))
            } else {
                rows.append(Row(id: "model", state: .pass, sentence: "Its model (\(assistant.model ?? "default")) takes your answers during a call."))
            }
            if let recording = assistant.recordingOn {
                rows.append(recording == setup.records
                    ? Row(id: "recording", state: .pass, sentence: recording ? "Recording is on, as set here." : "Recording is off, as set here.")
                    : Row(id: "recording", state: .fail, sentence: "Recording is \(recording ? "on" : "off") on the assistant but \(setup.records ? "on" : "off") here.",
                          fix: "\(DeviceWord.Tap) Save. The next call also sets it."))
            } else {
                rows.append(Row(id: "recording", state: .unknown, sentence: "Recording: " + couldNotCheck))
            }
            let voiceIssues = assistant.callQualityIssues
            if !voiceIssues.isEmpty {
                rows.append(Row(id: "voice", state: .warn,
                                sentence: "Assistant call settings can be tuned for smoother conversations (\(voiceIssues.joined(separator: "; "))).",
                                fix: "\(DeviceWord.Tap) Optimize assistant below or in Phone Calls settings."))
            }
        case .failure(.unexpected(404))?:
            rows.append(Row(id: "assistant", state: .fail, sentence: "The chosen assistant isn't on this samplehost account.",
                            fix: "Choose another assistant above."))
        default:
            rows.append(Row(id: "assistant", state: .unknown, sentence: "Your assistant: " + couldNotCheck))
        }
        // The balance.
        switch reads.balance {
        case .success(let balance)?:
            let shown = (balance.currency.map { $0 == "USD" ? "$" : $0 + " " } ?? "$") + balance.balance
            if let amount = balance.amount, amount > 1 {
                rows.append(Row(id: "balance", state: .pass, sentence: "Your balance is \(shown)."))
            } else if balance.amount != nil {
                rows.append(Row(id: "balance", state: .fail, sentence: "Your balance is \(shown), too low to call.",
                                fix: "Add funds in the samplehost portal (Billing)."))
            } else {
                rows.append(Row(id: "balance", state: .unknown, sentence: "Your balance: " + couldNotCheck))
            }
        default:
            rows.append(Row(id: "balance", state: .unknown, sentence: "Your balance: " + couldNotCheck))
        }
        return rows
    }

    /// Runs the reads one after another (wire fact 11).
    @MainActor static func read(_ api: samplehostAPI, setup: PhoneSetup) async -> Reads {
        func typed<T>(_ result: Result<T, Error>) -> Result<T, samplehostError> {
            result.mapError { ($0 as? samplehostError) ?? .network }
        }
        var reads = Reads()
        reads.numbers = typed(await Result.of { try await api.allPhoneNumbers() })
        if let connection = setup.connectionID, !connection.isEmpty {
            reads.app = typed(await Result.of { try await api.callControlApp(id: connection) })
            if case .success(let app)? = reads.app, let profile = app.outbound?.outbound_voice_profile_id, !profile.isEmpty {
                reads.profile = typed(await Result.of { try await api.voiceProfile(id: profile) })
            }
        }
        if let assistant = setup.assistantID, !assistant.isEmpty {
            reads.assistant = typed(await Result.of { try await api.assistant(id: assistant) })
        }
        reads.balance = typed(await Result.of { try await api.balance() })
        return reads
    }
}

struct PhoneSetupCheckView: View {
    let accountID: String
    @State private var rows: [PhoneSetupCheck.Row] = []
    @State private var loadedNumbers: [samplehostNumber] = []
    @State private var running = false
    @State private var optimizing = false
    @State private var fixingConnection = false
    @State private var optimizeError: String?

    private var canOptimize: Bool { rows.contains { $0.id == "voice" && $0.state == .warn } }
    private var canFixConnection: Bool {
        rows.contains { ($0.id == "connection" || $0.id == "profile") && $0.state == .fail }
            || rows.contains { $0.id == "number" && $0.state == .fail && $0.sentence.contains("voice connection") }
    }

    var body: some View {
        Form {
            Section {
                if rows.isEmpty && running { ProgressView() }
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(row.state)).foregroundStyle(tint(row.state))
                            .accessibilityLabel(label(row.state))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.sentence)
                            if let fix = row.fix { Text(fix).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("phone.check." + row.id)
                }
            } footer: {
                Text("Hermes HQ reads these from samplehost with your key. Checking changes nothing.")
            }
            if let optimizeError {
                Section { Text(optimizeError).foregroundStyle(Color.hqRed) }
            }
            Section {
                if canFixConnection {
                    Button(fixingConnection ? "Fixing voice connection…" : "Fix voice connection") {
                        Task { await fixConnection() }
                    }
                    .disabled(running || optimizing || fixingConnection)
                    .accessibilityIdentifier("phone.check.fix-connection")
                }
                if canOptimize {
                    Button(optimizing ? "Optimizing…" : "Optimize assistant for calls") { Task { await optimize() } }
                        .disabled(running || optimizing || fixingConnection)
                        .accessibilityIdentifier("phone.check.optimize")
                }
                Button(running ? "Checking…" : "Check Again") { Task { await run() } }
                    .disabled(running || optimizing || fixingConnection)
                    .accessibilityIdentifier("phone.check.again")
                NavigationLink("Setup & how to use guide") {
                    PhoneGuideView().navigationTitle("Setup & how to use")
                }
                .accessibilityIdentifier("phone.check.guide")
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .task { await run() }
    }

    private func fixConnection() async {
        guard !fixingConnection, var setup = PhoneKeyStore.app.load(for: accountID) else { return }
        fixingConnection = true; optimizeError = nil
        defer { fixingConnection = false }
        let targetNumber = loadedNumbers.first { $0.phone_number == setup.fromNumber }
        let api = samplehostAPI(key: setup.apiKey)
        let repaired = await Result.of {
            try await api.repairVoiceConnection(connectionID: setup.connectionID, for: targetNumber)
        }
        switch repaired {
        case .success(let updated):
            setup.connectionID = updated.connectionID
            try? PhoneKeyStore.app.save(setup, for: accountID)
            await run()
        case .failure(let error):
            optimizeError = phoneMessage(error)
        }
    }

    private func optimize() async {
        guard !optimizing, let setup = PhoneKeyStore.app.load(for: accountID), let assistantID = setup.assistantID else { return }
        optimizing = true; optimizeError = nil
        defer { optimizing = false }
        let updated = await Result.of { try await samplehostAPI(key: setup.apiKey).optimizeAssistant(id: assistantID, recording: setup.records) }
        switch updated {
        case .success: await run()
        case .failure(let error): optimizeError = phoneMessage(error)
        }
    }

    private func run() async {
        guard !running, let setup = PhoneKeyStore.app.load(for: accountID) else { return }
        running = true
        defer { running = false }
        let reads = await PhoneSetupCheck.read(samplehostAPI(key: setup.apiKey), setup: setup)
        if case .success(let nums)? = reads.numbers { loadedNumbers = nums }
        rows = PhoneSetupCheck.rows(setup: setup, reads: reads)
        AppLog.note("phone", "setup checked: \(rows.filter { $0.state == .fail }.count) to fix")
    }

    private func symbol(_ state: PhoneSetupCheck.State) -> String {
        switch state {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private func tint(_ state: PhoneSetupCheck.State) -> Color {
        switch state {
        case .pass: return .green
        case .fail: return .red
        case .warn: return .orange
        case .unknown: return Color.hqLabel2
        }
    }
    private func label(_ state: PhoneSetupCheck.State) -> String {
        switch state {
        case .pass: return "OK"
        case .fail: return "Needs fixing"
        case .warn: return "Warning"
        case .unknown: return "Couldn't check"
        }
    }
}
