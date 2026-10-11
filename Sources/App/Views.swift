import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ServerModel

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            TabView {
                SetupView().tabItem { Text("Setup") }
                DevicesView().tabItem { Text("Devices (\(model.activeLeaseCount))") }
                LogView().tabItem { Text("Activity") }
            }
            .padding(.top, 10)
        }
        .frame(minWidth: 540, minHeight: 640)
    }
}

private struct StatusHeader: View {
    @EnvironmentObject private var model: ServerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusTitle).font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(model.isRunning || model.problem == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(model.isRunning ? "Stop" : "Start") { model.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(model.isRunning ? .red : .accentColor)
                    .disabled(!model.isRunning && model.problem != nil)
            }
            if let notice = model.notice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.notice = nil }.buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .padding()
    }

    private var subtitle: String {
        if model.isRunning {
            let count = model.activeLeaseCount
            return "Handing out \(model.poolRange ?? "") · \(count) device\(count == 1 ? "" : "s")"
        }
        if let problem = model.problem {
            return problem
        }
        return "Ready to hand out \(model.poolRange ?? "")"
    }
}

private struct SetupView: View {
    @EnvironmentObject private var model: ServerModel

    private static let leaseTimes: [(String, Int)] = [
        ("1 hour", 3_600), ("8 hours", 28_800), ("1 day", 86_400), ("1 week", 604_800),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Interface", selection: Binding(get: { model.config.interfaceName }, set: model.selectInterface)) {
                    if model.selectedInterface == nil {
                        Text(model.config.interfaceName.isEmpty ? "Choose…" : "\(model.config.interfaceName) (not connected)")
                            .tag(model.config.interfaceName)
                    }
                    ForEach(model.interfaces) { interface in
                        Text("\(interface.displayName) (\(interface.name))").tag(interface.name)
                    }
                }
                LabeledContent("This Mac's address", value: macAddressSummary)
            } header: {
                Text("Network interface")
            } footer: {
                Text("Devices connected to this interface receive their addresses from this Mac. Only run one DHCP server per network — turn off DHCP on your router first if it has one.")
            }
            .disabled(model.isRunning)

            Section("Address pool") {
                TextField("First address", text: $model.config.poolStart, prompt: Text("192.168.10.100"))
                LabeledContent("Pool size") {
                    TextField("Pool size", value: $model.config.poolSize, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Stepper("Pool size", value: $model.config.poolSize, in: 1...65_000)
                        .labelsHidden()
                }
                LabeledContent("Addresses handed out", value: model.poolRange ?? "—")
                Picker("Lease time", selection: $model.config.leaseSeconds) {
                    ForEach(Self.leaseTimes, id: \.1) { name, seconds in
                        Text(name).tag(seconds)
                    }
                }
            }
            .disabled(model.isRunning)

            Section {
                TextField("Router", text: $model.config.router, prompt: Text("Optional"))
                TextField("DNS servers", text: $model.config.dns, prompt: Text("Optional, e.g. 1.1.1.1, 8.8.8.8"))
            } header: {
                Text("Sent to each device")
            } footer: {
                Text("Leave both blank on an isolated network with no internet connection.")
            }
            .disabled(model.isRunning)

            Section {
                ForEach($model.config.reservations) { $reservation in
                    HStack {
                        TextField("MAC address", text: $reservation.mac, prompt: Text("aa:bb:cc:dd:ee:ff"))
                        TextField("Address", text: $reservation.ip, prompt: Text("IP address"))
                        Button {
                            model.config.reservations.removeAll { $0.id == reservation.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this reservation")
                    }
                    .labelsHidden()
                }
                Button("Add Reserved Address") {
                    model.config.reservations.append(Reservation())
                }
            } header: {
                Text("Reserved addresses")
            } footer: {
                Text("A reserved device always receives the same address. Everything else is assigned automatically from the pool.")
            }
            .disabled(model.isRunning)

            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                Toggle("Start the server when the app opens", isOn: $model.startOnLaunch)
            } header: {
                Text("Background")
            } footer: {
                Text(model.isRunning
                     ? "Stop the server to change its settings. Closing this window leaves it running — use the menu bar icon to reopen or quit."
                     : "Closing this window leaves the server running — use the menu bar icon to reopen or quit.")
            }
        }
        .formStyle(.grouped)
    }

    private var macAddressSummary: String {
        guard let interface = model.selectedInterface else { return "—" }
        guard let address = interface.address, let mask = interface.netmask else { return "No address" }
        return "\(address)  ·  mask \(mask)"
    }
}

private struct DevicesView: View {
    @EnvironmentObject private var model: ServerModel

    var body: some View {
        Table(model.leases) {
            TableColumn("Address") { Text($0.ip.description) }
            TableColumn("Device") { Text($0.hostname.isEmpty ? "—" : $0.hostname) }
            TableColumn("MAC address") { Text($0.mac).monospaced() }
            TableColumn("Status") { Text(model.status(of: $0)) }
        }
        .overlay {
            if model.leases.isEmpty {
                Text(model.isRunning ? "No devices have asked for an address yet." : "Start the server to hand out addresses.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LogView: View {
    @EnvironmentObject private var model: ServerModel

    var body: some View {
        VStack(spacing: 0) {
            List(model.log.reversed()) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.time.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(line.text).textSelection(.enabled)
                }
                .font(.callout)
            }
            .overlay {
                if model.log.isEmpty {
                    Text("Nothing has happened yet.").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Clear") { model.clearLog() }.disabled(model.log.isEmpty)
            }
            .padding(8)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: ServerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle)
        if model.isRunning {
            Text("\(model.activeLeaseCount) device\(model.activeLeaseCount == 1 ? "" : "s") · \(model.poolRange ?? "")")
        }
        Divider()
        Button(model.isRunning ? "Stop Server" : "Start Server") { model.toggle() }
            .disabled(!model.isRunning && model.problem != nil)
        Button("Open DHCP Server…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit DHCP Server") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
