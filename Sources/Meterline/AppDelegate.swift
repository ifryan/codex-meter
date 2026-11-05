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

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("Quit Meterline"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
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
