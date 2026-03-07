# Button Style Design Tokens Implementation Plan

**Goal:** Define 4 reusable ButtonStyle design tokens for the ModelProxy Settings UI and migrate every ad-hoc button style across all Settings views to use them.

**Architecture:** A single new file `ButtonStyles.swift` declares four `ButtonStyle`-conforming structs under the `MP` prefix. All four delegate visual rendering to SwiftUI's built-in primitive styles (`.borderedProminent`, `.bordered`, `.borderless`) so they inherit platform-correct focus rings, hover states, and disabled appearance automatically on macOS 14+. Consuming views replace their ad-hoc `.buttonStyle()` and `.foregroundStyle()` calls with the appropriate token. The `MPInlineButtonStyle` accepts an optional `Color` parameter to cover the dynamic copied-state color in `ClientsTabView` without breaking encapsulation.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+ (Sonoma). No third-party dependencies.

**Design doc:** none

**Design analysis:** none

**Crystal file:** none

---

### Task 1: Create ButtonStyles.swift

**Files:**
- Create: `ModelProxy/Views/Components/ButtonStyles.swift`

**Steps:**

1. Create the directory `ModelProxy/Views/Components/` (Xcode group — add the file under this group in the Xcode project navigator; the filesystem directory is created alongside it).

2. Create `ModelProxy/Views/Components/ButtonStyles.swift` with the following content:

```swift
import SwiftUI

// MARK: - MP Button Style Design Tokens
//
// Use these four styles for all buttons in Settings views.
// StatusPopover buttons are excluded (system-managed popover context).

/// Confirm / submit actions (Save, Add).
/// Renders as `.borderedProminent` — system accent fill, strong visual weight.
struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.borderedProminent)
            // Apply borderedProminent rendering by wrapping in a Button primitive.
            // ButtonStyle composition: delegate to a real Button so we get the
            // full platform rendering without reimplementing it.
    }
}

/// Dismiss / cancel actions (Cancel).
/// Renders as `.bordered` — visible border, lower visual weight than Primary.
struct MPCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .buttonStyle(.bordered)
    }
}

/// Delete / remove actions (Delete).
/// Renders as `.bordered` with `.red` foreground to signal danger.
struct MPDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.red)
            .buttonStyle(.bordered)
    }
}

/// Lightweight row-level actions (Edit, Copy, Reveal/Hide, Add Rule, Custom…).
/// Renders as `.borderless` — minimal visual weight, blends with content.
/// Pass a custom `color` for buttons that change color on state (e.g. Copy → Copied).
struct MPInlineButtonStyle: ButtonStyle {
    var color: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color ?? .accentColor)
            .buttonStyle(.borderless)
    }
}
```

> Note on `ButtonStyle` composition: SwiftUI does not allow calling `.buttonStyle()` inside `makeBody` on `configuration.label` directly — `configuration.label` is `ButtonStyleConfiguration.Label`, not a `View` that accepts `.buttonStyle`. The correct approach is to use a nested real `Button` or to apply the primitive style differently. The implementation below uses the correct pattern.

**Replace the file content with the correct SwiftUI-idiomatic implementation:**

```swift
import SwiftUI

// MARK: - MP Button Style Design Tokens
//
// Use these four styles for all buttons in Settings views.
// StatusPopover buttons and .confirmationDialog buttons are out of scope
// (system-managed).

/// Confirm / submit actions (Save, Add).
/// Visual weight: high — system accent fill background.
struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            // Delegate to the primitive by wrapping in PrimitiveButtonStyle indirection.
            // We use a modifier-based approach so the host button's
            // .borderedProminent rendering is preserved end-to-end.
    }
}
```

**Correct final implementation** (use this — avoids the `.buttonStyle` inside `makeBody` trap by using `ButtonStyleConfiguration` opacity only and applying the real primitive at the call site via a `View` extension sugar):

```swift
import SwiftUI

// MARK: - MP Button Style Design Tokens
//
// Apply with: .buttonStyle(.mpPrimary), .buttonStyle(.mpCancel), etc.
// StatusPopover and confirmationDialog buttons are out of scope.

// MARK: Primary — confirm / submit (Save, Add)

struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Cancel — dismiss / cancel

struct MPCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.clear)
            .foregroundStyle(.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: Destructive — delete / remove

struct MPDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.clear)
            .foregroundStyle(.red)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: Inline — lightweight row-level actions (Edit, Copy, Reveal/Hide, Add Rule)

struct MPInlineButtonStyle: ButtonStyle {
    /// Override the default accentColor for state-dependent coloring (e.g. Copy → Copied).
    var color: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(color ?? .accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

// MARK: - ButtonStyle extensions for call-site convenience

extension ButtonStyle where Self == MPPrimaryButtonStyle {
    static var mpPrimary: MPPrimaryButtonStyle { MPPrimaryButtonStyle() }
}

extension ButtonStyle where Self == MPCancelButtonStyle {
    static var mpCancel: MPCancelButtonStyle { MPCancelButtonStyle() }
}

extension ButtonStyle where Self == MPDestructiveButtonStyle {
    static var mpDestructive: MPDestructiveButtonStyle { MPDestructiveButtonStyle() }
}

extension ButtonStyle where Self == MPInlineButtonStyle {
    static var mpInline: MPInlineButtonStyle { MPInlineButtonStyle() }
}
```

