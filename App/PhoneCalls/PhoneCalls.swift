// Phone Calls (Beta) screens. App-only: requests go straight to samplehost (samplehostClient.swift) with the owner's key from
// this device's Keychain. Nothing here talks to the gateway. Each HQ account has its own key and its own calls
// (PhoneCallController.shared(for:), PhoneCallController.swift), so switching accounts never shows another account's
// key or calls. The controller watches every call; these screens only show it.

import SwiftUI

// MARK: - Settings › Phone Calls (Beta)

struct PhoneSettingsView: View {
    let accountID: String
    @State private var setup: PhoneSetup?
    @State private var numbers: [samplehostNumber] = []
    /// `nil` before `callControlApps()` has answered (or if that read failed); `[...]` once known.
    @State private var apps: [samplehostCallControlAppSummary]? = nil
    @State private var assistants: [samplehostAssistant] = []
    @State private var key = ""
    @State private var number = ""
    @State private var connection = ""
    @State private var assistant = ""
    @State private var ownerName = ""
    @State private var recordCalls = false
    @State private var sendResults = true
    @State private var customWebhookURL = ""
    @State private var needsCustomWebhookURL = false
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var confirmClear = false
    /// One create-assistant operation per page visit: a retried tap reuses it, so samplehost never makes two.
    @State private var createKey = UUID().uuidString

    private var store: PhoneKeyStore { .app }
    private var controller: PhoneCallController { .shared(for: accountID) }
    private var connections: [PhoneConnectionResolver.Option] {
        PhoneConnectionResolver.options(numbers: numbers, apps: apps)
    }
    private var selectedNumber: samplehostNumber? {
        numbers.first { $0.phone_number == number }
    }
    private var selectedApp: samplehostCallControlAppSummary? {
        apps?.first { $0.id == connection }
    }
    private var savedConnectionInvalid: Bool {
        PhoneConnectionResolver.isInvalidSavedConnection(setup?.connectionID, apps: apps)
    }
    private var selectedAppNeedsFix: Bool {
        guard let selectedApp else { return false }
        return PhoneConnectionResolver.needsFix(selectedApp)
    }
    private var nonCallControlWarning: String? {
        guard loaded else { return nil }
        return PhoneConnectionResolver.nonCallControlWarning(selectedNumber: selectedNumber, connectionID: connection, apps: apps)
    }
    private var statusWords: String {
        guard let setup else { return "Not connected" }
        if savedConnectionInvalid { return "Connected, choose or create a Voice API connection" }
        return setup.ready ? "Ready" : "Connected, choose a number and assistant"
    }
    private var changed: Bool {
        guard let setup else { return false }
        return setup.fromNumber != number || setup.connectionID != connection || setup.assistantID != assistant
            || setup.name != ownerName.trimmingCharacters(in: .whitespacesAndNewlines) || setup.records != recordCalls
            || setup.sendsResults != sendResults
    }

