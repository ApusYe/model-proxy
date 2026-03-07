import SwiftUI

// MARK: - MP Button Style Design Tokens
//
// Apply with: .buttonStyle(.mpPrimary), .buttonStyle(.mpCancel), etc.
// StatusPopover and confirmationDialog buttons are out of scope.

// MARK: Primary — confirm / submit (Save, Add)

struct MPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MPButtonBody(isPressed: configuration.isPressed) {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: Cancel — dismiss / cancel

struct MPCancelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MPButtonBody(isPressed: configuration.isPressed) {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.clear)
                .foregroundStyle(.primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                )
        }
    }
}

// MARK: Destructive — delete / remove

struct MPDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MPButtonBody(isPressed: configuration.isPressed) {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.clear)
                .foregroundStyle(.red)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

// MARK: Inline — lightweight row-level actions (Edit, Copy, Reveal/Hide, Add Rule)

struct MPInlineButtonStyle: ButtonStyle {
    /// Override the default accentColor for state-dependent coloring (e.g. Copy -> Copied).
    var color: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        MPButtonBody(isPressed: configuration.isPressed) {
            configuration.label
                .foregroundStyle(color ?? .accentColor)
        }
    }
}

// MARK: - Disabled + Pressed State Helper

/// Reads `\.isEnabled` from the environment (not accessible inside `makeBody` directly)
/// and applies consistent disabled/pressed opacity across all MP button styles.
private struct MPButtonBody<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let isPressed: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .opacity(isEnabled ? (isPressed ? 0.7 : 1.0) : 0.4)
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
