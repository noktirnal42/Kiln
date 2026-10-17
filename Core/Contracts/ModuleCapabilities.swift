import Foundation

public struct ModuleCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let fileSystemRead = ModuleCapabilities(rawValue: 1 << 0)
    public static let fileSystemWrite = ModuleCapabilities(rawValue: 1 << 1)
    public static let fileSystemExecute = ModuleCapabilities(rawValue: 1 << 2)
    public static let fileSystemAdmin = ModuleCapabilities(rawValue: 1 << 3)

    public static let processSpawn = ModuleCapabilities(rawValue: 1 << 4)
    public static let processAttach = ModuleCapabilities(rawValue: 1 << 5)
    public static let processDebug = ModuleCapabilities(rawValue: 1 << 6)
    public static let processControl = ModuleCapabilities(rawValue: 1 << 7)

    public static let networkClient = ModuleCapabilities(rawValue: 1 << 8)
    public static let networkServer = ModuleCapabilities(rawValue: 1 << 9)
    public static let networkRaw = ModuleCapabilities(rawValue: 1 << 10)
    public static let networkVPN = ModuleCapabilities(rawValue: 1 << 11)

    public static let systemInfo = ModuleCapabilities(rawValue: 1 << 12)
    public static let systemAdmin = ModuleCapabilities(rawValue: 1 << 13)
    public static let kernelExtension = ModuleCapabilities(rawValue: 1 << 14)

    public static let metalCompute = ModuleCapabilities(rawValue: 1 << 15)
    public static let neuralEngine = ModuleCapabilities(rawValue: 1 << 16)
    public static let cameraAccess = ModuleCapabilities(rawValue: 1 << 17)
    public static let microphoneAccess = ModuleCapabilities(rawValue: 1 << 18)
    public static let usbAccess = ModuleCapabilities(rawValue: 1 << 19)
    public static let bluetoothAccess = ModuleCapabilities(rawValue: 1 << 20)

    public static let keychainRead = ModuleCapabilities(rawValue: 1 << 21)
    public static let keychainWrite = ModuleCapabilities(rawValue: 1 << 22)
    public static let cloudKitSync = ModuleCapabilities(rawValue: 1 << 23)
    public static let iCloudDrive = ModuleCapabilities(rawValue: 1 << 24)

    public static let debuggerAttach = ModuleCapabilities(rawValue: 1 << 25)
    public static let simulatorControl = ModuleCapabilities(rawValue: 1 << 26)
    public static let kernelDebug = ModuleCapabilities(rawValue: 1 << 27)
    public static let memoryInspection = ModuleCapabilities(rawValue: 1 << 28)
    public static let codeSigning = ModuleCapabilities(rawValue: 1 << 29)
    public static let entitlementManagement = ModuleCapabilities(rawValue: 1 << 30)

    public static let none: ModuleCapabilities = []

    private static let bitNames: [(UInt64, String)] = [
        (1 << 0, "fileSystem.read"),
        (1 << 1, "fileSystem.write"),
        (1 << 2, "fileSystem.execute"),
        (1 << 3, "fileSystem.admin"),
        (1 << 4, "process.spawn"),
        (1 << 5, "process.attach"),
        (1 << 6, "process.debug"),
        (1 << 7, "process.control"),
        (1 << 8, "network.client"),
        (1 << 9, "network.server"),
        (1 << 10, "network.raw"),
        (1 << 11, "network.vpn"),
        (1 << 12, "systemInfo"),
        (1 << 13, "system.admin"),
        (1 << 14, "kernel.extension"),
        (1 << 15, "metal.compute"),
        (1 << 16, "neuralEngine"),
        (1 << 17, "camera.access"),
        (1 << 18, "microphone.access"),
        (1 << 19, "usb.access"),
        (1 << 20, "bluetooth.access"),
        (1 << 21, "keychain.read"),
        (1 << 22, "keychain.write"),
        (1 << 23, "cloudKit.sync"),
        (1 << 24, "iCloud.drive"),
        (1 << 25, "debugger.attach"),
        (1 << 26, "simulator.control"),
        (1 << 27, "kernel.debug"),
        (1 << 28, "memory.inspection"),
        (1 << 29, "codeSigning"),
        (1 << 30, "entitlementManagement"),
    ]

    private static let namesByCapability: [String: ModuleCapabilities] = {
        var table: [String: ModuleCapabilities] = [:]
        for (bit, name) in bitNames {
            table[name] = ModuleCapabilities(rawValue: bit)
        }
        table["fileSystem.readWrite"] = [.fileSystemRead, .fileSystemWrite]
        return table
    }()

    public static func parse(_ names: [String]) -> (known: ModuleCapabilities, unknown: [String]) {
        var known: ModuleCapabilities = []
        var unknown: [String] = []
        for name in names {
            if let capability = namesByCapability[name] {
                known.insert(capability)
            } else {
                unknown.append(name)
            }
        }
        return (known, unknown)
    }

    public var names: [String] {
        var result: [String] = []
        for (bit, name) in Self.bitNames where contains(ModuleCapabilities(rawValue: bit)) {
            result.append(name)
        }
        return result
    }
}

public struct CapabilityError: Error, Equatable, Sendable, CustomStringConvertible {
    public let missing: ModuleCapabilities

    public init(missing: ModuleCapabilities) { self.missing = missing }

    public var description: String {
        let names = missing.names.isEmpty ? ["<unknown capabilities>"] : missing.names
        return "Capability denied: module lacks required capabilities [\(names.joined(separator: ", "))]"
    }
}
