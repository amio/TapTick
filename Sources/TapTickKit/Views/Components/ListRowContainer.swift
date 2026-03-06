import SwiftUI

/// A shared table header used in ApplicationsView and ScriptsView.
/// Renders column labels with consistent caption styling and a tinted background.
struct ListTableHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var backgroundStyle: AnyShapeStyle = AnyShapeStyle(.quaternary.opacity(0.5))

    init(
        backgroundStyle: AnyShapeStyle = AnyShapeStyle(.quaternary.opacity(0.5)),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
        self.backgroundStyle = backgroundStyle
    }

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(backgroundStyle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A shared row container used in ApplicationsView and ScriptsView.
/// Provides zebra-stripe background, hover highlight, and consistent padding.
/// Pass `isOdd` from the enclosing ForEach index to alternate row tints.
struct ListRowContainer<Content: View>: View {
    /// Whether this is an odd-indexed row — drives the zebra stripe.
    var isOdd: Bool = false
    /// Optional accent tint applied beneath the hover/stripe layers (e.g. for bound-app rows).
    var accentBackground: Color = .clear
    /// Vertical padding inside the row. Defaults to 6; use 8 for rows with taller content.
    var verticalPadding: CGFloat = 6

    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        ZStack {
            // Persistent accent tint (e.g. for bound-app rows in ApplicationsView)
            accentBackground

            // Zebra stripe — odd rows get a very subtle tint
            if isOdd {
                Color.primary.opacity(0.03)
            }

            // Hover highlight — slightly stronger, appears on top of stripe
            if isHovered {
                Color.primary.opacity(0.05)
            }
        }
    }
}
