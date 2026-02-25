import SwiftUI

/// The main settings view with tabbed navigation: Shortcuts and General.
public struct SettingsView: View {
    public init() {}

    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService
    @Environment(LoginItemManager.self) private var loginItemManager

    enum Tab: Hashable {
        case shortcuts
        case general
    }

    @State private var selectedTab: Tab = .shortcuts

    public var body: some View {
        TabView(selection: $selectedTab) {
            ShortcutsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(Tab.shortcuts)

            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(Tab.general)
        }
        .onAppear {
            hotkeyService.start(store: store)
        }
    }
}

/// The shortcuts list view: a NavigationSplitView with sidebar + detail.
struct ShortcutsView: View {
    @Environment(ShortcutStore.self) private var store
    @Environment(HotkeyService.self) private var hotkeyService

    @State private var selectedShortcutID: UUID?
    @State private var showingAddSheet = false
    @State private var editingShortcut: Shortcut?
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""

    private var filteredShortcuts: [Shortcut] {
        if searchText.isEmpty {
            return store.shortcuts
        }
        return store.shortcuts.filter { shortcut in
            shortcut.name.localizedCaseInsensitiveContains(searchText) ||
            shortcut.keyCombo.displayString.localizedCaseInsensitiveContains(searchText) ||
            shortcut.action.displayDescription.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search shortcuts")
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                ShortcutEditView()
                    .environment(store)
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            NavigationStack {
                ShortcutEditView(editingShortcut: shortcut)
                    .environment(store)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selectedShortcutID) {
            Section {
                ForEach(filteredShortcuts) { shortcut in
                    ShortcutRow(shortcut: shortcut) {
                        store.toggleEnabled(id: shortcut.id)
                        hotkeyService.restart(store: store)
                    }
                    .tag(shortcut.id)
                    .contextMenu {
                        Button("Edit") {
                            editingShortcut = shortcut
                        }
                        Button("Duplicate") {
                            duplicateShortcut(shortcut)
                        }
                        Divider()
                        Button(shortcut.isEnabled ? "Disable" : "Enable") {
                            store.toggleEnabled(id: shortcut.id)
                            hotkeyService.restart(store: store)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            selectedShortcutID = shortcut.id
                            showingDeleteConfirmation = true
                        }
                    }
                }
                .onDelete { offsets in
                    store.remove(atOffsets: offsets)
                    hotkeyService.restart(store: store)
                }
            } header: {
                HStack {
                    Text("Shortcuts")
                        .font(.headline)
                    Spacer()
                    Text("\(store.shortcuts.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "Delete Shortcut?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = selectedShortcutID {
                    store.remove(id: id)
                    hotkeyService.restart(store: store)
                    selectedShortcutID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedShortcutID,
           let shortcut = store.shortcuts.first(where: { $0.id == id }) {
            ShortcutDetailView(shortcut: shortcut) {
                editingShortcut = shortcut
            }
        } else {
            ContentUnavailableView {
                Label("No Shortcut Selected", systemImage: "keyboard")
            } description: {
                Text("Select a shortcut from the sidebar or create a new one.")
            } actions: {
                Button("Add Shortcut") {
                    showingAddSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func duplicateShortcut(_ shortcut: Shortcut) {
        var copy = shortcut
        copy = Shortcut(
            name: "\(shortcut.name) (Copy)",
            keyCombo: shortcut.keyCombo,
            action: shortcut.action,
            isEnabled: false // Disable to avoid conflict
        )
        store.add(copy)
    }
}
