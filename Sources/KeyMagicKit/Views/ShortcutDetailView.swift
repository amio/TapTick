import SwiftUI

/// Detail view for a selected shortcut showing full information.
struct ShortcutDetailView: View {
    let shortcut: Shortcut
    var onEdit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text(shortcut.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                        } icon: {
                            Image(systemName: shortcut.action.systemImage)
                                .font(.title2)
                                .foregroundStyle(.tint)
                        }

                        Text(shortcut.isEnabled ? "Active" : "Disabled")
                            .font(.subheadline)
                            .foregroundStyle(shortcut.isEnabled ? .green : .secondary)
                    }

                    Spacer()

                    // Key combo display
                    Text(shortcut.keyCombo.displayString)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.ultraThickMaterial)
                                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                        }
                }

                Divider()

                // Action details
                GroupBox("Action") {
                    VStack(alignment: .leading, spacing: 8) {
                        actionDetailContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // Metadata
                GroupBox("Info") {
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            Text("Created")
                                .foregroundStyle(.secondary)
                            Text(shortcut.createdAt, style: .date)
                        }
                        if let lastTriggered = shortcut.lastTriggeredAt {
                            GridRow {
                                Text("Last Triggered")
                                    .foregroundStyle(.secondary)
                                Text(lastTriggered, style: .relative)
                                    + Text(" ago")
                            }
                        }
                        GridRow {
                            Text("ID")
                                .foregroundStyle(.secondary)
                            Text(shortcut.id.uuidString)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Spacer()
            }
            .padding(24)
        }
        .toolbar {
            Button("Edit") {
                onEdit()
            }
        }
    }

    @ViewBuilder
    private var actionDetailContent: some View {
        switch shortcut.action {
        case .launchApp(let bundleID, let appName):
            HStack(spacing: 12) {
                AppIconView(bundleIdentifier: bundleID)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .fontWeight(.medium)
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

        case .runScript(let script, let shell):
            Label(shell.displayName, systemImage: "terminal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(script)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

        case .runScriptFile(let path, let shell):
            Label(shell.displayName, systemImage: "terminal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "doc.text")
            }
        }
    }
}
