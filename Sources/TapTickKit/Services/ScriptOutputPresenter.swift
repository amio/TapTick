import AppKit
import QuartzCore
import SwiftUI

private extension CGPoint {
    func centeredRect(for size: CGSize) -> CGRect {
        CGRect(
            x: x - size.width / 2,
            y: y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

enum ScriptOutputToastSettings {
    static let holdDurationKey = "scriptOutputToastHoldDuration"
    static let defaultHoldDuration: TimeInterval = 2.4
    static let holdDurationRange: ClosedRange<TimeInterval> = 1.2...6
    static let holdDurationStep: TimeInterval = 0.6

    static func normalizedHoldDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return defaultHoldDuration }

        let clamped = min(max(duration, holdDurationRange.lowerBound), holdDurationRange.upperBound)
        let steps = ((clamped - holdDurationRange.lowerBound) / holdDurationStep).rounded()
        return ((holdDurationRange.lowerBound + steps * holdDurationStep) * 10).rounded() / 10
    }

    static func holdDuration(defaults: UserDefaults = .standard) -> TimeInterval {
        guard
            let storedDuration = defaults.object(forKey: holdDurationKey) as? TimeInterval
        else { return defaultHoldDuration }

        return normalizedHoldDuration(storedDuration)
    }
}

/// Displays script output in a transient Liquid Glass toast at the center of the screen.
@MainActor
public final class ScriptOutputPresenter {
    public init() {}
    private let model = ScriptOutputPresentationModel()
    private lazy var hostingView: NSHostingView<ScriptOutputToastContentView> = {
        let view = NSHostingView(rootView: ScriptOutputToastContentView(model: model))
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }()
    private lazy var toastView: ScriptOutputGlassToastView = {
        let view = ScriptOutputGlassToastView(contentView: hostingView)
        view.onHoverChanged = { [weak self] isHovering in
            self?.handleHoverChange(isHovering)
        }
        view.onDragEnded = { [weak self] in
            self?.handleDragEnd()
        }
        view.onDoubleClick = { [weak self] in
            self?.copyVisibleText()
        }
        return view
    }()
    private lazy var panel: NSPanel = makePanel()
    private lazy var appearanceAnimator = ScriptOutputSmootherstepAnimator(view: toastView)
    private lazy var bodyAnimator = ScriptOutputSmootherstepAnimator(view: toastView)
    private var entranceTask: Task<Void, Never>?
    private var contentSwapTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var lifecycle = ScriptOutputToastLifecycle.hidden
    private var pendingItems: [ScriptOutputToastItem] = []
    private var remainingHoldDuration = TimeInterval.zero
    private var holdDeadline: TimeInterval?
    private var isPointerHovering = false
    /// Stable screen-space origin. Only fresh placement or a completed drag may change it.
    private var centerAnchor: CGPoint?

    private let copyFeedbackDuration: TimeInterval = 0.8

    public func show(log: ScriptExecutionLog) {
        guard let subtitleText = log.subtitleText else { return }
        let items = subtitleText.split(whereSeparator: \.isNewline).map { line in
            let text = String(line)
            return ScriptOutputToastItem(
                text: text,
                textWidth: ScriptOutputToastMetrics.textWidth(for: text),
                isError: !log.succeeded
            )
        }
        guard let firstItem = items.first else { return }

        switch lifecycle {
        case .entering, .holding, .swapping:
            pendingItems.append(contentsOf: items)
            updateRemainingCounts()
        case .hidden, .dismissing:
            presentFresh(firstItem, pending: Array(items.dropFirst()))
        }
    }

    private func presentFresh(_ item: ScriptOutputToastItem, pending: [ScriptOutputToastItem]) {
        if lifecycle != .hidden {
            persistVerticalPosition()
        }

        entranceTask?.cancel()
        contentSwapTask?.cancel()
        appearanceAnimator.cancel()
        bodyAnimator.cancel()
        clearCopyFeedback()
        resetHoldCountdown()
        pendingItems = pending
        model.currentItem = item
        model.nextItem = nil
        updateRemainingCounts()
        model.viewportTextWidth = item.textWidth
        model.contentSwapProgress = 0
        model.phase = .hidden
        model.contentRevealProgress = 0
        layoutPanel()
        applyAppearanceProgress(0)

        if lifecycle == .hidden {
            panel.orderFrontRegardless()
        }

        lifecycle = .entering
        playEntranceAnimation()
    }

