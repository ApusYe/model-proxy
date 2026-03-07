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
                        .buttonStyle(.mpInline)
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

    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var editSourceModel = ""
    @State private var editTargetModel = ""
    @State private var editVendorID: UUID?

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                SourceModelField(text: $editSourceModel)
                TextField("Target model (vendor model name)", text: $editTargetModel)
                    .autocorrectionDisabled()
                Picker("Target vendor", selection: $editVendorID) {
                    Text("Select...").tag(UUID?.none)
                    ForEach(configStore.config.vendors) { vendor in
                        Text(vendor.name).tag(UUID?.some(vendor.id))
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(.mpCancel)
                    Button("Save") {
                        let trimmedSource = editSourceModel.trimmingCharacters(in: .whitespaces)
                        guard let index = configStore.config.modelMappings.firstIndex(where: { $0.id == mapping.id }),
                              !trimmedSource.isEmpty,
                              !editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                              let vendorID = editVendorID else { return }
                        configStore.config.modelMappings[index].sourceModel = trimmedSource
                        configStore.config.modelMappings[index].targetModel = editTargetModel.trimmingCharacters(in: .whitespaces)
                        configStore.config.modelMappings[index].targetVendorID = vendorID
                        configStore.saveAndReload(proxyServer: proxyServer)
                        isEditing = false
                    }
                    .buttonStyle(.mpPrimary)
                    .disabled(
                        editSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editVendorID == nil
                    )
                }
            }
            .padding(.vertical, 4)
        } else {
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
                Button("Edit") {
                    editSourceModel = mapping.sourceModel
                    editTargetModel = mapping.targetModel
                    editVendorID = mapping.targetVendorID
                    isEditing = true
                }
                .buttonStyle(.mpInline)
                .accessibilityLabel("Edit rule for \(mapping.sourceModel)")
                Button("Delete") {
                    showDeleteConfirmation = true
                }
                .buttonStyle(.mpDestructive)
                .accessibilityLabel("Delete rule for \(mapping.sourceModel)")
            }
            .confirmationDialog(
                "Delete routing rule?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    configStore.config.modelMappings.removeAll { $0.id == mapping.id }
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove the rule for \"\(mapping.sourceModel)\"? This cannot be undone.")
            }
        }
    }
}

private struct AddMappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    let onAdd: (ModelMapping) -> Void
    let onCancel: () -> Void

    @State private var selectedSourceModel: String = ""
    @State private var targetModel: String = ""
    @State private var selectedVendorID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceModelField(text: $selectedSourceModel)
            TextField("Target model (vendor model name)", text: $targetModel)
                .autocorrectionDisabled()
            Picker("Target vendor", selection: $selectedVendorID) {
                Text("Select...").tag(UUID?.none)
                ForEach(configStore.config.vendors) { vendor in
                    Text(vendor.name).tag(UUID?.some(vendor.id))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.mpCancel)
                    .accessibilityLabel("Cancel")
                Button("Add") {
                    let trimmedSource = selectedSourceModel.trimmingCharacters(in: .whitespaces)
                    guard !trimmedSource.isEmpty,
                          !targetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                          let vendorID = selectedVendorID else { return }
                    let mapping = ModelMapping(
                        sourceModel: trimmedSource,
                        targetModel: targetModel.trimmingCharacters(in: .whitespaces),
                        targetVendorID: vendorID
                    )
                    onAdd(mapping)
                }
                .buttonStyle(.mpPrimary)
                .disabled(
                    selectedSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    selectedVendorID == nil
                )
                .accessibilityLabel("Add Routing Rule")
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            selectedVendorID = configStore.config.vendors.first?.id
        }
    }
}

/// TextField with a preset menu for quick selection of known Anthropic model IDs.
private struct SourceModelField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Source model (e.g. claude-haiku-4-5)", text: $text)
                .autocorrectionDisabled()
                .focused($isFocused)
            Menu {
                ForEach(KnownAnthropicModels.all, id: \.self) { model in
                    Button(model) { text = model }
                }
                Divider()
                Button("Custom…") {
                    text = ""
                    isFocused = true
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Preset models")
        }
    }
}
