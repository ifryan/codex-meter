// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
private final class GLMSettingsWindow: NSWindow {
    // The accessory app has no Edit menu to supply field-editor shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil); return true
            case "a": editor.selectAll(nil); return true
            case "z": editor.undoManager?.undo(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class GLMConfigurationWindow: NSWindowController, NSWindowDelegate {
    private let credentials: GLMCredentialsStore
    private let onChange: () -> Void
    private let keyField = NSSecureTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(credentials: GLMCredentialsStore, onChange: @escaping () -> Void) {
        self.credentials = credentials
        self.onChange = onChange
        let window = GLMSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Configure GLM Coding Plan")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        window.contentView = content
        let instructions = NSTextField(wrappingLabelWithString:
            L("Zhipu (China) · Enter your Coding Plan API key. It stays in the macOS Keychain and is only used to query quota. Save with this field empty to migrate the old authorization once, so reinstalls won't ask again."))
        instructions.frame = NSRect(x: 24, y: 184, width: 432, height: 52)
        content.addSubview(instructions)
        keyField.placeholderString = L("Enter a new API key, or leave empty to use the saved one")
        keyField.frame = NSRect(x: 24, y: 140, width: 432, height: 26)
        keyField.setAccessibilityLabel("GLM Coding Plan API Key")
        content.addSubview(keyField)
        statusLabel.frame = NSRect(x: 24, y: 73, width: 432, height: 56)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)
        let remove = NSButton(title: L("Remove configuration"), target: self, action: #selector(removeKey))
        remove.frame = NSRect(x: 20, y: 22, width: 100, height: 32)
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 248, y: 22, width: 80, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: L("Save and connect"), target: self, action: #selector(saveKey))
        save.frame = NSRect(x: 334, y: 22, width: 126, height: 32)
        save.keyEquivalent = "\r"
        [remove, cancel, save].forEach { $0.bezelStyle = .rounded; content.addSubview($0) }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { keyField.stringValue = "" }

    func present() {
        keyField.stringValue = ""
        statusLabel.stringValue = L("Saving runs a query right away. The result appears in the notch details.")
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(keyField)
    }

    @objc private func saveKey() {
        do {
            if keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let key = try credentials.read(allowInteraction: true) else { throw GLMError.invalidKey }
                try credentials.save(key)
            } else {
                try credentials.save(keyField.stringValue)
            }
            keyField.stringValue = ""
            onChange()
            close()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func removeKey() {
        do {
            try credentials.remove()
            keyField.stringValue = ""
            onChange()
            close()
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    @objc private func cancel() {
        keyField.stringValue = ""
        close()
    }
}
