// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

actor MonitorFetchLimit {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
}

@MainActor
final class MonitorEngine: ObservableObject {
    @Published private(set) var revision = 0
    @Published var message: String?
    @Published private(set) var scanStatus = L("Local log collection is off")
    @Published private(set) var scanning = false
    let repository: AccountRepository
    let isDemo: Bool
    private(set) var history: UsageHistory?
    private var states: [UUID: UsageLoader<MonitorSnapshot>] = [:]
    private var nextRefresh: [UUID: Date] = [:]
    private var failureCounts: [UUID: Int] = [:]
    private let adapter = MonitorAdapter()
    private let limit = MonitorFetchLimit()
    private let scanner = UsageLogScanner()
    private let notifier = QuotaResetNotifier()
    private var scanTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    var configuration: MonitorConfiguration { repository.configuration }
    var accounts: [SourceAccount] { configuration.accounts }
    var refreshing: Bool { states.values.contains { $0.isLoading } }

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        repository = AccountRepository(demo: isDemo)
        message = repository.loadError
        if !isDemo {
            do { history = try UsageHistory() }
            catch { message = L("Couldn't open the local history database. Live queries still work: %@", "\(error.localizedDescription)") }
        }
        for account in accounts { states[account.id] = UsageLoader() }
    }

    func start() {
        if isDemo {
            for (index, account) in accounts.enumerated() {
                let window = RateWindow(usedPercent: [48, 28, 64][index % 3], durationMinutes: 300,
                                        resetsAt: Date().addingTimeInterval(Double(index + 1) * 3_600))
                let weekly = RateWindow(usedPercent: 12 + index * 4, durationMinutes: 10_080, resetsAt: Date().addingTimeInterval(4 * 86_400))
                states[account.id]?.seed(MonitorSnapshot(accountID: account.id, sourceID: account.sourceID,
                    metrics: [.window(id: "five-hour", title: L("5 hours"), window: window), .window(id: "weekly", title: L("Weekly"), window: weekly)], plan: "DEMO"))
            }
            changed(); return
        }
        notifier.prepare()
        startupTask = Task { [weak self] in
            guard let self else { return }
            for account in accounts where account.enabled {
                guard !Task.isCancelled else { return }
                if let cached = try? await history?.latest(account.id), cached.credentialRevision == account.credentialRevision,
                   !Task.isCancelled, accounts.contains(account), states[account.id]?.snapshot == nil {
                    states[account.id]?.seed(cached)
                } else if account.sourceID == "claude", account.legacyCredentials,
                          let cached = ClaudeSnapshotCache().load(), states[account.id]?.snapshot == nil {
                    let metrics = [cached.fiveHour.map { MonitorMetric.window(id: "five-hour", title: L("5 hours"), window: $0) },
                                   cached.sevenDay.map { MonitorMetric.window(id: "weekly", title: L("Weekly"), window: $0) }].compactMap { $0 }
                    states[account.id]?.seed(MonitorSnapshot(accountID: account.id, sourceID: account.sourceID, metrics: metrics, fetchedAt: cached.capturedAt, credentialRevision: account.credentialRevision))
                }
            }
            changed()
            refresh(force: true)
        }
    }

    func stop() {
        startupTask?.cancel(); scanTask?.cancel()
        for state in states.values { state.cancel() }
    }

    func snapshot(_ id: UUID) -> MonitorSnapshot? { states[id]?.snapshot }
    func status(_ id: UUID) -> String {
        guard let state = states[id] else { return L("Not configured") }
        if state.isLoading { return L("Refreshing…") }
        if let error = state.error { return error.localizedDescription }
        if let date = state.snapshot?.fetchedAt { return L("Updated ") + DetailTimeFormatter.timestamp(date, seconds: true) }
        return L("Not connected")
    }

    func refresh(force: Bool = false) {
        guard !isDemo else { return }
        for account in accounts where account.enabled {
            guard force || (nextRefresh[account.id] ?? .distantPast) <= Date(), let state = states[account.id] else { continue }
            let adapter = self.adapter
            let limit = self.limit
            state.refresh(fetch: {
                await limit.acquire()
                do {
                    try Task.checkCancellation()
                    var result = try await adapter.fetch(account)
                    result.credentialRevision = account.credentialRevision
                    await limit.release()
                    return result
                } catch {
                    await limit.release()
                    throw error
                }
            }, onSuccess: { [weak self] previous, current in
                self?.received(current, previous: previous, account: account)
            }, onChange: { [weak self, weak state] in
                guard let self, let state else { return }
                if !state.isLoading {
                    if state.error != nil {
                        if let error = state.error as? MonitorError, error == .http(401) || error == .http(403) {
                            AccountSecrets.shared.invalidate(account.id)
                        }
                        let count = min(6, (self.failureCounts[account.id] ?? 0) + 1)
                        self.failureCounts[account.id] = count
                        self.nextRefresh[account.id] = Date().addingTimeInterval(max(Double(account.refreshMinutes) * 60, pow(2, Double(count)) * 30))
                    }
                }
                self.changed()
            })
        }
        scanLogs()
    }

    private func received(_ snapshot: MonitorSnapshot, previous: MonitorSnapshot?, account: SourceAccount) {
        failureCounts[account.id] = 0
        nextRefresh[account.id] = Date().addingTimeInterval(Double(account.refreshMinutes) * 60)
        let sameIdentity = previous?.identity == snapshot.identity
            && (!(account.authentication == .local || account.authentication == .oauthFile) || snapshot.identity != nil)
        for metric in snapshot.metrics where metric.kind == .quota && sameIdentity {
            guard let old = previous?.metrics.first(where: { $0.id == metric.id }),
                  let oldPercent = old.remainingPercent, let newPercent = metric.remainingPercent,
                  let event = QuotaResetDetector.detect(
                    previous: RateWindow(usedPercent: 100 - oldPercent, durationMinutes: old.durationMinutes, resetsAt: old.resetsAt),
                    current: RateWindow(usedPercent: 100 - newPercent, durationMinutes: metric.durationMinutes, resetsAt: metric.resetsAt), at: snapshot.fetchedAt) else { continue }
            notifier.notify(event, account: account, metric: metric)
        }
        Task { [weak self] in
            guard let self, let history, accounts.first(where: { $0.id == account.id })?.credentialRevision == snapshot.credentialRevision else { return }
            do {
                try await history.record(snapshot)
                try await history.insert(snapshot.usageEvents)
                if account.sourceID == "cc-switch", !account.credentialPath.isEmpty {
                    let events = try await UsageImport.read(account.credentialPath, accountID: account.id)
                    let prices = configuration.prices
                    try await history.insert(events.map { event in var event = event; event.price(using: prices); return event })
                }
                try await history.prune(days: configuration.historyDays)
            } catch { message = error.localizedDescription }
        }
    }

    func save(_ proposedAccount: SourceAccount, secrets: [String: String]? = nil) async throws {
        var account = proposedAccount
        guard !isDemo else { throw MonitorError.message(L("Demo mode doesn't save configuration")) }
        if let error = repository.loadError { throw MonitorError.message(error) }
        guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MonitorError.message(L("Name this connection")) }
        if let custom = account.custom { try custom.validate() }
        let old = accounts.first { $0.id == account.id }
        if let old, old.sourceID != account.sourceID { throw MonitorError.message(L("To change the source, add a new connection, so account histories don't mix")) }
        if account.pinned && account.enabled && accounts.filter({ $0.id != account.id && $0.pinned && $0.enabled }).count >= 3 {
            throw MonitorError.message(L("You can pin up to 3. Unpin another one first"))
        }
        if account.authentication == .local && ["codex", "claude", "cursor", "copilot", "kiro", "windsurf"].contains(account.sourceID),
           accounts.contains(where: { $0.id != account.id && $0.enabled && $0.sourceID == account.sourceID && $0.authentication == .local && $0.credentialPath == account.credentialPath }) {
            throw MonitorError.message(L("This local sign-in is already added. For another account, choose separate credentials or a different profile file"))
        }
        let identityChanged = secrets != nil || old?.authentication != account.authentication || old?.credentialPath != account.credentialPath
            || old?.endpoint != account.endpoint || old?.custom != account.custom
        if identityChanged { account.credentialRevision = UUID() }
        var proposed = configuration
        if let index = proposed.accounts.firstIndex(where: { $0.id == account.id }) { proposed.accounts[index] = account }
        else { proposed.accounts.append(account) }
        let previousSecrets: [String: String]?
        if secrets != nil { previousSecrets = try AccountSecrets.shared.read(account.id, interactive: true) }
        else { previousSecrets = nil }
        if let secrets { try AccountSecrets.shared.save(secrets, for: account.id) }
        do { try repository.save(proposed) }
        catch {
            if let previousSecrets {
                if previousSecrets.isEmpty { try? AccountSecrets.shared.remove(account.id) }
                else { try? AccountSecrets.shared.save(previousSecrets, for: account.id) }
            }
            throw error
        }
        if identityChanged {
            states[account.id]?.invalidate()
            do { try await history?.forgetSnapshots(account.id) }
            catch { message = L("Connection saved, but clearing the old cache didn't finish: %@", "\(error.localizedDescription)") }
        }
        guard accounts.first(where: { $0.id == account.id })?.credentialRevision == account.credentialRevision else { return }
        if states[account.id] == nil { states[account.id] = UsageLoader() }
        if !account.enabled { states[account.id]?.cancel() }
        nextRefresh[account.id] = .distantPast
        changed(); refresh()
    }

    func remove(_ id: UUID) async throws {
        guard !isDemo else { throw MonitorError.message(L("Demo mode doesn't change configuration")) }
        if let error = repository.loadError { throw MonitorError.message(error) }
        let previous = configuration
        var proposed = configuration
        proposed.accounts.removeAll { $0.id == id }
        proposed.logAccountIDs = proposed.logAccountIDs.filter { $0.value != id }
        try repository.save(proposed)
        do { try AccountSecrets.shared.remove(id) }
        catch {
            try? repository.save(previous)
            changed()
            throw error
        }
        states.removeValue(forKey: id)?.invalidate()
        nextRefresh.removeValue(forKey: id)
        do { try await history?.forgetSnapshots(id) }
        catch { message = L("Connection removed, but clearing the old cache didn't finish: %@", "\(error.localizedDescription)") }
        changed()
    }

    func reorder(_ ids: [UUID]) {
        var proposed = configuration
        let visible = ids.compactMap { id in accounts.first { $0.id == id } }
        proposed.accounts = visible + accounts.filter { !ids.contains($0.id) }
        do { try repository.save(proposed); changed() } catch { message = error.localizedDescription }
    }

    func saveStatistics(logs: Bool, roots: [String: String], bindings: [String: UUID], prices: [ModelPrice], retention: Int) throws {
        guard !isDemo else { throw MonitorError.message(L("Demo mode doesn't save configuration")) }
        guard prices.allSatisfy({ !$0.model.isEmpty && !$0.currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.inputPerMillion.isNaN && !$0.outputPerMillion.isNaN && $0.inputPerMillion >= 0 && $0.outputPerMillion >= 0 }) else {
            throw MonitorError.message(L("Model prices need an exact model name and non-negative values"))
        }
        guard Set(prices.map(\.model)).count == prices.count,
              prices.allSatisfy({ [$0.cacheReadPerMillion, $0.cacheWritePerMillion].compactMap { $0 }.allSatisfy { !$0.isNaN && $0 >= 0 } }) else {
            throw MonitorError.message(L("Model names must be unique, and cache prices can't be negative"))
        }
        var proposed = configuration
        proposed.logsEnabled = logs; proposed.logRoots = roots; proposed.logAccountIDs = bindings
        proposed.prices = prices.map { price in
            var next = price
            if let previous = configuration.prices.first(where: { $0.id == price.id }), previous != price {
                next.version = MonitorFormat.manualPriceVersionPrefix + ISO8601DateFormatter().string(from: Date())
            }
            return next
        }
        proposed.historyDays = retention
        try repository.save(proposed)
        let previous = scanTask
        previous?.cancel()
        Task { [weak self] in
            await previous?.value
            guard let self else { return }
            scanning = false; scanTask = nil
            changed(); scanLogs()
        }
        changed()
    }

    func clearHistory() async throws {
        guard !isDemo else { return }
        scanTask?.cancel()
        await scanTask?.value
        try await history?.clear()
        changed()
    }

    func reimportLogs() async throws {
        guard !isDemo else { return }
        scanTask?.cancel()
        await scanTask?.value
        try await history?.resetImportPositions()
        scanning = false
        scanLogs()
    }

    func scanLogs() {
        guard !isDemo, configuration.logsEnabled, let history, !scanning else { return }
        let configuration = self.configuration
        scanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { scanning = false }
            do { scanStatus = try await scanner.scan(configuration: configuration, history: history) }
            catch is CancellationError { return }
            catch { scanStatus = error.localizedDescription }
            changed()
        }
    }

    func pinned(now: Date = Date()) -> [PinnedReading] {
        accounts.filter { $0.enabled && $0.pinned }.prefix(3).map { account in
            let snapshot = states[account.id]?.snapshot
            let metric = account.primary(in: snapshot)
            let secondary = metric?.kind == .quota && metric?.durationMinutes == 300 && account.primaryMetricID == nil
                ? snapshot?.metrics.filter({ $0.durationMinutes == 10_080 && $0.kind == .quota && $0.primaryEligible })
                    .min(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }) : nil
            var value = metric?.compact ?? "--"
            if let secondary { value += "/" + secondary.compact }
            let reset = metric?.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) } ?? ""
            let secondReset = secondary?.resetsAt.map { CompactTimeFormatter.text(until: $0, now: now) }
            return PinnedReading(accountID: account.id, title: account.name + (metric.map { " · " + $0.title } ?? ""), value: value,
                subtitle: reset + (secondReset.map { "/" + $0 } ?? ""), percent: metric?.remainingPercent,
                secondaryPercent: secondary?.remainingPercent, refreshing: states[account.id]?.isLoading ?? false)
        }
    }

    func sections(now: Date = Date()) -> [MonitorSection] {
        accounts.filter(\.enabled).map { account in
            let state = states[account.id]
            let snapshot = state?.snapshot
            var rows = snapshot?.metrics.map { metric in
                MonitorDetailRow(title: metric.title, value: metric.formatted,
                    detail: [metric.resetsAt.map { L("Resets ") + DetailTimeFormatter.reset($0, now: now) }, metric.origin.title].compactMap { $0 }.joined(separator: " · "))
            } ?? []
            rows += snapshot?.detailRows ?? []
            if let identity = snapshot?.identity { rows.append(.init(title: L("Account"), value: identity)) }
            if let coverage = snapshot?.coverage { rows.append(.init(title: L("Coverage"), value: coverage)) }
            if let date = snapshot?.fetchedAt {
                rows.append(.init(title: L("Data time"), value: DetailTimeFormatter.timestamp(date, seconds: true)))
                if state?.error != nil || now.timeIntervalSince(date) > max(StalenessFormatter.freshnessThreshold, Double(account.refreshMinutes) * 120) {
                    rows.append(.init(title: L("Data status"), value: L("Last successful data, may be stale")))
                }
            }
            if state?.isLoading == true || state?.error != nil || rows.isEmpty { rows.append(.init(title: L("Status"), value: status(account.id))) }
            return MonitorSection(accountID: account.id, title: account.name, plan: snapshot?.plan, rows: rows)
        }
    }

    func footer() -> String {
        if let error = repository.loadError { return error }
        let latest = accounts.filter(\.enabled).compactMap { states[$0.id]?.snapshot?.fetchedAt }.max()
        return latest.map { L("Last updated ") + DetailTimeFormatter.timestamp($0, seconds: true) } ?? L("Add and enable a source in Connections")
    }

    private func changed() { revision += 1; onChange?() }
}
