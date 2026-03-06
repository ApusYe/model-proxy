import SwiftUI

@main
struct ModelProxyApp: App {
    @State private var configStore: ConfigStore
    @State private var tokenStatsStore: TokenStatsStore
    @State private var proxyServer: ProxyServer
    @State private var loginItemService: LoginItemService

    init() {
        let store = TokenStatsStore()
        _tokenStatsStore = State(initialValue: store)
        _configStore = State(initialValue: ConfigStore())
        _proxyServer = State(initialValue: ProxyServer(tokenStatsStore: store))
        _loginItemService = State(initialValue: LoginItemService())
    }

    var body: some Scene {
        MenuBarExtra("ModelProxy", systemImage: proxyServer.menuBarSymbol) {
            StatusPopover()
                .environment(configStore)
                .environment(proxyServer)
                .environment(proxyServer.trafficLog)
                .environment(tokenStatsStore)
                .environment(loginItemService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(configStore)
                .environment(proxyServer)
                .environment(tokenStatsStore)
                .environment(loginItemService)
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}
