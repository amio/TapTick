import Cocoa
import SwiftUI

/// Represents a discovered application on the system.
struct DiscoveredApp: Identifiable, Hashable {
    let id: String  // bundleIdentifier
    let name: String
    let path: String
    let icon: NSImage

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredApp, rhs: DiscoveredApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// The Applications settings view: lists all system apps with hotkey binding support.
struct ApplicationsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService

    @State private var discoveredApps: [DiscoveredApp] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var recordingAppID: String?

    /// All apps sorted: bound apps first, then alphabetical.
    private var sortedApps: [DiscoveredApp] {
        let filtered: [DiscoveredApp]
        if searchText.isEmpty {
            filtered = discoveredApps
        } else {
            filtered = discoveredApps.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
                    || $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }

        let boundIDs = Set(
            store.shortcuts.compactMap { shortcut -> String? in
                if case .launchApp(let bundleID, _) = shortcut.action {
                    return bundleID
                }
                return nil
            })

        return filtered.sorted { a, b in
            let aBound = boundIDs.contains(a.id)
            let bBound = boundIDs.contains(b.id)
            if aBound != bBound { return aBound }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Text("Applications")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(boundCount) bound")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Scanning applications...")
                Spacer()
            } else {
                // Table header
                AppTableHeader()

                Divider()

                // App list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedApps) { app in
                            AppRow(
                                app: app,
                                shortcut: shortcutFor(app: app),
                                isRecording: recordingAppID == app.id,
                                onStartRecording: {
                                    recordingAppID = app.id
                                },
                                onRecordKey: { combo in
                                    bindHotkey(combo, to: app)
                                    recordingAppID = nil
                                },
                                onCancelRecording: {
                                    recordingAppID = nil
                                },
                                onClearHotkey: {
                                    clearHotkey(for: app)
                                },
                                onToggleEnabled: {
                                    toggleEnabled(for: app)
                                }
                            )

                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadApps()
        }
    }

    // MARK: - Helpers

    private var boundCount: Int {
        store.shortcuts.filter { shortcut in
            if case .launchApp = shortcut.action { return true }
            return false
        }.count
    }

    private func shortcutFor(app: DiscoveredApp) -> Shortcut? {
        store.shortcuts.first { shortcut in
            if case .launchApp(let bundleID, _) = shortcut.action {
                return bundleID == app.id
            }
            return false
        }
    }

    private func bindHotkey(_ combo: KeyCombo, to app: DiscoveredApp) {
        if let existing = shortcutFor(app: app) {
            var updated = existing
            updated.keyCombo = combo
            store.update(updated)
        } else {
            let shortcut = Shortcut(
                name: app.name,
                keyCombo: combo,
                action: .launchApp(bundleIdentifier: app.id, appName: app.name),
                isEnabled: true
            )
            store.add(shortcut)
        }
        hotkeyService.restart(store: store)
    }

    private func clearHotkey(for app: DiscoveredApp) {
        if let existing = shortcutFor(app: app) {
            store.remove(id: existing.id)
            hotkeyService.restart(store: store)
        }
    }

    private func toggleEnabled(for app: DiscoveredApp) {
        if let existing = shortcutFor(app: app) {
            store.toggleEnabled(id: existing.id)
            hotkeyService.restart(store: store)
        }
    }

    @MainActor
    private func loadApps() async {
        isLoading = true
        let apps = await Task.detached {
            ApplicationsView.scanApplications()
        }.value
        discoveredApps = apps
        isLoading = false
    }

    // MARK: - App Discovery

    private nonisolated static func scanApplications() -> [DiscoveredApp] {
        var apps: [String: DiscoveredApp] = [:]

        let searchDirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]

        let fm = FileManager.default

        for dir in searchDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                let url = URL(fileURLWithPath: fullPath)
                guard let bundle = Bundle(url: url),
                    let bundleID = bundle.bundleIdentifier
                else { continue }

                // Skip duplicates (keep the first found)
                guard apps[bundleID] == nil else { continue }

                let name = url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: fullPath)

                apps[bundleID] = DiscoveredApp(
                    id: bundleID,
                    name: name,
                    path: fullPath,
                    icon: icon
                )
            }
        }

        return Array(apps.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Table Header

private struct AppTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Application")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Path")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Hotkey")
                .frame(width: 160, alignment: .leading)
            Text("Enabled")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }
}

// MARK: - App Row

private struct AppRow: View {
    let app: DiscoveredApp
    let shortcut: Shortcut?
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecordKey: (KeyCombo) -> Void
    let onCancelRecording: () -> Void
    let onClearHotkey: () -> Void
    let onToggleEnabled: () -> Void

    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            // App name + icon
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)

                Text(app.name)
                    .lineLimit(1)
                    .fontWeight(shortcut != nil ? .medium : .regular)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Path
            Text(app.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hotkey column
            hotkeyCell
                .frame(width: 160, alignment: .leading)

            // Enabled toggle
            enabledCell
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(shortcut != nil ? Color.accentColor.opacity(0.04) : Color.clear)
        .onDisappear {
            if isRecording {
                stopLocalMonitor()
                onCancelRecording()
            }
        }
    }

    // MARK: - Hotkey Cell

    @ViewBuilder
    private var hotkeyCell: some View {
        if isRecording {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("Press keys...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.red.opacity(0.5), lineWidth: 1)
            )
            .onAppear { startLocalMonitor() }
            .onDisappear { stopLocalMonitor() }
        } else if let shortcut {
            HStack(spacing: 4) {
                Text(shortcut.keyCombo.displayString)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                    )

                Button {
                    onStartRecording()
                } label: {
                    Image(systemName: "pencil.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    onClearHotkey()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } else {
            Button("Record Hotkey") {
                onStartRecording()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Enabled Cell

    @ViewBuilder
    private var enabledCell: some View {
        if shortcut != nil {
            Toggle("", isOn: Binding(
                get: { shortcut?.isEnabled ?? false },
                set: { _ in onToggleEnabled() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        } else {
            // No shortcut bound, show disabled placeholder
            Text("--")
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Key Recording (local monitor)

    private func startLocalMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                return nil
            }

            let keyCode = UInt32(event.keyCode)
            let modifiers = KeyCombo.Modifiers(
                cgEventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

            // Escape cancels recording
            if keyCode == UInt32(0x35) && modifiers == [] {
                stopLocalMonitor()
                onCancelRecording()
                return nil
            }

            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
            stopLocalMonitor()
            onRecordKey(combo)
            return nil
        }
    }

    private func stopLocalMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
