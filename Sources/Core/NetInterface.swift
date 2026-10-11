import Foundation
import SystemConfiguration

public struct NetInterface: Identifiable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var address: IPv4?
    public var netmask: IPv4?
    public var isActive: Bool

    public var id: String { name }

    public init(name: String, displayName: String, address: IPv4?, netmask: IPv4?, isActive: Bool) {
        self.name = name
        self.displayName = displayName
        self.address = address
        self.netmask = netmask
        self.isActive = isActive
    }

    /// Ethernet-like interfaces (Ethernet, Wi-Fi, USB adapters, bridges) that are connected or configured.
    public static func all() -> [NetInterface] {
        let displayNames = systemDisplayNames()
        var found: [String: NetInterface] = [:]
        var order: [String] = []

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }

        var cursor = list
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next

            let name = String(cString: entry.ifa_name)
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            if found[name] == nil {
                order.append(name)
                found[name] = NetInterface(
                    name: name,
                    displayName: displayNames[name] ?? name,
                    address: nil,
                    netmask: nil,
                    isActive: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
                )
            }

            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let address = ipv4(from: sa) else { continue }
            // Prefer a real address over a self-assigned one if the interface has both.
            if let existing = found[name]?.address, !existing.isLinkLocal { continue }
            found[name]?.address = address
            found[name]?.netmask = entry.ifa_netmask.flatMap(ipv4(from:))
        }

        return order.compactMap { found[$0] }.filter { $0.isActive || $0.address != nil }
    }

    private static func ipv4(from sa: UnsafeMutablePointer<sockaddr>) -> IPv4? {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
    }

    private static func systemDisplayNames() -> [String: String] {
        var names: [String: String] = [:]
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return names }
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = display
        }
        return names
    }
}
