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
///
/// Apps synced from other devices that are not installed locally appear in a separate
/// "Unavailable on This Mac" section so users understand why a shortcut won't fire.
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

    /// App shortcuts synced from other devices whose bundle ID isn't installed locally.
    private var unavailableAppShortcuts: [Shortcut] {
        let localBundleIDs = Set(discoveredApps.map(\.id))
        let query = searchText.lowercased()

        return store.shortcuts.filter { shortcut in
            guard case .launchApp(let bundleID, let appName) = shortcut.action else { return false }
            guard !localBundleIDs.contains(bundleID) else { return false }
            if query.isEmpty { return true }
            return appName.localizedCaseInsensitiveContains(query)
                || bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Scanning applications...")
                Spacer()
            } else {
                // Table header
                AppTableHeader()

                // App list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sortedApps.enumerated()), id: \.element.id) { index, app in
                            AppRow(
                                app: app,
                                shortcut: shortcutFor(app: app),
                                isOdd: index.isMultiple(of: 2) == false,
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
                        }

                        // Synced apps not installed on this Mac
                        if !unavailableAppShortcuts.isEmpty {
                            UnavailableAppsSection(
                                shortcuts: unavailableAppShortcuts,
                                baseIndex: sortedApps.count,
                                onRemove: { id in
                                    store.remove(id: id)
                                    hotkeyService.restart(store: store)
                                }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Applications")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .task {
            await loadApps()
        }
    }

    // MARK: - Helpers

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
        ListTableHeader {
            Text("Application")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Path")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Hotkey")
                .frame(width: 120, alignment: .leading)
            Text("Enabled")
                .frame(width: 70, alignment: .trailing)
        }
    }
}

// MARK: - App Row

private struct AppRow: View {
    let app: DiscoveredApp
    let shortcut: Shortcut?
    let isOdd: Bool
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecordKey: (KeyCombo) -> Void
    let onCancelRecording: () -> Void
    let onClearHotkey: () -> Void
    let onToggleEnabled: () -> Void

    var body: some View {
        ListRowContainer(
            isOdd: isOdd,
            accentBackground: shortcut != nil ? Color.accentColor.opacity(0.04) : .clear
        ) {
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
            HotkeyCellView(
                keyCombo: shortcut?.keyCombo,
                isRecording: isRecording,
                onStartRecording: onStartRecording,
                onRecordKey: onRecordKey,
                onCancelRecording: onCancelRecording,
                onClearHotkey: onClearHotkey
            )
            .frame(width: 120, alignment: .leading)

            // Enabled toggle
            enabledCell
                .frame(width: 70, alignment: .trailing)
        }
        // Tapping anywhere on the row toggles enabled; only active when a shortcut exists.
        // Child controls (Toggle, HotkeyCellView buttons) intercept their own gestures first.
        .onTapGesture {
            guard shortcut != nil else { return }
            onToggleEnabled()
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
}

// MARK: - Unavailable Apps Section

/// Shows app shortcuts synced from other devices where the app is not installed locally.
private struct UnavailableAppsSection: View {
    let shortcuts: [Shortcut]
    let baseIndex: Int
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Not Installed on This Mac")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Synced from another device")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.06))

            ForEach(Array(shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                UnavailableAppRow(
                    shortcut: shortcut,
                    isOdd: (baseIndex + index).isMultiple(of: 2) == false,
                    onRemove: { onRemove(shortcut.id) }
                )
            }
        }
    }
}

/// A row for an app shortcut whose target app isn't installed on this Mac.
private struct UnavailableAppRow: View {
    let shortcut: Shortcut
    let isOdd: Bool
    let onRemove: () -> Void

    private var appName: String {
        if case .launchApp(_, let name) = shortcut.action { return name }
        return shortcut.name
    }

    private var bundleID: String {
        if case .launchApp(let id, _) = shortcut.action { return id }
        return ""
    }

    var body: some View {
        ListRowContainer(
            isOdd: isOdd,
            accentBackground: Color.orange.opacity(0.04),
            verticalPadding: 8
        ) {
            // App name with warning icon
            HStack(spacing: 10) {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .lineLimit(1)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Hotkey display (read-only)
            Text(shortcut.keyCombo?.displayString ?? "--")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Hotkey badge placeholder
            Text("Unavailable")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(width: 120, alignment: .leading)

            // Remove button
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this synced shortcut")
            .frame(width: 70, alignment: .trailing)
        }
        .opacity(0.7)
    }
}
