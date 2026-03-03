import Carbon.HIToolbox
import Cocoa
import SwiftUI

/// A view that records a keyboard shortcut from the user.
///
/// Interaction model:
/// - Any key activity during recording is previewed in real time via `displayString`.
/// - A combo is only committed if it contains at least one primary modifier (⌘ ⌃ ⌥).
///   Invalid combos (e.g. bare "S") show their characters but recording continues.
/// - If the combo conflicts with an existing binding, an alert is shown and recording stops.
struct KeyRecorderView: View {
    @Binding var keyCombo: KeyCombo?
    var checkConflict: ((KeyCombo) -> Bool)?
    /// Called after a successful, non-conflicting record.
    var onRecord: ((KeyCombo) -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Current live preview text. nil = nothing pressed yet.
    @State private var previewText: String?
    @State private var conflictingCombo: KeyCombo?

    var body: some View {
        Button {
            if isRecording { stopRecording() } else { startRecording() }
        } label: {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    if let previewText {
                        Text(previewText)
                            .fontDesign(.monospaced)
                            .fontWeight(.medium)
                    } else {
                        Text("Press keys...")
                            .foregroundStyle(.secondary)
                    }
                } else if let keyCombo {
                    Text(keyCombo.displayString)
                        .fontDesign(.monospaced)
                        .fontWeight(.medium)
                } else {
                    Text("Record Shortcut")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .onDisappear { stopRecording() }
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

    private func startRecording() {
        isRecording = true
        previewText = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
            return nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifiers = KeyCombo.Modifiers(nsEventFlags: event.modifierFlags)

        if event.type == .flagsChanged {
            // Show held modifier symbols only — never render the modifier keyCode itself
            previewText = modifiers.isEmpty ? nil : modifiers.displayString
            return
        }

        // Escape with no modifiers cancels
        if keyCode == UInt32(kVK_Escape) && modifiers == [] {
            stopRecording()
            return
        }

        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)

        // Show the full combo as preview regardless of validity
        previewText = combo.displayString

        // Validity: require at least one primary modifier (⌘ ⌃ ⌥) to avoid shadowing global typing
        let primaryModifiers: KeyCombo.Modifiers = [.command, .control, .option]
        guard !modifiers.intersection(primaryModifiers).isEmpty else {
            // Invalid — keep recording so the user can try again
            return
        }

        if checkConflict?(combo) == true {
            conflictingCombo = combo
            stopRecording()
            return
        }

        keyCombo = combo
        onRecord?(combo)
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        previewText = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
