import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore = ConfigStore()
    @State private var proxyServer = ProxyServer()

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: "arrow.triangle.2.circlepath") {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
        }
    }
}
