import Foundation
import ServiceManagement
import SwiftUI

struct LogLine: Identifiable {
    let id: Int
    let time: Date
    let text: String
}

@MainActor
final class ServerModel: ObservableObject {
    @Published var config: ServerConfig {
        didSet {
            if config != oldValue, let data = try? JSONEncoder().encode(config) {
                defaults.set(data, forKey: Keys.config)
            }
        }
    }
    @Published var startOnLaunch: Bool {
        didSet { defaults.set(startOnLaunch, forKey: Keys.startOnLaunch) }
    }
    @Published var notice: String?
    @Published private(set) var interfaces: [NetInterface] = []
    /// The settings the server is currently running with; nil while stopped.
    @Published private(set) var running: ResolvedConfig?
    @Published private(set) var leases: [Lease] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var now = Date()
    @Published private(set) var isChecking = false
    /// Outcome of the last "check for existing servers", shown under the interface picker.
    @Published private(set) var checkResult: (text: String, conflict: Bool)?

    private enum Keys {
        static let config = "config"
        static let startOnLaunch = "startOnLaunch"
    }

    private let defaults = UserDefaults.standard
    private let engine = DHCPEngine()
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var nextLogID = 0

    init() {
        config = defaults.data(forKey: Keys.config)
            .flatMap { try? JSONDecoder().decode(ServerConfig.self, from: $0) } ?? ServerConfig()
        startOnLaunch = defaults.bool(forKey: Keys.startOnLaunch)
        interfaces = NetInterface.all()
        leases = (try? Data(contentsOf: Self.leaseFile))
            .flatMap { try? JSONDecoder().decode([Lease].self, from: $0) } ?? []

        if config.interfaceName.isEmpty,
           let first = interfaces.first(where: { $0.address.map { !$0.isLinkLocal } ?? false }) ?? interfaces.first {
            selectInterface(first.name)
        }

        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if startOnLaunch {
            startAfterCheck(interactive: false)
        }
    }

    // MARK: - State for the UI

    var isRunning: Bool { running != nil }

    var selectedInterface: NetInterface? {
        interfaces.first { $0.name == config.interfaceName }
    }

    /// Why the current settings can't be used, or nil when they are fine.
    var problem: String? {
        do {
            _ = try config.resolved(on: selectedInterface)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var poolRange: String? {
        guard let resolved = running ?? (try? config.resolved(on: selectedInterface)) else { return nil }
        return resolved.poolStart == resolved.poolEnd
            ? "\(resolved.poolStart)"
            : "\(resolved.poolStart) – \(resolved.poolEnd)"
    }

    var activeLeaseCount: Int {
        leases.filter { $0.state == .active && $0.expires > now }.count
    }

    var statusTitle: String {
        guard isRunning else { return "Server is stopped" }
        return "Running on \(selectedInterface?.displayName ?? config.interfaceName)"
    }

    func status(of lease: Lease) -> String {
        switch lease.state {
        case .offered: return "Offered"
        case .declined: return "Address conflict"
        case .active:
            return lease.expires > now
                ? "Until \(lease.expires.formatted(date: .abbreviated, time: .shortened))"
                : "Expired"
        }
    }

    // MARK: - Actions

    func selectInterface(_ name: String) {
        config.interfaceName = name
        checkResult = nil
        guard let interface = selectedInterface, let suggestion = ServerConfig.suggestedPool(for: interface) else { return }
        // Keep the user's pool if it already fits this network.
        if let start = IPv4(config.poolStart), let ip = interface.address, let mask = interface.netmask,
           start.raw & mask.raw == ip.raw & mask.raw {
            return
        }
        config.poolStart = suggestion.start.description
        config.poolSize = suggestion.size
    }

    func toggle() {
        isRunning ? stop() : startAfterCheck(interactive: true)
    }

    /// Looks for DHCP servers already on the selected network and reports what it finds.
    func checkForServers() {
        guard !isRunning, !isChecking else { return }
        Task {
            switch await findServers() {
            case .success(let servers) where servers.isEmpty:
                checkResult = ("No other DHCP server answered on this network.", false)
            case .success(let servers):
                checkResult = ("Already handing out addresses here: \(Self.list(servers))", true)
            case .failure(let error):
                checkResult = ("Could not check: \(error.localizedDescription)", true)
            }
        }
    }

    /// Starts the server unless another one is already on the network. When `interactive`,
    /// the user is asked whether to start anyway; otherwise the server stays stopped.
    func startAfterCheck(interactive: Bool) {
        guard !isRunning, !isChecking else { return }
        if let problem {
            notice = problem
            return
        }
        Task {
            switch await findServers() {
            case .success(let servers) where !servers.isEmpty:
                let found = Self.list(servers)
                checkResult = ("Already handing out addresses here: \(found)", true)
                append("Found another DHCP server on \(config.interfaceName): \(found)")
                if interactive {
                    guard confirmStart(despite: found) else { return }
                } else {
                    notice = "The server was not started because another DHCP server (\(found)) is already on this network."
                    return
                }
            case .success:
                checkResult = ("No other DHCP server answered on this network.", false)
            case .failure(let error):
                append("Could not check for other DHCP servers: \(error.localizedDescription)")
            }
            start()
        }
    }

    private func findServers() async -> Result<[IPv4], Error> {
        let name = config.interfaceName
        isChecking = true
        defer { isChecking = false }
        return await Task.detached {
            Result { try DHCPProbe.findServers(interfaceName: name) }
        }.value
    }

    private func confirmStart(despite servers: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Another DHCP server is already on this network"
        alert.informativeText = "\(servers) is already handing out addresses on \(selectedInterface?.displayName ?? config.interfaceName). Running a second server gives devices conflicting addresses and can knock them offline."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func list(_ servers: [IPv4]) -> String {
        servers.map(\.description).joined(separator: ", ")
    }

    private func start() {
        guard !isRunning else { return }
        refreshInterfaces()
        do {
            let resolved = try config.resolved(on: selectedInterface)
            try engine.start(config: resolved, interfaceName: config.interfaceName, leases: leases)
            running = resolved
            notice = nil
            // Without this, App Nap can delay replies once the window is closed.
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Serving DHCP")
            append("Server started on \(config.interfaceName) (\(resolved.serverIP)), pool \(resolved.poolStart) – \(resolved.poolEnd)")
        } catch {
            notice = error.localizedDescription
            append("Could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        running = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        append("Server stopped")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notice = "Could not change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Internals

    private func handle(_ event: DHCPEngine.Event) {
        switch event {
        case .log(let text):
            append(text)
        case .leases(let current):
            leases = current.sorted { $0.ip < $1.ip }
            saveLeases()
        }
    }

    private func tick() {
        now = Date()
        refreshInterfaces()
        if let running, selectedInterface?.address != running.serverIP {
            stop()
            notice = "The server was stopped because \(config.interfaceName) was disconnected or its address changed."
        }
    }

    private func refreshInterfaces() {
        let current = NetInterface.all()
        if current != interfaces {
            interfaces = current
        }
    }

    private func append(_ text: String) {
        nextLogID += 1
        log.append(LogLine(id: nextLogID, time: Date(), text: text))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }

    private static var leaseFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DHCP Server/leases.json")
    }

    private func saveLeases() {
        let file = Self.leaseFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(leases.filter { $0.state == .active }).write(to: file, options: .atomic)
    }
}
