import SwiftUI

struct DebugTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(AppLogManager.self) private var logManager

    var body: some View {
        Form {
            debugToggleSection

            if configStore.config.debug.isEnabled {
                logSettingsSection
                liveLogSection
                storageInfoSection
            } else {
                disabledSection
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Debug Toggle

    private var debugToggleSection: some View {
        Section {
            Toggle(isOn: binding(\.isEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Mode")
                    Text("Enable file-based logging and log viewer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Log Settings

    private var logSettingsSection: some View {
        Section("Log Settings") {
            Picker("Minimum Level", selection: binding(\.minimumLogLevel)) {
                ForEach(DebugConfig.LogLevel.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }

            Toggle("Auto Cleanup", isOn: binding(\.autoCleanupEnabled))

            if configStore.config.debug.autoCleanupEnabled {
                HStack {
                    Text("Retain")
                    Spacer()
                    TextField("", value: binding(\.cleanupAfterDays), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("days")
                }

                HStack {
                    Text("Compress After")
                    Spacer()
                    TextField("", value: binding(\.compressAfterDays), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("days")
                }
            }
        }
    }

    // MARK: - Live Log

    private var liveLogSection: some View {
        Section("Live Log") {
            LogViewerView()
        }
    }

    // MARK: - Storage Info

    private var storageInfoSection: some View {
        Section {
            HStack {
                Text("Log storage:")
                Text(logManager.logsDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            StorageInfoRow()
        }
    }

    // MARK: - Disabled State

    private var disabledSection: some View {
        Section {
            Text("Debug mode is disabled. Enable it to view logs, configure log levels, and manage log files.")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Binding Helper

    /// Creates a binding to a DebugConfig keypath that auto-saves and reconfigures.
    private func binding<T>(_ keyPath: WritableKeyPath<DebugConfig, T>) -> Binding<T> {
        Binding(
            get: { configStore.config.debug[keyPath: keyPath] },
            set: { newValue in
                configStore.config.debug[keyPath: keyPath] = newValue
                configStore.save()
                Task { await logManager.configure(from: configStore.config.debug) }
            }
        )
    }
}

// MARK: - Storage Info Row

private struct StorageInfoRow: View {
    @Environment(AppLogManager.self) private var logManager
    @State private var totalSize: Int64 = 0
    @State private var fileCount: Int = 0

    var body: some View {
        HStack {
            Text("Current size:")
            Text("\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) (\(fileCount) files)")
                .foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            let info = try await logManager.getLogFilesInfo()
            totalSize = info.reduce(0) { $0 + $1.size }
            fileCount = info.count
        } catch {
            totalSize = 0
            fileCount = 0
        }
    }
}
