import SwiftUI

struct GeneralTabView: View {
    @Environment(LoginItemService.self) private var loginItemService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("ModelProxy will start automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("When enabled, ModelProxy starts automatically after you log in.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refreshStatus()
        }
    }
}

#Preview {
    GeneralTabView()
        .environment(LoginItemService())
}
