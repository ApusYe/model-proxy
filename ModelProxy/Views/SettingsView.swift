import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    var body: some View {
        TabView {
            ClientsTabView()
                .tabItem { Label("Clients", systemImage: "desktopcomputer") }

            VendorsTabView()
                .tabItem { Label("Vendors", systemImage: "server.rack") }

            RoutingTabView()
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
        }
        .frame(minWidth: 520, minHeight: 380)
        .environment(configStore)
        .environment(proxyServer)
    }
}

#Preview {
    SettingsView()
        .environment(ConfigStore())
        .environment(ProxyServer())
}
