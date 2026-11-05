// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OSLog
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.meterline",
        category: "usage"
    )
    private let isDemoMode = AppEnvironment.isDemo
    private let monitor = MonitorEngine(isDemo: AppEnvironment.isDemo)
    private var notchPanel: NotchPanelController!
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var connectionsWindow: ConnectionsWindow?
    private var statisticsWindow: StatisticsWindow?
    private var launchAtLoginError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchPanel = NotchPanelController(menuProvider: { [weak self] in self?.makeMenu() ?? NSMenu() }, orderChanged: { _ in })
        monitor.onChange = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        render()
        monitor.start()
        guard !isDemoMode else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.monitor.refresh() }
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.onChange = nil
        monitor.stop()
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        notchPanel?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func render(now: Date = Date()) {
        guard notchPanel != nil else { return }
        notchPanel.setMonitor(readings: monitor.pinned(now: now), sections: monitor.sections(now: now)) { [weak self] order in
            self?.monitor.reorder(order)
        }
        notchPanel.setUpdateText(monitor.footer() + (monitor.refreshing ? L(" · Refreshing…") : ""))
    }

    @objc private func configureConnections() {
        if connectionsWindow == nil { connectionsWindow = ConnectionsWindow(engine: monitor) }
        connectionsWindow?.present()
    }

    @objc private func showStatistics() {
        if statisticsWindow == nil { statisticsWindow = StatisticsWindow(engine: monitor) }
        statisticsWindow?.present()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refreshItem = NSMenuItem(title: monitor.refreshing ? L("Refreshing…") : L("Refresh now"), action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !monitor.refreshing
        menu.addItem(refreshItem)

        let connectionsItem = NSMenuItem(title: L("Connections…"), action: #selector(configureConnections), keyEquivalent: ",")
        connectionsItem.target = self
        connectionsItem.isEnabled = true
        menu.addItem(connectionsItem)

        let statisticsItem = NSMenuItem(title: L("Usage statistics…"), action: #selector(showStatistics), keyEquivalent: "u")
        statisticsItem.target = self
        menu.addItem(statisticsItem)

        let openItem = NSMenuItem(title: L("Open Codex"), action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let loginItem = NSMenuItem(title: launchAtLoginTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        if let launchAtLoginError { addDisabled(launchAtLoginError, to: menu) }
        menu.addItem(makeLanguageItem())

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit Meterline"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func makeLanguageItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let current = LanguagePreference.current
        let choices: [(code: String?, name: String)] = [(nil, L("Follow System"))] + LanguagePreference.options.map { ($0.code, $0.name) }
        for choice in choices {
            let item = NSMenuItem(title: choice.name, action: #selector(selectLanguage), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.code
            item.state = choice.code == current ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        // Demo mode saves nothing, and its restart would start the app with real data.
        item.isEnabled = !isDemoMode
        return item
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        guard code != LanguagePreference.current else { return }
        LanguagePreference.set(code)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Restart Meterline to change the language")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }

    /// The app allows one running instance, so the new one starts only after this one has exited.
    private func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$1\"",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            logger.error("Failed to restart: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func launchAtLoginTitle() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return L("Turn off launch at login")
        case .requiresApproval: return L("Approve launch at login in System Settings…")
        case .notRegistered, .notFound: return L("Launch at login")
        @unknown default: return L("Launch at login")
        }
    }

    @objc private func refreshFromMenu() { monitor.refresh(force: true) }
    @objc private func screenParametersChanged() { notchPanel.reposition() }
    @objc private func systemDidWake() { monitor.refresh(force: true) }

    @objc private func toggleLaunchAtLogin() {
        launchAtLoginError = nil
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } catch {
            launchAtLoginError = L("Couldn't change launch at login: %@", "\(error.localizedDescription)")
            logger.error("Failed to update launch-at-login: \(error.localizedDescription, privacy: .private)")
        }
    }

    @objc private func openCodex() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app")
        ]
        guard let application = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            launchAtLoginError = L("Codex or ChatGPT app not found")
            return
        }
        NSWorkspace.shared.open(application)
    }

    @objc private func quit() { NSApp.terminate(nil) }

}
