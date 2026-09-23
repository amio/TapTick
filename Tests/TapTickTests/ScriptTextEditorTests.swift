import AppKit
import SwiftUI
import Testing
@testable import TapTickKit

@Suite("ScriptTextEditor")
@MainActor
struct ScriptTextEditorTests {
    @Test("Editor keeps long lines unwrapped and provides horizontal scrolling")
    func nonWrappingLayout() throws {
        let scrollView = NSTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        let textContainer = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)
        scrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        textView.string = String(repeating: "a", count: 200)

        ScriptTextEditor.configureNonWrappingLayout(textView, in: scrollView)
        ScriptTextEditor.resizeDocumentView(textView, in: scrollView)
        layoutManager.ensureLayout(for: textContainer)
        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(layoutManager.usedRect(for: textContainer).width > scrollView.contentSize.width)
        #expect(textView.frame.width > scrollView.documentVisibleRect.width)
    }

    @Test("Loading a script establishes a clean saved baseline")
    func loadingDraftIsSaved() throws {
        let shortcut = Shortcut(
            name: "Example",
            action: .runScript(script: "#!/bin/zsh\necho initial")
        )
        var state = ScriptEditorDraftState()

        state.load(shortcut)
        let savedDraft = state.draft
        #expect(!state.hasUnsavedChanges)

        state.draft.scriptContent = "echo changed"
        #expect(state.hasUnsavedChanges)

        state.draft = savedDraft
        #expect(!state.hasUnsavedChanges)

        state.draft.name = "Renamed"
        let persisted = try #require(state.shortcutWithCurrentDraft())
        state.load(persisted)
        #expect(state.loadedShortcut?.name == "Renamed")
        #expect(!state.hasUnsavedChanges)
    }

    @Test("Switching scripts retargets the draft without carrying editor state")
    func switchingDraftRetargetsEditorState() throws {
        let first = Shortcut(
            name: "First",
            action: .runScript(script: "#!/bin/zsh\necho first")
        )
        let second = Shortcut(
            name: "Second",
            action: .runScript(script: "#!/bin/bash\necho second")
        )
        var state = ScriptEditorDraftState(shortcut: first)

        state.draft.name = "Edited First"
        let firstUpdate = try #require(state.shortcutWithCurrentDraft())
        #expect(firstUpdate.id == first.id)
        #expect(firstUpdate.name == "Edited First")

        state.load(second)

        #expect(state.loadedShortcutID == second.id)
        #expect(state.draft.name == "Second")
        #expect(state.draft.scriptContent == "#!/bin/bash\necho second")
        #expect(!state.hasUnsavedChanges)
    }

    @Test("Native undo and redo share the editor controller")
    func nativeUndoRedo() {
        let text = TextBox("a")
        let controller = ScriptTextEditorController()
        let editor = ScriptTextEditor(
            text: Binding(
                get: { text.value },
                set: { text.value = $0 }
            ),
            language: .shell(.zsh),
            controller: controller
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.string = text.value
        coordinator.attach(to: textView, controller: controller)
        textView.setSelectedRange(NSRange(location: 1, length: 0))

        textView.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(text.value == "ab")
        #expect(controller.undoManager.levelsOfUndo == 0)
        #expect(controller.undoManager.canUndo)

        controller.undo()
        #expect(text.value == "a")
        #expect(controller.canRedo)

        controller.redo()
        #expect(text.value == "ab")
    }

    @Test("Unrelated store updates preserve a dirty editor draft")
    func unrelatedStoreUpdatePreservesDraft() throws {
        let shortcut = Shortcut(
            name: "Example",
            action: .runScript(script: "#!/bin/zsh\necho saved")
        )
        var state = ScriptEditorDraftState(shortcut: shortcut)
        state.draft.scriptContent = "#!/bin/zsh\necho draft"
        var triggered = shortcut
        triggered.keyCombo = KeyCombo(keyCode: 12, modifiers: .command)
        triggered.lastTriggeredAt = Date()

        #expect(!state.hasPersistedEditorChange(in: triggered))
        state.updateLoadedMetadata(triggered)

        let update = try #require(state.shortcutWithCurrentDraft())
        #expect(update.keyCombo == triggered.keyCombo)
        #expect(update.action == .runScript(script: "#!/bin/zsh\necho draft"))

        var externallyEdited = triggered
        externallyEdited.action = .runScript(script: "#!/bin/sh\necho external")
        #expect(state.hasPersistedEditorChange(in: externallyEdited))
    }

    @Test("Editor command replacement is a single native undoable change")
    func editorCommandReplacement() {
        let text = TextBox("old")
        let controller = ScriptTextEditorController()
        let editor = ScriptTextEditor(
            text: Binding(
                get: { text.value },
                set: { text.value = $0 }
            ),
            language: .shell(.zsh),
            controller: controller
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.string = text.value
        coordinator.attach(to: textView, controller: controller)

        #expect(controller.replaceAll(with: "generated", actionName: "Generate Script"))
        #expect(textView.string == "generated")
        #expect(text.value == "generated")
        #expect(controller.undoManager.undoActionName == "Generate Script")

        controller.undo()
        #expect(textView.string == "old")
        #expect(text.value == "old")
        #expect(controller.canRedo)
    }

    @Test("IME composition survives SwiftUI updates and publishes only after commit")
    func imeCompositionLifecycle() throws {
        let text = TextBox("echo ")
        let controller = ScriptTextEditorController()
        let editor = ScriptTextEditor(
            text: Binding(
                get: { text.value },
                set: { text.value = $0 }
            ),
            language: .shell(.zsh),
            controller: controller
        )
        let coordinator = editor.makeCoordinator()
        let scrollView = ScriptEditorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? ScriptEditorTextView)
        textView.delegate = coordinator
        textView.string = text.value
        coordinator.attach(to: textView, in: scrollView, controller: controller)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.hasMarkedText())
        #expect(textView.markedRange() == NSRange(location: 5, length: 2))
        #expect(textView.string == "echo ni")
        #expect(text.value == "echo ")

        coordinator.updateTextViewFromModelIfNeeded(textView)
        coordinator.highlightIfNeeded(textView)

        #expect(textView.string == "echo ni")
        #expect(text.value == "echo ")

        textView.insertText("你", replacementRange: textView.markedRange())

        #expect(!textView.hasMarkedText())
        #expect(textView.string == "echo 你")
        #expect(text.value == "echo 你")
    }

    @Test("Generation preview never writes a partial draft and commits as one undo operation")
    func generationPreviewTransaction() {
        let text = TextBox("#!/bin/sh\necho old")
        let original = text.value
        let controller = ScriptTextEditorController()
        let editor = ScriptTextEditor(
            text: Binding(get: { text.value }, set: { text.value = $0 }),
            language: .shell(.sh), controller: controller
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.string = original
        coordinator.attach(to: textView, controller: controller)

        controller.beginPreview()
        controller.showPreview("#!/bin/sh\necho par")
        coordinator.updateTextViewFromModelIfNeeded(textView)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(textView.string == "#!/bin/sh\necho par")
        #expect(text.value == original)
        #expect(!textView.isEditable)
        #expect(coordinator.undoManager(for: textView) == nil)

        let generated = "#!/bin/sh\necho generated"
        controller.endPreview(with: generated)
        #expect(text.value == generated)
        #expect(textView.isEditable)
        controller.undo()
        #expect(text.value == original)
        controller.redo()
        #expect(text.value == generated)
    }

    @Test("Cancelling preview preserves preceding edits, selection and undo history")
    func cancelledPreviewHistory() {
        let text = TextBox("original")
        let controller = ScriptTextEditorController()
        let editor = ScriptTextEditor(
            text: Binding(get: { text.value }, set: { text.value = $0 }),
            language: .shell(.sh), controller: controller
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView()
        textView.delegate = coordinator
        textView.allowsUndo = true
        textView.string = text.value
        coordinator.attach(to: textView, controller: controller)
        controller.replaceAll(with: "edited", actionName: "Edit")
        let selection = NSRange(location: 2, length: 2)
        textView.setSelectedRange(selection)
        controller.beginPreview()
        controller.showPreview("unfinished")
        controller.endPreview()
        #expect(textView.string == "edited")
        #expect(textView.selectedRange() == selection)
        #expect(text.value == "edited")
        controller.undo()
        #expect(text.value == "original")
    }
}

@MainActor
private final class TextBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}
