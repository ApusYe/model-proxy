import SwiftUI

struct StatusPopover: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(TrafficLog.self) private var trafficLog
    @Environment(\.openSettings) private var openSettings
    @Environment(TokenStatsStore.self) private var tokenStatsStore
    @State private var showingCorruptAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            bannerSection
                .padding(.horizontal, 12)
                .padding(.top, 12)

            clientHeader
                .padding(.horizontal, 12)
                .padding(.top, bannerIsVisible ? 8 : 12)
                .padding(.bottom, 8)

            Divider()

            tokenSummaryCard
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            trafficSection
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()
                .padding(.top, 4)

            controlRow
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 360)
        .onAppear {
            if configStore.didResetFromCorrupt {
                showingCorruptAlert = true
                configStore.clearCorruptFlag()
            }
            let stale = DeprecationChecker.staleSourceModels(in: configStore.config.modelMappings)
            proxyServer.setDeprecationWarnings(stale)
        }
        .alert("Config Reset", isPresented: $showingCorruptAlert) {
            Button("OK") { }
        } message: {
            Text("config.json was corrupt and has been reset to defaults. Your previous settings were not recoverable.")
        }
        .task {
            guard !proxyServer.isRunning, !proxyServer.isStopped else { return }
            await proxyServer.start(config: configStore.config)
        }
    }

    private var bannerIsVisible: Bool {
        proxyServer.lastError != nil || !proxyServer.deprecationWarnings.isEmpty
    }

    // MARK: - Banner

    @ViewBuilder
    private var bannerSection: some View {
        if !proxyServer.isRunning, let error = proxyServer.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Error: \(error)")
        } else if proxyServer.isRunning, let error = proxyServer.lastError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Warning: \(error)")
        }

        if !proxyServer.deprecationWarnings.isEmpty {
            let modelList = proxyServer.deprecationWarnings.joined(separator: ", ")
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Deprecated model mappings: \(modelList)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Warning: deprecated model mappings \(modelList)")
        }
    }

    // MARK: - Client Header

    @ViewBuilder
    private var clientHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(
                proxyServer.boundPorts.sorted(by: { $0.key < $1.key }),
                id: \.key
            ) { name, port in
                Text("\(name):\(port)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            if proxyServer.boundPorts.isEmpty {
                Text("No active listeners")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(clientHeaderAccessibilityLabel)
    }

    private var clientHeaderAccessibilityLabel: String {
        if proxyServer.boundPorts.isEmpty {
            return "No active listeners"
        }
        return proxyServer.boundPorts
            .sorted { $0.key < $1.key }
            .map { "\($0.key) on port \($0.value)" }
            .joined(separator: ", ")
    }

    // MARK: - Token Summary Card

    @ViewBuilder
    private var tokenSummaryCard: some View {
        let total = tokenStatsStore.todayTotalTokens
        let input = tokenStatsStore.stats.totalInputTokens()
        let output = tokenStatsStore.stats.totalOutputTokens()

        Group {
            if total == 0 {
                Text("No tokens today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 1) {
                        Text("↓ \(input.formatted())")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("input")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 28)

                    VStack(spacing: 1) {
                        Text("↑ \(output.formatted())")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("output")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)

                    Divider().frame(height: 28)

                    VStack(spacing: 1) {
                        Text(total.formatted())
                            .font(.caption2.monospacedDigit())
                            .fontWeight(.medium)
                        Text("total")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(total == 0
            ? "Today: no tokens"
            : "Today: \(total.formatted()) tokens, \(input.formatted()) input, \(output.formatted()) output"
        )
    }

    // MARK: - Control Row

    @ViewBuilder
    private var controlRow: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 110, alignment: .leading)

            Spacer()

            HStack(spacing: 6) {
                if proxyServer.isRunning {
                    Button {
                        Task { await proxyServer.stop() }
                    } label: {
                        Text("Stop")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop Proxy")
                    .accessibilityHint("Stops the local proxy server.")
                } else {
                    Button {
                        Task { await proxyServer.start(config: configStore.config) }
                    } label: {
                        Text("Start")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Start Proxy")
                    .accessibilityHint("Starts the local proxy server on configured ports.")
                }

                Button { openSettings() } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open Settings")

                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("Quit")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Quit ModelProxy")
                .accessibilityHint("Stops the proxy and closes the application.")
            }
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            if proxyServer.isRunning {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Running").font(.caption).fontWeight(.medium)
                }
            } else if proxyServer.lastError != nil {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Error").font(.caption).fontWeight(.medium).foregroundStyle(.red)
                }
            } else if proxyServer.isStopped {
                HStack(spacing: 5) {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                    Text("Stopped").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.55).frame(width: 7, height: 7)
                    Text("Starting...").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        if proxyServer.isRunning { return "Proxy running" }
        if proxyServer.lastError != nil { return "Proxy error" }
        if proxyServer.isStopped { return "Proxy stopped" }
        return "Proxy starting"
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
                    .frame(maxHeight: 240)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.model), \(routeLabel), HTTP \(entry.httpStatus), \(relativeTime) ago")
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

// Note: running state with bound ports requires runtime start;
// isRunning and boundPorts are private(set) and cannot be set from a preview.
#Preview("Starting / Stopped") {
    let store = TokenStatsStore()
    StatusPopover()
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: store))
        .environment({
            let log = TrafficLog()
            log.append(TrafficEntry(model: "claude-opus-4-6", routeType: .mapped(vendorName: "DashScope"), httpStatus: 200))
            log.append(TrafficEntry(model: "claude-sonnet-4-6", routeType: .passthrough, httpStatus: 200))
            log.append(TrafficEntry(model: "gpt-4o", routeType: .blocked, httpStatus: 403))
            return log
        }())
        .environment(store)
        .environment(LoginItemService())
}
