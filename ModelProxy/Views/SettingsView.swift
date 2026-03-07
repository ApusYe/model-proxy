import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TokenStatsStore.self) private var tokenStatsStore
    @Environment(LoginItemService.self) private var loginItemService

    var body: some View {
        TabView {
            GeneralTabView()
                .tabItem { Label("General", systemImage: "gearshape") }

            ClientsTabView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }

            VendorsTabView()
                .tabItem { Label("Vendors", systemImage: "server.rack") }

            RoutingTabView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }

            StatisticsTabView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }

            DebugTabView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(minWidth: 520, minHeight: 380)
        .environment(configStore)
        .environment(proxyServer)
        .environment(tokenStatsStore)
        .environment(loginItemService)
    }
}

#Preview {
    let statsStore = TokenStatsStore()
    SettingsView()
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: statsStore))
        .environment(statsStore)
        .environment(LoginItemService())
}
