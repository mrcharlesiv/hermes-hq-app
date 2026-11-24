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
    @State private var apps: [samplehostCallControlAppSummary] = []
    @State private var assistants: [samplehostAssistant] = []
    @State private var key = ""
    @State private var number = ""
    @State private var connection = ""
    @State private var assistant = ""
    @State private var ownerName = ""
    @State private var recordCalls = false
    @State private var sendResults = true
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var loaded = false
    @State private var confirmClear = false
    /// One create-assistant operation per page visit: a retried tap reuses it, so samplehost never makes two.
    @State private var createKey = UUID().uuidString

    private var store: PhoneKeyStore { .app }
    private var controller: PhoneCallController { .shared(for: accountID) }
    private var connections: [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(id: String, name: String)] = numbers.compactMap { n in
            guard let id = n.connection_id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, n.connection_name.flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
        for app in apps where !app.id.isEmpty && seen.insert(app.id).inserted {
            out.append((app.id, app.application_name.flatMap { $0.isEmpty ? nil : $0 } ?? app.id))
        }
        return out
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
                Text(setup == nil ? "Not connected" : setup?.ready == true ? "Ready" : "Connected, choose a number and assistant")
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
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("phone.settings.error") } }
            if let notice { Section { Text(notice).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("phone.settings.notice") } }
            if setup != nil {
                Section {
                    Picker("From number", selection: $number) {
                        Text("Select").tag("")
                        ForEach(numbers) { Text($0.phone_number).tag($0.phone_number) }
                    }
                    .onChange(of: number) { _, picked in
                        if let id = numbers.first(where: { $0.phone_number == picked })?.connection_id, !id.isEmpty { connection = id }
                    }
                    Picker("Voice connection", selection: $connection) {
                        Text("Select").tag("")
                        ForEach(connections, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("AI Assistant", selection: $assistant) {
                        Text("Select").tag("")
                        ForEach(assistants) { Text($0.name).tag($0.id) }
                    }
                    TextField("Your name (said on calls)", text: $ownerName)
                        .textContentType(.name).autocorrectionDisabled()
                        .accessibilityIdentifier("phone.settings.name")
                } header: { Text("Calls") } footer: {
                    Text("The voice connection must be the Call Control application your number uses. Each call gives your assistant this call's context, who it is calling, and an ask_owner tool. With a name, the assistant introduces itself for you (or speaks directly to you when calling you). \(PhoneLimits.stayCopy)")
                }
                if numbers.isEmpty && loaded {
                    Section { Text("No active phone numbers on this samplehost account.").font(Font.hq(.footnote)) }
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
                    Button("Save") { save() }.disabled(busy || !changed || number.isEmpty || connection.isEmpty || assistant.isEmpty)
                        .accessibilityIdentifier("phone.settings.save")
                }
                if setup?.ready == true {
                    Section {
                        NavigationLink("Check my setup") { PhoneSetupCheckView(accountID: accountID).navigationTitle("Check my setup") }
                            .accessibilityIdentifier("phone.settings.check")
                        Button("Optimize assistant for calls") { optimizeAssistant() }.disabled(busy)
                            .accessibilityIdentifier("phone.settings.optimize")
                        NavigationLink("Call history") { PhoneHistoryView(accountID: accountID).navigationTitle("Call history") }
                            .accessibilityIdentifier("phone.settings.history")
                        Button("Clear call history", role: .destructive) { confirmClear = true }
                            .disabled(!controller.calls.contains { !$0.active })
                            .accessibilityIdentifier("phone.settings.clear-history")
                    } footer: {
                        Text("Hermes HQ automatically tunes your assistant for fast turn-taking, natural interruptions, noise suppression, and prompt pickup before your next call. Use this button to apply those settings right away.")
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
        if !numbers.contains(where: { !($0.connection_id ?? "").isEmpty }) {
            apps = (try? await api.callControlApps()) ?? []
        }
        assistants = try await api.assistants()
        pickOnlyAssistant()
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
                if !number.isEmpty, !connection.isEmpty { busy = false; save() }
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
        key = ""; busy = true; error = nil
        Task {
            defer { busy = false }
            let api = samplehostAPI(key: submitted)
            do {
                numbers = try await api.phoneNumbers()   // the read-only check that the key works
                var fresh = PhoneSetup(apiKey: submitted)
                if numbers.count == 1 { fresh.fromNumber = numbers[0].phone_number; fresh.connectionID = numbers[0].connection_id }
                try store.save(fresh, for: accountID)
                apply(fresh)
                if numbers.count != 1 { number = ""; connection = "" }
                if !numbers.contains(where: { !($0.connection_id ?? "").isEmpty }) {
                    apps = (try? await api.callControlApps()) ?? []
                    if apps.count == 1 && connection.isEmpty { connection = apps[0].id }
                }
                assistants = try await api.assistants()
                pickOnlyAssistant()
                if fresh.ready == false, !number.isEmpty, !connection.isEmpty, !assistant.isEmpty { busy = false; save() }
            } catch {
                self.error = (error as? PhoneKeyStoreError) != nil ? "Couldn't save the key in the Keychain." : phoneMessage(error)
            }
        }
    }

    /// Saves the choices, then makes the assistant's recording match the switch (wire fact 9). A failed match is
    /// shown; the choices stay saved and the next dial tries again (and won't dial if it fails).
    private func save() {
        guard !busy, var next = setup else { return }
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
        busy = true
        let api = samplehostAPI(key: next.apiKey), on = next.records
        Task {
            defer { busy = false }
            let matched = await Result.of { try await api.prepareAssistantForCall(assistantID: assistantID, recording: on) }
            if case .failure(let failure) = matched {
                error = "Saved, but the assistant's recording couldn't be set to \(on ? "on" : "off"). Calls won't go out until it can. " + phoneMessage(failure)
            }
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
            apply(nil); numbers = []; apps = []; assistants = []; error = nil; notice = nil
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