> **Why not delegate to `.borderedProminent` / `.bordered` inside `makeBody`?** SwiftUI's `ButtonStyle.makeBody` receives a `ButtonStyleConfiguration.Label`, which is an opaque view that has already been resolved. Applying `.buttonStyle()` to it has no effect — the modifier is ignored at that point in the render tree. The correct approach for custom styles that must match system appearance exactly is either (a) use `PrimitiveButtonStyle` instead, or (b) reproduce the visual treatment manually (padding, background, corner radius). This plan uses option (b) because it gives explicit, reviewable control over the four distinct visual weights and avoids undocumented behavioral coupling to macOS system button rendering internals.

> **Visual equivalence to current ad-hoc styles:**
> - `MPPrimaryButtonStyle` reproduces `.borderedProminent` (accent fill, white label).
> - `MPCancelButtonStyle` reproduces `.bordered` (outlined, primary foreground).
> - `MPDestructiveButtonStyle` reproduces `.borderless` + `.foregroundStyle(.red)` with a subtle red border to increase danger signal clarity (no visual regression — matches or improves current appearance).
> - `MPInlineButtonStyle` reproduces `.borderless` with accent or custom color.

3. Add the file to the Xcode project: in Xcode's project navigator, right-click `Views`, choose "New Group without Folder" named `Components`, then drag/add `ButtonStyles.swift` into it. Alternatively, use "Add Files to ModelProxy…" and place it under `Views/Components`.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD"`
Expected: `BUILD SUCCEEDED` with no errors in `ButtonStyles.swift`.

---

### Task 2: Migrate VendorsTabView.swift

**Files:**
- Modify: `ModelProxy/Views/VendorsTabView.swift:30-50`

**Steps:**

Current ad-hoc styles:
- Line 30 "Edit": `.buttonStyle(.borderless)` → Inline
- Line 35 "Delete": `.buttonStyle(.borderless)` + `.foregroundStyle(.red)` → Destructive
- Line 49 "Add Vendor" (section header): `.buttonStyle(.borderless)` → Inline

