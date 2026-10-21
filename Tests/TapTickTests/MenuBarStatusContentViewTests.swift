import Foundation
import Testing
@testable import TapTickKit

@Suite("Menu Bar Status Content")
struct MenuBarStatusContentViewTests {
    @Test("Removing slots publishes the reduced status item width")
    @MainActor
    func removingSlotsPublishesReducedWidth() {
        let slots = [40, 60, 80].map { width in
            renderedSlot(
                fitsContentWidth: false,
                widthPoints: width,
                contents: [MenuBarTextContent(text: "CPU 9%", isPlaceholder: false)]
            )
        }
        let view = MenuBarStatusContentView(frame: .zero)
        var publishedWidth: CGFloat?
        view.widthDidChange = { publishedWidth = $0 }

        view.update(slots: slots, animated: true)
        let remainingSlots = [slots[0], slots[2]]
        view.update(slots: remainingSlots, animated: true)

        let expectedWidth = MenuBarStatusContentView.width(for: remainingSlots)
        #expect(publishedWidth == expectedWidth)
        #expect(view.intrinsicContentSize.width == expectedWidth)
    }

    @Test("Removing the last slot publishes the icon-only width")
    @MainActor
    func removingLastSlotPublishesIconOnlyWidth() {
        let slot = renderedSlot(
            fitsContentWidth: false,
            widthPoints: 80,
            contents: [MenuBarTextContent(text: "CPU 9%", isPlaceholder: false)]
        )
        let view = MenuBarStatusContentView(frame: .zero)
        var publishedWidth: CGFloat?
        view.widthDidChange = { publishedWidth = $0 }

        view.update(slots: [slot], animated: true)
        view.update(slots: [], animated: true)

        #expect(publishedWidth == MenuBarStatusContentView.iconAreaWidth)
        #expect(view.intrinsicContentSize.width == MenuBarStatusContentView.iconAreaWidth)
    }

    @Test("Fixed width ignores content length")
    @MainActor
    func fixedWidthIgnoresContentLength() {
        let slot = renderedSlot(
            fitsContentWidth: false,
            widthPoints: 88,
            contents: [MenuBarTextContent(text: String(repeating: "W", count: 100), isPlaceholder: false)]
        )

        #expect(MenuBarStatusContentView.width(for: slot) == 88)
    }

    @Test("Content-fitted width follows text within slot bounds")
    @MainActor
    func contentFittedWidthFollowsTextWithinBounds() {
        let previewEmptySlot = renderedSlot(
            fitsContentWidth: true,
            contents: [.empty],
            collapsesWhenEmpty: false
        )
        let shortSlot = renderedSlot(
            fitsContentWidth: true,
            contents: [MenuBarTextContent(text: "CPU 9%", isPlaceholder: false)]
        )
        let longSlot = renderedSlot(
            fitsContentWidth: true,
            contents: [MenuBarTextContent(text: String(repeating: "W", count: 100), isPlaceholder: false)]
        )

        #expect(
            MenuBarStatusContentView.width(for: previewEmptySlot)
                == CGFloat(MenuBarTextSlot.widthRange.lowerBound)
        )
        #expect(
            MenuBarStatusContentView.width(for: shortSlot)
                > MenuBarStatusContentView.width(for: previewEmptySlot)
        )
        #expect(
            MenuBarStatusContentView.width(for: longSlot)
                == CGFloat(MenuBarTextSlot.widthRange.upperBound)
        )
    }

    @Test("Runtime slots collapse only when every row is empty")
    @MainActor
    func runtimeSlotsCollapseOnlyWhenEveryRowIsEmpty() {
        let fixedEmptySlot = renderedSlot(
            fitsContentWidth: false,
            contents: [.empty]
        )
        let fittedEmptyRows = renderedSlot(
            fitsContentWidth: true,
            contents: [.empty, .empty]
        )
        let partiallyEmptyRows = renderedSlot(
            fitsContentWidth: true,
            contents: [
                .empty,
                MenuBarTextContent(text: "CPU 9%", isPlaceholder: false),
            ]
        )

        #expect(MenuBarStatusContentView.width(for: fixedEmptySlot) == 0)
        #expect(MenuBarStatusContentView.width(for: fittedEmptyRows) == 0)
        #expect(MenuBarStatusContentView.width(for: partiallyEmptyRows) > 0)
    }

    @Test("Two-line content-fitted width follows the wider row")
    @MainActor
    func twoLineContentFittedWidthFollowsWiderRow() {
        let shortRows = renderedSlot(
            fitsContentWidth: true,
            contents: [
                MenuBarTextContent(text: "A", isPlaceholder: false),
                MenuBarTextContent(text: "B", isPlaceholder: false),
            ]
        )
        let oneLongRow = renderedSlot(
            fitsContentWidth: true,
            contents: [
                MenuBarTextContent(text: "A", isPlaceholder: false),
                MenuBarTextContent(text: "Longer bottom row", isPlaceholder: false),
            ]
        )

        #expect(
            MenuBarStatusContentView.width(for: oneLongRow)
                > MenuBarStatusContentView.width(for: shortRows)
        )
    }

    @MainActor
    private func renderedSlot(
        fitsContentWidth: Bool,
        widthPoints: Int = MenuBarTextSlot.defaultWidthPoints,
        contents: [MenuBarTextContent],
        collapsesWhenEmpty: Bool = true
    ) -> MenuBarTextRenderedSlot {
        MenuBarTextRenderedSlot(
            id: UUID(),
            alignment: .center,
            fitsContentWidth: fitsContentWidth,
            widthPoints: widthPoints,
            contents: contents,
            collapsesWhenEmpty: collapsesWhenEmpty
        )
    }
}
