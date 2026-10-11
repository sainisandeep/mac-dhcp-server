import Foundation

// Exercises the allocation logic without touching the network: `swift run SelfTest`.

var failures = 0
func ip(_ text: String) -> IPv4 { IPv4(text)! }
func check(_ condition: Bool, _ what: String, line: Int = #line) {
    print(condition ? "  ok   \(what)" : "  FAIL \(what) (line \(line))")
    if !condition { failures += 1 }
}

func client(_ last: UInt8, _ type: DHCPMessageType, requested: IPv4? = nil, server: IPv4? = nil, ciaddr: IPv4 = .zero) -> DHCPPacket {
    var packet = DHCPPacket()
    packet.xid = 0xABCD_0000 | UInt32(last)
    packet.chaddr = [0x02, 0, 0, 0, 0, last] + [UInt8](repeating: 0, count: 10)
    packet.ciaddr = ciaddr
    packet.options[DHCPOption.messageType] = [type.rawValue]
    packet.options[DHCPOption.hostname] = Array("host\(last)".utf8)
    if let requested { packet.options[DHCPOption.requestedIP] = requested.bytes }
    if let server { packet.options[DHCPOption.serverID] = server.bytes }
    // Round-trip through the wire format so the codec is covered too.
    return DHCPPacket(packet.encoded())!
}

let interface = NetInterface(name: "en9", displayName: "Test", address: ip("192.168.10.1"), netmask: ip("255.255.255.0"), isActive: true)
var settings = ServerConfig()
settings.poolStart = "192.168.10.100"
settings.poolSize = 3
settings.router = "192.168.10.1"
settings.dns = "1.1.1.1, 8.8.8.8"
var reservation = Reservation()
reservation.mac = "02-00-00-00-00-09"
reservation.ip = "192.168.10.50"
settings.reservations = [reservation]

let config = try settings.resolved(on: interface)
let server = config.serverIP
let table = LeaseTable(config: config)
let now = Date()

print("Configuration")
check(config.poolEnd == ip("192.168.10.102"), "pool end computed from size")
check(config.reservations["02:00:00:00:00:09"] == ip("192.168.10.50"), "MAC normalised")
settings.poolSize = 500
check((try? settings.resolved(on: interface)) == nil, "oversized pool rejected")
settings.poolSize = 3
var selfAssigned = interface
selfAssigned.address = ip("169.254.3.4")
check((try? settings.resolved(on: selfAssigned)) == nil, "self-assigned interface rejected")

print("Discover / request")
let offer = table.handle(client(1, .discover), now: now)
check(offer?.packet.messageType == .offer && offer?.packet.yiaddr == ip("192.168.10.100"), "first client offered first address")
check(offer?.destination == .broadcast, "offer is broadcast")
check(offer?.packet.address(DHCPOption.subnetMask) == ip("255.255.255.0"), "offer carries subnet mask")
check(offer?.packet.options[DHCPOption.dns]?.count == 8, "offer carries both DNS servers")
check(offer?.packet.xid == 0xABCD_0001, "transaction id echoed")
let ack = table.handle(client(1, .request, requested: ip("192.168.10.100"), server: server), now: now)
check(ack?.packet.messageType == .ack && table.leases[ip("192.168.10.100")]?.state == .active, "request acknowledged")
check(table.leases[ip("192.168.10.100")]?.hostname == "host1", "hostname recorded")

print("Second client, reservation, renewals")
check(table.handle(client(2, .discover), now: now)?.packet.yiaddr == ip("192.168.10.101"), "second client gets next address")
check(table.handle(client(9, .discover), now: now)?.packet.yiaddr == ip("192.168.10.50"), "reserved client gets its fixed address")
check(table.handle(client(1, .discover), now: now)?.packet.yiaddr == ip("192.168.10.100"), "returning client keeps its address")
let renew = table.handle(client(1, .request, ciaddr: ip("192.168.10.100")), now: now)
check(renew?.packet.messageType == .ack && renew?.destination == ip("192.168.10.100"), "renewal acknowledged by unicast")
check(table.handle(client(3, .request, requested: ip("192.168.10.100")), now: now)?.packet.messageType == .nak, "taken address refused")
check(table.handle(client(3, .request, requested: ip("10.0.0.5")), now: now)?.packet.messageType == .nak, "foreign address refused")
check(table.handle(client(3, .request, requested: ip("192.168.10.102"), server: ip("192.168.10.200")), now: now) == nil, "request for another server ignored")

print("Exhaustion, decline, release, expiry")
_ = table.handle(client(2, .request, requested: ip("192.168.10.101"), server: server), now: now)
_ = table.handle(client(3, .discover), now: now)
_ = table.handle(client(3, .request, requested: ip("192.168.10.102"), server: server), now: now)
check(table.handle(client(4, .discover), now: now) == nil, "full pool gives no offer")
_ = table.handle(client(3, .decline, requested: ip("192.168.10.102"), server: server), now: now)
check(table.handle(client(4, .discover), now: now) == nil, "declined address is held back")
_ = table.handle(client(2, .release, ciaddr: ip("192.168.10.101")), now: now)
check(table.handle(client(4, .discover), now: now)?.packet.yiaddr == ip("192.168.10.101"), "released address is reused")
let later = now.addingTimeInterval(TimeInterval(config.leaseSeconds) + 1)
check(table.handle(client(5, .discover), now: later)?.packet.yiaddr != nil, "expired leases are reclaimed")

print("Persistence")
let restored = LeaseTable(config: config, leases: [
    Lease(ip: ip("192.168.10.101"), mac: "02:00:00:00:00:07", hostname: "", expires: now.addingTimeInterval(3600), state: .active),
    Lease(ip: ip("192.168.10.200"), mac: "02:00:00:00:00:08", hostname: "", expires: now.addingTimeInterval(3600), state: .active),
])
check(restored.leases.count == 1, "saved leases outside the pool are dropped")
check(restored.handle(client(1, .discover), now: now)?.packet.yiaddr == ip("192.168.10.100"), "restored lease is not handed out again")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
