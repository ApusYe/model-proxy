import SwiftUI

struct VendorsTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddSheet: Bool = false
    @State private var editingVendor: Vendor? = nil
    @State private var deletingVendor: Vendor? = nil

    var body: some View {
        Form {
            Section {
                if configStore.config.vendors.isEmpty {
                    Text("No vendors configured. Add one to enable routing.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(configStore.config.vendors) { vendor in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vendor.name)
                                    .fontWeight(.medium)
                                Text(vendor.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editingVendor = vendor
                            }
                            .buttonStyle(.mpInline)
                            .accessibilityLabel("Edit \(vendor.name)")
                            Button("Delete") {
                                deletingVendor = vendor
                            }
                            .buttonStyle(.mpDestructive)
                            .accessibilityLabel("Delete \(vendor.name)")
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text("Vendors")
                    Spacer()
                    Button("Add Vendor") { showAddSheet = true }
                        .buttonStyle(.mpInline)
                        .accessibilityLabel("Add Vendor")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAddSheet) {
            VendorEditSheet(editingVendorID: nil)
                .environment(configStore)
                .environment(proxyServer)
        }
        .sheet(item: $editingVendor) { vendor in
            VendorEditSheet(editingVendorID: vendor.id)
                .environment(configStore)
                .environment(proxyServer)
        }
        .confirmationDialog(
            "Delete vendor?",
            isPresented: Binding(
                get: { deletingVendor != nil },
                set: { if !$0 { deletingVendor = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let vendor = deletingVendor {
                    deleteVendor(id: vendor.id)
                }
                deletingVendor = nil
            }
            Button("Cancel", role: .cancel) { deletingVendor = nil }
        } message: {
            if let vendor = deletingVendor {
                let mappingCount = configStore.config.modelMappings
                    .filter { $0.targetVendorID == vendor.id }.count
                if mappingCount > 0 {
                    Text("\"\(vendor.name)\" has \(mappingCount) routing rule(s) that will also be removed.")
                } else {
                    Text("Remove \"\(vendor.name)\"? This cannot be undone.")
                }
            }
        }
    }

    private func deleteVendor(id: UUID) {
        configStore.config.vendors.removeAll { $0.id == id }
        configStore.config.modelMappings.removeAll { $0.targetVendorID == id }
        configStore.saveAndReload(proxyServer: proxyServer)
    }
}
