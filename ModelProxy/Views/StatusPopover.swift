import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TrafficLog.self) private var trafficLog
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Text("ModelProxy")
                .font(.headline)

            statusSection

            Divider()

            controlSection

            Divider()

            trafficSection
        }
        .padding()
        .frame(width: 360)
        .task {
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

    // MARK: - Traffic

    @ViewBuilder
    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Requests")
                .font(.caption)
                .foregroundStyle(.secondary)

            if trafficLog.entries.isEmpty {
                Text("No requests yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(trafficLog.entries) { entry in
                                TrafficRowView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    .onChange(of: trafficLog.entries.last?.id) { _, _ in
                        if let last = trafficLog.entries.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - TrafficRowView

private struct TrafficRowView: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(entry.model)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(routeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(entry.httpStatus)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(statusColor)
                .frame(width: 28, alignment: .trailing)

            Text(relativeTime)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch entry.httpStatus {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }

    private var routeLabel: String {
        switch entry.routeType {
        case .passthrough: return "pass"
        case .mapped(let vendor): return vendor
        case .blocked: return "blocked"
        }
    }

    private var relativeTime: String {
        let elapsed = Date.now.timeIntervalSince(entry.timestamp)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            return "\(Int(elapsed / 3600))h"
        }
    }
}

#Preview {
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer())
        .environment({
            let log = TrafficLog()
            log.append(TrafficEntry(model: "claude-opus-4-6", routeType: .mapped(vendorName: "DashScope"), httpStatus: 200))
            log.append(TrafficEntry(model: "claude-sonnet-4-6", routeType: .passthrough, httpStatus: 200))
            log.append(TrafficEntry(model: "gpt-4o", routeType: .blocked, httpStatus: 403))
            return log
        }())
}