    // MARK: - Panel Lifecycle

    private func beginHold() {
        remainingHoldDuration = ScriptOutputToastSettings.holdDuration()
        lifecycle = .holding
        isPointerHovering = toastView.isPointerInsideGlass

        if !isPointerHovering {
            resumeHoldCountdown()
        }
    }

    private func handleHoverChange(_ isHovering: Bool) {
        isPointerHovering = isHovering
        guard lifecycle == .holding else { return }

        if isHovering {
            pauseHoldCountdown()
        } else {
            resumeHoldCountdown()
        }
    }

    private func handleDragEnd() {
        centerAnchor = panel.frame.center
        persistVerticalPosition()
    }

    private func copyVisibleText() {
        let item =
            model.contentSwapProgress >= 0.5
            ? model.nextItem ?? model.currentItem
            : model.currentItem
        guard !item.text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(item.text, forType: .string) else { return }

        copyFeedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            model.isCopyFeedbackVisible = true
        }
        copyFeedbackTask = Task { [weak self] in
            guard let self, await wait(for: copyFeedbackDuration) else { return }

            withAnimation(.easeInOut(duration: 0.15)) {
                model.isCopyFeedbackVisible = false
            }
            copyFeedbackTask = nil
        }
    }

    private func clearCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        model.isCopyFeedbackVisible = false
    }

    private func pauseHoldCountdown() {
        guard let holdDeadline else { return }

        remainingHoldDuration = max(
            0,
            holdDeadline - ProcessInfo.processInfo.systemUptime
        )
        self.holdDeadline = nil
        hideTask?.cancel()
        hideTask = nil
    }

    private func resumeHoldCountdown() {
        guard lifecycle == .holding, !isPointerHovering, hideTask == nil else { return }

        let duration = remainingHoldDuration
        holdDeadline = ProcessInfo.processInfo.systemUptime + duration
        hideTask = Task { [weak self] in
            guard let self else { return }

            guard await wait(for: duration) else { return }
            guard lifecycle == .holding, !isPointerHovering else { return }

            remainingHoldDuration = 0
            holdDeadline = nil
            if !pendingItems.isEmpty {
                hideTask = nil
                startContentSwap(to: pendingItems.removeFirst())
                return
            }
            lifecycle = .dismissing
            await dismissToast()
        }
    }

    private func resetHoldCountdown() {
        hideTask?.cancel()
        hideTask = nil
        remainingHoldDuration = ScriptOutputToastSettings.holdDuration()
        holdDeadline = nil
        isPointerHovering = false
    }

    private func playEntranceAnimation() {
        entranceTask = Task { [weak self] in
            guard let self else { return }

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                applyBodyProgress(1)
                model.phase = .revealed
                applyAppearanceProgress(1)
                entranceTask = nil
                beginHold()
                return
            }

            animateAppearance(from: 0, to: 1)
            guard await wait(for: ScriptOutputToastTiming.iconStagger) else { return }

            withAnimation(.easeOut(duration: ScriptOutputToastTiming.iconDuration)) {
                model.phase = .compact
            }

            guard await wait(for: ScriptOutputToastTiming.iconDuration) else { return }
            appearanceAnimator.cancel()
            applyAppearanceProgress(1)

            let bodyDuration = ScriptOutputToastTiming.bodyDuration(
                forTextWidth: model.currentItem.textWidth
            )
            animateBody(from: 0, to: 1, duration: bodyDuration)
            guard await wait(for: bodyDuration) else { return }
            bodyAnimator.cancel()
            applyBodyProgress(1)
            model.phase = .revealed
            entranceTask = nil
            beginHold()
        }
    }

    private func startContentSwap(to item: ScriptOutputToastItem) {
        clearCopyFeedback()
        lifecycle = .swapping

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishContentSwap(with: item)
            beginHold()
            return
        }

        let startWidth = model.viewportTextWidth
        model.nextItem = item
        updateRemainingCounts()
        model.contentSwapProgress = 0
        contentSwapTask = Task { [weak self] in
            guard let self else { return }

            bodyAnimator.animate(
                from: 0,
                to: 1,
                duration: ScriptOutputToastTiming.contentSwapDuration
            ) { [weak self] progress in
                self?.applyContentSwapProgress(
                    progress,
                    fromTextWidth: startWidth,
                    toTextWidth: item.textWidth
                )
            }
            guard await wait(for: ScriptOutputToastTiming.contentSwapDuration) else { return }
            bodyAnimator.cancel()
            applyContentSwapProgress(
                1,
                fromTextWidth: startWidth,
                toTextWidth: item.textWidth
            )
            finishContentSwap(with: item)
            contentSwapTask = nil
            beginHold()
        }
    }

    private func applyContentSwapProgress(
        _ progress: CGFloat,
        fromTextWidth: CGFloat,
        toTextWidth: CGFloat
    ) {
        model.contentSwapProgress = progress
        let textWidth = fromTextWidth + (toTextWidth - fromTextWidth) * progress
        model.viewportTextWidth = textWidth
        resizeExpandedPanel(textWidth: textWidth)
    }

    private func finishContentSwap(with item: ScriptOutputToastItem) {
        clearCopyFeedback()
        model.currentItem = item
        model.nextItem = nil
        updateRemainingCounts()
        model.viewportTextWidth = item.textWidth
        model.contentSwapProgress = 0
        resizeExpandedPanel(textWidth: item.textWidth)
    }

    private func updateRemainingCounts() {
        model.currentRemainingCount = pendingItems.count + (model.nextItem == nil ? 0 : 1)
        model.nextRemainingCount = pendingItems.count
    }

    private func dismissToast() async {
        clearCopyFeedback()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let bodyDuration = ScriptOutputToastTiming.bodyDuration(
                forTextWidth: model.currentItem.textWidth
            )
            model.phase = .compact
            animateBody(from: 1, to: 0, duration: bodyDuration)
            guard await wait(for: bodyDuration) else { return }
            bodyAnimator.cancel()
            applyBodyProgress(0)

            withAnimation(.easeIn(duration: ScriptOutputToastTiming.iconDuration)) {
                model.phase = .hidden
            }
            guard await wait(for: ScriptOutputToastTiming.iconStagger) else { return }

            animateAppearance(from: 1, to: 0)
            guard await wait(for: ScriptOutputToastTiming.surfaceDuration) else { return }
            appearanceAnimator.cancel()
            applyAppearanceProgress(0)
        } else {
            applyAppearanceProgress(0)
        }

        persistVerticalPosition()
        lifecycle = .hidden
        isPointerHovering = false
        panel.orderOut(nil)
    }

    private func animateBody(from start: CGFloat, to end: CGFloat, duration: TimeInterval) {
        bodyAnimator.animate(from: start, to: end, duration: duration) { [weak self] progress in
            self?.applyBodyProgress(progress)
        }
    }

    private func animateAppearance(from start: CGFloat, to end: CGFloat) {
        appearanceAnimator.animate(
            from: start,
            to: end,
            duration: ScriptOutputToastTiming.surfaceDuration
        ) { [weak self] progress in
            self?.applyAppearanceProgress(progress)
        }
    }

    private func applyAppearanceProgress(_ progress: CGFloat) {
        let t = min(max(progress, 0), 1)
        panel.alphaValue = t
        toastView.setAppearanceScale(
            ScriptOutputToastMetrics.initialAppearanceScale
                + (1 - ScriptOutputToastMetrics.initialAppearanceScale) * t
        )
    }

    private func applyBodyProgress(_ progress: CGFloat) {
        toastView.setExpansionProgress(progress)
        model.contentRevealProgress = progress
    }

    private func resizeExpandedPanel(textWidth: CGFloat) {
        let contentSize = ScriptOutputToastMetrics.contentSize(forTextWidth: textWidth)
        let panelSize = ScriptOutputGlassToastView.panelSize(for: contentSize)
        applyPanelSize(panelSize)
        toastView.updateExpandedContentSize(contentSize)
        toastView.setExpansionProgress(1)
    }

    private func applyPanelSize(_ size: NSSize) {
        guard let centerAnchor else { return }
        panel.setFrame(centerAnchor.centeredRect(for: size), display: true)
    }

    private func wait(for duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func layoutPanel() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let contentSize = hostingView.fittingSize
        let panelSize = ScriptOutputGlassToastView.panelSize(for: contentSize)

        guard let screen = targetScreen() else { return }

        let frame = screen.visibleFrame
        let verticalPosition = preferredVerticalPositionFromTop()
        let halfHeight = panelSize.height / 2
        let minimumCenterY = frame.minY + halfHeight
        let maximumCenterY = max(minimumCenterY, frame.maxY - halfHeight)
        let desiredCenterY = frame.maxY - frame.height * verticalPosition
        let anchor = CGPoint(
            x: frame.midX,
            y: min(max(desiredCenterY, minimumCenterY), maximumCenterY)
        )
        centerAnchor = anchor
        applyPanelSize(panelSize)
        toastView.prepare(expandedContentSize: contentSize)
    }

    private func preferredVerticalPositionFromTop() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: ScriptOutputToastPosition.defaultsKey) != nil else {
            return ScriptOutputToastPosition.defaultVerticalPositionFromTop
        }

        let storedPosition = defaults.double(forKey: ScriptOutputToastPosition.defaultsKey)
        guard storedPosition.isFinite else {
            return ScriptOutputToastPosition.defaultVerticalPositionFromTop
        }
        return min(max(CGFloat(storedPosition), 0), 1)
    }

    private func persistVerticalPosition() {
        guard
            let screen = panel.screen,
            screen.visibleFrame.height > 0,
            let centerAnchor
        else { return }

        let visibleFrame = screen.visibleFrame
        let positionFromTop = (visibleFrame.maxY - centerAnchor.y) / visibleFrame.height
        let normalizedPosition = min(max(positionFromTop, 0), 1)
        UserDefaults.standard.set(
            Double(normalizedPosition),
            forKey: ScriptOutputToastPosition.defaultsKey
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = toastView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
            .transient,
        ]

        return panel
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }
}

