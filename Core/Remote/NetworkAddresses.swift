import Darwin
import Foundation

/// This Mac's IPv4 addresses worth giving a phone: Wi-Fi/Ethernet, and a VPN such as Tailscale (100.64.0.0/10).
public enum NetworkAddresses {
    public struct Entry: Equatable, Sendable { public var interface: String; public var address: String; public var isTailscale: Bool }

    public static func current() -> [Entry] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Entry] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }   // link-local: no use to a phone
            result.append(Entry(interface: String(cString: entry.ifa_name), address: text, isTailscale: isTailscale(text)))
        }
        return result
    }

    public static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}
