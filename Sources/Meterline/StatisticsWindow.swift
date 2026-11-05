// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Charts

@MainActor
final class StatisticsWindow: NSWindowController {
    init(engine: MonitorEngine) {
        let window = MonitorSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Meterline · Usage statistics")
        window.minSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StatisticsView(engine: engine))
        window.center(); super.init(window: window)
    }
    required init?(coder: NSCoder) { return nil }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

@MainActor
struct StatisticsView: View {
    @ObservedObject var engine: MonitorEngine
    @State private var days = 7
    @State private var grouping: UsageGrouping = .tool
    @State private var dataset: UsageDataset = .local
    @State private var report: UsageReport?
    @State private var error: String?
    @State private var settings = false
    @State private var clearing = false
    @State private var refreshToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("Usage statistics")).font(.title.bold())
                Spacer()
                Picker(L("Period"), selection: $days) { Text(L("Today")).tag(1); Text(L("7 days")).tag(7); Text(L("30 days")).tag(30) }.pickerStyle(.segmented).frame(width: 220)
                Button(L("Collection and pricing")) { settings = true }
                Button(L("Refresh")) { engine.scanLogs(); refreshToken = UUID() }
            }
            HStack {
                Picker(L("Dataset"), selection: $dataset) { ForEach(UsageDataset.allCases) { Text($0.title).tag($0) } }.frame(width: 250)
                Picker(L("Group by"), selection: $grouping) { ForEach(UsageGrouping.allCases) { Text($0.title).tag($0) } }.frame(width: 180)
                Spacer()
                Text(engine.scanning ? L("Reading new entries…") : engine.scanStatus).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let report, !report.groups.isEmpty {
                        HStack(spacing: 28) {
                            summary("Token", value: MonitorFormat.amount(Decimal(report.groups.reduce(0) { $0 + $1.tokens }), unit: "tokens", compact: true))
                            summary(L("Records"), value: String(report.groups.reduce(0) { $0 + $1.requests }))
                            summary(L("Unpriced records"), value: String(report.groups.reduce(0) { $0 + $1.unpriced }))
                        }
                        Text(L("Token trend")).font(.headline)
                        Chart(report.days) { point in
                            BarMark(x: .value(L("Date"), point.date, unit: .day), y: .value("Token", point.tokens))
                        }.frame(height: 180).chartXAxis { AxisMarks(values: .stride(by: .day, count: days > 7 ? 5 : 1)) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                            .environment(\.timeZone, reportCalendar.timeZone).environment(\.calendar, reportCalendar)
                        let currencies = Array(Set(report.days.flatMap { $0.costs.keys })).sorted()
                        ForEach(currencies, id: \.self) { key in
                            let parts = key.split(separator: "|").map(String.init)
                            let currency = parts.first ?? "USD"
                            let origin = parts.last.flatMap(MeasurementOrigin.init(rawValue:))?.title ?? L("Cost")
                            Text("\(currency) · \(origin)").font(.headline)
                            Chart(report.days) { point in
                                BarMark(x: .value(L("Date"), point.date, unit: .day), y: .value(currency, NSDecimalNumber(decimal: point.costs[key] ?? 0).doubleValue))
                            }.frame(height: 140).environment(\.timeZone, reportCalendar.timeZone).environment(\.calendar, reportCalendar)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                            GridRow { Text(grouping.title).bold(); Text("Token").bold(); Text(L("Cost")).bold(); Text(L("Basis")).bold(); Text(L("Unpriced")).bold() }
                            Divider().gridCellColumns(5)
                            ForEach(report.groups) { group in
                                GridRow {
                                    Text(label(group.label)).lineLimit(2)
                                    Text(MonitorFormat.amount(Decimal(group.tokens), unit: "tokens", compact: true)).monospacedDigit()
                                    Text(group.unpriced == group.requests ? L("Unknown") : MonitorFormat.amount(group.cost, unit: group.currency)).monospacedDigit()
                                    Text(group.origin.title).foregroundStyle(.secondary)
                                    Text(String(group.unpriced))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(dataset == .provider
                             ? L("Providers report by UTC day. Records count daily billing or usage groups, not requests. Costs not split by model are listed separately.")
                             : L("Counted up to now in the local time zone. Costs are shown separately by currency and basis. Unpriced records don't count as free.")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView(L("No usage records yet"), systemImage: "chart.bar", description: Text(L("Turn on local logs, choose a CC Switch usage export, or add an OpenAI or Anthropic connection with organization billing access. Quota queries and usage statistics are independent.")))
                    }
                    providerMetrics
                }.padding(.vertical, 8)
            }
            HStack {
                Text(L("Logs, exports, and provider bills are counted separately. Bills follow the current connection's identity, so nothing is counted twice")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Clear local history…"), role: .destructive) { clearing = true }.disabled(engine.isDemo)
            }
        }.padding(24)
            .task(id: "\(days)|\(grouping.rawValue)|\(dataset.rawValue)|\(engine.revision)|\(refreshToken)") { await load() }
            .sheet(isPresented: $settings) { StatisticsSettingsView(engine: engine) }
            .confirmationDialog(L("Clear local statistics and quota history? Connections, credentials, and import positions are kept."), isPresented: $clearing) {
                Button(L("Clear history"), role: .destructive) {
                    Task {
                        do { try await engine.clearHistory(); refreshToken = UUID() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
    }
    private var providerMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Current totals from sources")).font(.headline)
            Text(L("Shown in each source's own billing period, separate from the log statistics above. A key's balance and the account balance aren't added together.")).font(.caption).foregroundStyle(.secondary)
            ForEach(engine.accounts.filter(\.enabled)) { account in
                let metrics = engine.snapshot(account.id)?.metrics.filter { $0.kind != .quota } ?? []
                if !metrics.isEmpty {
                    GroupBox(account.name) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(metrics) { metric in
                                LabeledContent(metric.title, value: metric.formatted)
                                if let start = metric.periodStart, let end = metric.periodEnd {
                                    Text(start.formatted(date: .abbreviated, time: .omitted) + " – " + end.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).foregroundStyle(.secondary); Text(value).font(.title2.monospacedDigit().bold()) }
    }
    private var reportCalendar: Calendar {
        guard dataset == .provider else { return .current }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func label(_ raw: String) -> String {
        guard grouping == .account else { return StoredLabel.display(raw) }
        return engine.accounts.first { $0.id.uuidString == raw }?.name ?? (raw == StoredLabel.unattributed ? StoredLabel.display(raw) : L("Removed account ") + String(raw.prefix(8)))
    }
    private func load() async {
        guard let history = engine.history else { return }
        do {
            let scopes = Dictionary(uniqueKeysWithValues: engine.accounts.map { ($0.id, $0.credentialRevision) })
            let result = try await history.report(days: days, grouping: grouping, dataset: dataset, activeProviderScopes: scopes)
            try Task.checkCancellation(); report = result; error = nil
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct StatisticsSettingsView: View {
    @ObservedObject var engine: MonitorEngine
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var roots: [String: String]
    @State private var bindings: [String: UUID]
    @State private var prices: [ModelPrice]
    @State private var retention: Int
    @State private var downloadingPrices = false
    @State private var error: String?

    init(engine: MonitorEngine) {
        self.engine = engine
        let config = engine.configuration
        _enabled = State(initialValue: config.logsEnabled)
        _roots = State(initialValue: config.logRoots)
        _bindings = State(initialValue: config.logAccountIDs)
        _prices = State(initialValue: config.prices)
        _retention = State(initialValue: config.historyDays)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Collection and pricing")).font(.title2.bold())
            ScrollView {
                Form {
                    Section(L("Local logs")) {
                        Toggle(L("Enable read-only usage collection"), isOn: $enabled)
                        Text(L("Only usage fields such as time, tool, model, tokens, and cost are saved, never prompts, replies, or code. Accounts aren't guessed by default.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(UsageLogScanner.defaults.keys.sorted(), id: \.self) { tool in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tool).font(.headline)
                                TextField(UsageLogScanner.defaults[tool]!, text: Binding(get: { roots[tool] ?? UsageLogScanner.defaults[tool]! }, set: { roots[tool] = $0 }))
                                Picker(L("These logs belong to"), selection: Binding<UUID?>(get: { bindings[tool] }, set: { bindings[tool] = $0 })) {
                                    Text(L("Unattributed")).tag(Optional<UUID>.none)
                                    ForEach(engine.accounts) { account in Text(account.name).tag(Optional(account.id)) }
                                }
                            }.padding(.vertical, 5)
                        }
                        Stepper(L("Keep history for %@ days", "\(retention)"), value: $retention, in: 30...730, step: 30)
                    }
                    Section(L("Estimated model prices · Per million tokens")) {
                        Text(L("Model names must match exactly. Missing prices or cache prices stay unknown. Subscription costs estimated at API prices aren't what you actually pay.")).font(.caption).foregroundStyle(.secondary)
                        ForEach($prices) { $price in
                            VStack(spacing: 8) {
                                HStack { TextField(L("Exact model name"), text: $price.model); TextField(L("Currency"), text: $price.currency).frame(width: 70); Button(L("Remove"), role: .destructive) { prices.removeAll { $0.id == price.id } } }
                                HStack {
                                    TextField(L("Input price"), value: $price.inputPerMillion, format: .number)
                                    TextField(L("Output price"), value: $price.outputPerMillion, format: .number)
                                }
                                HStack {
                                    TextField(L("Cache read (optional)"), text: decimalBinding(price.id, \.cacheReadPerMillion))
                                    TextField(L("Cache write (optional)"), text: decimalBinding(price.id, \.cacheWritePerMillion))
                                }
                            }.padding(.vertical, 6)
                        }
                        Button(L("Add model price")) { prices.append(ModelPrice(model: "", inputPerMillion: 0, outputPerMillion: 0, version: ISO8601DateFormatter().string(from: Date()))) }
                        Button(downloadingPrices ? L("Downloading prices…") : L("Fill in prices from models.dev")) {
                            downloadingPrices = true
                            Task {
                                defer { downloadingPrices = false }
                                do {
                                    let downloaded = try await ModelPricing.download()
                                    let existing = Set(prices.map(\.model))
                                    prices.append(contentsOf: downloaded.filter { !existing.contains($0.model) })
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(downloadingPrices)
                        Text(L("models.dev is contacted only when you click this, to get official OpenAI, Anthropic, and Google catalog prices. Existing settings take priority. Click Save to apply.")).font(.caption).foregroundStyle(.secondary)
                        Button(L("Reimport logs to fill in unpriced records")) {
                            Task { do { try await engine.reimportLogs() } catch { self.error = error.localizedDescription } }
                        }.disabled(engine.scanning)
                        Text(L("Save prices before reimporting. Records that already have a price keep their price version.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    do {
                        try engine.saveStatistics(logs: enabled, roots: roots, bindings: bindings, prices: prices, retention: retention)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(engine.isDemo)
            }
        }.padding(24).frame(width: 780, height: 740)
    }
    private func decimalBinding(_ id: UUID, _ path: WritableKeyPath<ModelPrice, Decimal?>) -> Binding<String> {
        Binding(get: {
            guard let value = prices.first(where: { $0.id == id })?[keyPath: path] else { return "" }
            return NSDecimalNumber(decimal: value).stringValue
        }, set: { text in
            if let index = prices.firstIndex(where: { $0.id == id }) {
                prices[index][keyPath: path] = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            }
        })
    }
}
