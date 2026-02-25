import SwiftUI

/// A single row in the shortcuts list.
struct ShortcutRow: View {
    let shortcut: Shortcut
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Action type icon
            Image(systemName: shortcut.action.systemImage)
                .font(.title3)
                .foregroundStyle(shortcut.isEnabled ? .primary : .tertiary)
                .frame(width: 28)

            // Name and description
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name)
                    .fontWeight(.medium)
                    .foregroundStyle(shortcut.isEnabled ? .primary : .secondary)

                Text(shortcut.action.displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Key combo badge
            Text(shortcut.keyCombo.displayString)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                )
                .foregroundStyle(shortcut.isEnabled ? .primary : .tertiary)

            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(shortcut.isEnabled ? 1.0 : 0.7)
    }
}