// MARK: - Presentation Model

private enum ScriptOutputToastLifecycle {
    case hidden
    case entering
    case holding
    case swapping
    case dismissing
}

private struct ScriptOutputToastItem {
    static let empty = ScriptOutputToastItem(text: "", textWidth: 0, isError: false)

    let text: String
    let textWidth: CGFloat
    let isError: Bool
}

@Observable
@MainActor
private final class ScriptOutputPresentationModel {
    var currentItem = ScriptOutputToastItem.empty
    var nextItem: ScriptOutputToastItem?
    var currentRemainingCount = 0
    var nextRemainingCount = 0
    var viewportTextWidth = CGFloat.zero
    var contentRevealProgress = CGFloat.zero
    var contentSwapProgress = CGFloat.zero
    var isCopyFeedbackVisible = false
    var phase = ScriptOutputToastPhase.compact
}

// MARK: - Toast View

@MainActor
private enum ScriptOutputToastTiming {
    static let surfaceDuration: TimeInterval = 0.2
    static let iconDuration: TimeInterval = 0.2
    static let iconStagger: TimeInterval = 0.1
    static let contentSwapDuration: TimeInterval = 0.32
    private static let maximumBodyDuration: TimeInterval = 0.48

    static func bodyDuration(forTextWidth textWidth: CGFloat) -> TimeInterval {
        let normalizedWidth = Double(
            min(max(textWidth / ScriptOutputToastMetrics.maximumTextWidth, 0), 1)
        )
        let minimumDuration = maximumBodyDuration / 2
        return minimumDuration + (maximumBodyDuration - minimumDuration) * normalizedWidth
    }

