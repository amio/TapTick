import SwiftUI

// MARK: - immediateHelp

/// A tooltip that appears instantly on hover, with zero delay.
///
/// macOS's built-in `.help()` modifier uses a system-controlled delay (~1 s) that
/// cannot be overridden via SwiftUI. This modifier replaces it with an `onHover`
/// + floating overlay approach — no popover arrow, no focus stealing.
///
/// Usage:
/// ```swift
/// Button("Generate") { … }
///     .immediateHelp("Requires macOS 26")
/// ```
extension View {
    /// Displays `message` as a small tooltip the instant the cursor hovers over the view.
    /// Pass `nil` to disable.
    @ViewBuilder
    func immediateHelp(_ message: String?) -> some View {
        if let message {
            self.modifier(ImmediateHelpModifier(message: message))
        } else {
            self
        }
    }
}

/// Renders a compact label above the view using an `overlay` so there is no
/// popover arrow and no window/focus side-effects.
///
/// The tooltip floats **above** the button (negative y offset) so it is never
/// occluded by sibling views that come later in the layout hierarchy.
private struct ImmediateHelpModifier: ViewModifier {
    let message: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .overlay(alignment: .top) {
                if isHovering {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        // Float above the button so later siblings can't occlude it
                        .offset(y: -28)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeIn(duration: 0.1)))
                }
            }
    }
}
