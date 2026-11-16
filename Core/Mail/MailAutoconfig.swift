import Foundation

/// Finds a mail account's servers from its address, the way mail apps do: built-in providers, then the published
/// Mozilla/Thunderbird configuration database, then the domain's own autoconfig file, then common host names.
/// Only implicit-TLS servers (IMAP 993, SMTP 465) are used; STARTTLS is not supported yet and is reported plainly.
public enum MailAutoconfig {
    public struct Found: Equatable, Sendable {
        public var account: MailAccount
        public var source: String
        public var note: String?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case badAddress, notFound, needsStartTLS, needsOAuth(String)
        public var errorDescription: String? {
            switch self {
            case .badAddress: "Enter a full email address."
            case .notFound: "Kiln could not find this provider's mail servers. Open Advanced and enter them."
            case .needsStartTLS: "This provider only offers an upgrade-to-TLS connection (STARTTLS), which Kiln does not support yet. Open Advanced to try other ports."
            case .needsOAuth(let provider): "\(provider) no longer accepts a password for mail apps; it needs a browser sign-in (OAuth), which Kiln does not support yet."
            }
        }
    }

    public static func domain(of address: String) -> String? {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].contains(" ") else { return nil }
        return parts[1].lowercased()
    }

    /// Providers that need a browser sign-in. Named so the person is told the truth instead of seeing a login failure.
    static let oauthOnly: [String: String] = [
        "outlook.com": "Outlook.com", "hotmail.com": "Outlook.com", "live.com": "Outlook.com", "msn.com": "Outlook.com", "office365.com": "Microsoft 365",
    ]

    public static func discover(address: String, displayName: String = "", session: URLSession = .shared, probe: Bool = true) async throws -> Found {
        guard let domain = domain(of: address) else { throw Failure.badAddress }
        if let provider = oauthOnly[domain] { throw Failure.needsOAuth(provider) }
        if var preset = MailAccount.preset(for: address, displayName: displayName) {
            preset.displayName = displayName
            return Found(account: preset, source: "built-in settings", note: MailProviderGuide.note(for: domain)?.text)
        }
        var sawStartTLSOnly = false
        for url in ["https://autoconfig.thunderbird.net/v1.1/\(domain)", "https://autoconfig.\(domain)/mail/config-v1.1.xml"] {
            guard let target = URL(string: url), let data = await fetch(target, session: session) else { continue }
            switch parse(xml: data, address: address, displayName: displayName) {
            case .success(let account): return Found(account: account, source: target.host ?? "autoconfig", note: MailProviderGuide.note(for: domain)?.text)
            case .failure(.needsStartTLS): sawStartTLSOnly = true
            case .failure: break
            }
        }
        if probe, let guessed = await guess(address: address, domain: domain, displayName: displayName) {
            return Found(account: guessed, source: "common server names", note: nil)
        }
        throw sawStartTLSOnly ? Failure.needsStartTLS : Failure.notFound
    }

    static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Kiln mail setup", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// Reads a Mozilla autoconfig document (`clientConfig`), keeping implicit-TLS IMAP and SMTP entries.
    public static func parse(xml: Data, address: String, displayName: String = "") -> Result<MailAccount, Failure> {
        let reader = ConfigReader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        // Never fetch external entities from a document that came off the network.
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !reader.servers.isEmpty else { return .failure(.notFound) }
        let local = address.split(separator: "@").first.map(String.init) ?? address
        func login(_ template: String?) -> String {
            (template ?? "%EMAILADDRESS%").replacingOccurrences(of: "%EMAILADDRESS%", with: address).replacingOccurrences(of: "%EMAILLOCALPART%", with: local)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain(of: address) ?? "")
        }
        let imaps = reader.servers.filter { $0.kind == "incoming" && $0.type == "imap" }
        let smtps = reader.servers.filter { $0.kind == "outgoing" && $0.type == "smtp" }
        guard let imap = imaps.first(where: { $0.socket == "SSL" }) else { return .failure(imaps.isEmpty ? .notFound : .needsStartTLS) }
        guard let smtp = smtps.first(where: { $0.socket == "SSL" }) else { return .failure(smtps.isEmpty ? .notFound : .needsStartTLS) }
        guard !imap.host.contains("%"), !smtp.host.contains("%"), let imapPort = Int(imap.port), let smtpPort = Int(smtp.port) else { return .failure(.notFound) }
        return .success(MailAccount(displayName: displayName, address: address, username: login(imap.username),
                                    imapHost: imap.host, imapPort: imapPort, imapSecurity: .tls, smtpHost: smtp.host, smtpPort: smtpPort, smtpSecurity: .tls))
    }

    /// Last resort: the names almost every provider uses. A guess is only kept if a server answers on it.
    static func guess(address: String, domain: String, displayName: String) async -> MailAccount? {
        for prefix in ["imap", "mail"] {
            let host = "\(prefix).\(domain)"
            guard let client = try? IMAPClient(host: host, port: 993, security: .tls, timeout: 5) else { continue }
            do {
                try await client.connect()
                await client.logout()
                return MailAccount(displayName: displayName, address: address, imapHost: host, smtpHost: "smtp.\(domain)")
            } catch { continue }
        }
        return nil
    }

    private final class ConfigReader: NSObject, XMLParserDelegate {
        struct Server { var kind: String; var type: String; var host = ""; var port = ""; var socket = ""; var username: String? }
        var servers: [Server] = []
        private var current: Server?
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            if name == "incomingServer" || name == "outgoingServer" {
                current = Server(kind: name == "incomingServer" ? "incoming" : "outgoing", type: (attributes["type"] ?? "").lowercased())
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "hostname": current?.host = value
            case "port": current?.port = value
            case "socketType": current?.socket = value.uppercased()
            case "username": current?.username = value
            case "incomingServer", "outgoingServer": if let s = current { servers.append(s) }; current = nil
            default: break
            }
        }
    }
}

