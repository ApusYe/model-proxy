import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Text("ModelProxy")
                .font(.headline)

            statusSection

            Divider()

            controlSection
        }
        .padding()
        .frame(width: 300)
        .task {
            // Start proxy on first appearance if not already running.
            guard !proxyServer.isRunning else { return }
            await proxyServer.start(config: configStore.config)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if proxyServer.isRunning {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Running").font(.caption)
                }
                let portList = proxyServer.boundPorts.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ", ")
                Text("127.0.0.1 — \(portList)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if let error = proxyServer.lastError {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("Error").font(.caption)
                }
                Text(error)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.center)
            }
        } else {
            HStack {
                ProgressView().scaleEffect(0.6)
                Text("Starting...").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlSection: some View {
        if proxyServer.isRunning {
            Button(action: {
                Task { await proxyServer.stop() }
            }) {
                Text("Stop Proxy").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button(action: {
                Task { await proxyServer.start(config: configStore.config) }
            }) {
                Text("Start Proxy").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }

        Button(action: { openSettings() }) {
            Label("Settings...", systemImage: "gear").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button("Quit ModelProxy") {
            NSApplication.shared.terminate(nil)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer())
}
