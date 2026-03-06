import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore = ConfigStore()
    @State private var proxyServer = ProxyServer()

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: "network") {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
                .environment(proxyServer.trafficLog)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
        }
    }
}
