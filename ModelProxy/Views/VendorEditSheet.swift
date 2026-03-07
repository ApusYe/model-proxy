import SwiftUI

/// Sheet for adding a new vendor or editing an existing one.
struct VendorEditSheet: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.dismiss) private var dismiss

    /// nil = adding new; non-nil = editing existing (matched by id)
    let editingVendorID: UUID?

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false

    private var isEditing: Bool { editingVendorID != nil }
    private var title: String { isEditing ? "Edit Vendor" : "Add Vendor" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Vendor Details") {
                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()

                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $apiKey)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                        Button(showAPIKey ? "Hide" : "Reveal") {
                            showAPIKey.toggle()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                Button(isEditing ? "Save" : "Add") {
                    commitVendor()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.scheme == nil
                )
                .accessibilityLabel(isEditing ? "Save Vendor" : "Add Vendor")
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear {
            if let vid = editingVendorID,
               let vendor = configStore.config.vendors.first(where: { $0.id == vid }) {
                name = vendor.name
                baseURL = vendor.baseURL
                apiKey = vendor.apiKey
            }
        }
    }

    private func commitVendor() {
        if let vid = editingVendorID,
           let idx = configStore.config.vendors.firstIndex(where: { $0.id == vid }) {
            configStore.config.vendors[idx].name = name
            configStore.config.vendors[idx].baseURL = baseURL
            configStore.config.vendors[idx].apiKey = apiKey
        } else {
            let v = Vendor(name: name, baseURL: baseURL, apiKey: apiKey)
            configStore.config.vendors.append(v)
        }
        configStore.saveAndReload(proxyServer: proxyServer)
    }
}
