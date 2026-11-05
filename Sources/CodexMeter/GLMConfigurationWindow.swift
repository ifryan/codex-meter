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
        window.title = "配置 GLM Coding Plan"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        window.contentView = content
        let instructions = NSTextField(wrappingLabelWithString:
            "智谱国内版 · 输入 Coding Plan API Key。密钥仅保存在 macOS 钥匙串，用于查询额度。留空保存可一次性迁移旧授权，后续重装不再重复授权读取。")
        instructions.frame = NSRect(x: 24, y: 184, width: 432, height: 52)
        content.addSubview(instructions)
        keyField.placeholderString = "输入新的 API Key，或留空使用已保存的密钥"
        keyField.frame = NSRect(x: 24, y: 140, width: 432, height: 26)
        keyField.setAccessibilityLabel("GLM Coding Plan API Key")
        content.addSubview(keyField)
        statusLabel.frame = NSRect(x: 24, y: 73, width: 432, height: 56)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)
        let remove = NSButton(title: "移除配置", target: self, action: #selector(removeKey))
        remove.frame = NSRect(x: 20, y: 22, width: 100, height: 32)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 248, y: 22, width: 80, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存并连接", target: self, action: #selector(saveKey))
        save.frame = NSRect(x: 334, y: 22, width: 126, height: 32)
        save.keyEquivalent = "\r"
        [remove, cancel, save].forEach { $0.bezelStyle = .rounded; content.addSubview($0) }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { keyField.stringValue = "" }

    func present() {
        keyField.stringValue = ""
        statusLabel.stringValue = "保存后将立即查询；连接结果显示在刘海明细中。"
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