    static func smootherstep(_ progress: CGFloat) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

@MainActor
private final class ScriptOutputSmootherstepAnimator: NSObject {
    private weak var view: NSView?
    private var displayLink: CADisplayLink?
    private var startTime = CFTimeInterval.zero
    private var duration = TimeInterval.zero
    private var startValue = CGFloat.zero
    private var endValue = CGFloat.zero
    private var update: ((CGFloat) -> Void)?

    init(view: NSView) {
        self.view = view
    }

    func animate(
        from startValue: CGFloat,
        to endValue: CGFloat,
        duration: TimeInterval,
        update: @escaping (CGFloat) -> Void
    ) {
        cancel()
        self.startValue = startValue
        self.endValue = endValue
        self.duration = max(duration, .leastNonzeroMagnitude)
        self.update = update
        startTime = CACurrentMediaTime()
        update(startValue)

        guard
            let displayLink = view?.displayLink(
                target: self,
                selector: #selector(handleDisplayLink(_:))
            )
        else {
            update(endValue)
            self.update = nil
            return
        }

        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        update = nil
    }

    @objc
    private func handleDisplayLink(_ displayLink: CADisplayLink) {
        let elapsed = displayLink.timestamp - startTime
        let linearProgress = CGFloat(min(max(elapsed / duration, 0), 1))
        let curvedProgress = ScriptOutputToastTiming.smootherstep(linearProgress)
        update?(startValue + (endValue - startValue) * curvedProgress)

        if linearProgress >= 1 {
            cancel()
        }
    }
}

private enum ScriptOutputToastPosition {
    static let defaultsKey = "scriptOutputToastVerticalPositionFromTop"
    static let defaultVerticalPositionFromTop: CGFloat = 0.75
}

@MainActor
private enum ScriptOutputToastMetrics {
    static let copyFeedbackText = "Copied"
    static let collapsedDiameter: CGFloat = 58
    static let initialAppearanceScale: CGFloat = 0.3
    static let horizontalPadding: CGFloat = 12
    static let contentSpacing: CGFloat = 13
    static let statusSymbolSize: CGFloat = 34
    static let statusGlyphSize: CGFloat = 18
    static let maximumTextWidth: CGFloat = 720
    private static let minimumTrailingStabilizationPadding: CGFloat = 3
    private static let widthQuantum: CGFloat = 2

