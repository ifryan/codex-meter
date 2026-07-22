// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import OSLog
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum LoadState {
        case idle
        case loading(previous: UsageSnapshot?)
        case loaded(UsageSnapshot)
        case failed(error: Error, previous: UsageSnapshot?)

        var snapshot: UsageSnapshot? {
            switch self {
            case .idle: return nil
            case .loading(let previous): return previous
            case .loaded(let snapshot): return snapshot
            case .failed(_, let previous): return previous
            }
        }

        var error: Error? {
            if case .failed(let error, _) = self { return error }
            return nil
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.codexmeter",
        category: "usage"
    )
    private let usageClient = CodexUsageClient()
    private var notchPanel: NotchPanelController!
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var state: LoadState = .idle
    private var launchAtLoginError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchPanel = NotchPanelController { [weak self] in self?.makeMenu() ?? NSMenu() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        render()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        notchPanel?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func refresh() {
        guard !state.isLoading else { return }
        let previous = state.snapshot
        state = .loading(previous: previous)
        render()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await usageClient.fetch()
                guard !Task.isCancelled else { return }
                state = .loaded(snapshot)
                logger.info("Fetched Codex usage successfully")
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error: error, previous: previous)
                logger.error("Failed to fetch Codex usage: \(error.localizedDescription, privacy: .private)")
            }
            render()
        }
    }

    private func render(now: Date = Date()) {
        guard notchPanel != nil else { return }
        guard let snapshot = state.snapshot else {
            notchPanel.setRemainingPercent(nil)
            notchPanel.setResetText("--H")
            notchPanel.setResetCredits([ResetCreditDisplayRow(title: "暂无可用重置卡", expiry: "--")])
            return
        }

        notchPanel.setRemainingPercent(snapshot.main.primary?.remainingPercent)
        if let resetAt = snapshot.main.primary?.resetsAt {
            notchPanel.setResetText(CompactTimeFormatter.text(until: resetAt, now: now))
        } else {
            notchPanel.setResetText("--H")
        }
        notchPanel.setResetCredits(ResetCreditRowBuilder.rows(for: snapshot, now: now))
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(title: headingText(), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        if state.isLoading {
            addDisabled("正在刷新…", to: menu)
        }
        if let error = state.error {
            addDisabled("最近一次刷新失败", to: menu)
            addDisabled((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, to: menu)
            if state.snapshot != nil { addDisabled("当前显示最后一次成功读取的数据", to: menu) }
            menu.addItem(.separator())
        }

        if let snapshot = state.snapshot {
            append(bucket: snapshot.main, title: "Codex", to: menu)
            for bucket in snapshot.buckets where bucket.id != snapshot.main.id {
                menu.addItem(.separator())
                append(bucket: bucket, title: bucket.name ?? bucket.id, to: menu)
            }
            if let count = snapshot.resetCreditCount {
                menu.addItem(.separator())
                addDisabled("重置卡  \(max(0, count)) 张", to: menu)
            }
            addDisabled("更新于  \(Self.timeFormatter.string(from: snapshot.fetchedAt))", to: menu)
        } else if state.error == nil {
            addDisabled("正在读取 Codex 余量…", to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: state.isLoading ? "正在刷新…" : "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !state.isLoading
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let loginItem = NSMenuItem(title: launchAtLoginTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        if let launchAtLoginError { addDisabled(launchAtLoginError, to: menu) }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Meter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func headingText() -> String {
        if let plan = state.snapshot?.plan { return "Codex 余量 · \(plan.uppercased())" }
        return "Codex 余量"
    }

    private func append(bucket: RateBucket, title: String, to menu: NSMenu) {
        addDisabled(title, to: menu)
        if let primary = bucket.primary {
            addDisabled(windowText(primary), to: menu)
        } else {
            addDisabled("暂无额度窗口", to: menu)
        }
        if let secondary = bucket.secondary { addDisabled(windowText(secondary), to: menu) }
    }

    private func windowText(_ window: RateWindow) -> String {
        let label = durationLabel(window.durationMinutes)
        let reset = window.resetsAt.map { Self.resetFormatter.string(from: $0) } ?? "未知"
        return "\(label)  剩余 \(window.remainingPercent)% · \(reset) 重置"
    }

    private func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) 周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func launchAtLoginTitle() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "关闭开机自动启动"
        case .requiresApproval: return "在系统设置中批准开机启动…"
        case .notRegistered, .notFound: return "开机自动启动"
        @unknown default: return "开机自动启动"
        }
    }

    @objc private func refreshFromMenu() { refresh() }
    @objc private func screenParametersChanged() { notchPanel.reposition() }
    @objc private func systemDidWake() { refresh() }

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
            launchAtLoginError = "开机启动设置失败：\(error.localizedDescription)"
            logger.error("Failed to update launch-at-login: \(error.localizedDescription, privacy: .private)")
        }
    }

    @objc private func openCodex() {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app")
        ]
        guard let application = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            launchAtLoginError = "未找到 Codex 或 ChatGPT 应用"
            return
        }
        NSWorkspace.shared.open(application)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
