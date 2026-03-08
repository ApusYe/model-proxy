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
    @State private var editBackupTargetModel = ""
    @State private var editBackupVendorID: UUID?
    @State private var showBackupFields = false

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                SourceModelField(text: $editSourceModel)
                PlainModelField(placeholder: "Target model (vendor model name)", text: $editTargetModel)
                VendorMenuField(
                    placeholder: "Target vendor",
                    selection: $editVendorID,
                    vendors: configStore.config.vendors,
                    clients: configStore.config.clients
                )

                if showBackupFields {
                    Divider()
                    Text("Backup Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PlainModelField(placeholder: "Backup model (vendor model name)", text: $editBackupTargetModel)
                    VendorMenuField(
                        placeholder: "Backup vendor",
                        selection: $editBackupVendorID,
                        vendors: configStore.config.vendors,
                        clients: configStore.config.clients
                    )
                }

                HStack {
                    Spacer()
                    if showBackupFields {
                        Button("Remove Backup") {
                            showBackupFields = false
                            editBackupTargetModel = ""
                            editBackupVendorID = nil
                        }
                        .buttonStyle(.mpDestructive)
                    } else {
                        Button("Add Backup Target") {
                            showBackupFields = true
                        }
                        .buttonStyle(.mpCancel)
                    }
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
                        if showBackupFields,
                           !editBackupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                           let backupVendorID = editBackupVendorID {
                            configStore.config.modelMappings[index].backupTargetModel = editBackupTargetModel.trimmingCharacters(in: .whitespaces)
                            configStore.config.modelMappings[index].backupTargetVendorID = backupVendorID
                        } else {
                            configStore.config.modelMappings[index].backupTargetModel = nil
                            configStore.config.modelMappings[index].backupTargetVendorID = nil
                        }
                        configStore.saveAndReload(proxyServer: proxyServer)
                        isEditing = false
                    }
                    .buttonStyle(.mpPrimary)
                    .disabled(
                        editSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editVendorID == nil ||
                        (showBackupFields && (editBackupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty || editBackupVendorID == nil))
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
                    HStack(spacing: 4) {
                        Text(vendorName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if mapping.backupTargetVendorID != nil {
                            Text("Primary")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue, in: Capsule())
                        }
                    }
                    if let backupVendorID = mapping.backupTargetVendorID {
                        HStack(spacing: 4) {
                            Text(mapping.backupTargetModel ?? mapping.targetModel)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(configStore.config.vendors.first(where: { $0.id == backupVendorID })?.name ?? "Unknown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Backup")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.gray, in: Capsule())
                        }
                    }
                }
                Spacer()
                Button("Edit") {
                    editSourceModel = mapping.sourceModel
                    editTargetModel = mapping.targetModel
                    editVendorID = mapping.targetVendorID
                    editBackupTargetModel = mapping.backupTargetModel ?? ""
                    editBackupVendorID = mapping.backupTargetVendorID
                    showBackupFields = mapping.backupTargetVendorID != nil
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
    @State private var backupTargetModel: String = ""
    @State private var backupTargetVendorID: UUID? = nil
    @State private var showBackupFields: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceModelField(text: $selectedSourceModel)
            PlainModelField(placeholder: "Target model (vendor model name)", text: $targetModel)
            VendorMenuField(
                placeholder: "Target vendor",
                selection: $selectedVendorID,
                vendors: configStore.config.vendors,
                clients: configStore.config.clients
            )

            if showBackupFields {
                Divider()
                Text("Backup Target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PlainModelField(placeholder: "Backup model (vendor model name)", text: $backupTargetModel)
                VendorMenuField(
                    placeholder: "Backup vendor",
                    selection: $backupTargetVendorID,
                    vendors: configStore.config.vendors,
                    clients: configStore.config.clients
                )
            }

            HStack {
                Spacer()
                if showBackupFields {
                    Button("Remove Backup") {
                        showBackupFields = false
                        backupTargetModel = ""
                        backupTargetVendorID = nil
                    }
                    .buttonStyle(.mpDestructive)
                } else {
                    Button("Add Backup Target") {
                        showBackupFields = true
                    }
                    .buttonStyle(.mpCancel)
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(.mpCancel)
                    .accessibilityLabel("Cancel")
                Button("Add") {
                    let trimmedSource = selectedSourceModel.trimmingCharacters(in: .whitespaces)
                    guard !trimmedSource.isEmpty,
                          !targetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                          let vendorID = selectedVendorID else { return }
                    var backupModel: String? = nil
                    var backupVendor: UUID? = nil
                    if showBackupFields,
                       !backupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                       let bvID = backupTargetVendorID {
                        backupModel = backupTargetModel.trimmingCharacters(in: .whitespaces)
                        backupVendor = bvID
                    }
                    let mapping = ModelMapping(
                        sourceModel: trimmedSource,
                        targetModel: targetModel.trimmingCharacters(in: .whitespaces),
                        targetVendorID: vendorID,
                        backupTargetModel: backupModel,
                        backupTargetVendorID: backupVendor
                    )
                    onAdd(mapping)
                }
                .buttonStyle(.mpPrimary)
                .disabled(
                    selectedSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    selectedVendorID == nil ||
                    (showBackupFields && (backupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty || backupTargetVendorID == nil))
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
        TextField("Source model (e.g. claude-haiku-4-5)", text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isFocused)
            .overlay(alignment: .trailing) {
                Menu {
                    ForEach(KnownAnthropicModels.all, id: \.self) { model in
                        Button(model) { text = model }
                    }
                    Divider()
                    Button("Custom...") {
                        text = ""
                        isFocused = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: menuIconWidth)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Preset models")
                .padding(.trailing, 4)
            }
    }
}

private struct PlainModelField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
    }
}

private struct VendorMenuField: View {
    let placeholder: String
    @Binding var selection: UUID?
    let vendors: [Vendor]
    let clients: [ClientConfig]

    private var displayName: String {
        guard let vendorID = selection,
              let vendor = vendors.first(where: { $0.id == vendorID }) else {
            return ""
        }
        return vendor.name
    }

    var body: some View {
        TextField(placeholder, text: .constant(displayName))
            .textFieldStyle(.roundedBorder)
            .allowsHitTesting(false)
            .overlay(alignment: .trailing) {
                Menu {
                    Button("Select...") { selection = nil }
                    Divider()
                    ForEach(vendors) { vendor in
                        Button(vendorPickerLabel(vendor: vendor, clients: clients)) {
                            selection = vendor.id
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: menuIconWidth)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .accessibilityLabel(placeholder)
                .padding(.trailing, 4)
            }
    }
}

/// Vendor picker label annotated with compatible client name (if restricted).
private func vendorPickerLabel(vendor: Vendor, clients: [ClientConfig]) -> String {
    guard let clientID = vendor.compatibleClientID,
          let client = clients.first(where: { $0.id == clientID }) else {
        return vendor.name
    }
    return "\(vendor.name) (\(client.clientName) only)"
}

private let menuIconWidth: CGFloat = 24