    private static let textFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
    private static let minimumTextWidth = ceil(
        (copyFeedbackText as NSString).size(withAttributes: [.font: textFont]).width
    )

    static func textWidth(for text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont],
            context: nil
        )
        return min(maximumTextWidth, ceil(max(minimumTextWidth, bounds.width)))
    }

    static func contentSize(forTextWidth textWidth: CGFloat) -> NSSize {
        NSSize(
            width: stabilizedContentWidth(forTextWidth: textWidth),
            height: collapsedDiameter
        )
    }

    /// Keeps every row on the same whole-point center phase as its animated viewport.
    static func trailingStabilizationPadding(forTextWidth textWidth: CGFloat) -> CGFloat {
        stabilizedContentWidth(forTextWidth: textWidth)
            - naturalContentWidth(
                forTextWidth: textWidth
            )
    }

    private static func naturalContentWidth(forTextWidth textWidth: CGFloat) -> CGFloat {
        horizontalPadding * 2 + statusSymbolSize + contentSpacing + textWidth
    }

    private static func stabilizedContentWidth(forTextWidth textWidth: CGFloat) -> CGFloat {
        let paddedWidth =
            naturalContentWidth(forTextWidth: textWidth)
            + minimumTrailingStabilizationPadding
        return ceil(paddedWidth / widthQuantum) * widthQuantum
    }
}

private enum ScriptOutputToastPhase {
    case hidden
    case compact
    case revealed

    var iconScale: CGFloat {
        switch self {
        case .hidden: 0
        case .compact, .revealed: 1
        }
    }
}

private struct ScriptOutputToastContentView: View {
    let model: ScriptOutputPresentationModel

