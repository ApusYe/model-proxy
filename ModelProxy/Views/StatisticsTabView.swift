import SwiftUI

struct StatisticsTabView: View {
    @Environment(TokenStatsStore.self) private var tokenStatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Divider()

            let rows = tokenStatsStore.tableRows
            if rows.isEmpty {
                emptyState
            } else {
                statsTable(rows: rows)
            }
        }
        .padding()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Statistics — \(tokenStatsStore.statsDate)")
                .font(.headline)
            Spacer()
            Text("Today: \(tokenStatsStore.todayTotalTokens.formatted()) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No token usage recorded today")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Token counts appear after the first proxied request.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Stats Table

    @ViewBuilder
    private func statsTable(
        rows: [(vendorID: UUID, model: String, record: ModelTokenRecord)]
    ) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Column headers
                HStack {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input")
                        .frame(width: 80, alignment: .trailing)
                    Text("Output")
                        .frame(width: 80, alignment: .trailing)
                    Text("Total")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.model)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.record.inputTokens.formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Text(row.record.outputTokens.formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        Text((row.record.inputTokens + row.record.outputTokens).formatted())
                            .font(.body.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.model): \(row.record.inputTokens.formatted()) input, \(row.record.outputTokens.formatted()) output, \((row.record.inputTokens + row.record.outputTokens).formatted()) total tokens")

                    Divider()
                }
            }
        }
    }
}

#Preview {
    StatisticsTabView()
        .environment(TokenStatsStore())
        .frame(width: 520, height: 380)
}
