import SwiftUI
import UniformTypeIdentifiers

struct LogViewerView: View {
    @Environment(AppLogManager.self) private var logManager
    @State private var selectedCategory: String = "All"
    @State private var searchText = ""
    @State private var autoScroll = true

    private let categories = ["All", "proxy", "config", "stats"]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logListView
            Divider()
            controlBar
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain)

            Picker("", selection: $selectedCategory) {
                ForEach(categories, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 80)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
        )
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    private var logListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: logManager.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 200)
        .background(.background)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack {
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Spacer()

            Button("Clear") {
                Task { try? await logManager.clearLogs() }
            }
            .buttonStyle(.mpInline)

            Button("Open Log Folder") {
                NSWorkspace.shared.open(logManager.logsDirectory)
            }
            .buttonStyle(.mpInline)

            Button("Export Log") { exportLog() }
                .buttonStyle(.mpInline)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        var result = logManager.entries
        if selectedCategory != "All" {
            result = result.filter { $0.category == selectedCategory }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    // MARK: - Export

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "modelproxy-export.log"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = filteredEntries.map { entry in
            let time = LogEntryRow.timeFormatter.string(from: entry.timestamp)
            return "[\(time)] [\(entry.category)] \(entry.level.rawValue.uppercased()) \(entry.message)"
        }.joined(separator: "\n")

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    nonisolated(unsafe) static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text("[\(entry.category)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(levelColor)
                .frame(width: 50, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(nil)
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
