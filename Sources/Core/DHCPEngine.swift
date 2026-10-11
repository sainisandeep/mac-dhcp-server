import Foundation

/// Owns the UDP socket on port 67 and feeds incoming messages to a `LeaseTable`.
public final class DHCPEngine {
    public enum Event: Sendable {
        case log(String)
        case leases([Lease])
    }

    public struct StartError: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Called on the engine's private queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "dhcp.engine")
    private var source: DispatchSourceRead?
    private var table: LeaseTable?

    public init() {}

    public func start(config: ResolvedConfig, interfaceName: String, leases: [Lease]) throws {
        stop()

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw StartError(message: "Could not open a network socket: \(Self.lastError())") }

        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, intSize)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, intSize)

        // Tie the socket to the chosen interface so other networks are never served.
        var index = if_nametoindex(interfaceName)
        guard index != 0, setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, intSize) == 0 else {
            close(fd)
            throw StartError(message: "The interface \(interfaceName) is not available.")
        }

        var address = Self.socketAddress(.zero, port: 67)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                throw StartError(message: "Another DHCP server on this Mac is already using port 67. Turn off Internet Sharing (or any other DHCP server) and try again.")
            }
            throw StartError(message: "Could not listen on the DHCP port: \(String(cString: strerror(code)))")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let table = LeaseTable(config: config, leases: leases)
        table.log = { [weak self] in self?.onEvent?(.log($0)) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        source.setCancelHandler { close(fd) }

        queue.sync {
            self.table = table
            self.source = source
        }
        source.resume()
        onEvent?(.leases(Array(table.leases.values)))
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            table = nil
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            // Relayed requests (giaddr set) belong to other subnets, which this server doesn't cover.
            guard let table, let request = DHCPPacket(Array(buffer[..<count])), request.giaddr == .zero else { continue }

            let before = table.leases
            let reply = table.handle(request)
            if table.leases != before {
                onEvent?(.leases(Array(table.leases.values)))
            }
            if let reply {
                send(reply, on: fd)
            }
        }
    }

    private func send(_ reply: DHCPReply, on fd: Int32) {
        let bytes = reply.packet.encoded()
        var address = Self.socketAddress(reply.destination, port: 68)
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent < 0 else { return }
        let code = errno
        var message = "Could not send a reply: \(String(cString: strerror(code)))"
        if code == EHOSTUNREACH || code == EPERM {
            message += ". Check that DHCP Server is allowed in System Settings › Privacy & Security › Local Network."
        }
        onEvent?(.log(message))
    }

    static func socketAddress(_ ip: IPv4, port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = ip.raw.bigEndian
        return address
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}
