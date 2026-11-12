import Testing
import UIKit
@testable import HermesHQNative

/// [passwords-page] More › Passwords: a section per kind, Logins first, each by name; one line a row.
@MainActor @Suite struct PasswordsPageTests {
    private func item(_ id: String, _ kind: String, _ label: String, origin: String? = nil, identifier: String? = nil) -> VaultItem {
        var fields: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "label": .string(label)]
        if let origin { fields["origin"] = .string(origin) }
        if let identifier { fields["identifier"] = .string(identifier) }
        return VaultItem(.object(fields))!
    }

    @Test func groupsByKindLoginsFirstEachByName() {
        let groups = PasswordsLayout.groups([
            item("1", "address", "Home"), item("2", "payment", "Travel Card"), item("3", "login", "zebra"),
            item("4", "login", "Bank"), item("5", "passkey", "Work"),
        ])
        #expect(groups.map(\.title) == ["Logins", "Cards", "Addresses", "Passkey"])
        #expect(groups[0].items.map(\.label) == ["Bank", "zebra"])
        #expect(PasswordsLayout.groups([]).isEmpty)
    }

    @Test func rowDetailIsWhoElseWhere() {
        #expect(PasswordsLayout.detail(item("1", "login", "Bank", origin: "https://www.bank.com/login", identifier: "ivy@example.com"))
                == "ivy@example.com")
        #expect(PasswordsLayout.detail(item("2", "payment", "Card", origin: "https://www.shop.example.com/pay")) == "shop.example.com")
        #expect(PasswordsLayout.detail(item("3", "address", "Home")) == nil)
    }

    @Test func keyCounts() {
        #expect(PasswordsLayout.setCount([]) == "None Set")
        #expect(PasswordsLayout.setCount([EnvVarInfo(key: "A", isSet: true), EnvVarInfo(key: "B"), EnvVarInfo(key: "C", isSet: true)]) == "2 Set")
    }

    @Test func everyKindHasARealSymbolAndTheRowCanBeATab() {
        for kind in ["login", "payment", "address", "other"] { #expect(UIImage(systemName: PasswordsLayout.symbol(kind)) != nil) }
        #expect(TabChoice(key: "page.passwords") == .page("passwords"))
        #expect(MoreSearch.pageKeywords["passwords"]?.contains("logins") == true)
    }
}
