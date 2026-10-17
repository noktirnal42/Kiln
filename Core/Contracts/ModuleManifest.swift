import Foundation

public struct ModuleManifest: Sendable, Equatable {
    public let identifier: String
    public let displayName: String
    public let version: String
    public let minAppVersion: String
    public let maxAppVersion: String?
    public let author: String?
    public let description: String?
    public let category: String?
    public let icon: String?
    public let dependencies: [String]
    public let requiredCapabilities: [String]
    public let optionalCapabilities: [String]
    public let provides: [String]
    public let entryPoint: String?

    public init(
        identifier: String,
        displayName: String,
        version: String,
        minAppVersion: String,
        maxAppVersion: String? = nil,
        author: String? = nil,
        description: String? = nil,
        category: String? = nil,
        icon: String? = nil,
        dependencies: [String] = [],
        requiredCapabilities: [String] = [],
        optionalCapabilities: [String] = [],
        provides: [String] = [],
        entryPoint: String? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.version = version
        self.minAppVersion = minAppVersion
        self.maxAppVersion = maxAppVersion
        self.author = author
        self.description = description
        self.category = category
        self.icon = icon
        self.dependencies = dependencies
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.provides = provides
        self.entryPoint = entryPoint
    }
}

extension ModuleManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case identifier, displayName, version, minAppVersion, maxAppVersion
        case author, description, category, icon, dependencies
        case requiredCapabilities, optionalCapabilities, provides, entryPoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? identifier
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        minAppVersion = try container.decodeIfPresent(String.self, forKey: .minAppVersion) ?? "0.0.0"
        maxAppVersion = try container.decodeIfPresent(String.self, forKey: .maxAppVersion)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        requiredCapabilities = try container.decodeIfPresent([String].self, forKey: .requiredCapabilities) ?? []
        optionalCapabilities = try container.decodeIfPresent([String].self, forKey: .optionalCapabilities) ?? []
        provides = try container.decodeIfPresent([String].self, forKey: .provides) ?? []
        entryPoint = try container.decodeIfPresent(String.self, forKey: .entryPoint)
    }
}

public struct SemVer: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(parsing string: String) {
        let parts = string.split(separator: ".").map { Int($0) }
        guard parts.count >= 1, parts.allSatisfy({ $0 != nil }) else { return nil }
        major = parts[0]!
        minor = parts.count > 1 ? parts[1]! : 0
        patch = parts.count > 2 ? parts[2]! : 0
    }

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