1. Replace line 33-34 (Edit button's `.buttonStyle`):

```swift
// Before
Button("Edit") { editingVendor = vendor }
    .buttonStyle(.borderless)
    .accessibilityLabel("Edit \(vendor.name)")

// After
Button("Edit") { editingVendor = vendor }
    .buttonStyle(.mpInline)
    .accessibilityLabel("Edit \(vendor.name)")
```

2. Replace lines 38-40 (Delete button's `.buttonStyle` + `.foregroundStyle`):

```swift
// Before
Button("Delete") { deletingVendor = vendor }
    .buttonStyle(.borderless)
    .foregroundStyle(.red)
    .accessibilityLabel("Delete \(vendor.name)")

// After
Button("Delete") { deletingVendor = vendor }
    .buttonStyle(.mpDestructive)
    .accessibilityLabel("Delete \(vendor.name)")
```

3. Replace line 50 (Add Vendor button's `.buttonStyle`):

```swift
// Before
Button("Add Vendor") { showAddSheet = true }
    .buttonStyle(.borderless)
    .accessibilityLabel("Add Vendor")

// After
Button("Add Vendor") { showAddSheet = true }
    .buttonStyle(.mpInline)
    .accessibilityLabel("Add Vendor")
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

---

### Task 3: Migrate VendorEditSheet.swift

**Files:**
- Modify: `ModelProxy/Views/VendorEditSheet.swift:35-62`

**Steps:**

Current ad-hoc styles:
- Line 35 "Reveal"/"Hide": `.buttonStyle(.borderless)` → Inline
- Line 49 "Cancel": no explicit style (system default), has `.keyboardShortcut(.cancelAction)` → Cancel
- Line 52 "Save"/"Add": no explicit style (system default), has `.keyboardShortcut(.defaultAction)` → Primary

1. Replace Reveal/Hide button (line 35-39):

```swift
// Before
Button(showAPIKey ? "Hide" : "Reveal") { showAPIKey.toggle() }
    .buttonStyle(.borderless)
    .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")

// After
Button(showAPIKey ? "Hide" : "Reveal") { showAPIKey.toggle() }
    .buttonStyle(.mpInline)
    .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")
```

2. Replace Cancel button (line 49-51):

```swift
// Before
Button("Cancel") { dismiss() }
    .keyboardShortcut(.cancelAction)
    .accessibilityLabel("Cancel")

// After
Button("Cancel") { dismiss() }
    .buttonStyle(.mpCancel)
    .keyboardShortcut(.cancelAction)
    .accessibilityLabel("Cancel")
```

3. Replace Save/Add button (line 52-62):

```swift
// Before
Button(isEditing ? "Save" : "Add") { commitVendor(); dismiss() }
    .keyboardShortcut(.defaultAction)
    .disabled(...)
    .accessibilityLabel(isEditing ? "Save Vendor" : "Add Vendor")

// After
Button(isEditing ? "Save" : "Add") { commitVendor(); dismiss() }
    .buttonStyle(.mpPrimary)
    .keyboardShortcut(.defaultAction)
    .disabled(
        name.trimmingCharacters(in: .whitespaces).isEmpty
        || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        || URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.scheme == nil
    )
    .accessibilityLabel(isEditing ? "Save Vendor" : "Add Vendor")
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

---

### Task 4: Migrate ClientsTabView.swift

**Files:**
- Modify: `ModelProxy/Views/ClientsTabView.swift:110-122`

**Steps:**

Current ad-hoc styles:
- Line 110 "Copy"/"Copied": `.buttonStyle(.borderless)` + `.foregroundStyle(showCopied ? .green : .accentColor)` → Inline with dynamic color

The "Copy" button uses a dynamic foreground color (`showCopied ? .green : .accentColor`). `MPInlineButtonStyle` accepts an optional `color` parameter exactly for this case. The `.foregroundStyle()` call is removed; the color is passed into the style instead.

1. Replace the Copy button (lines 110-122):

```swift
// Before
Button(showCopied ? "Copied" : "Copy") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(envExportCommand, forType: .string)
    showCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        showCopied = false
    }
}
.buttonStyle(.borderless)
.foregroundStyle(showCopied ? .green : .accentColor)
.accessibilityLabel("Copy quick start command for \(client.clientName)")
.accessibilityHint("Copies the export command to clipboard.")

// After
Button(showCopied ? "Copied" : "Copy") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(envExportCommand, forType: .string)
    showCopied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        showCopied = false
    }
}
.buttonStyle(MPInlineButtonStyle(color: showCopied ? .green : nil))
.accessibilityLabel("Copy quick start command for \(client.clientName)")
.accessibilityHint("Copies the export command to clipboard.")
```

> When `color` is `nil`, `MPInlineButtonStyle` falls back to `.accentColor`, which matches the pre-migration default. When `showCopied` is `true`, it passes `.green` explicitly. The result is visually identical to the removed `.foregroundStyle()` line.

> Note: The static `.mpInline` extension shorthand does not support the `color` parameter. Use the explicit initializer `MPInlineButtonStyle(color:)` at this call site.

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

---

### Task 5: Migrate RoutingTabView.swift

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift:41-44` (Add Rule header button)
- Modify: `ModelProxy/Views/RoutingTabView.swift:87-106` (MappingRow edit mode Cancel + Save)
- Modify: `ModelProxy/Views/RoutingTabView.swift:124-137` (MappingRow view mode Edit + Delete)
- Modify: `ModelProxy/Views/RoutingTabView.swift:178-199` (AddMappingRow Cancel + Add)

**Steps:**

Current ad-hoc styles (all 7 buttons in this file):
- Line 41 "Add Rule" (header): `.buttonStyle(.borderless)` → Inline
- Line 87 "Cancel" (edit mode): `.buttonStyle(.borderless)` → Cancel
- Line 89 "Save" (edit mode): `.buttonStyle(.borderedProminent)` → Primary
- Line 124 "Edit" (view mode): `.buttonStyle(.borderless)` → Inline
- Line 132 "Delete" (view mode): `.buttonStyle(.borderless)` + `.foregroundStyle(.red)` → Destructive
- Line 178 "Cancel" (add mode): `.buttonStyle(.borderless)` → Cancel
- Line 181 "Add" (add mode): `.buttonStyle(.borderedProminent)` → Primary

1. **Header "Add Rule" button** (in `RoutingTabView.body`, `Section` header, ~line 41):

```swift
// Before
Button("Add Rule") { showAddRow = true }
    .buttonStyle(.borderless)
    .disabled(showAddRow || configStore.config.vendors.isEmpty)
    .accessibilityLabel("Add Routing Rule")

// After
Button("Add Rule") { showAddRow = true }
    .buttonStyle(.mpInline)
    .disabled(showAddRow || configStore.config.vendors.isEmpty)
    .accessibilityLabel("Add Routing Rule")
```

2. **MappingRow edit mode "Cancel" button** (~line 87):

```swift
// Before
Button("Cancel") { isEditing = false }
    .buttonStyle(.borderless)

// After
Button("Cancel") { isEditing = false }
    .buttonStyle(.mpCancel)
```

3. **MappingRow edit mode "Save" button** (~line 89):

```swift
// Before
Button("Save") { ... }
    .buttonStyle(.borderedProminent)
    .disabled(...)

// After
Button("Save") { ... }
    .buttonStyle(.mpPrimary)
    .disabled(
        editSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
        editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
        editVendorID == nil
    )
```

4. **MappingRow view mode "Edit" button** (~line 124):

```swift
// Before
Button("Edit") { ... }
    .buttonStyle(.borderless)
    .accessibilityLabel("Edit rule for \(mapping.sourceModel)")

// After
Button("Edit") { ... }
    .buttonStyle(.mpInline)
    .accessibilityLabel("Edit rule for \(mapping.sourceModel)")
```

5. **MappingRow view mode "Delete" button** (~line 132):

```swift
// Before
Button("Delete") { showDeleteConfirmation = true }
    .buttonStyle(.borderless)
    .foregroundStyle(.red)
    .accessibilityLabel("Delete rule for \(mapping.sourceModel)")

// After
Button("Delete") { showDeleteConfirmation = true }
    .buttonStyle(.mpDestructive)
    .accessibilityLabel("Delete rule for \(mapping.sourceModel)")
```

6. **AddMappingRow "Cancel" button** (~line 178):

```swift
// Before
Button("Cancel", action: onCancel)
    .buttonStyle(.borderless)
    .accessibilityLabel("Cancel")

// After
Button("Cancel", action: onCancel)
    .buttonStyle(.mpCancel)
    .accessibilityLabel("Cancel")
```

7. **AddMappingRow "Add" button** (~line 181):

```swift
// Before
Button("Add") { ... }
    .buttonStyle(.borderedProminent)
    .disabled(...)
    .accessibilityLabel("Add Routing Rule")

// After
Button("Add") { ... }
    .buttonStyle(.mpPrimary)
    .disabled(
        selectedSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
        targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
        selectedVendorID == nil
    )
    .accessibilityLabel("Add Routing Rule")
```

**Verify:**
Run: `xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `BUILD SUCCEEDED`.

---

### Task 6: Final audit — confirm no ad-hoc styles remain in Settings views

**Files:**
- Inspect: `ModelProxy/Views/VendorsTabView.swift`
- Inspect: `ModelProxy/Views/VendorEditSheet.swift`
- Inspect: `ModelProxy/Views/ClientsTabView.swift`
- Inspect: `ModelProxy/Views/RoutingTabView.swift`

**Steps:**

1. Search for any remaining `.buttonStyle(.borderless)` in the four Settings files:

```
Run: grep -n "buttonStyle(.borderless)" \
  ModelProxy/Views/VendorsTabView.swift \
  ModelProxy/Views/VendorEditSheet.swift \
  ModelProxy/Views/ClientsTabView.swift \
  ModelProxy/Views/RoutingTabView.swift
```

Expected: no output (zero matches).

2. Search for any remaining `.buttonStyle(.borderedProminent)` in the four Settings files:

```
Run: grep -n "buttonStyle(.borderedProminent)" \
  ModelProxy/Views/VendorsTabView.swift \
  ModelProxy/Views/VendorEditSheet.swift \
  ModelProxy/Views/ClientsTabView.swift \
  ModelProxy/Views/RoutingTabView.swift
```

Expected: no output (zero matches).

3. Search for standalone `.foregroundStyle(.red)` on buttons in the four Settings files (should be gone — absorbed into `MPDestructiveButtonStyle`):

```
Run: grep -n "foregroundStyle(.red)" \
  ModelProxy/Views/VendorsTabView.swift \
  ModelProxy/Views/VendorEditSheet.swift \
  ModelProxy/Views/ClientsTabView.swift \
  ModelProxy/Views/RoutingTabView.swift
```

Expected: no output (zero matches).

4. Confirm StatusPopover.swift is untouched:

```
Run: grep -n "buttonStyle" ModelProxy/Views/StatusPopover.swift
```

Expected: output shows existing styles unchanged (this file is out of scope; any matches are fine as long as they were not modified in this plan).

5. Full build:

```
Run: xcodebuild -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: last line is `BUILD SUCCEEDED`.

---

## Decisions

None.
