# Vendor Presets & Routing Model Picker Implementation Plan

**Goal:** Add preset vendor templates for Chinese AI coding plan providers and known model lists, improving Add Vendor and Routing UI experience.

**Architecture:** A new `KnownVendors.swift` file holds all preset data (vendor templates and their associated model lists) as static structs, keeping it parallel to the existing `KnownAnthropicModels.swift` pattern. `VendorEditSheet` reads this data to drive a template picker only in add mode. `RoutingTabView`'s target model field is upgraded from a plain `TextField` to a combo-style `Picker + TextField` that derives its option list from the selected vendor's baseURL.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+. No new dependencies.

**Design doc:** none

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-03-06-proxy-routing-crystal.md`

---

## Decisions

None.

---

### Task 1: Create KnownVendors.swift

**Files:**
- Create: `ModelProxy/Models/KnownVendors.swift`

**Steps:**

1. Create the file with a `KnownVendorTemplate` struct for preset vendor data and a `KnownVendors` enum as the namespace. Each template carries a display name, a baseURL, and a static model list. A separate lookup function maps an arbitrary baseURL to a known model list by substring matching.

```swift
import Foundation

/// A preset vendor template for the Add Vendor sheet.
struct KnownVendorTemplate: Identifiable {
    let id: String          // stable identifier, not persisted
    let name: String
    let baseURL: String
    let knownModels: [String]
}

/// Preset vendor templates and model lists for known Chinese AI coding plan providers.
/// These are UI helpers only — they do not affect the Vendor struct or persistence format.
enum KnownVendors {

    static let templates: [KnownVendorTemplate] = [
        KnownVendorTemplate(
            id: "aliyun",
            name: "阿里云百炼 Coding Plan",
            baseURL: "https://coding.dashscope.aliyuncs.com/v1",
            knownModels: [
                "qwen3-coder-next",
                "qwen3-coder-plus",
                "qwen3-coder-flash",
                "qwen3.5-plus",
                "qwen3-max",
                "glm-5",
                "kimi-k2.5",
                "MiniMax-M2.5",
            ]
        ),
        KnownVendorTemplate(
            id: "zhipuai",
            name: "智谱AI Coding Plan",
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
            knownModels: [
                "glm-5",
                "glm-4.7",
                "glm-4.5-air",
            ]
        ),
        KnownVendorTemplate(
            id: "volces",
            name: "火山方舟 Coding Plan",
            baseURL: "https://ark.cn-beijing.volces.com/api/coding/v3",
            knownModels: [
                "ark-code-latest",
                "doubao-seed-code-preview-latest",
                "deepseek-v3.2",
                "kimi-k2.5",
                "glm-4.7",
            ]
        ),
    ]