    var body: some View {
        Form {
            Section {
                Text(statusWords)
                    .accessibilityIdentifier("phone.settings.status")
                if setup == nil {
                    SecureField("samplehost API key", text: $key)
                        .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Connect") { connect() }.disabled(key.isEmpty || busy)
                } else {
                    Button("Disconnect", role: .destructive) { disconnect() }.disabled(busy)
                }
            } header: { Text("samplehost") } footer: {
                Text("Hermes HQ calls samplehost directly with your key. It stays in this device's Keychain for this account and is never sent to your gateway. Calls are billed to your samplehost account.")
            }
            if let error { Section { Text(error).foregroundStyle(Color.hqRed).accessibilityIdentifier("phone.settings.error") } }
            if let notice { Section { Text(notice).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("phone.settings.notice") } }
            if setup == nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. In portal.samplehost.com, add credit and buy an active phone number.")
                        Text("2. Create an API key under Keys & Credentials and paste it above.")
                        Text("3. Hermes HQ sets up your Voice API connection and AI Assistant right here — then start calls from any chat via ⋯ › Phone Call or by asking your bot to call.")
                    }
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.vertical, 2)
                    NavigationLink("Setup & how to use guide") {
                        PhoneGuideView().navigationTitle("Setup & how to use")
                    }
                    .accessibilityIdentifier("phone.settings.guide")
                } header: { Text("How it works") }
            }
            if setup != nil {
                Section {
                    Picker("From number", selection: $number) {
                        Text("Select").tag("")
                        ForEach(numbers) { Text($0.phone_number).tag($0.phone_number) }
                    }
                    .onChange(of: number) { _, picked in
                        connection = PhoneConnectionResolver.preferredConnection(
                            for: picked, numbers: numbers, apps: apps, current: connection
                        )
                    }
                    Picker("Voice connection", selection: $connection) {
                        Text("Select").tag("")
                        ForEach(connections) { Text($0.name).tag($0.id) }
                    }
                    Picker("AI Assistant", selection: $assistant) {
                        Text("Select").tag("")
                        ForEach(assistants) { Text($0.name).tag($0.id) }
                    }
                    TextField("Your name (said on calls)", text: $ownerName)
                        .textContentType(.name).autocorrectionDisabled()
                        .accessibilityIdentifier("phone.settings.name")
                } header: { Text("Calls") } footer: {
                    Text("Voice connection must be a samplehost Voice API (Call Control) application — not a TeXML application. Each call gives your assistant this call's context, who it is calling, and an ask_owner tool. With a name, the assistant introduces itself for you (or speaks directly to you when calling you). \(PhoneLimits.stayCopy)")
                }
                if let warning = nonCallControlWarning {
                    Section {
                        Text(warning)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqOrange)
                            .accessibilityIdentifier("phone.settings.texml-warning")
                    }
                }
                if numbers.isEmpty && loaded {
                    Section { Text("No active phone numbers on this samplehost account. Buy a voice number in portal.samplehost.com under Numbers › Buy Numbers, then reopen this page.").font(Font.hq(.footnote)) }
                }
                if loaded, let knownApps = apps, knownApps.isEmpty || selectedAppNeedsFix || savedConnectionInvalid {
                    Section {
                        if knownApps.isEmpty {
                            Text("This samplehost account has no Voice API (Call Control) application yet. TeXML applications created for AI Assistants can't place outbound calls here. Hermes HQ can create a Voice API connection, set up its Outbound Voice Profile, and link your number in one tap.")
                                .font(Font.hq(.footnote))
                        } else if selectedAppNeedsFix {
                            Text("The chosen Voice API application is missing an https:// webhook URL or Outbound Voice Profile, which samplehost requires before placing calls.")
                                .font(Font.hq(.footnote))
                        }
                        if needsCustomWebhookURL {
                            TextField("Webhook URL (https://…)", text: $customWebhookURL)
                                .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                                .accessibilityIdentifier("phone.settings.webhook-url")
                            Text("samplehost asked for a reachable https:// address on this Voice API application. Enter any https:// URL you own; Hermes HQ reads call events directly with your API key, so no webhook server is needed.")
                                .font(Font.hq(.caption))
                                .foregroundStyle(Color.hqLabel2)
                        }
                        if knownApps.isEmpty {
                            Button(busy ? "Setting up…" : "Create Voice Connection") { createVoiceConnection() }
                                .disabled(busy)
                                .accessibilityIdentifier("phone.settings.create-connection")
                        } else if selectedAppNeedsFix || savedConnectionInvalid {
                            Button(busy ? "Fixing…" : "Fix Voice Connection") { fixVoiceConnection() }
                                .disabled(busy)
                                .accessibilityIdentifier("phone.settings.fix-connection")
                        }
                    }
                }
                if assistants.isEmpty && loaded {
                    Section {
                        Text("This samplehost account has no AI Assistants yet. Hermes HQ can make one for you, named \(PhoneAskOwner.assistantName).")
                            .font(Font.hq(.footnote))
                        Button("Create Assistant") { createAssistant() }.disabled(busy)
                            .accessibilityIdentifier("phone.settings.create-assistant")
                    }
                }
                Section {
                    Toggle("Record calls", isOn: $recordCalls).accessibilityIdentifier("phone.settings.record")
                } footer: {
                    Text("Recording is a setting on the chosen samplehost assistant, and Hermes HQ changes that setting there. When it is on, the assistant mentions in its opening turn that the call is recorded. Recordings stay in your samplehost account.")
                }
                Section {
                    Toggle("Send call results to the chat", isOn: $sendResults).accessibilityIdentifier("phone.settings.results")
                } footer: {
                    Text("When a call ends, Hermes HQ sends what happened (the outcome, questions and answers, and the transcript) into the chat the call was made from, so your agent knows.")
                }
                Section {
                    Button("Save") { save() }
                        .disabled(busy || (!changed && !savedConnectionInvalid) || number.isEmpty || connection.isEmpty || assistant.isEmpty
                                  || PhoneConnectionResolver.isInvalidSavedConnection(connection, apps: apps))
                        .accessibilityIdentifier("phone.settings.save")
                }
                Section {
                    NavigationLink("Setup & how to use guide") {
                        PhoneGuideView().navigationTitle("Setup & how to use")
                    }
                    .accessibilityIdentifier("phone.settings.guide")
                    if setup?.ready == true && !savedConnectionInvalid {
                        NavigationLink("Check my setup") { PhoneSetupCheckView(accountID: accountID).navigationTitle("Check my setup") }
                            .accessibilityIdentifier("phone.settings.check")
                        Button("Optimize assistant for calls") { optimizeAssistant() }.disabled(busy)
                            .accessibilityIdentifier("phone.settings.optimize")
                        NavigationLink("Call history") { PhoneHistoryView(accountID: accountID).navigationTitle("Call history") }
                            .accessibilityIdentifier("phone.settings.history")
                        Button("Clear call history", role: .destructive) { confirmClear = true }
                            .disabled(!controller.calls.contains { !$0.active })
                            .accessibilityIdentifier("phone.settings.clear-history")
                    }
                } footer: {
                    if setup?.ready == true && !savedConnectionInvalid {
                        Text("Place calls from any chat via ⋯ › Phone Call, or ask your bot in chat to call someone. Hermes HQ automatically tunes your assistant for fast turn-taking, natural interruptions, and noise suppression before your next call.")
                    } else {
                        Text("Open the guide for step-by-step samplehost setup, Voice API vs. TeXML details, and how to place and steer calls from a chat.")
                    }
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .task { await load() }
        .onDisappear { key = "" }
        .confirmationDialog("Clear call history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear call history", role: .destructive) { controller.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Ended calls and their transcripts leave this device. Nothing changes in samplehost.")
        }
    }

    private func apply(_ value: PhoneSetup?) {
        setup = value
        number = value?.fromNumber ?? ""; connection = value?.connectionID ?? ""; assistant = value?.assistantID ?? ""
        ownerName = value?.name ?? ""; recordCalls = value?.records ?? false; sendResults = value?.sendsResults ?? true
    }

    private func fetch(_ api: samplehostAPI) async throws {
        numbers = try await api.phoneNumbers()
        apps = try? await api.callControlApps()
        if !number.isEmpty {
            let resolved = PhoneConnectionResolver.preferredConnection(
                for: number, numbers: numbers, apps: apps, current: connection
            )
            if !PhoneConnectionResolver.isInvalidSavedConnection(setup?.connectionID, apps: apps) || !resolved.isEmpty {
                connection = resolved
            }
        } else if numbers.count == 1 {
            number = numbers[0].phone_number
            connection = PhoneConnectionResolver.preferredConnection(
                for: number, numbers: numbers, apps: apps, current: connection
            )
        }
        assistants = try await api.assistants()
        pickOnlyAssistant()
    }

    private var effectiveWebhookURL: String {
        let trimmed = customWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? PhoneLimits.voiceWebhookURL : trimmed
    }

    private func handleWebhookRejectionIfNeeded(_ caught: Error) {
        let words = phoneMessage(caught).lowercased()
        if customWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           words.contains("webhook") || words.contains("url") || words.contains("10003") {
            needsCustomWebhookURL = true
        }
    }

    private func createVoiceConnection() {
        guard !busy, let stored = setup else { return }
        busy = true; error = nil; notice = nil
        let targetNumber = selectedNumber ?? (numbers.count == 1 ? numbers[0] : nil)
        let webhook = effectiveWebhookURL
        Task {
            defer { busy = false }
            do {
                let api = samplehostAPI(key: stored.apiKey)
                let result = try await api.provisionVoiceConnection(for: targetNumber, webhookURL: webhook)
                var currentApps = apps ?? []
                if !currentApps.contains(where: { $0.id == result.app.id }) { currentApps.append(result.app) }
                apps = currentApps
                if let updated = result.updatedNumber, let idx = numbers.firstIndex(where: { $0.id == updated.id }) {
                    numbers[idx] = updated
                }
                if number.isEmpty, let targetNumber { number = targetNumber.phone_number }
                connection = result.app.id
                needsCustomWebhookURL = false
                notice = "Created Voice API connection “\(result.app.application_name ?? PhoneLimits.voiceAppName)”."
                if !number.isEmpty, !connection.isEmpty, !assistant.isEmpty { await saveAndPrepare() }
            } catch {
                handleWebhookRejectionIfNeeded(error)
                self.error = phoneMessage(error)
            }
        }
    }

    private func fixVoiceConnection() {
        guard !busy, let stored = setup else { return }
        busy = true; error = nil; notice = nil
        let targetNumber = selectedNumber ?? (numbers.count == 1 ? numbers[0] : nil)
        let currentConn = connection.isEmpty ? stored.connectionID : connection
        let webhook = effectiveWebhookURL
        Task {
            defer { busy = false }
            do {
                let api = samplehostAPI(key: stored.apiKey)
                let repaired = try await api.repairVoiceConnection(connectionID: currentConn, for: targetNumber, webhookURL: webhook)
                apps = (try? await api.callControlApps()) ?? [samplehostCallControlAppSummary(
                    id: repaired.connectionID,
                    application_name: repaired.connectionName,
                    active: true,
                    webhook_event_url: webhook,
                    outbound: .init(outbound_voice_profile_id: "configured")
                )]
                if let updated = repaired.updatedNumber, let idx = numbers.firstIndex(where: { $0.id == updated.id }) {
                    numbers[idx] = updated
                }
                if number.isEmpty, let targetNumber { number = targetNumber.phone_number }
                connection = repaired.connectionID
                needsCustomWebhookURL = false
                notice = "Updated Voice API connection “\(repaired.connectionName)”."
                if !number.isEmpty, !connection.isEmpty, !assistant.isEmpty { await saveAndPrepare() }
            } catch {
                handleWebhookRejectionIfNeeded(error)
                self.error = phoneMessage(error)
            }
        }
    }

    private func optimizeAssistant() {
        guard !busy, let stored = setup, let assistantID = stored.assistantID else { return }
        busy = true; error = nil; notice = nil
        Task {
            defer { busy = false }
            let updated = await Result.of {
                try await samplehostAPI(key: stored.apiKey).optimizeAssistant(id: assistantID, recording: stored.records)
            }
            switch updated {
            case .success: notice = "Assistant updated for smoother phone calls."
            case .failure(let failure): error = phoneMessage(failure)
            }
        }
    }

    /// With exactly one assistant on the account there is nothing to choose: take it.
    private func pickOnlyAssistant() {
        if assistant.isEmpty, assistants.count == 1 { assistant = assistants[0].id }
    }

    private func createAssistant() {
        guard !busy, let stored = setup else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let made = try await samplehostAPI(key: stored.apiKey).createAssistant(idempotencyKey: createKey)
                if !assistants.contains(made) { assistants.append(made) }
                assistant = made.id
                if !number.isEmpty, !connection.isEmpty, !PhoneConnectionResolver.isInvalidSavedConnection(connection, apps: apps) {
                    await saveAndPrepare()
                }
            } catch { self.error = phoneMessage(error) }
        }
    }

    private func load() async {
        let stored = store.load(for: accountID)
        apply(stored)
        guard let stored else { loaded = true; return }
        do { try await fetch(samplehostAPI(key: stored.apiKey)); error = nil } catch { self.error = phoneMessage(error) }
        loaded = true
    }

    private func connect() {
        guard !busy, !key.isEmpty, setup == nil else { return }
        let submitted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        key = ""; busy = true; error = nil; notice = nil
        Task {
            defer { busy = false }
            let api = samplehostAPI(key: submitted)
            do {
                numbers = try await api.phoneNumbers()   // the read-only check that the key works
                let fetchedApps = try? await api.callControlApps()
                apps = fetchedApps
                var fresh = PhoneSetup(apiKey: submitted)
                if numbers.count == 1 {
                    fresh.fromNumber = numbers[0].phone_number
                    let preferred = PhoneConnectionResolver.preferredConnection(
                        for: numbers[0].phone_number, numbers: numbers, apps: fetchedApps, current: ""
                    )
                    fresh.connectionID = preferred.isEmpty ? nil : preferred
                } else if let fetchedApps, fetchedApps.count == 1 {
                    fresh.connectionID = fetchedApps[0].id
                }
                try store.save(fresh, for: accountID)
                apply(fresh)
                if numbers.count != 1 { number = "" }
                assistants = try await api.assistants()
                pickOnlyAssistant()
                if fresh.ready == false, !number.isEmpty, !connection.isEmpty, !assistant.isEmpty { await saveAndPrepare() }
            } catch {
                self.error = (error as? PhoneKeyStoreError) != nil ? "Couldn't save the key in the Keychain." : phoneMessage(error)
            }
        }
    }

    /// Saves the choices, links the samplehost number to the chosen Voice API connection when needed, and makes the
    /// assistant's recording match the switch (wire fact 9). A failed recording match is shown; the choices stay saved
    /// and the next dial tries again (and won't dial if it fails).
    private func save() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            await saveAndPrepare()
        }
    }

    private func saveAndPrepare() async {
        guard var next = setup else { return }
        next.fromNumber = number; next.connectionID = connection; next.assistantID = assistant
        next.assistantName = assistants.first { $0.id == assistant }?.name
        let name = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        next.ownerName = name.isEmpty ? nil : name
        next.recordCalls = recordCalls
        next.sendResults = sendResults
        do { try store.save(next, for: accountID); apply(next); error = nil } catch {
            self.error = "Couldn't save the selection in the Keychain."
            return
        }
        guard next.ready, let assistantID = next.assistantID else { return }
        let api = samplehostAPI(key: next.apiKey), on = next.records
        let numberToLink = selectedNumber.flatMap { $0.connection_id != connection && !$0.id.isEmpty ? $0 : nil }
        let targetConnection = connection
        if let numberToLink, let updated = try? await api.assignNumberConnection(numberID: numberToLink.id, connectionID: targetConnection),
           let idx = numbers.firstIndex(where: { $0.id == updated.id }) {
            numbers[idx] = updated
        }
        let matched = await Result.of { try await api.prepareAssistantForCall(assistantID: assistantID, recording: on) }
        if case .failure(let failure) = matched {
            error = "Saved, but the assistant's recording couldn't be set to \(on ? "on" : "off"). Calls won't go out until it can. " + phoneMessage(failure)
        }
    }

    private func disconnect() {
        guard !busy, setup != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            await controller.endAll()
            controller.forgetHistory()
            store.delete(for: accountID)
            apply(nil); numbers = []; apps = nil; assistants = []; error = nil; notice = nil
            needsCustomWebhookURL = false; customWebhookURL = ""
        }
    }
}

// MARK: - Settings › Phone Calls › Call history

struct PhoneHistoryView: View {
    let accountID: String
    @State private var selected: PhoneCallRecord?
    private var controller: PhoneCallController { .shared(for: accountID) }

    var body: some View {
        let calls = controller.calls.sorted { $0.placedAt > $1.placedAt }
        Form {
            if calls.isEmpty {
                Section { Text("No calls yet.").foregroundStyle(Color.hqLabel2) }
            } else {
                Section {
                    ForEach(calls) { call in
                        Button { selected = call } label: { PhoneRecentRow(call: call) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("phone.history.row")
                    }
                } footer: {
                    Text("Kept on this device for this account: the newest \(PhoneHistoryStore.maxCalls) calls.")
                }
            }
        }
        .hqGroupedPage()
        .sheet(item: $selected) { call in
            PhoneCallView(accountID: accountID, sessionID: call.sessionID, profile: call.profile, callID: call.id)
        }
    }
}
