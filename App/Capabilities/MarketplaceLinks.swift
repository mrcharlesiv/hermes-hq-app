// [marketplace] The website's "Install in Hermes" buttons: hermes://plugin/install?catalog=<name> and
// hermes://skill/install?identifier=<id> (apps/shared/src/catalog-install.ts). As in Hermes Desktop, a link never
// installs by itself: it opens the plugin's or skill's page in a sheet, with Install To for the bot, and Install asks
// as it does in the app. A `catalog=` link only names a listed plugin (a `repo` riding along is ignored), so a link
// can't install anything Nous didn't review. A skill outside the Marketplace's list opens a page that says where it is
// from; the gateway's own checks run on every install.

import UIKit

@MainActor enum MarketplaceLinks {
    enum Target: Equatable {
        case plugin(String)
        case skill(String)
    }

    /// The install a link asks for; nil for any other link.
    static func target(_ link: DeepLink?) -> Target? {
        guard case .other(let kind, let name, let params)? = link, name == "install" else { return nil }
        func param(_ key: String) -> String? { params.first { $0.key == key }?.value.trimmingCharacters(in: .whitespaces) }
        switch kind {
        case "plugin": return param("catalog").map(Target.plugin)
        case "skill": return param("identifier").map(Target.skill)
        default: return nil
        }
    }

    static func open(_ target: Target, services: any AppServices, from host: UIViewController) {
        AppLog.note("link", "marketplace install link: \(target)")
        Task {
            switch target {
            case .plugin(let name):
                await PluginCatalogStore.shared.load()
                guard !name.isEmpty, let entry = PluginCatalogStore.shared.entries?.first(where: { $0.name == name }) else {
                    LinkOpener.notice(name.isEmpty ? "That link doesn’t name a plugin." : "“\(name)” isn’t in the Hermes Marketplace.", from: host)
                    return
                }
                present(services: services, tab: .plugins, from: host) { model, router in
                    PluginCatalogEntryController(model: model, entry: entry, router: router)
                }
            case .skill(let identifier):
                guard !identifier.isEmpty else { LinkOpener.notice("That link doesn’t name a skill.", from: host); return }
                await SkillCatalogStore.shared.load()
                let entry = SkillCatalogStore.shared.entries?.first { $0.installIdentifier == identifier } ?? outside(identifier)
                present(services: services, tab: .skills, from: host) { model, router in
                    SkillCatalogEntryController(model: model, entry: entry, router: router)
                }
            }
        }
    }

    /// A skill the Marketplace doesn't list (a ClawHub or GitHub link from the Skills Hub's own pages).
    static func outside(_ identifier: String) -> MarketSkill {
        let parts = identifier.split(separator: "/").map(String.init)
        let source = parts.count > 1 ? parts[0] : "community"
        return MarketSkill(name: parts.last ?? identifier, description: "", author: "", category: "other", categoryLabel: "Other",
                                 tags: [], source: source, slug: identifier, installIdentifier: identifier)
    }

    private static func present(services: any AppServices, tab: CapabilitiesTab, from host: UIViewController,
                                page: (CapabilitiesModel, SettingsRouter) -> UIViewController) {
        let model = CapabilitiesModel(services: services, profile: nil, tab: tab)
        let navigation = UINavigationController()
        let router = SettingsRouter(services: services, navigation: navigation)
        let root = page(model, router)
        root.loadViewIfNeeded()
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        close.accessibilityIdentifier = "marketplace.link.close"
        root.navigationItem.rightBarButtonItems = [close] + (root.navigationItem.rightBarButtonItems ?? [])
        navigation.setViewControllers([root], animated: false)
        model.presenter = root
        Task { tab == .plugins ? await model.reloadPlugins() : await model.reloadSkills() }
        let top = FailureAlert.topmost(host) ?? host
        SheetStyle.apply(navigation, from: top)
        top.present(navigation, animated: true)
    }
}
