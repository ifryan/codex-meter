// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MonitorSettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let editor = firstResponder as? NSTextView {
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
final class ConnectionsWindow: NSWindowController {
    init(engine: MonitorEngine) {
        let window = MonitorSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Codex Meter · 连接"
        window.minSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ConnectionsView(engine: engine))
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { return nil }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

struct ConnectionTemplate: Codable {
    var version = 1
    var sourceID: String
    var name: String
    var endpoint: String
    var custom: CustomQuery?
}

@MainActor
struct ConnectionsView: View {
    @ObservedObject var engine: MonitorEngine
    @State private var search = ""
    @State private var editing: SourceAccount?
    @State private var error: String?
    @State private var statisticsSettings = false

    private var filtered: [SourceAccount] { engine.accounts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || (SourceRegistry.descriptor($0.sourceID)?.title.localizedCaseInsensitiveContains(search) ?? false) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接").font(.title.bold())
                    Text("添加你使用的账户，选择最多 3 项常驻刘海").foregroundStyle(.secondary)
                }
                Spacer()
                Button("统计设置") { statisticsSettings = true }
                Button("导入模板", action: importTemplate).disabled(engine.isDemo)
                Menu("添加连接") {
                    let discovered = SourceRegistry.discovered()
                    if !discovered.isEmpty {
                        Menu("发现本机工具") { ForEach(discovered) { source in Button(source.title) { add(source) } } }
                        Divider()
                    }
                    ForEach(Array(Set(SourceRegistry.all.map(\.category))).sorted(), id: \.self) { category in
                        Menu(category) {
                            ForEach(SourceRegistry.all.filter { $0.category == category }) { source in Button(source.title) { add(source) } }
                        }
                    }
                }.disabled(engine.isDemo)
            }
            TextField("搜索来源或账户", text: $search).textFieldStyle(.roundedBorder)
            if let error = error ?? engine.message { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if filtered.isEmpty {
                ContentUnavailableView("还没有连接", systemImage: "link", description: Text("从添加连接中选择来源，配置后可独立刷新和固定显示"))
            } else {
                List {
                    ForEach(filtered) { account in
                        HStack(spacing: 14) {
                            Image(systemName: account.pinned ? "pin.fill" : "circle").foregroundStyle(account.pinned ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.name).font(.headline)
                                Text(SourceRegistry.descriptor(account.sourceID)?.title ?? account.sourceID).font(.caption).foregroundStyle(.secondary)
                                Text(engine.status(account.id)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if let metric = account.primary(in: engine.snapshot(account.id)) { Text(metric.formatted).monospacedDigit() }
                            Toggle("启用", isOn: Binding(get: { account.enabled }, set: { enabled in var next = account; next.enabled = enabled; save(next) }))
                                .toggleStyle(.switch).fixedSize()
                            Button(account.pinned ? "取消固定" : "固定") { var next = account; next.pinned.toggle(); save(next) }.disabled(!account.enabled)
                            Button("编辑") { editing = account }
                            Menu {
                                Button("导出配置模板") { exportTemplate(account) }
                                Button("向上移动") { move(account, delta: -1) }
                                Button("向下移动") { move(account, delta: 1) }
                                Divider()
                                Button("移除连接", role: .destructive) {
                                    Task { do { try await engine.remove(account.id) } catch { self.error = error.localizedDescription } }
                                }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.vertical, 7).disabled(engine.isDemo)
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text("仅启用的连接参与查询 · 凭据保存在本机钥匙串").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新已启用连接") { engine.refresh(force: true) }.disabled(engine.isDemo)
            }
        }.padding(24)
            .sheet(item: $editing) { account in AccountEditorView(engine: engine, initial: account) }
            .sheet(isPresented: $statisticsSettings) { StatisticsSettingsView(engine: engine) }
    }

    private func add(_ source: SourceDescriptor) {
        editing = SourceAccount(sourceID: source.id, name: source.title, authentication: source.authentication.first ?? .token,
                                endpoint: source.defaultEndpoint, custom: source.customTemplate ?? (source.id == "custom" ? CustomQuery(url: "", mappings: [.init(title: "余额", kind: .balance, valuePath: "data.balance", unit: "USD")]) : nil))
    }
    private func save(_ account: SourceAccount) {
        Task { do { try await engine.save(account) } catch { self.error = error.localizedDescription } }
    }
    private func move(_ account: SourceAccount, delta: Int) {
        var ids = engine.accounts.map(\.id)
        guard let index = ids.firstIndex(of: account.id), ids.indices.contains(index + delta) else { return }
        ids.swapAt(index, index + delta); engine.reorder(ids)
    }
    private func importTemplate() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw MonitorError.message("模板超过大小限制") }
            let template = try JSONDecoder().decode(ConnectionTemplate.self, from: Data(contentsOf: url))
            guard template.version == 1, let source = SourceRegistry.descriptor(template.sourceID) else { throw MonitorError.message("模板版本或来源不受支持") }
            if let query = template.custom { try query.validate() }
            editing = SourceAccount(sourceID: template.sourceID, name: template.name, enabled: false,
                authentication: source.authentication.first ?? .token, endpoint: template.endpoint, custom: template.custom)
        } catch { self.error = error.localizedDescription }
    }
    private func exportTemplate(_ account: SourceAccount) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(account.sourceID)-template.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let custom = account.custom { try custom.validate() }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let template = ConnectionTemplate(sourceID: account.sourceID, name: account.name, endpoint: account.endpoint, custom: account.custom)
            try MonitorFiles.write(encoder.encode(template), to: url)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct AccountEditorView: View {
    @ObservedObject var engine: MonitorEngine
    @Environment(\.dismiss) private var dismiss
    @State private var account: SourceAccount
    @State private var enteredSecrets: [String: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var preview: MonitorSnapshot?
    @State private var responseStructure: [String] = []
    @State private var previewTask: Task<Void, Never>?
    @State private var cookieWindow: CookieLoginWindow?
    @StateObject private var copilot = CopilotDeviceLogin()
    @State private var headerText = ""

    init(engine: MonitorEngine, initial: SourceAccount) {
        self.engine = engine
        _account = State(initialValue: initial)
        _headerText = State(initialValue: (initial.custom?.headers ?? [:]).keys.sorted().map { $0 + ": " + (initial.custom?.headers[$0] ?? "") }.joined(separator: "\n"))
    }
    private var source: SourceDescriptor { SourceRegistry.descriptor(account.sourceID)! }
    private var secretNames: [String] {
        if account.authentication == .cookie { return ["cookie"] }
        if account.authentication == .local || account.authentication == .oauthFile { return [] }
        return source.secretFields
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(source.title).font(.title2.bold()); Spacer(); Text("连接设置").foregroundStyle(.secondary) }.padding(24)
            ScrollView {
                Form {
                    Section("账户") {
                        TextField("连接名称", text: $account.name)
                        Toggle("启用查询", isOn: $account.enabled)
                        Toggle("固定到刘海（最多 3 项）", isOn: $account.pinned)
                        Picker("登录方式", selection: $account.authentication) {
                            ForEach(source.authentication, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }
                        Text(source.help).font(.caption).foregroundStyle(.secondary)
                    }
                    if account.authentication == .oauthFile || (account.authentication == .local && !["claude", "copilot"].contains(account.sourceID)) {
                        Section(account.sourceID == "cc-switch" ? "导出文件" : "独立路径（留空使用默认位置）") {
                            TextField("文件或可执行文件路径", text: $account.credentialPath)
                            Button("选择文件…", action: selectFile)
                        }
                    }
                    if !secretNames.isEmpty {
                        Section("安全凭据 · 留空保留已有值") {
                            ForEach(secretNames, id: \.self) { name in
                                SecureField(secretLabel(name), text: Binding(get: { enteredSecrets[name] ?? "" }, set: { enteredSecrets[name] = $0 }))
                            }
                            if account.legacyCredentials { Text("尚未输入新凭据时，继续使用原有专属钥匙串配置").font(.caption).foregroundStyle(.secondary) }
                            if account.sourceID == "glm" {
                                Button("迁移旧 GLM 凭据") {
                                    do {
                                        guard let key = try GLMCredentialsStore().read(allowInteraction: true) else { throw MonitorError.notConfigured }
                                        enteredSecrets["token"] = key
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                            if engine.accounts.contains(where: { $0.id == account.id }) && !account.legacyCredentials {
                                Button("重新授权已保存凭据") {
                                    do {
                                        AccountSecrets.shared.invalidate(account.id)
                                        let saved = try AccountSecrets.shared.read(account.id, interactive: true)
                                        guard !saved.isEmpty else { throw MonitorError.notConfigured }
                                        try AccountSecrets.shared.save(saved, for: account.id)
                                        error = nil
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                            if account.authentication == .cookie && !source.dashboard.isEmpty {
                                Button("连接网页账户…") {
                                    cookieWindow = CookieLoginWindow(source: source) { value in enteredSecrets["cookie"] = value }
                                    cookieWindow?.present()
                                }
                            }
                            if account.sourceID == "copilot" {
                                Button(copilot.active ? "等待 GitHub 授权…" : "使用 GitHub 登录") {
                                    copilot.start { token in enteredSecrets["token"] = token }
                                }.disabled(copilot.active)
                                if !copilot.code.isEmpty { Text(copilot.code).font(.title.monospaced()).textSelection(.enabled) }
                                if !copilot.status.isEmpty { Text(copilot.status).font(.caption) }
                            }
                        }
                    } else if account.sourceID == "copilot" {
                        Button("连接额外 GitHub 账户") {
                            account.authentication = .token
                            copilot.start { token in enteredSecrets["token"] = token }
                        }
                    }
                    if ["magpie", "volcengine", "tencent"].contains(account.sourceID) {
                        Section(account.sourceID == "magpie" ? "服务地址" : "云服务区域") {
                            TextField(account.sourceID == "magpie" ? "http://127.0.0.1:3425" : account.sourceID == "tencent" ? "ap-guangzhou" : "cn-beijing", text: $account.endpoint)
                        }
                    }
                    if account.sourceID == "claude" {
                        Toggle("允许消耗少量推理额度的探测（默认关闭）", isOn: $account.allowsPaidProbe)
                    }
                    if account.custom != nil { customForm }
                    Section("显示与刷新") {
                        Picker("常驻主指标", selection: $account.primaryMetricID) {
                            Text("自动选择").tag(Optional<String>.none)
                            ForEach((preview ?? engine.snapshot(account.id))?.metrics ?? []) { metric in Text(metric.title).tag(Optional(metric.id)) }
                        }
                        Stepper("每 \(account.refreshMinutes) 分钟刷新", value: $account.refreshMinutes, in: 1...1_440)
                    }
                    if let preview {
                        Section("连接预览") {
                            ForEach(preview.metrics) { metric in LabeledContent(metric.title, value: metric.formatted) }
                            Text("预览只查询此连接；结果尚未保存").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !responseStructure.isEmpty {
                        Section("响应字段结构 · 不显示字段内容") {
                            Text(responseStructure.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.formStyle(.grouped).padding(.horizontal, 8)
            }
            HStack {
                if !source.dashboard.isEmpty, let url = URL(string: source.dashboard) { Link("打开服务商", destination: url) }
                Spacer()
                Button("取消") { previewTask?.cancel(); copilot.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("连接预览") { previewConnection() }.disabled(busy)
                Button(busy ? "正在处理…" : "保存连接") { save() }.keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(20)
        }.frame(width: 720, height: 760)
            .onDisappear { previewTask?.cancel(); copilot.cancel(); cookieWindow?.close(); enteredSecrets.removeAll() }
    }

    private var customForm: some View {
        Section("自定义查询") {
            TextField("查询 URL", text: customBinding(\.url, default: ""))
            Text("填写完整查询地址，包含 API 路径；URL、请求体和请求头常量会随模板导出，请勿填写凭据。").font(.caption).foregroundStyle(.secondary)
            Picker("方法", selection: customBinding(\.method, default: "GET")) { Text("GET").tag("GET"); Text("POST").tag("POST") }
            Toggle("允许 HTTP（例如本机服务）", isOn: customBinding(\.allowsHTTP, default: false))
            Text("请求头：每行 名称: 值；凭据使用 ${token}、${cookie}、${userID}").font(.caption)
            TextEditor(text: $headerText).font(.system(.caption, design: .monospaced)).frame(minHeight: 70)
            if account.custom?.method == "POST" { TextField("JSON 请求体", text: customBinding(\.body, default: "")) }
            TextField("账户身份路径（可选）", text: customBinding(\.identityPath, default: ""))
            TextField("套餐名称路径（可选）", text: customBinding(\.planPath, default: ""))
            if let custom = account.custom {
                ForEach(custom.mappings) { mapping in
                    MappingEditor(mapping: mappingBinding(mapping)) {
                        account.custom?.mappings.removeAll { $0.id == mapping.id }
                    }
                }
            }
            Button("添加指标") { account.custom?.mappings.append(.init(title: "新指标", kind: .balance, valuePath: "", unit: "")) }
        }
    }

    private func customBinding<T>(_ path: WritableKeyPath<CustomQuery, T>, default fallback: T) -> Binding<T> {
        Binding(get: { account.custom?[keyPath: path] ?? fallback }, set: { account.custom?[keyPath: path] = $0 })
    }
    private func mappingBinding(_ original: MetricMapping) -> Binding<MetricMapping> {
        Binding(get: { account.custom?.mappings.first { $0.id == original.id } ?? original }, set: { next in
            if let index = account.custom?.mappings.firstIndex(where: { $0.id == original.id }) { account.custom?.mappings[index] = next }
        })
    }
    private func prepared() throws -> SourceAccount {
        var copy = account
        if copy.custom != nil {
            var headers: [String: String] = [:]
            for line in headerText.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { throw MonitorError.message("请求头需使用 名称: 值 格式") }
                let key = pair[0].trimmingCharacters(in: .whitespaces)
                guard headers.keys.allSatisfy({ $0.lowercased() != key.lowercased() }) else { throw MonitorError.message("请求头重复") }
                headers[key] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            copy.custom?.headers = headers
            try copy.custom?.validate()
        }
        if enteredSecrets.values.contains(where: { !$0.isEmpty }) { copy.legacyCredentials = false }
        return copy
    }
    private func mergedSecrets() throws -> [String: String]? {
        let entered = enteredSecrets.filter { !$0.value.isEmpty }
        guard !entered.isEmpty else { return nil }
        var saved = try AccountSecrets.shared.read(account.id, interactive: true)
        for (key, value) in entered {
            if key == "cookie", let data = value.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(json) {
                saved[key] = String(decoding: try JSONSerialization.data(withJSONObject: json, options: .sortedKeys), as: UTF8.self)
            } else { saved[key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return saved
    }
    private func previewConnection() {
        do {
            let copy = try prepared(), secrets = try mergedSecrets()
            busy = true; error = nil
            previewTask = Task {
                defer { busy = false }
                do {
                    responseStructure = []; preview = nil
                    if let custom = copy.custom {
                        let credentials = try await Task.detached(priority: .utility) {
                            if let secrets { return secrets }
                            return try AccountSecrets.shared.read(copy.id)
                        }.value
                        let root = try await MonitorHTTP.shared.json(custom.request(secrets: credentials))
                        try Task.checkCancellation()
                        responseStructure = JSONField.structure(root)
                        preview = try custom.parse(root, account: copy)
                    } else { preview = try await MonitorAdapter().fetch(copy, secretsOverride: secrets) }
                }
                catch is CancellationError { return }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            let copy = try prepared(), secrets = try mergedSecrets()
            busy = true; error = nil
            Task {
                defer { busy = false }
                do { try await engine.save(copy, secrets: secrets); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func selectFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; account.credentialPath = url.path
    }
    private func secretLabel(_ name: String) -> String {
        ["token": "API Key / OAuth Token", "cookie": account.sourceID == "windsurf" ? "Windsurf JSON 会话包" : "Cookie 请求头",
         "userID": "用户 ID", "accessKey": "AccessKey ID / SecretId", "secretKey": "SecretAccessKey / SecretKey",
         "accountID": "ChatGPT Account ID（可选）", "projectID": "Google 项目 ID（可选）",
         "organization": "智谱团队组织 ID", "project": "智谱团队项目 ID"][name] ?? name
    }
}

struct MappingEditor: View {
    @Binding var mapping: MetricMapping
    var remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("指标名称", text: $mapping.title)
                Picker("类型", selection: $mapping.kind) { ForEach(MetricKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                Button("移除", role: .destructive, action: remove)
            }
            TextField("值路径，例如 data.balance 或 data.items[0].remaining", text: $mapping.valuePath)
            HStack { TextField("单位：USD / CNY / tokens / 次", text: $mapping.unit); TextField("缩放系数", value: $mapping.scale, format: .number) }
            Picker("数值含义", selection: $mapping.mode) { ForEach(MappingMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            TextField("总量路径（可选）", text: $mapping.totalPath)
            TextField("重置时间路径（ISO 8601 / 秒 / 毫秒，可选）", text: $mapping.resetPath)
            TextField("周期分钟数（可选）", text: Binding(get: { mapping.durationMinutes.map(String.init) ?? "" }, set: { mapping.durationMinutes = Int($0) }))
            DisclosureGroup("从数组中提取多个指标") {
                TextField("数组路径", text: $mapping.rowsPath)
                TextField("数组项中的名称路径", text: $mapping.labelPath)
            }
        }.padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
