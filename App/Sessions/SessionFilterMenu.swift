// [sessions-m9] The Sessions Filter & Sort menu as UIKit draws it (docs/spec/3x-sessions.md §5.2, §5.4): the pure
// model's nodes (`SessionFilterMenuModel.nodes`) turned into `UIMenu` elements. Every menu and action carries its
// node's id, as its identifier (so an open menu can be redrawn level by level) and its accessibility identifier.

import UIKit

@MainActor enum SessionFilterMenu {
    typealias Perform = (SessionFilterAction, UIAction) -> Void

    static func elements(_ nodes: [SessionFilterNode], perform: @escaping Perform) -> [UIMenuElement] {
        nodes.map { element($0, perform: perform) }
    }

    static func element(_ node: SessionFilterNode, perform: @escaping Perform) -> UIMenuElement {
        let image = node.symbol.flatMap { UIImage(systemName: $0) }
        switch node.kind {
        case .action(let action):
            var attributes: UIMenuElement.Attributes = []
            if node.keepsOpen { attributes.insert(.keepsMenuPresented) }
            if node.disabled { attributes.insert(.disabled) }
            let item = UIAction(title: node.title, image: image, identifier: UIAction.Identifier(node.id), attributes: attributes,
                                state: node.checked ? .on : .off) { item in
                perform(action, item)
            }
            item.accessibilityIdentifier = node.id
            return item
        case .submenu(let single):
            let menu = UIMenu(title: node.title, subtitle: node.subtitle, image: image, identifier: UIMenu.Identifier(node.id),
                              options: single ? .singleSelection : [], children: elements(node.children, perform: perform))
            menu.accessibilityIdentifier = node.id
            return menu
        case .inline:
            return UIMenu(title: node.title, identifier: UIMenu.Identifier(node.id), options: .displayInline,
                          children: elements(node.children, perform: perform))
        }
    }

    /// The menu with this identifier, at any depth.
    static func find(_ identifier: UIMenu.Identifier, in elements: [UIMenuElement]) -> UIMenu? {
        for case let menu as UIMenu in elements {
            if menu.identifier == identifier { return menu }
            if let found = find(identifier, in: menu.children) { return found }
        }
        return nil
    }
}
