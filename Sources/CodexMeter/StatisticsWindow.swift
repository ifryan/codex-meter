// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Charts

@MainActor
final class StatisticsWindow: NSWindowController {
    init(engine: MonitorEngine) {
        let window = MonitorSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex Meter · 用量统计"
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
                Text("用量统计").font(.title.bold())
                Spacer()
                Picker("时间", selection: $days) { Text("今天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30) }.pickerStyle(.segmented).frame(width: 220)
                Button("采集与价格设置") { settings = true }
                Button("刷新") { engine.scanLogs(); refreshToken = UUID() }
            }
            HStack {
                Picker("数据来源", selection: $dataset) { ForEach(UsageDataset.allCases) { Text($0.title).tag($0) } }.frame(width: 250)
                Picker("分组", selection: $grouping) { ForEach(UsageGrouping.allCases) { Text($0.title).tag($0) } }.frame(width: 180)
                Spacer()
                Text(engine.scanning ? "正在增量读取…" : engine.scanStatus).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let report, !report.groups.isEmpty {
                        HStack(spacing: 28) {
                            summary("Token", value: MonitorFormat.amount(Decimal(report.groups.reduce(0) { $0 + $1.tokens }), unit: "tokens", compact: true))
                            summary("记录", value: String(report.groups.reduce(0) { $0 + $1.requests }))
                            summary("未计价记录", value: String(report.groups.reduce(0) { $0 + $1.unpriced }))
                        }
                        Text("Token 趋势").font(.headline)
                        Chart(report.days) { point in
                            BarMark(x: .value("日期", point.date, unit: .day), y: .value("Token", point.tokens))
                        }.frame(height: 180).chartXAxis { AxisMarks(values: .stride(by: .day, count: days > 7 ? 5 : 1)) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                            .environment(\.timeZone, reportCalendar.timeZone).environment(\.calendar, reportCalendar)
                        let currencies = Array(Set(report.days.flatMap { $0.costs.keys })).sorted()
                        ForEach(currencies, id: \.self) { key in
                            let parts = key.split(separator: "|").map(String.init)
                            let currency = parts.first ?? "USD"
                            let origin = parts.last.flatMap(MeasurementOrigin.init(rawValue:))?.title ?? "费用"
                            Text("\(currency) · \(origin)").font(.headline)
                            Chart(report.days) { point in
                                BarMark(x: .value("日期", point.date, unit: .day), y: .value(currency, NSDecimalNumber(decimal: point.costs[key] ?? 0).doubleValue))
                            }.frame(height: 140).environment(\.timeZone, reportCalendar.timeZone).environment(\.calendar, reportCalendar)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                            GridRow { Text(grouping.title).bold(); Text("Token").bold(); Text("费用").bold(); Text("口径").bold(); Text("未计价").bold() }
                            Divider().gridCellColumns(5)
                            ForEach(report.groups) { group in
                                GridRow {
                                    Text(label(group.label)).lineLimit(2)
                                    Text(MonitorFormat.amount(Decimal(group.tokens), unit: "tokens", compact: true)).monospacedDigit()
                                    Text(group.unpriced == group.requests ? "未知" : MonitorFormat.amount(group.cost, unit: group.currency)).monospacedDigit()
                                    Text(group.origin.title).foregroundStyle(.secondary)
                                    Text(String(group.unpriced))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(dataset == .provider
                             ? "服务商按 UTC 日汇总，记录数表示日账单／用量分组数；不代表请求次数。未按模型拆分的费用单独列出。"
                             : "按本机时区统计至当前时间。费用按币种与数据口径分开展示；未计价记录不视为免费。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("暂无用量记录", systemImage: "chart.bar", description: Text("启用本地日志、为 CC Switch 选择用量导出，或添加具有组织账单权限的 OpenAI / Anthropic 连接。额度查询与用量统计相互独立。"))
                    }
                    providerMetrics
                }.padding(.vertical, 8)
            }
            HStack {
                Text("日志、导出、服务商账单分别统计；账单按当前连接身份查看，避免重复汇总").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清除本地历史…", role: .destructive) { clearing = true }.disabled(engine.isDemo)
            }
        }.padding(24)
            .task(id: "\(days)|\(grouping.rawValue)|\(dataset.rawValue)|\(engine.revision)|\(refreshToken)") { await load() }
            .sheet(isPresented: $settings) { StatisticsSettingsView(engine: engine) }
            .confirmationDialog("清除本地统计与额度历史？保留连接、凭据和导入位置。", isPresented: $clearing) {
                Button("清除历史", role: .destructive) {
                    Task {
                        do { try await engine.clearHistory(); refreshToken = UUID() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
    }
    private var providerMetrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源返回的当前汇总").font(.headline)
            Text("按各来源自己的账期展示，与上方日志统计分开；同一 Key 与账户余额也不相加。").font(.caption).foregroundStyle(.secondary)
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
        guard grouping == .account else { return raw }
        return engine.accounts.first { $0.id.uuidString == raw }?.name ?? (raw == "未归属" ? raw : "已移除账户 " + String(raw.prefix(8)))
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
            Text("采集与价格设置").font(.title2.bold())
            ScrollView {
                Form {
                    Section("本地日志") {
                        Toggle("启用只读用量采集", isOn: $enabled)
                        Text("只保存时间、工具、模型、Token 和费用等用量字段，不保存提示词、回复和代码。默认不猜测账户归属。").font(.caption).foregroundStyle(.secondary)
                        ForEach(UsageLogScanner.defaults.keys.sorted(), id: \.self) { tool in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tool).font(.headline)
                                TextField(UsageLogScanner.defaults[tool]!, text: Binding(get: { roots[tool] ?? UsageLogScanner.defaults[tool]! }, set: { roots[tool] = $0 }))
                                Picker("这些日志归属", selection: Binding<UUID?>(get: { bindings[tool] }, set: { bindings[tool] = $0 })) {
                                    Text("未归属").tag(Optional<UUID>.none)
                                    ForEach(engine.accounts) { account in Text(account.name).tag(Optional(account.id)) }
                                }
                            }.padding(.vertical, 5)
                        }
                        Stepper("保留 \(retention) 天历史", value: $retention, in: 30...730, step: 30)
                    }
                    Section("模型估算价格 · 每百万 Token") {
                        Text("模型名精确匹配；没有价格或缺少缓存价格时保留未知。订阅按 API 价估算的费用不代表实付账单。").font(.caption).foregroundStyle(.secondary)
                        ForEach($prices) { $price in
                            VStack(spacing: 8) {
                                HStack { TextField("精确模型名", text: $price.model); TextField("币种", text: $price.currency).frame(width: 70); Button("移除", role: .destructive) { prices.removeAll { $0.id == price.id } } }
                                HStack {
                                    TextField("输入单价", value: $price.inputPerMillion, format: .number)
                                    TextField("输出单价", value: $price.outputPerMillion, format: .number)
                                }
                                HStack {
                                    TextField("缓存读取（可选）", text: decimalBinding(price.id, \.cacheReadPerMillion))
                                    TextField("缓存写入（可选）", text: decimalBinding(price.id, \.cacheWritePerMillion))
                                }
                            }.padding(.vertical, 6)
                        }
                        Button("添加模型价格") { prices.append(ModelPrice(model: "", inputPerMillion: 0, outputPerMillion: 0, version: ISO8601DateFormatter().string(from: Date()))) }
                        Button(downloadingPrices ? "正在下载价格…" : "从 models.dev 补充价格") {
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
                        Text("只在点击时访问 models.dev 获取 OpenAI / Anthropic / Google 官方目录价格；已有配置优先保留，需点击保存生效。").font(.caption).foregroundStyle(.secondary)
                        Button("重新导入日志，补全未计价记录") {
                            Task { do { try await engine.reimportLogs() } catch { self.error = error.localizedDescription } }
                        }.disabled(engine.scanning)
                        Text("先保存价格再重新导入；既有已计价记录保留其价格版本。").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
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
