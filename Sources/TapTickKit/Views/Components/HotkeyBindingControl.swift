import Carbon.HIToolbox
import Cocoa
import SwiftUI

/// A compact hotkey binding control shared by list cells and settings forms.
///
/// The parent owns the persisted value and decides whether recording is active,
/// which keeps the interaction reusable in both single-item forms and multi-row lists.
struct HotkeyBindingControl: View {
    @Environment(HotkeyService.self) private var hotkeyService

    let keyCombo: KeyCombo?
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecordKey: (KeyCombo) -> Void
    let onCancelRecording: () -> Void
    var onClearHotkey: (() -> Void)? = nil
    var checkConflict: ((KeyCombo) -> Bool)?
    var emptyTitle = "Record Hotkey"
    var usesEmphasizedAppearance = false

    @State private var monitor: Any?
    @State private var recordingWindow: NSWindow?
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
        .frame(height: 22)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === recordingWindow else { return }
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelRecording()
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
                .foregroundStyle(recordingIndicatorColor)
                .symbolEffect(.pulse)
            if let previewText {
                Text(previewText)
                    .font(.body)
                    .fontWeight(.medium)
                    .tracking(1)
                    .foregroundStyle(usesEmphasizedAppearance ? Color.white : Color.primary)
            } else {
                Text("Press keys...")
                    .font(.caption)
                    .foregroundStyle(
                        usesEmphasizedAppearance ? Color.white.opacity(0.85) : Color.secondary
                    )
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .frame(width: 87, height: 20, alignment: .leading)
        .background(recordingBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(recordingBorder, lineWidth: 1)
        )
        .onAppear { startLocalMonitor() }
        .onDisappear { stopLocalMonitor() }
    }

    // MARK: - Bound State

    private func boundContent(_ combo: KeyCombo) -> some View {
        HStack(spacing: 4) {
            hotkeyButton(action: onStartRecording) {
                Text(combo.displayString)
                    .tracking(1.5)
            }
            .controlSize(.small)
            .help("Click to re-bind hotkey")

            if let onClearHotkey {
                Button {
                    onClearHotkey()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    usesEmphasizedAppearance ? Color.white.opacity(0.9) : Color.secondary
                )
                .help("Remove hotkey")
            }
        }
    }

    // MARK: - Empty State

    private var emptyContent: some View {
        hotkeyButton(action: onStartRecording) {
            Text(emptyTitle)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func hotkeyButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) -> some View {
        if usesEmphasizedAppearance {
            Button(action: action, label: label)
                .buttonStyle(EmphasizedHotkeyButtonStyle())
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
        }
    }

    private var recordingBackground: Color {
        usesEmphasizedAppearance ? .white.opacity(0.16) : .clear
    }

    private var recordingBorder: Color {
        usesEmphasizedAppearance ? .white.opacity(0.4) : .red.opacity(0.5)
    }

    private var recordingIndicatorColor: Color {
        usesEmphasizedAppearance ? .white.opacity(0.9) : .red.opacity(0.7)
    }

    // MARK: - Key Recording

    private func startLocalMonitor() {
        guard monitor == nil else { return }
        guard NSApp.isActive, let window = NSApp.keyWindow else {
            onCancelRecording()
            return
        }
        recordingWindow = window
        previewText = nil
        hotkeyService.suspendRegistrations()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard monitor != nil else { return event }
            guard NSApp.isActive, recordingWindow?.isKeyWindow == true,
                event.window === recordingWindow
            else {
                cancelRecording()
                return event
            }
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

        if event.type == .keyUp {
            let primaryModifiers: KeyCombo.Modifiers = [.command, .control, .option]
            if modifiers.intersection(primaryModifiers).isEmpty {
                previewText = modifiers.isEmpty ? nil : modifiers.displayString
            }
            return
        }

        if keyCode == UInt32(kVK_Escape) && modifiers == [] {
            stopLocalMonitor()
            onCancelRecording()
            return
        }

        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        previewText = combo.displayString

        let primaryModifiers: KeyCombo.Modifiers = [.command, .control, .option]
        guard !modifiers.intersection(primaryModifiers).isEmpty else { return }

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
        let hadMonitor = monitor != nil
        previewText = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindow = nil
        if hadMonitor {
            hotkeyService.resumeRegistrations()
        }
    }

    private func cancelRecording() {
        guard monitor != nil else { return }
        stopLocalMonitor()
        onCancelRecording()
    }
}

/// Keeps compact Hotkey actions legible without competing with the active selection fill.
private struct EmphasizedHotkeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(
                .white.opacity(configuration.isPressed ? 0.28 : 0.18),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