/// Provider-specific help shown during setup: where to make the app-specific password that mail apps need.
public enum MailProviderGuide {
    public struct Note: Equatable, Sendable { public var text: String; public var url: URL? }

    public static func note(for domain: String) -> Note? {
        switch domain.lowercased() {
        case "gmail.com", "googlemail.com":
            Note(text: "Gmail needs an app password: turn on 2-Step Verification, then create one at myaccount.google.com/apppasswords and paste it here.", url: URL(string: "https://myaccount.google.com/apppasswords"))
        case "icloud.com", "me.com", "mac.com":
            Note(text: "iCloud Mail needs an app-specific password: sign in at account.apple.com, open Sign-In and Security, then App-Specific Passwords.", url: URL(string: "https://account.apple.com"))
        case "yahoo.com", "ymail.com", "aol.com":
            Note(text: "Yahoo and AOL need an app password: create one under Account Security on your account page.", url: URL(string: "https://login.yahoo.com/account/security"))
        default: nil
        }
    }
}

/// The whole "add an account" flow in one place: find the servers (unless given), prove the login works, return the account to save.
public enum MailSetup {
    public typealias Discover = @Sendable (_ address: String, _ name: String) async throws -> MailAutoconfig.Found
    public typealias Verify = @Sendable (_ account: MailAccount, _ password: String) async throws -> Void

    public static func run(name: String, address: String, password: String, manual: MailAccount? = nil,
                           discover: Discover = { try await MailAutoconfig.discover(address: $0, displayName: $1) },
                           verify: Verify = { try await MailService.verify($0, password: $1) }) async throws -> MailAccount {
        let cleaned = address.trimmingCharacters(in: .whitespaces)
        guard MailAutoconfig.domain(of: cleaned) != nil else { throw MailAutoconfig.Failure.badAddress }
        var account: MailAccount
        if let manual { account = manual } else { account = try await discover(cleaned, name).account }
        account.displayName = name
        if let problem = account.validationProblem { throw MailTransportError.serverRejected(problem) }
        try await verify(account, password)
        return account
    }

    /// Turns a transport error into words a person can act on.
    public static func explain(_ error: Error, provider domain: String?) -> String {
        if case MailTransportError.authenticationFailed = error {
            let hint = domain.flatMap { MailProviderGuide.note(for: $0)?.text }
            return "The server refused this email address and password." + (hint.map { " " + $0 } ?? " Check the password, or create an app-specific password if the provider requires one.")
        }
        return error.localizedDescription
    }
}
