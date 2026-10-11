import Foundation

public struct Reservation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var mac = ""
    public var ip = ""

    public init() {}
}

/// What the user edits. Everything is kept as text so half-typed values survive.
public struct ServerConfig: Codable, Equatable, Sendable {
    public var interfaceName = ""
    public var poolStart = ""
    public var poolSize = 100
    public var router = ""
    public var dns = ""
    public var leaseSeconds = 86_400
    public var reservations: [Reservation] = []

    public init() {}

    /// Validates the settings against the chosen interface.
    public func resolved(on interface: NetInterface?) throws -> ResolvedConfig {
        guard let interface else {
            throw ConfigError("Choose a network interface.")
        }
        guard let serverIP = interface.address, let mask = interface.netmask else {
            throw ConfigError("\(interface.displayName) has no IP address. Give it a manual address in System Settings › Network first.")
        }
        guard !serverIP.isLinkLocal else {
            throw ConfigError("\(interface.displayName) only has a self-assigned address (\(serverIP)). Set a manual address such as 192.168.10.1 in System Settings › Network first.")
        }
        let hostBits = ~mask.raw
        guard hostBits & (hostBits &+ 1) == 0, hostBits >= 3 else {
            throw ConfigError("The subnet mask \(mask) on \(interface.displayName) leaves no room for other devices.")
        }
        let network = IPv4(serverIP.raw & mask.raw)
        let broadcast = IPv4(network.raw | hostBits)
        func inSubnet(_ ip: IPv4) -> Bool { ip > network && ip < broadcast }

        guard let start = IPv4(poolStart) else {
            throw ConfigError("Enter the first address of the pool, for example \(IPv4(network.raw + 1)).")
        }
        guard inSubnet(start) else {
            throw ConfigError("The first address must be on this Mac's network (\(IPv4(network.raw + 1)) – \(IPv4(broadcast.raw - 1))).")
        }
        guard poolSize >= 1 else {
            throw ConfigError("The pool needs at least one address.")
        }
        let available = Int(broadcast.raw - start.raw)
        guard poolSize <= available else {
            throw ConfigError("Only \(available) address\(available == 1 ? "" : "es") fit after \(start) on this network. Reduce the pool size.")
        }
        let end = IPv4(start.raw + UInt32(poolSize) - 1)

        var routerIP: IPv4?
        if !router.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let ip = IPv4(router), inSubnet(ip) else {
                throw ConfigError("The router must be an address on this Mac's network, or left blank.")
            }
            routerIP = ip
        }

        var dnsServers: [IPv4] = []
        for entry in dns.split(whereSeparator: { $0 == "," || $0 == " " }) {
            guard let ip = IPv4(String(entry)) else {
                throw ConfigError("“\(entry)” is not a valid DNS server address.")
            }
            dnsServers.append(ip)
        }

        var reserved: [String: IPv4] = [:]
        for reservation in reservations {
            guard let mac = Self.normalizedMAC(reservation.mac) else {
                throw ConfigError("“\(reservation.mac)” is not a valid MAC address (expected aa:bb:cc:dd:ee:ff).")
            }
            guard let ip = IPv4(reservation.ip), inSubnet(ip), ip != serverIP else {
                throw ConfigError("The reserved address for \(mac) must be a free address on this Mac's network.")
            }
            guard reserved[mac] == nil, !reserved.values.contains(ip) else {
                throw ConfigError("Each reserved device and address may only be listed once (\(mac) → \(ip)).")
            }
            reserved[mac] = ip
        }

        return ResolvedConfig(
            serverIP: serverIP, mask: mask, poolStart: start, poolEnd: end,
            router: routerIP, dns: dnsServers,
            leaseSeconds: UInt32(max(60, leaseSeconds)), reservations: reserved
        )
    }

    /// A sensible default pool for the interface's subnet: (first address, size).
    public static func suggestedPool(for interface: NetInterface) -> (start: IPv4, size: Int)? {
        guard let ip = interface.address, let mask = interface.netmask, !ip.isLinkLocal else { return nil }
        let hostBits = ~mask.raw
        guard hostBits >= 3 else { return nil }
        let network = ip.raw & mask.raw
        let hosts = hostBits - 1
        if hosts >= 200 {
            return (IPv4(network + 100), 100)
        }
        return (IPv4(network + hosts / 2 + 1), max(1, Int(hosts / 2) - 1))
    }

    public static func normalizedMAC(_ text: String) -> String? {
        let hex = text.lowercased().filter(\.isHexDigit)
        guard hex.count == 12, text.allSatisfy({ $0.isHexDigit || ":-. ".contains($0) }) else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset -> String in
            let from = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[from..<hex.index(from, offsetBy: 2)])
        }.joined(separator: ":")
    }
}

public struct ResolvedConfig: Equatable, Sendable {
    public var serverIP: IPv4
    public var mask: IPv4
    public var poolStart: IPv4
    public var poolEnd: IPv4
    public var router: IPv4?
    public var dns: [IPv4]
    public var leaseSeconds: UInt32
    /// MAC (aa:bb:cc:dd:ee:ff) → fixed address.
    public var reservations: [String: IPv4]

    public var broadcast: IPv4 { IPv4(serverIP.raw | ~mask.raw) }

    public func inPool(_ ip: IPv4) -> Bool {
        ip >= poolStart && ip <= poolEnd
    }

    public func inSubnet(_ ip: IPv4) -> Bool {
        ip.raw & mask.raw == serverIP.raw & mask.raw
    }
}

public struct ConfigError: LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