    /// Returns the known model list for a given baseURL using substring matching.
    /// Returns an empty array when no template matches.
    static func knownModels(for baseURL: String) -> [String] {
        if baseURL.contains("dashscope") {
            return templates.first(where: { $0.id == "aliyun" })?.knownModels ?? []
        } else if baseURL.contains("bigmodel") {
            return templates.first(where: { $0.id == "zhipuai" })?.knownModels ?? []
        } else if baseURL.contains("volces") {
            return templates.first(where: { $0.id == "volces" })?.knownModels ?? []
        }
        return []
    }
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

---

### Task 2: Add Vendor Template Picker to VendorEditSheet

**Files:**
- Modify: `ModelProxy/Views/VendorEditSheet.swift`

**Steps:**

1. Add a `@State private var selectedTemplateID: String = "custom"` to track which preset is chosen. The sentinel value `"custom"` means no template selected.

2. Add a computed property `templateOptions` that prepends a "Custom" entry to `KnownVendors.templates` for display in the Picker. Use a simple local struct or tuple approach — since `Picker` needs `Hashable` tags, use the `id: String` of `KnownVendorTemplate` plus `"custom"`.

3. Insert a `Picker("Template", ...)` row at the top of the "Vendor Details" `Section`, guarded by `!isEditing`. When the selection changes (via `.onChange`), if the new value is not `"custom"`, auto-fill `name` and `baseURL` from the matching template; if it reverts to `"custom"`, clear the fields.

4. Keep all existing fields (`TextField` for name, baseURL, apiKey) unchanged and fully editable regardless of preset selection.

The complete rewritten file:

```swift
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
    @State private var selectedTemplateID: String = "custom"

    private var isEditing: Bool { editingVendorID != nil }
    private var title: String { isEditing ? "Edit Vendor" : "Add Vendor" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Vendor Details") {
                    if !isEditing {
                        Picker("Template", selection: $selectedTemplateID) {
                            Text("Custom").tag("custom")
                            ForEach(KnownVendors.templates) { template in
                                Text(template.name).tag(template.id)
                            }
                        }
                        .onChange(of: selectedTemplateID) { _, newID in
                            if let template = KnownVendors.templates.first(where: { $0.id == newID }) {
                                name = template.name
                                baseURL = template.baseURL
                            } else {
                                name = ""
                                baseURL = ""
                            }
                        }
                    }

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
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
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
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual check: Open Settings > Vendors > click "+". The Template picker row must appear. Select "阿里云百炼 Coding Plan" — Name and Base URL fields fill automatically. The API Key field stays empty and focusable. Open Settings > Vendors > click Edit on an existing vendor — no Template picker row is shown.

---

### Task 3: Upgrade Target Model Field to Combo-Style Picker in RoutingTabView

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift`

**Steps:**

The target model field must become a combo-style control: a `Picker` listing known models for the selected vendor, plus a `TextField` for custom input that is always accessible. The approach:

- When the selected vendor's baseURL matches a known template (via `KnownVendors.knownModels(for:)`), show `Picker` + `TextField` side-by-side.
- Selecting a Picker item writes that value into the `targetModel` binding; the `TextField` reflects and allows overriding it.
- When no vendor is selected, or the vendor's baseURL produces an empty model list, show only `TextField` (same as current behavior).

This logic is shared between `AddMappingRow` and `MappingRow` (edit mode). Extract it into a private `TargetModelField` view that takes a binding to the current value and a `[String]` of known models.

The complete rewritten file:

```swift
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

// MARK: - TargetModelField

/// Combo-style control for selecting or typing a target model name.
/// Shows a Picker populated with knownModels when the list is non-empty,
/// plus a TextField that always allows free-form input.
/// When knownModels is empty, shows only the TextField.
private struct TargetModelField: View {
    @Binding var value: String
    let knownModels: [String]

    var body: some View {
        if knownModels.isEmpty {
            TextField("Target model (vendor model name)", text: $value)
                .autocorrectionDisabled()
        } else {
            HStack(spacing: 6) {
                Picker("", selection: $value) {
                    Text("Select...").tag("")
                    ForEach(knownModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                TextField("or type custom", text: $value)
                    .autocorrectionDisabled()
                    .frame(minWidth: 120)
            }
        }
    }
}

// MARK: - MappingRow

private struct MappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let mapping: ModelMapping

    @State private var isEditing = false
    @State private var editSourceModel = ""
    @State private var editTargetModel = ""
    @State private var editVendorID: UUID?

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    private var knownModelsForEditVendor: [String] {
        guard let id = editVendorID,
              let vendor = configStore.config.vendors.first(where: { $0.id == id }) else {
            return []
        }
        return KnownVendors.knownModels(for: vendor.baseURL)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Source model", selection: $editSourceModel) {
                    Text("Select...").tag("")
                    ForEach(KnownAnthropicModels.all, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                TargetModelField(value: $editTargetModel, knownModels: knownModelsForEditVendor)
                Picker("Target vendor", selection: $editVendorID) {
                    Text("Select...").tag(UUID?.none)
                    ForEach(configStore.config.vendors) { vendor in
                        Text(vendor.name).tag(UUID?.some(vendor.id))
                    }
                }
                HStack {
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Save") {
                        guard let index = configStore.config.modelMappings.firstIndex(where: { $0.id == mapping.id }),
                              !editSourceModel.isEmpty,
                              !editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                              let vendorID = editVendorID else { return }
                        configStore.config.modelMappings[index].sourceModel = editSourceModel
                        configStore.config.modelMappings[index].targetModel = editTargetModel.trimmingCharacters(in: .whitespaces)
                        configStore.config.modelMappings[index].targetVendorID = vendorID
                        configStore.saveAndReload(proxyServer: proxyServer)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        editSourceModel.isEmpty ||
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
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit rule for \(mapping.sourceModel)")
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
}

// MARK: - AddMappingRow

private struct AddMappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    let knownAnthropicModels: [String]
    let onAdd: (ModelMapping) -> Void
    let onCancel: () -> Void

    @State private var selectedSourceModel: String = ""
    @State private var targetModel: String = ""
    @State private var selectedVendorID: UUID? = nil

    private var knownModelsForSelectedVendor: [String] {
        guard let id = selectedVendorID,
              let vendor = configStore.config.vendors.first(where: { $0.id == id }) else {
            return []
        }
        return KnownVendors.knownModels(for: vendor.baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source model", selection: $selectedSourceModel) {
                Text("Select...").tag("")
                ForEach(knownAnthropicModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            TargetModelField(value: $targetModel, knownModels: knownModelsForSelectedVendor)
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
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Manual check (requires device): Open Settings > Routing > "Add Rule". Select a vendor that was added from the 阿里云百炼 template. The target model field must show a Picker with the 8 known models and a text field. Select a model from the Picker; confirm the text field reflects the selection. Clear the text field and type a custom ID not in the list; confirm it is accepted. Select a vendor whose baseURL does not match any known template; confirm only a plain text field is shown.

---

### Task 4: Final Build Verification

**Files:** (none modified)

**Steps:**

1. Confirm all three new/modified files compile together cleanly.

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **` with zero `error:` lines.
