import Foundation
import Contacts

/// One person from the Contacts app. Read-only: Kiln never creates, edits or deletes contacts.
public struct ContactEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var organization: String
    public var emails: [String]
    public var phones: [String]
    public init(id: String, name: String, organization: String = "", emails: [String] = [], phones: [String] = []) {
        self.id = id; self.name = name; self.organization = organization; self.emails = emails; self.phones = phones
    }
}

public enum ContactsAccess: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
    public var isAuthorized: Bool { self == .authorized }
    public var explanation: String {
        switch self {
        case .notDetermined: "Kiln has not asked for access to Contacts yet."
        case .authorized: "Kiln can read your contacts."
        case .denied: "Access to Contacts was refused. Allow Kiln in System Settings, Privacy & Security, Contacts."
        case .restricted: "Contacts access is restricted on this Mac."
        }
    }
}

/// Where contacts come from. The real one is the Contacts framework; tests supply a fixed list.
public protocol ContactSource: Sendable {
    func access() -> ContactsAccess
    func requestAccess() async -> Bool
    func allContacts() throws -> [ContactEntry]
}

public struct SystemContactSource: ContactSource {
    public init() {}

    public func access() -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined   // includes .limited on newer systems, which still lets the enumeration below return what was shared
        }
    }

    public func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    public func allContacts() throws -> [ContactEntry] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor]
        var out: [ContactEntry] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let emails = contact.emailAddresses.map { String($0.value) }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            guard !name.isEmpty || !emails.isEmpty else { return }
            out.append(ContactEntry(id: contact.identifier, name: name, organization: contact.organizationName, emails: emails, phones: phones))
        }
        return out
    }
}

public struct ContactsService: Sendable {
    private let source: any ContactSource
    public init(source: any ContactSource = SystemContactSource()) { self.source = source }

    public var access: ContactsAccess { source.access() }

    /// Asks macOS for access the first time; afterwards returns the existing answer without prompting.
    @discardableResult
    public func ensureAccess() async -> ContactsAccess {
        if source.access() == .notDetermined { _ = await source.requestAccess() }
        return source.access()
    }

    /// People whose name, organization or email contains `query`, best matches first. Empty when access is not granted.
    public func search(_ query: String, limit: Int = 10) async throws -> [ContactEntry] {
        guard await ensureAccess().isAuthorized else { return [] }
        let all = try await Task.detached { [source] in try source.allContacts() }.value
        return Self.rank(query, in: all, limit: limit)
    }

    /// Ranking: name starts with the query, then a word of the name starts with it, then email prefix, then anything containing it.
    public static func rank(_ query: String, in contacts: [ContactEntry], limit: Int = 10) -> [ContactEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ c: ContactEntry) -> Int? {
            let name = c.name.lowercased()
            if name.hasPrefix(q) { return 0 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            if c.emails.contains(where: { $0.lowercased().hasPrefix(q) }) { return 2 }
            if name.contains(q) || c.organization.lowercased().contains(q) || c.emails.contains(where: { $0.lowercased().contains(q) }) { return 3 }
            return nil
        }
        return contacts.compactMap { c in score(c).map { (c, $0) } }
            .sorted { ($0.1, $0.0.name.lowercased()) < ($1.1, $1.0.name.lowercased()) }
            .prefix(max(1, limit)).map(\.0)
    }
}
