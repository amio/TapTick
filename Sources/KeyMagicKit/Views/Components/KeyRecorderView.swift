import Carbon.HIToolbox
import Cocoa
import SwiftUI

/// A view that records a keyboard shortcut from the user.
/// When active, it captures the next key combo pressed and reports it.
struct KeyRecorderView: View {
    @Binding var keyCombo: KeyCombo?
    var onRecord: ((KeyCombo) -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    Text("Press keys...")
                        .foregroundStyle(.secondary)
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
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // Use local key monitor to capture keys
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Ignore modifier-only events (flagsChanged) unless it's just modifiers
            if event.type == .flagsChanged {
                return nil // Consume but don't record yet
            }

            let keyCode = UInt32(event.keyCode)
            let modifiers = KeyCombo.Modifiers(cgEventFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))

            // Escape cancels recording
            if keyCode == UInt32(kVK_Escape) && modifiers == [] {
                stopRecording()
                return nil
            }

            let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
            self.keyCombo = combo
            onRecord?(combo)
            stopRecording()
            return nil // Consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
