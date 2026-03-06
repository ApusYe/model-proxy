import SwiftUI

struct RoutingTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddRow: Bool = false

    var body: some View {
        Form {
            Section {
                if configStore.config.modelMappings.isEmpty && !showAddRow {
                    Text("No routing rules. Add one to redirect models to other vendors.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }

                ForEach(configStore.config.modelMappings) { mapping in
                    MappingRow(mapping: mapping)
                        .environment(configStore)
                        .environment(proxyServer)
                }

                if showAddRow {
                    AddMappingRow(
                        knownAnthropicModels: KnownAnthropicModels.all,
                        onAdd: { newMapping in
                            configStore.config.modelMappings.append(newMapping)
                            configStore.saveAndReload(proxyServer: proxyServer)
                            showAddRow = false
                        },
                        onCancel: { showAddRow = false }
                    )
                    .environment(configStore)
                }

            } header: {
                HStack {
                    Text("Model Routing Rules")
                    Spacer()
                    Button("Add Rule") { showAddRow = true }
                        .buttonStyle(.borderless)
                        .disabled(showAddRow || configStore.config.vendors.isEmpty)
                        .accessibilityLabel("Add Routing Rule")
                }
            } footer: {
                if configStore.config.vendors.isEmpty {
                    Text("Add at least one vendor in the Vendors tab before creating routing rules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let mapping: ModelMapping

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    var body: some View {
        HStack {
            Text(mapping.sourceModel)
                .font(.system(.body, design: .monospaced))
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(mapping.targetModel)
                    .font(.system(.body, design: .monospaced))
                Text(vendorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete") {
                configStore.config.modelMappings.removeAll { $0.id == mapping.id }
                configStore.saveAndReload(proxyServer: proxyServer)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete rule for \(mapping.sourceModel)")
        }
    }
}

private struct AddMappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    let knownAnthropicModels: [String]
    let onAdd: (ModelMapping) -> Void
    let onCancel: () -> Void

    @State private var selectedSourceModel: String = ""
    @State private var targetModel: String = ""
    @State private var selectedVendorID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source model", selection: $selectedSourceModel) {
                Text("Select...").tag("")
                ForEach(knownAnthropicModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            TextField("Target model (vendor model name)", text: $targetModel)
                .autocorrectionDisabled()
            Picker("Target vendor", selection: $selectedVendorID) {
                Text("Select...").tag(UUID?.none)
                ForEach(configStore.config.vendors) { vendor in
                    Text(vendor.name).tag(UUID?.some(vendor.id))
                }
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel")
                Spacer()
                Button("Add") {
                    guard !selectedSourceModel.isEmpty,
                          !targetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                          let vendorID = selectedVendorID else { return }
                    let mapping = ModelMapping(
                        sourceModel: selectedSourceModel,
                        targetModel: targetModel.trimmingCharacters(in: .whitespaces),
                        targetVendorID: vendorID
                    )
                    onAdd(mapping)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedSourceModel.isEmpty ||
                    targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    selectedVendorID == nil
                )
                .accessibilityLabel("Add Routing Rule")
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            selectedSourceModel = knownAnthropicModels.first ?? ""
            selectedVendorID = configStore.config.vendors.first?.id
        }
    }
}