    var body: some View {
        ZStack {
            if model.isCopyFeedbackVisible {
                toastContent(
                    item: ScriptOutputToastItem(
                        text: ScriptOutputToastMetrics.copyFeedbackText,
                        textWidth: model.viewportTextWidth,
                        isError: false
                    ),
                    remainingCount: 0,
                    phase: model.phase
                )
                .transition(.opacity)
            } else {
                toastContent(
                    item: model.currentItem,
                    remainingCount: model.currentRemainingCount,
                    phase: model.phase
                )
                .offset(y: -model.contentSwapProgress * ScriptOutputToastMetrics.collapsedDiameter)

                if let nextItem = model.nextItem {
                    toastContent(
                        item: nextItem,
                        remainingCount: model.nextRemainingCount,
                        phase: model.phase
                    )
                    .offset(
                        y: (1 - model.contentSwapProgress)
                            * ScriptOutputToastMetrics.collapsedDiameter
                    )
                }
            }
        }
        .offset(x: compactBodyOffset)
        .frame(
            width: ScriptOutputToastMetrics.contentSize(
                forTextWidth: model.viewportTextWidth
            ).width,
            height: ScriptOutputToastMetrics.collapsedDiameter
        )
        .clipped()
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.isCopyFeedbackVisible
                ? "Copied to clipboard"
                : accessibilityItem.isError ? "Script failed" : "Script completed"
        )
        .accessibilityValue(model.isCopyFeedbackVisible ? "" : accessibilityItem.text)
    }

    private var accessibilityItem: ScriptOutputToastItem {
        model.nextItem ?? model.currentItem
    }

    /// Morphs the compact symbol anchor into the centered full-row anchor during reveal.
    private var compactBodyOffset: CGFloat {
        let contentWidth = ScriptOutputToastMetrics.contentSize(
            forTextWidth: model.currentItem.textWidth
        ).width
        return (contentWidth - ScriptOutputToastMetrics.collapsedDiameter) / 2
            * (1 - model.contentRevealProgress)
    }

    private func toastContent(
        item: ScriptOutputToastItem,
        remainingCount: Int,
        phase: ScriptOutputToastPhase
    ) -> some View {
        HStack(spacing: ScriptOutputToastMetrics.contentSpacing) {
            statusSymbol(isError: item.isError, remainingCount: remainingCount, phase: phase)

            Text(item.text)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: item.textWidth, alignment: .leading)
                .mask {
                    ScriptOutputTextRevealMask(
                        progress: model.contentRevealProgress,
                        width: item.textWidth
                    )
                }
                .padding(
                    .trailing,
                    ScriptOutputToastMetrics.trailingStabilizationPadding(
                        forTextWidth: item.textWidth
                    )
                )
        }
        .padding(.horizontal, ScriptOutputToastMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .frame(minHeight: ScriptOutputToastMetrics.collapsedDiameter)
    }

    private func statusSymbol(
        isError: Bool,
        remainingCount: Int,
        phase: ScriptOutputToastPhase
    ) -> some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.72), lineWidth: 1.5)

            if remainingCount > 0 {
                Text(verbatim: String(remainingCount))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: ScriptOutputToastMetrics.statusSymbolSize - 6)
            } else {
                Image(systemName: isError ? "exclamationmark" : "checkmark")
                    .font(.system(size: ScriptOutputToastMetrics.statusGlyphSize, weight: .bold))
            }
        }
        .foregroundStyle(.primary)
        .frame(
            width: ScriptOutputToastMetrics.statusSymbolSize,
            height: ScriptOutputToastMetrics.statusSymbolSize
        )
        .scaleEffect(phase.iconScale)
        .accessibilityHidden(true)
    }
}

private struct ScriptOutputTextRevealMask: View {
    private static let featherWidth: CGFloat = 28

    let progress: CGFloat
    let width: CGFloat

    private var revealEdge: CGFloat {
        let expandedEdge = width + ScriptOutputToastMetrics.horizontalPadding
        return progress * expandedEdge
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.white)
                .frame(width: width)

            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.featherWidth)
        }
        // Tie the left-to-right feathered reveal to the symmetric Glass expansion progress.
        .offset(x: revealEdge - (width + Self.featherWidth))
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// Owns the native Glass surface at the panel boundary so AppKit can composite its hosted content.
private final class ScriptOutputGlassToastView: NSView {
    private static let panelPadding: CGFloat = 24
    private static let lightModeGlassTintOpacity: CGFloat = 0.2
    private static let lightModeSurfaceScrimOpacity: CGFloat = 0.4
    private static let lightModeShadowOpacity: Float = 0.18
    private static let shadowRadius: CGFloat = 12
    private static let shadowOffset = CGSize(width: 0, height: -4)

