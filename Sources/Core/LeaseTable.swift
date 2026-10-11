import Foundation

public struct Lease: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case offered, active, declined
    }

    public var ip: IPv4
    public var mac: String
    public var hostname: String
    public var expires: Date
    public var state: State

    public var id: IPv4 { ip }
}

public struct DHCPReply: Sendable {
    public var packet: DHCPPacket
    public var destination: IPv4
}

/// The address-allocation logic. Not thread-safe; the engine drives it from one queue.
public final class LeaseTable {
    public let config: ResolvedConfig
    public private(set) var leases: [IPv4: Lease] = [:]
    public var log: (String) -> Void = { _ in }

    private let reservedOwners: [IPv4: String]
    private static let offerHold: TimeInterval = 60
    private static let declineHold: TimeInterval = 600

    public init(config: ResolvedConfig, leases saved: [Lease] = []) {
        self.config = config
        reservedOwners = Dictionary(uniqueKeysWithValues: config.reservations.map { ($1, $0) })
        // Keep earlier leases only where they still agree with the current settings.
        for lease in saved where lease.state == .active {
            let stillValid = config.reservations[lease.mac] == lease.ip
                || (config.inPool(lease.ip) && isFree(lease.ip, for: lease.mac, now: .distantPast))
            if stillValid {
                leases[lease.ip] = lease
            }
        }
    }

    public func handle(_ request: DHCPPacket, now: Date = Date()) -> DHCPReply? {
        guard request.op == 1, request.htype == 1, request.hlen == 6, let type = request.messageType else { return nil }
        leases = leases.filter { $1.state == .active || $1.expires > now }

        switch type {
        case .discover: return discover(request, now: now)
        case .request: return self.request(request, now: now)
        case .decline: decline(request, now: now)
        case .release: release(request)
        case .inform: return inform(request)
        default: break
        }
        return nil
    }

    // MARK: - Messages

    private func discover(_ request: DHCPPacket, now: Date) -> DHCPReply? {
        let mac = request.mac
        guard let ip = chooseAddress(for: mac, requested: request.address(DHCPOption.requestedIP), now: now) else {
            log("No free address for \(describe(request)) — the pool is full")
            return nil
        }
        forget(mac, except: ip)
        leases[ip] = Lease(ip: ip, mac: mac, hostname: request.hostname,
                           expires: now.addingTimeInterval(Self.offerHold), state: .offered)
        log("Offered \(ip) to \(describe(request))")
        return reply(to: request, type: .offer, yiaddr: ip, withLease: true)
    }

    private func request(_ request: DHCPPacket, now: Date) -> DHCPReply? {
        let mac = request.mac
        if let chosen = request.address(DHCPOption.serverID), chosen != config.serverIP {
            // The client accepted another server's offer.
            leases = leases.filter { !($1.mac == mac && $1.state == .offered) }
            return nil
        }
        guard let wanted = request.address(DHCPOption.requestedIP) ?? (request.ciaddr != .zero ? request.ciaddr : nil) else {
            return nil
        }

        let acceptable: Bool
        if let reserved = config.reservations[mac], isFree(reserved, for: mac, now: now) {
            acceptable = wanted == reserved
        } else {
            acceptable = config.inPool(wanted) && isFree(wanted, for: mac, now: now)
        }
        guard acceptable else {
            log("Refused \(wanted) for \(describe(request))")
            return reply(to: request, type: .nak, yiaddr: .zero, withLease: false)
        }

        forget(mac, except: wanted)
        leases[wanted] = Lease(ip: wanted, mac: mac, hostname: request.hostname,
                               expires: now.addingTimeInterval(TimeInterval(config.leaseSeconds)), state: .active)
        log("Assigned \(wanted) to \(describe(request))")
        return reply(to: request, type: .ack, yiaddr: wanted, withLease: true)
    }

    private func decline(_ request: DHCPPacket, now: Date) {
        guard let ip = request.address(DHCPOption.requestedIP), leases[ip]?.mac == request.mac else { return }
        // The client found the address already in use, so keep it out of circulation for a while.
        leases[ip] = Lease(ip: ip, mac: "", hostname: "In use by another device",
                           expires: now.addingTimeInterval(Self.declineHold), state: .declined)
        log("\(ip) is already in use on the network (reported by \(describe(request)))")
    }

