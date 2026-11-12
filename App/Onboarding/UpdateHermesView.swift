// [onboarding] "Update Hermes on Your Gateway" (docs/spec/3x-onboarding.md §5.15; `showOutdated`,
// `W:src/main.ts:389-413`): the gateway accepted the sign-in, but its Hermes is older than this app needs. It says
// what to do on the gateway computer; Check Again enters once it is updated, and Continue Anyway is the person's call
// (the sign-in is saved either way, so the next launch goes straight in).

import Observation
import SwiftUI
import UIKit

@Observable final class UpdateHermesModel {
    enum Phase: Equatable { case idle, checking, stillOutdated }

    let name: String
    private(set) var info: OutdatedGateway
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let check: () async -> GatewayCompatibility
    @ObservationIgnored private let onEnter: () -> Void
    @ObservationIgnored private var left = false
    @ObservationIgnored var cap: Duration = CompatibilityCap.standard
    @ObservationIgnored var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    @ObservationIgnored var successHaptic: () -> Void = { Haptics.play(.success) }
    /// The latest check (tests await it).
    @ObservationIgnored private(set) var checkTask: Task<Void, Never>?
    /// [update-flow] Opens the one Update sheet for this gateway (nil: Hermes can't update itself there, or the gateway
    /// isn't known); Check Again still enters once it's done.
    @ObservationIgnored var update: ((UIViewController?) -> Void)?
    @ObservationIgnored weak var host: UIViewController?
    var canUpdateHere: Bool { update != nil && info.canUpdate }
    func updateHermes() { update?(host) }

    init(name: String, info: OutdatedGateway, check: @escaping () async -> GatewayCompatibility, onEnter: @escaping () -> Void) {
        self.name = name; self.info = info; self.check = check; self.onEnter = onEnter
    }

    var recovery: String { OutdatedCopy.recovery(canUpdate: info.canUpdate) }
    var release: String { OutdatedCopy.release(info) }
    var status: String {
        switch phase {
        case .idle: ""
        case .checking: OutdatedCopy.checking
        case .stillOutdated: OutdatedCopy.stillOlder
        }
    }
    var busy: Bool { phase == .checking }

    /// One check at a time (`rechecking`, `W:src/connection-startup.ts:417-418`). Still older: say so, with whatever
    /// the gateway reports now. Anything else (new enough, slow, unreadable, restarting) enters: DECISION D11.
    func checkAgain() {
        guard !busy, !left else { return }
        phase = .checking
        announce(OutdatedCopy.checking)
        let start = ContinuousClock.now
        checkTask = Task { [weak self, check, cap] in
            let answer = await CompatibilityCap.run(cap, check)
            guard let self, !self.left else { return }
            if let newer = answer.outdated {
                self.info = newer
                self.phase = .stillOutdated
                Haptics.play(.error)   // the check answered: still too old (a pass plays success)
                self.announce(OutdatedCopy.stillOlder)
                AppLog.trace("onboard", "update-hermes recheck in \(AppLog.ms(since: start)) ms: still older, canUpdate=\(newer.canUpdate)")
            } else {
                self.left = true
                self.successHaptic()
                AppLog.trace("onboard", "update-hermes recheck in \(AppLog.ms(since: start)) ms: new enough now")
                self.onEnter()
            }
        }
    }

    func continueAnyway() {
        guard !busy, !left else { return }
        left = true
        AppLog.trace("onboard", "update-hermes: continuing anyway on an outdated gateway")
        onEnter()
    }
}

struct UpdateHermesView: View {
    let model: UpdateHermesModel
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color.hqPage.ignoresSafeArea())
        // In the Add Gateway sheet this is pushed on a stack: the hosting controller follows SwiftUI's own setting,
        // so the Back button is hidden here as well as on the navigation item.
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("update-hermes")
    }

    private var content: some View {
        VStack(spacing: 0) {
            WornAppIcon(side: 72)
            Text(OutdatedCopy.title)
                .font(Font.hq(.title2).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("update-hermes.title")
                .padding(.top, 20)
            Text(model.recovery)
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update-hermes.recovery")
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    .accessibilityIdentifier("update-hermes.name")
                Text(model.release).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .accessibilityIdentifier("update-hermes.release")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: HQShape.radius(14, .card), style: .continuous).fill(Color(uiColor: HQPalette.groupedCard)))
            .padding(.top, 24)
            VStack(spacing: 12) {
                if model.canUpdateHere {
                    // [update-flow] The same sheet as Command Center's: names the gateway, waits for its bots, confirms.
                    Button(action: model.updateHermes) {
                        Text("Update Hermes").font(Font.hq(.headline)).frame(maxWidth: .infinity, minHeight: height)
                    }
                    .hqGlassProminentButtonStyle()
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("update-hermes.update")
                    Button(action: model.checkAgain) {
                        Text(OutdatedCopy.checkAgain).font(Font.hq(.headline)).frame(maxWidth: .infinity, minHeight: height)
                    }
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("update-hermes.check")
                } else {
                    Button(action: model.checkAgain) {
                        Text(OutdatedCopy.checkAgain).font(Font.hq(.headline)).frame(maxWidth: .infinity, minHeight: height)
                    }
                    .hqGlassProminentButtonStyle()
                    .tint(Color.hqTint)
                    .accessibilityIdentifier("update-hermes.check")
                }
                Button(action: model.continueAnyway) {
                    Text(OutdatedCopy.continueAnyway).font(Font.hq(.headline)).frame(maxWidth: .infinity, minHeight: height)
                }
                .hqGlassButtonStyle()
                .accessibilityIdentifier("update-hermes.continue")
            }
            .controlSize(.large)
            .disabled(model.busy)
            .padding(.top, 24)
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update-hermes.status")
            }
            .frame(minHeight: 24)
            .opacity(model.status.isEmpty ? 0 : 1)
            .accessibilityHidden(model.status.isEmpty)
            .padding(.top, 16)
        }
        .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: model.phase)
    }
}

enum UpdateHermesScreen {
    /// The screen for an outdated gateway just signed in to. `check` is one capped read of its status.
    /// `account`: [update-flow] the gateway signed in to, for its Update Hermes button.
    static func make(name: String, info: OutdatedGateway, account: GatewayAccount? = nil,
                     check: @escaping () async -> GatewayCompatibility, onEnter: @escaping () -> Void) -> UIViewController {
        let model = UpdateHermesModel(name: name, info: info, check: check, onEnter: onEnter)
        // Once the sheet closes on "Updated to …", the page checks again by itself (it had stayed until Check Again).
        if let account {
            model.update = { [weak model] host in
                HermesUpdateCenter.shared.update(account, from: host, afterUpdated: { model?.checkAgain() })
            }
        }
        let controller = UIHostingController(rootView: UpdateHermesView(model: model))
        model.host = controller
        controller.view.backgroundColor = HQPalette.page
        controller.navigationItem.hidesBackButton = true
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }

    /// The gateway's name on the card: the Name given on this phone, else its computer's name, else "Your Gateway".
    nonisolated static func name(url: URL, label: String?) -> String {
        let given = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? GatewayNaming.friendlyName(url) : given
    }
}
