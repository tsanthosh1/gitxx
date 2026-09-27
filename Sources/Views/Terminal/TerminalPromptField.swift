import SwiftUI
import AppKit

public struct TerminalPromptField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void

    public init(
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        onUpArrow: @escaping () -> Void,
        onDownArrow: @escaping () -> Void
    ) {
        self._text = text
        self.onCommit = onCommit
        self.onUpArrow = onUpArrow
        self.onDownArrow = onDownArrow
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = "type git or shell command..."
        textField.stringValue = text
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        textField.textColor = NSColor.textColor
        textField.delegate = context.coordinator
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        return textField
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder != nsView.currentEditor() && window.firstResponder != nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TerminalPromptField

        init(_ parent: TerminalPromptField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUpArrow()
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDownArrow()
                return true
            }
            return false
        }
    }
}
