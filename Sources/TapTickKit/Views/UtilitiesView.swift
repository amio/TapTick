import SwiftUI

struct UtilitiesDirectoryView: View {
    @Environment(UtilitiesController.self) private var utilities

    @Binding var selection: UtilityID
    @FocusState private var isUtilityListFocused: Bool

    var body: some View {
        List(utilities.catalog, selection: $selection) { feature in
            UtilityRow(
                feature: feature,
                isSelected: selection == feature.id
            )
            .tag(feature.id)
        }
        .listStyle(.inset)
        .focused($isUtilityListFocused)
        .onChange(of: selection) { _, featureID in
            restoreUtilityListFocus(afterSelecting: featureID)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsToolbarTitle(title: "Utilities")
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)
        }
    }

    /// Replacing the detail can interrupt AppKit's first-responder handoff from the click.
    /// Restore it after the selection transaction so the list keeps native focused selection.
    private func restoreUtilityListFocus(afterSelecting featureID: UtilityID) {
        Task { @MainActor in
            await Task.yield()
            guard selection == featureID, !isUtilityListFocused else { return }
            isUtilityListFocused = true
        }
    }
}

struct UtilityDetailView: View {
    @Environment(UtilitiesController.self) private var utilities

    let selectedFeatureID: UtilityID

    @State private var isRecordingKeystrokeOverlayHotkey = false
    @State private var isRecordingScreenshotMarkHotkey = false
    @State private var isRecordingLargeTypeHotkey = false

    var body: some View {
        featureDetail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SettingsToolbarItemLayout {
                        Label(selectedFeature.title, systemImage: selectedFeature.systemImage)
                            .font(.headline)
                            .labelStyle(.titleAndIcon)
                            .padding(.leading, SettingsLayout.toolbarTitleLeadingPadding)
                    }
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.flexible)

                ToolbarItem(placement: .automatic) {
                    UtilityDetailHeaderControl(
                        feature: selectedFeature,
                        isEnabled: enabledBinding
                    )
                }
                .sharedBackgroundVisibility(.hidden)
            }
    }

    private var selectedFeature: UtilityDescriptor {
        utilities.descriptor(for: selectedFeatureID)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: {
                switch selectedFeature.id {
                case .keystrokeOverlay:
                    utilities.keystrokeOverlay.isEnabled
                case .screenshotTools:
                    utilities.screenshotTools.isEnabled
                case .largeType:
                    utilities.largeType.isEnabled
                case .windowManager:
                    false
                }
            },
            set: { isEnabled in
                switch selectedFeature.id {
                case .keystrokeOverlay:
                    utilities.setKeystrokeOverlayEnabled(isEnabled)
                case .screenshotTools:
                    utilities.setScreenshotToolsEnabled(isEnabled)
                case .largeType:
                    utilities.setLargeTypeEnabled(isEnabled)
                case .windowManager:
                    break
                }
            }
        )
    }

    @ViewBuilder
    private var featureDetail: some View {
        switch selectedFeature.id {
        case .keystrokeOverlay:
            KeystrokeOverlaySettingsPane(
                isRecordingHotkey: $isRecordingKeystrokeOverlayHotkey
            )
        case .screenshotTools:
            ScreenshotToolsSettingsPane(
                isRecordingMarkHotkey: $isRecordingScreenshotMarkHotkey
            )
        case .largeType:
            LargeTypeSettingsPane(
                isRecordingHotkey: $isRecordingLargeTypeHotkey
            )
        case .windowManager:
            PlannedUtilityPane(feature: selectedFeature)
        }
    }
}

private struct UtilityDetailHeaderControl: View {
    let feature: UtilityDescriptor
    @Binding var isEnabled: Bool

    @ViewBuilder
    var body: some View {
        switch feature.availability {
        case .available:
            Toggle("Enable \(feature.title)", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        case .planned:
            StatusPill(title: "Planned", color: .secondary)
        }
    }
}

private struct UtilityRow: View {
    @Environment(UtilitiesController.self) private var utilities

