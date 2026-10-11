import Foundation

/// An IPv4 address held in host byte order.
public struct IPv4: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    public var raw: UInt32

    public static let zero = IPv4(0)
    public static let broadcast = IPv4(0xFFFF_FFFF)

    public init(_ raw: UInt32) {
        self.raw = raw
    }

    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        raw = value
    }

    public init?<C: Collection>(bytes: C) where C.Element == UInt8 {
        guard bytes.count == 4 else { return nil }
        raw = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public var bytes: [UInt8] {
        [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)]
    }

    public var description: String {
        bytes.map(String.init).joined(separator: ".")
    }

    /// 169.254.0.0/16 — what macOS self-assigns when no DHCP server answers.
    public var isLinkLocal: Bool {
        raw >> 16 == 0xA9FE
    }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool {
        lhs.raw < rhs.raw
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let ip = IPv4(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IPv4 address")
        }
        self = ip
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
