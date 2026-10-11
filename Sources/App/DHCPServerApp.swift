import SwiftUI

@main
struct DHCPServerApp: App {
    @StateObject private var model = ServerModel()

    var body: some Scene {
        Window("DHCP Server", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        // Keeps the app (and the server) alive after the window is closed.
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.isRunning
                  ? "antenna.radiowaves.left.and.right"
                  : "antenna.radiowaves.left.and.right.slash")
        }
    }
}
