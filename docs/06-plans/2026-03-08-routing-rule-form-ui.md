# Routing Rule Form UI Refinement Implementation Plan

**Goal:** Refine the Add Rule / Edit Rule form UI in RoutingTabView — move action buttons to bottom row, embed dropdown arrows inside text fields, and unify vendor picker style.

**Architecture:** All changes are confined to `ModelProxy/Views/RoutingTabView.swift`. Three new private sub-components replace the existing HStack+Color.clear spacer pattern and native Picker controls: `OverlayMenuTextField` (TextField with overlaid chevron + Menu for source model), `PlainTextField` (TextField with matching right padding but no menu), and `VendorMenuField` (TextField-look + Menu for vendor selection). The `menuWidth` @State and `MenuButtonWidthKey` PreferenceKey are removed from both `AddMappingRow` and `MappingRow` once padding unifies alignment. The bottom HStack in both row types is reordered to place the backup button left of Cancel.

**Tech Stack:** SwiftUI (macOS 14+), Swift 6. No new dependencies.

**Design doc:** none

**Design analysis:** none

**Crystal file:** `docs/11-crystals/2026-03-08-routing-rule-form-ui-crystal.md`

---

## Scope Boundaries

IN:
- "Add Backup Target" / "Remove Backup" moved into bottom button row
- Dropdown arrows embedded inside TextField border via overlay
- Uniform right padding on all TextFields (with or without arrow)
- Target Vendor and Backup Vendor replaced with TextField+Menu style
- Applied to both `AddMappingRow` and `MappingRow`
- Remove `Color.clear` spacer hack and `menuWidth` state

OUT:
- Form validation logic and data flow (unchanged)
- Any styles outside scope: button styles (`.mpInline`, `.mpCancel`, `.mpPrimary`, `.mpDestructive`), colors, fonts, spacing on non-modified elements

---

### Task 1: Define shared layout constants and build `OverlayMenuTextField`

Crystal ref: [D-002] [D-003]

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:342-392`

**Context:**

The current `SourceModelField` uses an HStack with the Menu button outside the TextField border. This task replaces it with a component where the chevron+Menu sits as an overlay inside the TextField's right edge.

The constant `menuOverlayWidth: CGFloat = 28` is the horizontal space reserved inside the TextField for the arrow icon. This value applies to every field in this file (arrow fields and plain fields alike), ensuring text starts at the same left indent regardless of whether an arrow is present.

**Steps:**

1. At the top of the private types section (after line 341), add a file-scoped private constant:

```swift
private let menuOverlayWidth: CGFloat = 28
```

2. Replace the entire `SourceModelField` struct (lines 342-375) with `OverlayMenuTextField`:

```swift
/// TextField with a chevron-triggered Menu overlaid inside the right edge of the border.
/// Used for Source Model quick-select. Crystal ref: D-002, D-003.
private struct OverlayMenuTextField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Source model (e.g. claude-haiku-4-5)", text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isFocused)
            .padding(.trailing, menuOverlayWidth)
            .overlay(alignment: .trailing) {
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
                        .foregroundStyle(.secondary)
                        .frame(width: menuOverlayWidth)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Preset models")
            }
    }
}
```

3. Add `PlainTextField` immediately after `OverlayMenuTextField`. This component carries the same right padding so text aligns with arrow fields:

```swift
/// TextField with right padding matching OverlayMenuTextField, but no arrow.
/// Used for Target Model and Backup Model fields. Crystal ref: D-004.
private struct PlainTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .padding(.trailing, menuOverlayWidth)
    }
}
```

4. Remove the now-unused `MenuButtonWidthKey` struct (lines 386-391).

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` with no `error:` lines.

---

### Task 2: Build `VendorMenuField`

