// Capabilities › Connectors, the managed half (the desktop's Connectors page names these "Managed": apps reached
// through the bot's Nous account). The person's apps first (broken ones on top), then a way into the whole catalog.
// The MCP servers on the gateway keep their own section below (ConnectorsSections).

import SwiftUI
import UIKit

struct ManagedAppsSection: View {
    @Bindable var model: CapabilitiesModel
    let router: SettingsRouter

    var body: some View {
        if let managed = model.managed {
            content(managed)
        }
    }

    /// Managed apps are off for the account and nothing here can turn them on: the section is only a footer line, set
    /// below the rows that work (UX study #96).
    static func isQuiet(_ model: CapabilitiesModel) -> Bool {
        guard let managed = model.managed, managed.phase == .unavailable else { return false }
        return NousAccountBox.isQuiet(managed.nous.state, unavailable: true, read: managed.nous.didRead)
    }

    @ViewBuilder private func content(_ managed: ManagedAppsModel) -> some View {
        if Self.isQuiet(model) {
            // No card or header for a sentence with nothing to tap.
            Section {} footer: { HQSectionFooter { nousBox(managed) }}
        } else {
            section(managed)
        }
    }

    private func nousBox(_ managed: ManagedAppsModel) -> some View {
        // [nous-sign-in] why the apps can't show, and Sign In to Nous when that is the reason
        let key = "\(managed.profile)|\(managed.phase == .unavailable)"
        return NousAccountBox(nous: managed.nous, botName: model.botName, unavailable: managed.phase == .unavailable, readOnly: model.readOnly)
            .task(id: key) {
                managed.nous.presenter = model.presenter
                // A read that turns the section quiet moves it to the footer slot: the moved box doesn't read again.
                guard managed.nous.readKey != key else { return }
                await managed.nous.refresh(profile: managed.profile)
                if !Task.isCancelled { managed.nous.readKey = key }
            }
    }

    @ViewBuilder private func section(_ managed: ManagedAppsModel) -> some View {
        Section {
            switch managed.phase {
            case .loading:
                ForEach(0..<2, id: \.self) { _ in SkeletonLine() }
            case .signedOut, .unavailable:
                nousBox(managed)
            case .tooOld:
                ManagedEmptyRow(title: "Managed apps need a newer Hermes.", detail: ConnectorFailure.tooOldWords, id: "managed.too-old")
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn’t reach the managed apps.").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                    Text("\(reason) Your other connectors are unaffected; nothing was turned off.").font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { managed.load(force: true) }.hqBorderedButtonStyle().padding(.top, 2)
                        .accessibilityIdentifier("managed.retry")
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("managed.failed")
            case .ready:
                ready(managed)
            }
        } header: { HQSectionLabel {
            Text("Managed Apps")
        } } footer: { HQSectionFooter {
            if managed.phase == .ready {
                // [connectors-ux] one sentence, not two that both said "Nous"
                Text("Connected through \(model.botName)’s Nous account, so they follow the account, not the bot.")
            }
        } }
    }

    @ViewBuilder private func ready(_ managed: ManagedAppsModel) -> some View {
        let apps = managed.apps
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = query.isEmpty ? ManagedJoin.mine(apps) : apps.filter { $0.matches(query) }
        if query.isEmpty, shown.isEmpty {
            Text("No apps connected yet. Connect Gmail, GitHub, Slack and more through Nous.")
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(shown.prefix(query.isEmpty ? 50 : 8))) { app in
            ManagedAppRow(app: app, busy: managed.busy.contains(app.slug), connecting: managed.waiting(app.slug)) {
                router.push(ManagedAppController(model: model, slug: app.slug, router: router))
            }
        }
        if !query.isEmpty, shown.isEmpty {
            Text("No managed app matches “\(query)”.").foregroundStyle(Color.hqLabel2).padding(.vertical, 4)
        }
        if !apps.isEmpty {
            Button {
                router.push(ManagedCatalogController(model: model, router: router, query: query))
            } label: {
                BrowseRowLabel(title: !query.isEmpty && shown.count > 8 ? "Show All \(shown.count) Matches" : "Browse Apps", count: apps.count)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browse \(apps.count) apps")
            .accessibilityIdentifier("managed.browse")
        }
    }
}

struct ManagedEmptyRow: View {
    let title: String
    let detail: String
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// One managed app: logo, name, the state as a dot and words (red when broken, orange when access expired).
struct ManagedAppRow: View {
    let app: ManagedApp
    var busy = false
    var connecting = false
    var showDescription = false
    var connect: (() -> Void)?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ManagedLogo(app: app, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqLabel)
                        if showDescription, !app.description.isEmpty, app.state == .available {
                            Text(app.description).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                        } else {
                            // [connectors-ux] the dot and words every connector row uses
                            ConnectorStatusLine(words: connecting ? "Connecting" : app.stateWord, tone: ConnectorTone.of(app, connecting: connecting))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if connect == nil || app.state != .available {
                        if busy { ProgressView() }
                        SettingsChevron()
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("managed-row-\(app.slug)")
            if let connect, app.state == .available {
                if busy {
                    ProgressView().frame(minWidth: 52).accessibilityLabel("Connecting \(app.name)")
                } else {
                    Button("Connect", action: connect)
                        .hqRowActionButtonStyle()
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .accessibilityLabel("Connect \(app.name)")
                        .accessibilityIdentifier("managed-connect-\(app.slug)")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The catalog's logo. Only https logos are fetched (loopback in DEBUG). [connectors-ux] Without one, the app's mark from
/// logos.composio.dev under its slug (the managed apps are Composio's, so the slug is the same), drawn as a catalog
/// app's is; else a symbol tile. Never the first letter on the tint (the owner: "never letter tiles").
struct ManagedLogo: View {
    let app: ManagedApp
    var size: CGFloat = 34
    @State private var image: UIImage?
    @State private var read = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.24))
            } else if read {
                CatalogLogo(name: app.name, slugs: [app.slug, app.slug.replacingOccurrences(of: "_", with: "")], size: size)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(Color.hqFill3, lineWidth: image == nil ? 0 : 0.5))
        .accessibilityHidden(true)
        .task(id: app.logoURL) {
            image = await ManagedLogoStore.shared.image(app.logoURL)
            read = true
        }
    }
}

@MainActor final class ManagedLogoStore {
    static let shared = ManagedLogoStore()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func image(_ link: String?) async -> UIImage? {
        guard let link, let url = ManagedSignInBrowser.accepts(link) else { return nil }
        if let hit = cache.object(forKey: link as NSString) { return hit }
        guard let (data, response) = try? await session.data(from: url), let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 256 * 1024, let image = await SVGLogo.decode(data) else { return nil }
        cache.setObject(image, forKey: link as NSString)
        return image
    }
}