    let feature: UtilityDescriptor
    let isSelected: Bool

    private let iconColumnWidth: CGFloat = 22

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow(alignment: .center) {
                utilityIcon
                titleRow
            }

            GridRow {
                Color.clear
                    .frame(width: iconColumnWidth, height: 1)
                summaryRow
            }
        }
        .padding(.vertical, 4)
    }

    private var utilityIcon: some View {
        Image(systemName: feature.systemImage)
            .font(.system(size: feature.directoryIconPointSize, weight: .regular))
            .foregroundStyle(iconColor)
            .frame(width: iconColumnWidth)
    }

    private var iconColor: Color {
        if isSelected {
            return .primary
        }

        return feature.availability == .available ? .accentColor : .secondary
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(feature.title)
                .font(.headline)

            featureStatusPill
        }
    }

    @ViewBuilder
    private var featureStatusPill: some View {
        switch feature.availability {
        case .planned:
            StatusPill(title: "Planned", color: .secondary)
        case .available:
            StatusPill(
                title: isFeatureActive ? "Active" : "Off",
                color: isFeatureActive ? .green : .secondary
            )
        }
    }

    private var isFeatureActive: Bool {
        switch feature.id {
        case .keystrokeOverlay:
            utilities.keystrokeOverlay.isEnabled
        case .screenshotTools:
            utilities.screenshotTools.isEnabled
        case .largeType:
            utilities.largeType.isEnabled
        case .windowManager:
            false
        }
    }

    private var summaryRow: some View {
        Text(feature.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct KeystrokeOverlaySettingsPane: View {
    @Environment(UtilitiesController.self) private var utilities
    @Environment(HotkeyService.self) private var hotkeyService

    @Binding var isRecordingHotkey: Bool

    var body: some View {
        ScrollView {
            Form {
                controlSection
                appearanceSection
                previewSection
                positionSection
                timingSection
            }
            .settingsFormStyle()
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: utilities.keystrokeOverlay.fontSize) {
                refreshLivePreview()
            }
            .onChange(of: utilities.keystrokeOverlay.foregroundColor) {
                refreshLivePreview()
            }
            .onChange(of: utilities.keystrokeOverlay.backgroundColor) {
                refreshLivePreview()
            }
            .onChange(of: utilities.keystrokeOverlay.verticalPosition) {
                refreshLivePreview()
            }
            .onChange(of: utilities.keystrokeOverlay.holdDuration) {
                refreshLivePreview()
            }
            .onChange(of: utilities.keystrokeOverlay.fadeOutDuration) {
                refreshLivePreview()
            }
        }
    }

    private var controlSection: some View {
        Section {
            if utilities.keystrokeOverlayPermission != .granted {
                permissionAccessRow
            }

            LabeledContent("Toggle Hotkey") {
                HStack(spacing: 8) {
                    HotkeyBindingControl(
                        keyCombo: utilities.keystrokeOverlay.hotkey,
                        isRecording: isRecordingHotkey,
                        onStartRecording: {
                            isRecordingHotkey = true
                        },
                        onRecordKey: { combo in
                            utilities.updateKeystrokeOverlayHotkey(combo)
                            isRecordingHotkey = false
                        },
                        onCancelRecording: {
                            isRecordingHotkey = false
                        },
                        checkConflict: { combo in
                            hotkeyService.hasConflict(
                                keyCombo: combo,
                                excludingUtilityID: .keystrokeOverlay
                            )
                        },
                        emptyTitle: "Record Hotkey"
                    )

                    Button("Default") {
                        utilities.restoreDefaultKeystrokeOverlayHotkey()
                    }
                    .controlSize(.small)
                    .disabled(
                        utilities.keystrokeOverlay.hotkey == KeystrokeOverlayConfiguration.defaultHotkey
                    )
                }
            }
        }
    }

    private var permissionAccessRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                grantInputMonitoringButton
                permissionRecoveryText
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                grantInputMonitoringButton
                permissionRecoveryText
            }
        }
    }

    private var grantInputMonitoringButton: some View {
        Button("Grant Input Monitoring Access") {
            utilities.requestKeystrokeOverlayPermission()
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var permissionRecoveryText: some View {
        Text("If previously denied, re-enable in System Settings › Privacy & Security › Input Monitoring.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Preview")
                    .font(.subheadline.weight(.semibold))

                HStack {
                    Spacer(minLength: 0)

                    Text(utilities.keystrokeOverlay.hotkey.displayString)
                        .font(
                            .system(
                                size: utilities.keystrokeOverlay.fontSize,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .tracking(max(0.8, utilities.keystrokeOverlay.fontSize * 0.025))
                        .foregroundStyle(utilities.keystrokeOverlay.foregroundColor.color)
                        .lineLimit(1)
                        .padding(.horizontal, max(18, utilities.keystrokeOverlay.fontSize * 0.48))
                        .padding(.vertical, max(12, utilities.keystrokeOverlay.fontSize * 0.28))
                        .background {
                            RoundedRectangle(
                                cornerRadius: max(18, utilities.keystrokeOverlay.fontSize * 0.42),
                                style: .continuous
                            )
                            .fill(utilities.keystrokeOverlay.backgroundColor.color)
                        }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.06))
                )
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            LabeledContent("Font Size") {
                HStack(spacing: 12) {
                    Slider(value: fontSizeBinding.stepped(by: 1), in: 18...72)
                        .frame(width: 200)
                    Text("\(Int(utilities.keystrokeOverlay.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            LabeledContent("Foreground Color") {
                ColorPicker("", selection: foregroundColorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .frame(height: 16)
            }

            LabeledContent("Background Color") {
                ColorPicker("", selection: backgroundColorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .frame(height: 16)
            }
        } header: {
            Text("Appearance")
        }
    }

    private var positionSection: some View {
        Section {
            LabeledContent("Vertical Position") {
                HStack(spacing: 12) {
                    Slider(value: verticalPositionBinding.stepped(by: 0.01), in: 0...1)
                        .frame(width: 200)
                    Text("\(Int(utilities.keystrokeOverlay.verticalPosition * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        } header: {
            Text("Position")
        }
    }

    private var timingSection: some View {
        Section {
            LabeledContent("Visible Time") {
                HStack(spacing: 12) {
                    Slider(value: holdDurationBinding.stepped(by: 0.1), in: 0.4...4)
                        .frame(width: 200)
                    Text(
                        "\(utilities.keystrokeOverlay.holdDuration.formatted(.number.precision(.fractionLength(2)))) s"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
                }
            }

            LabeledContent("Fade Out") {
                HStack(spacing: 12) {
                    Slider(value: fadeOutDurationBinding.stepped(by: 0.05), in: 0.1...1.4)
                        .frame(width: 200)
                    Text(
                        "\(utilities.keystrokeOverlay.fadeOutDuration.formatted(.number.precision(.fractionLength(2)))) s"
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
                }
            }
        } header: {
            Text("Timing")
        }
    }

    private var verticalPositionBinding: Binding<Double> {
        Binding(
            get: { utilities.keystrokeOverlay.verticalPosition },
            set: { utilities.keystrokeOverlay.verticalPosition = $0 }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { utilities.keystrokeOverlay.fontSize },
            set: { utilities.keystrokeOverlay.fontSize = $0 }
        )
    }

    private var holdDurationBinding: Binding<Double> {
        Binding(
            get: { utilities.keystrokeOverlay.holdDuration },
            set: { utilities.keystrokeOverlay.holdDuration = $0 }
        )
    }

    private var fadeOutDurationBinding: Binding<Double> {
        Binding(
            get: { utilities.keystrokeOverlay.fadeOutDuration },
            set: { utilities.keystrokeOverlay.fadeOutDuration = $0 }
        )
    }

    private var foregroundColorBinding: Binding<Color> {
        Binding(
            get: { utilities.keystrokeOverlay.foregroundColor.color },
            set: { utilities.keystrokeOverlay.foregroundColor = RGBAColor(NSColor($0)) }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { utilities.keystrokeOverlay.backgroundColor.color },
            set: { utilities.keystrokeOverlay.backgroundColor = RGBAColor(NSColor($0)) }
        )
    }

    private func refreshLivePreview() {
        utilities.showKeystrokeOverlayPreview()
    }
}

// MARK: - Helpers

private extension Binding where Value == Double {
    /** Returns a derived binding that snaps to the nearest multiple of `step`, avoiding
     tick marks that SwiftUI adds to `NSSlider` when the `step:` parameter is used. */
    func stepped(by step: Double) -> Binding<Double> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = (($0 / step).rounded() * step * 1e10).rounded() / 1e10 }
        )
    }
}

// MARK: - Screenshot Tools Settings

private struct ScreenshotToolsSettingsPane: View {
    @Environment(UtilitiesController.self) private var utilities
    @Environment(HotkeyService.self) private var hotkeyService

    @Binding var isRecordingMarkHotkey: Bool

    var body: some View {
        ScrollView {
            Form {
                hotkeySection
                usageSection
            }
            .settingsFormStyle()
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        Section {
            LabeledContent("Hotkey") {
                HStack(spacing: 8) {
                    HotkeyBindingControl(
                        keyCombo: utilities.screenshotTools.captureAndMarkHotkey,
                        isRecording: isRecordingMarkHotkey,
                        onStartRecording: {
                            isRecordingMarkHotkey = true
                        },
                        onRecordKey: { combo in
                            utilities.updateScreenshotCaptureAndMarkHotkey(combo)
                            isRecordingMarkHotkey = false
                        },
                        onCancelRecording: {
                            isRecordingMarkHotkey = false
                        },
                        checkConflict: { combo in
                            hotkeyService.hasConflict(
                                keyCombo: combo,
                                excludingUtilityID: .screenshotTools
                            )
                        },
                        emptyTitle: "Record Hotkey"
                    )

                    Button("Default") {
                        utilities.updateScreenshotCaptureAndMarkHotkey(
                            ScreenshotToolsConfiguration.defaultCaptureAndMarkHotkey
                        )
                    }
                    .controlSize(.small)
                    .disabled(
                        utilities.screenshotTools.captureAndMarkHotkey
                            == ScreenshotToolsConfiguration.defaultCaptureAndMarkHotkey
                    )
                }
            }
        }
    }

    // MARK: - Usage Guide

    private var usageSection: some View {
        Section("How It Works") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select a region, annotate it in the preview, then press Return to copy the image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Marking Shortcuts")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                        GridRow {
                            keycap("⌥")
                            Text("Tap to switch Line and Rect; hold to use the other tool until release")
                        }
                        GridRow {
                            keycap("TAB")
                            Text("Next color; Shift-Tab for previous")
                        }
                        GridRow {
                            keycap("⌘ Z")
                            Text("Undo the last annotation")
                        }
                        GridRow {
                            keycap("↩")
                            Text("Copy the annotated image and close")
                        }
                        GridRow {
                            keycap("ESC")
                            Text("Close without copying")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
            )
    }
}

// MARK: - Planned Utility

private struct PlannedUtilityPane: View {
    let feature: UtilityDescriptor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Planned Surface")
                        .font(.headline)

                    ForEach(feature.highlights, id: \.self) { highlight in
                        Label(highlight, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "This slot already has a dedicated place in the settings IA, so future implementation can add native controls here without changing the top-level structure."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}