Crystal ref: [D-005]

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift` — add new struct after `PlainTextField`

**Context:**

`VendorMenuField` replaces the native `Picker` for Target Vendor and Backup Vendor in both rows. It presents like a TextField (rounded border, same right padding) but is read-only — the user opens the menu via the overlaid chevron to select a vendor. The bound value is `UUID?`. When `nil` it shows "Select…" in secondary style. `vendorPickerLabel` is reused for menu item labels.

**Steps:**

1. Add `VendorMenuField` after `PlainTextField`:

```swift
/// Read-only TextField appearance with an overlay Menu for vendor selection.
/// Replaces native Picker for Target Vendor and Backup Vendor. Crystal ref: D-005.
private struct VendorMenuField: View {
    @Environment(ConfigStore.self) private var configStore
    let placeholder: String
    @Binding var selection: UUID?

    private var displayName: String {
        guard let id = selection,
              let vendor = configStore.config.vendors.first(where: { $0.id == id }) else {
            return placeholder
        }
        return vendor.name
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            Text(displayName)
                .foregroundStyle(selection == nil ? .secondary : .primary)
                .padding(.leading, 6)
                .padding(.trailing, menuOverlayWidth + 6)
                .lineLimit(1)
        }
        .frame(height: 22)
        .overlay(alignment: .trailing) {
            Menu {
                Button("Select…") { selection = nil }
                Divider()
                ForEach(configStore.config.vendors) { vendor in
                    Button(vendorPickerLabel(vendor: vendor, clients: configStore.config.clients)) {
                        selection = vendor.id
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: menuOverlayWidth)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(placeholder)
        }
    }
}
```

Note on the border/background: `.roundedBorder` TextField style on macOS 14 draws with `NSTextField`'s native appearance. `VendorMenuField` is a static display, not an actual TextField, so we replicate the visual appearance with `RoundedRectangle` stroke + fill. The corner radius 5 and stroke color match the system rounded border TextField on macOS 14 at default control size. If the visual does not match exactly on device, adjust `cornerRadius` and border color to match the adjacent `PlainTextField` — this is the one place where device verification is required (⚠️ Needs device verification: open Add Rule form and compare VendorMenuField border to adjacent PlainTextField border).

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` with no `error:` lines.

---

### Task 3: Rewrite `AddMappingRow` body

Crystal ref: [D-001] [D-004] [D-005] [D-006]

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:236-340`

**Context:**

`AddMappingRow` currently has:
- `@State private var menuWidth: CGFloat = 0` — remove this
- `SourceModelField(text:menuWidth:)` — replace with `OverlayMenuTextField(text:)`
- HStack with `Color.clear.frame(width: menuWidth)` wrapping the Target Model TextField — replace with `PlainTextField`
- `Picker` for Target Vendor and Backup Vendor — replace with `VendorMenuField`
- Standalone "Add Backup Target" / "Remove Backup" buttons inside the backup conditional block — remove from there
- Bottom HStack: `[Spacer] [Cancel] [Add]` — change to `[Add Backup Target or Remove Backup] [Spacer] [Cancel] [Add]`

All validation logic and closures (`onAdd`, `onCancel`) are unchanged.

**Steps:**

1. Remove `@State private var menuWidth: CGFloat = 0` from `AddMappingRow` state declarations (line 247).

2. Replace the entire `var body: some View` of `AddMappingRow` (lines 249-339) with:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        OverlayMenuTextField(text: $selectedSourceModel)

        PlainTextField(
            placeholder: "Target model (vendor model name)",
            text: $targetModel
        )

        VendorMenuField(placeholder: "Select target vendor…", selection: $selectedVendorID)
            .environment(configStore)

        if showBackupFields {
            Divider()
            Text("Backup Target")
                .font(.caption)
                .foregroundStyle(.secondary)
            PlainTextField(
                placeholder: "Backup model (vendor model name)",
                text: $backupTargetModel
            )
            VendorMenuField(placeholder: "Select backup vendor…", selection: $backupTargetVendorID)
                .environment(configStore)
        }

        HStack {
            if showBackupFields {
                Button("Remove Backup") {
                    showBackupFields = false
                    backupTargetModel = ""
                    backupTargetVendorID = nil
                }
                .buttonStyle(.mpDestructive)
                .controlSize(.small)
            } else {
                Button("Add Backup Target") {
                    showBackupFields = true
                }
                .buttonStyle(.mpInline)
                .controlSize(.small)
            }
            Spacer()
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
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` with no `error:` lines.

---

### Task 4: Rewrite `MappingRow` editing branch body

Crystal ref: [D-001] [D-004] [D-005] [D-006]

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:58-234`

**Context:**

`MappingRow` currently has:
- `@State private var menuWidth: CGFloat = 0` at line 71 — remove
- `SourceModelField(text:menuWidth:)` — replace with `OverlayMenuTextField(text:)`
- HStack with `Color.clear.frame(width: menuWidth)` for Target Model — replace with `PlainTextField`
- `Picker` for Target Vendor (line 87) and Backup Vendor (line 105) — replace with `VendorMenuField`
- Standalone "Remove Backup" button at line 112 and "Add Backup Target" at line 120 — remove from inline position
- Bottom HStack at line 127: `[Spacer] [Cancel] [Save]` — change to `[Add Backup Target or Remove Backup] [Spacer] [Cancel] [Save]`

All Save logic (lines 131-151) and the disabled condition are unchanged.

**Steps:**

1. Remove `@State private var menuWidth: CGFloat = 0` from `MappingRow` state declarations (line 71).

2. Replace only the `if isEditing { VStack(...) }` branch (lines 79-161). The `else` display branch (lines 162-233) is unchanged. New editing branch:

```swift
if isEditing {
    VStack(alignment: .leading, spacing: 8) {
        OverlayMenuTextField(text: $editSourceModel)

        PlainTextField(
            placeholder: "Target model (vendor model name)",
            text: $editTargetModel
        )

        VendorMenuField(placeholder: "Select target vendor…", selection: $editVendorID)
            .environment(configStore)

        if showBackupFields {
            Divider()
            Text("Backup Target")
                .font(.caption)
                .foregroundStyle(.secondary)
            PlainTextField(
                placeholder: "Backup model (vendor model name)",
                text: $editBackupTargetModel
            )
            VendorMenuField(placeholder: "Select backup vendor…", selection: $editBackupVendorID)
                .environment(configStore)
        }

        HStack {
            if showBackupFields {
                Button("Remove Backup") {
                    showBackupFields = false
                    editBackupTargetModel = ""
                    editBackupVendorID = nil
                }
                .buttonStyle(.mpDestructive)
                .controlSize(.small)
            } else {
                Button("Add Backup Target") {
                    showBackupFields = true
                }
                .buttonStyle(.mpInline)
                .controlSize(.small)
            }
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
}
```

**Verify:**
Run: `xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED` with no `error:` lines.

---

### Task 5: Remove dead code and final build check

Crystal ref: [D-007]

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift` — verify and remove any remaining dead code

**Steps:**

1. Confirm `MenuButtonWidthKey` is gone (it was removed in Task 1). Grep to verify:

```
rg "MenuButtonWidthKey" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/RoutingTabView.swift
```
Expected: no output (zero matches).

2. Confirm no `menuWidth` state or `Color.clear.frame(width:` remains:

```
rg "menuWidth|Color\.clear\.frame" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/RoutingTabView.swift
```
Expected: no output.

3. Confirm the original `SourceModelField` struct is gone (replaced by `OverlayMenuTextField`):

```
rg "struct SourceModelField" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/RoutingTabView.swift
```
Expected: no output.

4. Confirm all four vendor Picker sites are gone:

```
rg "Picker\(" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/RoutingTabView.swift
```
Expected: no output.

5. Confirm both bottom button rows have the backup button left of Cancel:

```
rg "Add Backup Target|Remove Backup" /Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/RoutingTabView.swift
```
Expected: 4 matches total — one "Add Backup Target" and one "Remove Backup" in `AddMappingRow`, one "Add Backup Target" and one "Remove Backup" in `MappingRow`, all within HStack blocks alongside Spacer/Cancel.

6. Full build:

```
xcodebuild -project /Users/norvyn/Code/Projects/ModelProxy/ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD"
```
Expected: `BUILD SUCCEEDED`, zero `error:` lines.

---

## Decisions

None.