    var onHoverChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let glassView: NSGlassEffectView
    private let glassContentView: ScriptOutputGlassContentView

    init(contentView: NSView) {
        glassContentView = ScriptOutputGlassContentView(hostedView: contentView)
        glassView = NSGlassEffectView()
        super.init(frame: .zero)

        wantsLayer = true
        glassView.style = .regular
        glassView.contentView = glassContentView
        addSubview(glassView)
        configureSurfaceAppearance()
        glassView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceAppearance()
    }

    static func panelSize(for contentSize: NSSize) -> NSSize {
        NSSize(
            width: contentSize.width + panelPadding * 2,
            height: contentSize.height + panelPadding * 2
        )
    }

    var isPointerInsideGlass: Bool {
        guard let window else { return false }
        let location = glassView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return glassView.bounds.contains(location)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        glassView.frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }

        window?.performDrag(with: event)
        onDragEnded?()
    }

    func prepare(expandedContentSize: NSSize) {
        updateExpandedContentSize(expandedContentSize)
        showCompact()
    }

    func updateExpandedContentSize(_ expandedContentSize: NSSize) {
        glassContentView.expandedContentSize = expandedContentSize
    }

    func setAppearanceScale(_ scale: CGFloat) {
        guard let layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let visualCenter = CGPoint(x: 0.5, y: 0.5)
        if layer.anchorPoint != visualCenter {
            var position = layer.position
            position.x += (visualCenter.x - layer.anchorPoint.x) * layer.bounds.width
            position.y += (visualCenter.y - layer.anchorPoint.y) * layer.bounds.height
            layer.position = position
            layer.anchorPoint = visualCenter
        }

        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func showCompact() {
        glassView.layer?.removeAllAnimations()
        setExpansionProgress(0)
    }

    func setExpansionProgress(_ progress: CGFloat) {
        let t = min(max(progress, 0), 1)
        let compactFrame = compactFrame
        let expandedFrame = expandedFrame
        let frame = NSRect(
            x: compactFrame.minX + (expandedFrame.minX - compactFrame.minX) * t,
            y: compactFrame.minY + (expandedFrame.minY - compactFrame.minY) * t,
            width: compactFrame.width + (expandedFrame.width - compactFrame.width) * t,
            height: compactFrame.height + (expandedFrame.height - compactFrame.height) * t
        )
        glassView.frame = frame
        let cornerRadius = min(
            ScriptOutputToastMetrics.collapsedDiameter / 2,
            frame.height / 2
        )
        glassView.cornerRadius = cornerRadius
        layer?.shadowPath = CGPath(
            roundedRect: frame,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    private func configureSurfaceAppearance() {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = Self.shadowRadius
        layer.shadowOffset = Self.shadowOffset
        updateSurfaceAppearance()
    }

    private func updateSurfaceAppearance() {
        let isLightMode =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        layer?.shadowOpacity = isLightMode ? Self.lightModeShadowOpacity : 0
        glassView.tintColor =
            isLightMode
            ? NSColor.white.withAlphaComponent(Self.lightModeGlassTintOpacity)
            : nil
        glassContentView.setSurfaceScrimColor(
            isLightMode
                ? NSColor.white.withAlphaComponent(Self.lightModeSurfaceScrimOpacity)
                : nil
        )
    }

    private var compactFrame: NSRect {
        let diameter = ScriptOutputToastMetrics.collapsedDiameter
        return bounds.center.centeredRect(
            for: NSSize(width: diameter, height: diameter)
        )
    }

    private var expandedFrame: NSRect {
        bounds.center.centeredRect(for: glassContentView.expandedContentSize)
    }
}

/// Keeps the full content viewport centered inside the animated Glass surface.
private final class ScriptOutputGlassContentView: NSView {
    var expandedContentSize = NSSize.zero {
        didSet { needsLayout = true }
    }

    private let hostedView: NSView

    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hostedView.frame = bounds.center.centeredRect(for: expandedContentSize)
    }

    func setSurfaceScrimColor(_ color: NSColor?) {
        layer?.backgroundColor = color?.cgColor
    }
}
