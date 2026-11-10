// [device-access] The Contacts side of Device Access: iOS's permission, and one lookup by name, email address or phone
// number that returns only the details switched on (DeviceAccess.check cut them). Never reads the whole address book
// for a bot: Contacts' own predicates find the matches, at most DeviceAccess.maxMatches of them.

import Contacts
import Foundation

nonisolated enum ContactsLookup {
    enum Permission: Sendable { case allowed, limited, notAsked, denied }

    static var permission: Permission {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .allowed
        case .limited: .limited
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Asks once (the first Contacts switch turned on); true when reading is allowed (all or selected contacts).
    static func requestPermission() async -> Bool {
        if permission == .notAsked { _ = try? await CNContactStore().requestAccess(for: .contacts) }
        return permission == .allowed || permission == .limited
    }

    /// Off the main thread: Contacts reads its database synchronously.
    @concurrent static func search(_ query: String, fields: Set<DeviceAccess.ContactField>) async -> DeviceAccess.Answer {
        guard permission == .allowed || permission == .limited else { return .unavailable(DeviceAccess.notAllowedWords(.contacts)) }
        let store = CNContactStore()
        var keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactOrganizationNameKey as CNKeyDescriptor]
        if fields.contains(.phone) { keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor) }
        if fields.contains(.email) { keys.append(CNContactEmailAddressesKey as CNKeyDescriptor) }
        if fields.contains(.birthday) { keys.append(CNContactBirthdayKey as CNKeyDescriptor) }
        if fields.contains(.address) { keys.append(CNContactPostalAddressesKey as CNKeyDescriptor) }
        let predicate: NSPredicate = switch DeviceAccess.kind(of: query) {
        case .email: CNContact.predicateForContacts(matchingEmailAddress: query)
        case .phone: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
        case .name: CNContact.predicateForContacts(matchingName: query)
        }
        let found: [CNContact]
        do {
            found = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            return .failed("Contacts couldn’t be read.")
        }
        let people = found.prefix(DeviceAccess.maxMatches).map { contact(from: $0, fields: fields) }
        return .contacts(Array(people), more: found.count > DeviceAccess.maxMatches)
    }

    private static func contact(from person: CNContact, fields: Set<DeviceAccess.ContactField>) -> DeviceAccess.Contact {
        let name = CNContactFormatter.string(from: person, style: .fullName) ?? ""
        var out = DeviceAccess.Contact(name: name.isEmpty ? person.organizationName : name, organization: name.isEmpty ? "" : person.organizationName)
        if fields.contains(.phone) {
            out.phones = person.phoneNumbers.map { DeviceAccess.Labeled(label: label($0.label), value: $0.value.stringValue) }
        }
        if fields.contains(.email) {
            out.emails = person.emailAddresses.map { DeviceAccess.Labeled(label: label($0.label), value: $0.value as String) }
        }
        if fields.contains(.birthday) { out.birthday = DeviceAccess.birthday(person.birthday) }
        if fields.contains(.address) {
            out.addresses = person.postalAddresses.map { item in
                let text = CNPostalAddressFormatter.string(from: item.value, style: .mailingAddress)
                    .split(whereSeparator: \.isNewline).joined(separator: ", ")
                return DeviceAccess.Labeled(label: label(item.label), value: text)
            }
        }
        return out
    }

    private static func label(_ raw: String?) -> String {
        raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
    }
}
