import Foundation

public enum DHCPMessageType: UInt8, Sendable {
    case discover = 1, offer, request, decline, ack, nak, release, inform
}

public enum DHCPOption {
    public static let subnetMask: UInt8 = 1
    public static let router: UInt8 = 3
    public static let dns: UInt8 = 6
    public static let hostname: UInt8 = 12
    public static let broadcastAddress: UInt8 = 28
    public static let requestedIP: UInt8 = 50
    public static let leaseTime: UInt8 = 51
    public static let messageType: UInt8 = 53
    public static let serverID: UInt8 = 54
    public static let renewalTime: UInt8 = 58
    public static let rebindingTime: UInt8 = 59
}

/// A BOOTP/DHCP message (RFC 2131).
public struct DHCPPacket: Sendable {
    public var op: UInt8 = 1
    public var htype: UInt8 = 1
    public var hlen: UInt8 = 6
    public var hops: UInt8 = 0
    public var xid: UInt32 = 0
    public var secs: UInt16 = 0
    public var flags: UInt16 = 0
    public var ciaddr = IPv4.zero
    public var yiaddr = IPv4.zero
    public var siaddr = IPv4.zero
    public var giaddr = IPv4.zero
    public var chaddr = [UInt8](repeating: 0, count: 16)
    public var options: [UInt8: [UInt8]] = [:]

    private static let magicCookie: [UInt8] = [99, 130, 83, 99]
    private static let headerLength = 236

    public init() {}

    public init?(_ data: [UInt8]) {
        let header = Self.headerLength
        guard data.count >= header + 4, Array(data[header..<header + 4]) == Self.magicCookie else { return nil }

        op = data[0]
        htype = data[1]
        hlen = data[2]
        hops = data[3]
        xid = data[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        secs = UInt16(data[8]) << 8 | UInt16(data[9])
        flags = UInt16(data[10]) << 8 | UInt16(data[11])
        ciaddr = IPv4(bytes: data[12..<16])!
        yiaddr = IPv4(bytes: data[16..<20])!
        siaddr = IPv4(bytes: data[20..<24])!
        giaddr = IPv4(bytes: data[24..<28])!
        chaddr = Array(data[28..<44])

        var index = header + 4
        while index < data.count {
            let code = data[index]
            index += 1
            if code == 0 { continue }
            if code == 255 { break }
            guard index < data.count else { return nil }
            let length = Int(data[index])
            index += 1
            guard index + length <= data.count else { return nil }
            // A repeated option is a continuation of the earlier one (RFC 3396).
            options[code, default: []] += data[index..<index + length]
            index += length
        }
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = [op, htype, hlen, hops]
        out += [UInt8(xid >> 24), UInt8(xid >> 16 & 0xFF), UInt8(xid >> 8 & 0xFF), UInt8(xid & 0xFF)]
        out += [UInt8(secs >> 8), UInt8(secs & 0xFF), UInt8(flags >> 8), UInt8(flags & 0xFF)]
        out += ciaddr.bytes + yiaddr.bytes + siaddr.bytes + giaddr.bytes
        out += chaddr.prefix(16) + [UInt8](repeating: 0, count: max(0, 16 - chaddr.count))
        out += [UInt8](repeating: 0, count: 64 + 128) // sname + file
        out += Self.magicCookie

        // Message type goes first; some clients expect it there.
        let codes = options.keys.sorted { ($0 == DHCPOption.messageType ? 0 : Int($0)) < ($1 == DHCPOption.messageType ? 0 : Int($1)) }
        for code in codes {
            let value = options[code]!
            out += [code, UInt8(min(value.count, 255))] + value.prefix(255)
        }
        out.append(255)

        // BOOTP minimum size; some older clients drop anything shorter.
        if out.count < 300 {
            out += [UInt8](repeating: 0, count: 300 - out.count)
        }
        return out
    }

    public var messageType: DHCPMessageType? {
        options[DHCPOption.messageType]?.first.flatMap(DHCPMessageType.init)
    }

    public var mac: String {
        chaddr.prefix(Int(min(hlen, 16))).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public var hostname: String {
        guard let bytes = options[DHCPOption.hostname] else { return "" }
        return String(decoding: bytes, as: UTF8.self).filter { !$0.isNewline && $0 != "\0" }
    }

    public func address(_ option: UInt8) -> IPv4? {
        options[option].flatMap { IPv4(bytes: $0) }
    }
}
