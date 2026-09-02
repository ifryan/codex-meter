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

    private enum ClaudeLoadState {
        case idle
        case loaded(ClaudeUsageSnapshot)
        case failed(error: Error, previous: ClaudeUsageSnapshot?)

        var snapshot: ClaudeUsageSnapshot? {
            switch self {
            case .idle: return nil
            case .loaded(let snapshot): return snapshot
            case .failed(_, let previous): return previous
            }
        }

        var error: Error? {
            if case .failed(let error, _) = self { return error }
            return nil
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.codexmeter",
        category: "usage"
    )
    private let usageClient = CodexUsageClient()
    private let claudeUsageClient = ClaudeUsageClient()
    private let resetNotifier = QuotaResetNotifier()
    private let isDemoMode = ProcessInfo.processInfo.arguments.contains("--demo")
        || ProcessInfo.processInfo.environment["CODEX_METER_DEMO"] == "1"
    private var notchPanel: NotchPanelController!
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var state: LoadState = .idle
    private var claudeState: ClaudeLoadState = .idle
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

        if isDemoMode {
            let now = Date()
            state = .loaded(Self.demoSnapshot(now: now))
            claudeState = .loaded(Self.demoClaudeSnapshot(now: now))
            render(now: now)
            return
        }

        resetNotifier.prepare()
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
        guard !isDemoMode else { return }
        guard !state.isLoading else { return }
        let previousCodex = state.snapshot
        let previousClaude = claudeState.snapshot
        state = .loading(previous: previousCodex)
        render()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            async let codex: Void = self.fetchCodex(previous: previousCodex)
            async let claude: Void = self.fetchClaude(previous: previousClaude)
            _ = await (codex, claude)
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private func fetchCodex(previous: UsageSnapshot?) async {
        do {
            let snapshot = try await usageClient.fetch()
            guard !Task.isCancelled else { return }
            if let resetEvent = QuotaResetDetector.detect(
                previous: previous?.main.primary,
                current: snapshot.main.primary,
                at: snapshot.fetchedAt
            ) {
                resetNotifier.notify(resetEvent, provider: .codex)
                logger.info(
                    "Detected Codex quota reset: \(resetEvent.previousRemainingPercent)% -> \(resetEvent.currentRemainingPercent)%"
                )
            }
            state = .loaded(snapshot)
            logger.info("Fetched Codex usage successfully")
        } catch is CancellationError {
        } catch {
            state = .failed(error: error, previous: previous)
            logger.error("Failed to fetch Codex usage: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func fetchClaude(previous: ClaudeUsageSnapshot?) async {
        do {
            let snapshot = try await claudeUsageClient.fetch()
            guard !Task.isCancelled else { return }
            if let event = QuotaResetDetector.detect(
                previous: previous?.fiveHour,
                current: snapshot.fiveHour,
                at: snapshot.capturedAt
            ) {
                resetNotifier.notify(event, provider: .claudeFiveHour)
            }
            if let event = QuotaResetDetector.detect(
                previous: previous?.sevenDay,
                current: snapshot.sevenDay,
                at: snapshot.capturedAt
            ) {
                resetNotifier.notify(event, provider: .claudeSevenDay)
            }
            claudeState = .loaded(snapshot)
            logger.info("Fetched Claude usage successfully")
        } catch is CancellationError {
        } catch {
            claudeState = .failed(error: error, previous: previous)
            logger.error("Failed to fetch Claude usage: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func render(now: Date = Date()) {
        guard notchPanel != nil else { return }

        let bucket = state.snapshot?.main
        notchPanel.setCodex(
            primary: meterValue(bucket?.primary, now: now),
            secondary: meterValue(bucket?.secondary, now: now)
        )
        notchPanel.setClaude(
            fiveHour: meterValue(claudeState.snapshot?.fiveHour, now: now),
            sevenDay: meterValue(claudeState.snapshot?.sevenDay, now: now)
        )

        notchPanel.setDetailRows(detailRows(now: now))
    }

    private func meterValue(_ window: RateWindow?, now: Date) -> MeterValue? {
        guard let window else { return nil }
        let resetText = window.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) } ?? "--H"
        return MeterValue(percent: window.remainingPercent, resetText: resetText)
    }

    private func detailRows(now: Date) -> [MeterDetailRow] {
        var rows: [MeterDetailRow] = []

        if let snapshot = state.snapshot {
            // Only the account-level `main` bucket is shown — `snapshot.buckets` also carries
            // per-model sub-limits (e.g. a specific model's 5-hour burst cap) that aren't part of
            // the plan's actual quota and were confusing users into thinking their plan had a
            // 5-hour window it doesn't.
            rows.append(contentsOf: codexRows(title: "Codex", bucket: snapshot.main, now: now))
            rows.append(DetailRowBuilder.codexResetCreditRow(for: snapshot, now: now))
        } else {
            rows.append(MeterDetailRow(title: "暂无可用重置卡", value: "--"))
        }

        if let claudeSnapshot = claudeState.snapshot {
            if let fiveHour = claudeSnapshot.fiveHour {
                rows.append(DetailRowBuilder.windowRow(title: "Claude 5H", window: fiveHour, now: now))
            }
            if let sevenDay = claudeSnapshot.sevenDay {
                rows.append(DetailRowBuilder.windowRow(title: "Claude 7D", window: sevenDay, now: now))
            }
        } else {
            let message = (claudeState.error as? LocalizedError)?.errorDescription ?? "正在读取 Claude 余量…"
            rows.append(MeterDetailRow(title: "Claude", value: message))
        }

        return rows
    }

    /// One row per window the bucket actually reports — a window that doesn't exist for this
    /// account (e.g. no weekly limit on this plan) is omitted rather than shown as unavailable.
    private func codexRows(title: String, bucket: RateBucket, now: Date) -> [MeterDetailRow] {
        [bucket.primary, bucket.secondary].compactMap { window in
            guard let window else { return nil }
            let label = "\(title) \(DurationLabelFormatter.label(window.durationMinutes))"
            return DetailRowBuilder.windowRow(title: label, window: window, now: now)
        }
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

        if state.snapshot != nil {
            for row in detailRows(now: Date()) {
                addDisabled("\(row.title)  \(row.value)", to: menu)
            }
            if let fetchedAt = state.snapshot?.fetchedAt {
                addDisabled("更新于  \(Self.timeFormatter.string(from: fetchedAt))", to: menu)
            }
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

    // MARK: - Demo data

    private static func demoSnapshot(now: Date) -> UsageSnapshot {
        // Matches a real Pro-plan account: a single weekly window, no 5-hour window.
        UsageSnapshot(
            plan: "pro",
            main: RateBucket(
                id: "codex",
                name: "Codex",
                primary: RateWindow(
                    usedPercent: 48,
                    durationMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(3 * 3_600)
                ),
                secondary: nil
            ),
            buckets: [],
            resetCreditCount: 3,
            resetCredits: [7, 14, 28].map {
                ResetCredit(expiresAt: now.addingTimeInterval(TimeInterval($0 * 86_400)))
            },
            fetchedAt: now
        )
    }

    private static func demoClaudeSnapshot(now: Date) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            fiveHour: RateWindow(usedPercent: 28, durationMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3_600)),
            sevenDay: RateWindow(usedPercent: 12, durationMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400)),
            capturedAt: now
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
