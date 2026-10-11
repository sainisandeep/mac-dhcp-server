import Foundation

/// Asks the network whether a DHCP server is already present, the way a new device would.
public enum DHCPProbe {
    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Broadcasts a DHCPDISCOVER on the interface and returns every server that makes an offer.
    /// Blocks for `timeout` seconds, so call it off the main thread.
    public static func findServers(interfaceName: String, timeout: TimeInterval = 3) throws -> [IPv4] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure(message: String(cString: strerror(errno))) }
        defer { close(fd) }

        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        // macOS's own DHCP client also uses port 68, so the port has to be shared.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, intSize)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, intSize)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, intSize)

        var index = if_nametoindex(interfaceName)
        guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, intSize) == 0 else {
            throw Failure(message: "The interface \(interfaceName) is not available.")
        }

        var local = DHCPEngine.socketAddress(.zero, port: 68)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure(message: String(cString: strerror(errno))) }

        var discover = DHCPPacket()
        discover.xid = UInt32.random(in: 1...UInt32.max)
        // Ask for a broadcast reply: this socket has no address a server could answer directly.
        discover.flags = 0x8000
        // A made-up, locally administered MAC, so no real device's lease is disturbed.
        discover.chaddr = [0x02] + (0..<5).map { _ in UInt8.random(in: 0...255) } + [UInt8](repeating: 0, count: 10)
        discover.options[DHCPOption.messageType] = [DHCPMessageType.discover.rawValue]
        let bytes = discover.encoded()

        var servers = Set<IPv4>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let start = Date()
        var nextSend = start

        while true {
            let now = Date()
            let remaining = timeout - now.timeIntervalSince(start)
            guard remaining > 0 else { break }

            // Repeat the request every second in case a packet is lost.
            if now >= nextSend {
                var target = DHCPEngine.socketAddress(.broadcast, port: 67)
                let sent = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard sent >= 0 else {
                    let code = errno
                    if code == EHOSTUNREACH || code == EPERM {
                        throw Failure(message: "macOS blocked the request. Allow DHCP Server in System Settings › Privacy & Security › Local Network, and make sure the interface has an IP address.")
                    }
                    throw Failure(message: String(cString: strerror(code)))
                }
                nextSend = now.addingTimeInterval(1)
            }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = min(remaining, max(0, nextSend.timeIntervalSince(now)))
            guard poll(&descriptor, 1, Int32(wait * 1000) + 1) > 0 else { continue }

            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0, let reply = DHCPPacket(Array(buffer[..<count])),
                  reply.op == 2, reply.xid == discover.xid, reply.messageType == .offer else { continue }
            if let server = reply.address(DHCPOption.serverID) ?? (reply.siaddr != .zero ? reply.siaddr : nil) {
                servers.insert(server)
            }
        }
        return servers.sorted()
    }
}