    private func release(_ request: DHCPPacket) {
        guard leases[request.ciaddr]?.mac == request.mac else { return }
        leases[request.ciaddr] = nil
        log("\(describe(request)) released \(request.ciaddr)")
    }

    private func inform(_ request: DHCPPacket) -> DHCPReply? {
        guard request.ciaddr != .zero else { return nil }
        var answer = reply(to: request, type: .ack, yiaddr: .zero, withLease: false)
        answer.destination = request.ciaddr
        return answer
    }

    // MARK: - Allocation

    private func chooseAddress(for mac: String, requested: IPv4?, now: Date) -> IPv4? {
        if let reserved = config.reservations[mac], isFree(reserved, for: mac, now: now) {
            return reserved
        }
        if let current = leases.values.first(where: { $0.mac == mac }),
           config.inPool(current.ip), isFree(current.ip, for: mac, now: now) {
            return current.ip
        }
        if let requested, config.inPool(requested), isFree(requested, for: mac, now: now) {
            return requested
        }
        // Never-used addresses first, then the lease that expired longest ago.
        var oldestExpired: Lease?
        var ip = config.poolStart
        while ip <= config.poolEnd {
            if isFree(ip, for: mac, now: now) {
                guard let previous = leases[ip] else { return ip }
                if oldestExpired == nil || previous.expires < oldestExpired!.expires {
                    oldestExpired = previous
                }
            }
            ip.raw += 1
        }
        return oldestExpired?.ip
    }

    private func isFree(_ ip: IPv4, for mac: String, now: Date) -> Bool {
        guard ip != config.serverIP, ip != config.router else { return false }
        if let owner = reservedOwners[ip], owner != mac { return false }
        guard let lease = leases[ip] else { return true }
        return lease.mac == mac || lease.expires <= now
    }

    private func forget(_ mac: String, except ip: IPv4) {
        leases = leases.filter { $1.mac != mac || $0 == ip }
    }

    // MARK: - Replies

    private func reply(to request: DHCPPacket, type: DHCPMessageType, yiaddr: IPv4, withLease: Bool) -> DHCPReply {
        var packet = DHCPPacket()
        packet.op = 2
        packet.xid = request.xid
        packet.flags = request.flags
        packet.giaddr = request.giaddr
        packet.chaddr = request.chaddr
        packet.yiaddr = yiaddr
        packet.options[DHCPOption.messageType] = [type.rawValue]
        packet.options[DHCPOption.serverID] = config.serverIP.bytes

        if type != .nak {
            packet.siaddr = config.serverIP
            packet.ciaddr = request.ciaddr
            packet.options[DHCPOption.subnetMask] = config.mask.bytes
            packet.options[DHCPOption.broadcastAddress] = config.broadcast.bytes
            if let router = config.router {
                packet.options[DHCPOption.router] = router.bytes
            }
            if !config.dns.isEmpty {
                packet.options[DHCPOption.dns] = config.dns.flatMap(\.bytes)
            }
        }
        if withLease {
            let seconds = config.leaseSeconds
            packet.options[DHCPOption.leaseTime] = IPv4(seconds).bytes
            packet.options[DHCPOption.renewalTime] = IPv4(seconds / 2).bytes
            packet.options[DHCPOption.rebindingTime] = IPv4(seconds / 8 * 7).bytes
        }

        // Clients that already hold a working address can be answered directly; everyone else
        // has no address yet and is reached by broadcast.
        let canUnicast = type != .nak && request.ciaddr != .zero
            && request.flags & 0x8000 == 0 && config.inSubnet(request.ciaddr)
        return DHCPReply(packet: packet, destination: canUnicast ? request.ciaddr : .broadcast)
    }

    private func describe(_ request: DHCPPacket) -> String {
        let name = request.hostname
        return name.isEmpty ? request.mac : "\(name) (\(request.mac))"
    }
}
