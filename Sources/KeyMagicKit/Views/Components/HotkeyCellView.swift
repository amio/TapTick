import Carbon.HIToolbox
import Cocoa
import SwiftUI

/// A reusable hotkey table-cell that supports recording, displaying, editing, and deleting a key combo.
///
/// Three visual states:
/// 1. **Empty** – shows a "Record Hotkey" button.
/// 2. **Recording** – pulsing red indicator with live preview text; Escape cancels.
/// 3. **Bound** – displays the key combo badge (clickable to re-bind) plus a delete button.
///
/// Interaction rules:
/// - Any key activity is previewed in real time. Invalid combos (no primary modifier)
///   show their characters but recording continues; only valid combos are committed.
/// - A conflict alert is shown if `checkConflict` returns `true`; recording then stops.
///
/// The parent owns the "which item is recording" state and drives `isRecording` from outside,
/// so that only one cell can record at a time across the entire list.
struct HotkeyCellView: View {
    let keyCombo: KeyCombo?
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecordKey: (KeyCombo) -> Void
    let onCancelRecording: () -> Void
    let onClearHotkey: () -> Void
    var checkConflict: ((KeyCombo) -> Bool)?

    @State private var monitor: Any?
    /// Live preview text shown while recording. nil = nothing pressed yet.
    @State private var previewText: String?
    @State private var conflictingCombo: KeyCombo?

    var body: some View {
        Group {
            if isRecording {
                recordingContent
            } else if let keyCombo {
                boundContent(keyCombo)
            } else {
                emptyContent
            }
        }
        .onDisappear {
            if isRecording {
                stopLocalMonitor()
                onCancelRecording()
            }
        }
        .alert(
            "Shortcut Conflict",
            isPresented: Binding(get: { conflictingCombo != nil }, set: { if !$0 { conflictingCombo = nil } })
        ) {
            Button("OK") { conflictingCombo = nil }
        } message: {
            if let combo = conflictingCombo {
                Text("\(combo.displayString) is already bound to another shortcut.")
            }
        }
    }

    // MARK: - Recording State

    private var recordingContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            if let previewText {
                Text(previewText)
                    .font(.body)
                    // .fontDesign(.monospaced)
                    .fontWeight(.medium)
                    .tracking(1)
            } else {
                Text("Press keys...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(width: 97, height: 20, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.red.opacity(0.5), lineWidth: 1)
        )
        .onAppear { startLocalMonitor() }
        .onDisappear { stopLocalMonitor() }
    }

    // MARK: - Bound State

    private func boundContent(_ combo: KeyCombo) -> some View {
        HStack(spacing: 4) {
            Button {
                onStartRecording()
            } label: {
                Text(combo.displayString)
                    .tracking(1.5)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Click to re-bind hotkey")

            Button {
                onClearHotkey()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove hotkey")
        }
    }

    // MARK: - Empty State

    private var emptyContent: some View {
        Button("Record Hotkey") {
            onStartRecording()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Key Recording (local monitor)

    private func startLocalMonitor() {
        previewText = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handleEvent(event)
            return nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifiers = KeyCombo.Modifiers(nsEventFlags: event.modifierFlags)

        if event.type == .flagsChanged {
            previewText = modifiers.isEmpty ? nil : modifiers.displayString
            return
        }

        // On key-up: clear preview if the released key left no valid combo
        if event.type == .keyUp {
            let primaryModifiers: KeyCombo.Modifiers = [.command, .control, .option]
            if modifiers.intersection(primaryModifiers).isEmpty {
                previewText = modifiers.isEmpty ? nil : modifiers.displayString
            }
            return
        }

        // keyDown from here
        if keyCode == UInt32(kVK_Escape) && modifiers == [] {
            stopLocalMonitor()
            onCancelRecording()
            return
        }

        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        previewText = combo.displayString

        let primaryModifiers: KeyCombo.Modifiers = [.command, .control, .option]
        guard !modifiers.intersection(primaryModifiers).isEmpty else {
            // Invalid — show the preview; keyUp will clear it once the key is released
            return
        }

        if checkConflict?(combo) == true {
            conflictingCombo = combo
            stopLocalMonitor()
            onCancelRecording()
            return
        }

        stopLocalMonitor()
        onRecordKey(combo)
    }

    private func stopLocalMonitor() {
        previewText = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
