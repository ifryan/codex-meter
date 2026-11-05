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
        window.title = L("Meterline · Connections")
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
                    Text(L("Connections")).font(.title.bold())
                    Text(L("Add the accounts you use and pin up to 3 to the notch")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Statistics settings")) { statisticsSettings = true }
                Button(L("Import template"), action: importTemplate).disabled(engine.isDemo)
                Menu(L("Add connection")) {
                    let discovered = SourceRegistry.discovered()
                    if !discovered.isEmpty {
                        Menu(L("Detected local tools")) { ForEach(discovered) { source in Button(source.title) { add(source) } } }
                        Divider()
                    }
                    ForEach(Array(Set(SourceRegistry.all.map(\.category))).sorted(), id: \.self) { category in
                        Menu(category) {
                            ForEach(SourceRegistry.all.filter { $0.category == category }) { source in Button(source.title) { add(source) } }
                        }
                    }
                }.disabled(engine.isDemo)
            }
            TextField(L("Search sources or accounts"), text: $search).textFieldStyle(.roundedBorder)
            if let error = error ?? engine.message { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if filtered.isEmpty {
                ContentUnavailableView(L("No connections yet"), systemImage: "link", description: Text(L("Choose a source under Add connection. Each one refreshes on its own and can be pinned")))
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
                            Toggle(L("Enabled"), isOn: Binding(get: { account.enabled }, set: { enabled in var next = account; next.enabled = enabled; save(next) }))
                                .toggleStyle(.switch).fixedSize()
                            Button(account.pinned ? L("Unpin") : L("Pin")) { var next = account; next.pinned.toggle(); save(next) }.disabled(!account.enabled)
                            Button(L("Edit")) { editing = account }
                            Menu {
                                Button(L("Export configuration template")) { exportTemplate(account) }
                                Button(L("Move up")) { move(account, delta: -1) }
                                Button(L("Move down")) { move(account, delta: 1) }
                                Divider()
                                Button(L("Remove connection"), role: .destructive) {
                                    Task { do { try await engine.remove(account.id) } catch { self.error = error.localizedDescription } }
                                }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.vertical, 7).disabled(engine.isDemo)
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text(L("Only enabled connections are queried · Credentials stay in the local Keychain")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Refresh enabled connections")) { engine.refresh(force: true) }.disabled(engine.isDemo)
            }
        }.padding(24)
            .sheet(item: $editing) { account in AccountEditorView(engine: engine, initial: account) }
            .sheet(isPresented: $statisticsSettings) { StatisticsSettingsView(engine: engine) }
    }

    private func add(_ source: SourceDescriptor) {
        editing = SourceAccount(sourceID: source.id, name: source.title, authentication: source.authentication.first ?? .token,
                                endpoint: source.defaultEndpoint, custom: source.customTemplate ?? (source.id == "custom" ? CustomQuery(url: "", mappings: [.init(title: L("Balance"), kind: .balance, valuePath: "data.balance", unit: "USD")]) : nil))
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
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw MonitorError.message(L("The template exceeds the size limit")) }
            let template = try JSONDecoder().decode(ConnectionTemplate.self, from: Data(contentsOf: url))
            guard template.version == 1, let source = SourceRegistry.descriptor(template.sourceID) else { throw MonitorError.message(L("Unsupported template version or source")) }
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
            HStack { Text(source.title).font(.title2.bold()); Spacer(); Text(L("Connection settings")).foregroundStyle(.secondary) }.padding(24)
            ScrollView {
                Form {
                    Section(L("Account")) {
                        TextField(L("Connection name"), text: $account.name)
                        Toggle(L("Enable queries"), isOn: $account.enabled)
                        Toggle(L("Pin to notch (up to 3)"), isOn: $account.pinned)
                        Picker(L("Sign-in method"), selection: $account.authentication) {
                            ForEach(source.authentication, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }
                        Text(source.help).font(.caption).foregroundStyle(.secondary)
                    }
                    if account.authentication == .oauthFile || (account.authentication == .local && !["claude", "copilot"].contains(account.sourceID)) {
                        Section(account.sourceID == "cc-switch" ? L("Export file") : L("Custom path (leave empty for the default location)")) {
                            TextField(L("File or executable path"), text: $account.credentialPath)
                            Button(L("Choose file…"), action: selectFile)
                        }
                    }
                    if !secretNames.isEmpty {
                        Section(L("Credentials · Leave empty to keep the saved value")) {
                            ForEach(secretNames, id: \.self) { name in
                                SecureField(secretLabel(name), text: Binding(get: { enteredSecrets[name] ?? "" }, set: { enteredSecrets[name] = $0 }))
                            }
                            if account.legacyCredentials { Text(L("Until you enter new credentials, the existing dedicated Keychain item stays in use")).font(.caption).foregroundStyle(.secondary) }
                            if account.sourceID == "glm" {
                                Button(L("Migrate legacy GLM credentials")) {
                                    do {
                                        guard let key = try GLMCredentialsStore().read(allowInteraction: true) else { throw MonitorError.notConfigured }
                                        enteredSecrets["token"] = key
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                            if engine.accounts.contains(where: { $0.id == account.id }) && !account.legacyCredentials {
                                Button(L("Reauthorize saved credentials")) {
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
                                Button(L("Connect web account…")) {
                                    cookieWindow = CookieLoginWindow(source: source) { value in enteredSecrets["cookie"] = value }
                                    cookieWindow?.present()
                                }
                            }
                            if account.sourceID == "copilot" {
                                Button(copilot.active ? L("Waiting for GitHub authorization…") : L("Sign in with GitHub")) {
                                    copilot.start { token in enteredSecrets["token"] = token }
                                }.disabled(copilot.active)
                                if !copilot.code.isEmpty { Text(copilot.code).font(.title.monospaced()).textSelection(.enabled) }
                                if !copilot.status.isEmpty { Text(copilot.status).font(.caption) }
                            }
                        }
                    } else if account.sourceID == "copilot" {
                        Button(L("Connect another GitHub account")) {
                            account.authentication = .token
                            copilot.start { token in enteredSecrets["token"] = token }
                        }
                    }
                    if ["magpie", "volcengine", "tencent"].contains(account.sourceID) {
                        Section(account.sourceID == "magpie" ? L("Service URL") : L("Cloud region")) {
                            TextField(account.sourceID == "magpie" ? "http://127.0.0.1:3425" : account.sourceID == "tencent" ? "ap-guangzhou" : "cn-beijing", text: $account.endpoint)
                        }
                    }
                    if account.sourceID == "claude" {
                        Toggle(L("Allow probes that use a small amount of inference quota (off by default)"), isOn: $account.allowsPaidProbe)
                    }
                    if account.custom != nil { customForm }
                    Section(L("Display and refresh")) {
                        Picker(L("Main metric in notch"), selection: $account.primaryMetricID) {
                            Text(L("Automatic")).tag(Optional<String>.none)
                            ForEach((preview ?? engine.snapshot(account.id))?.metrics ?? []) { metric in Text(metric.title).tag(Optional(metric.id)) }
                        }
                        Stepper(L("Refresh every %@ min", "\(account.refreshMinutes)"), value: $account.refreshMinutes, in: 1...1_440)
                    }
                    if let preview {
                        Section(L("Preview connection")) {
                            ForEach(preview.metrics) { metric in LabeledContent(metric.title, value: metric.formatted) }
                            Text(L("Preview queries only this connection. Nothing has been saved")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !responseStructure.isEmpty {
                        Section(L("Response structure · Field contents are hidden")) {
                            Text(responseStructure.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.formStyle(.grouped).padding(.horizontal, 8)
            }
            HStack {
                if !source.dashboard.isEmpty, let url = URL(string: source.dashboard) { Link(L("Open provider"), destination: url) }
                Spacer()
                Button(L("Cancel")) { previewTask?.cancel(); copilot.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Preview connection")) { previewConnection() }.disabled(busy)
                Button(busy ? L("Working…") : L("Save connection")) { save() }.keyboardShortcut(.defaultAction).disabled(busy)
            }.padding(20)
        }.frame(width: 720, height: 760)
            .onDisappear { previewTask?.cancel(); copilot.cancel(); cookieWindow?.close(); enteredSecrets.removeAll() }
    }

    private var customForm: some View {
        Section(L("Custom query")) {
            TextField(L("Query URL"), text: customBinding(\.url, default: ""))
            Text(L("Enter the full query URL including the API path. The URL, request body, and literal headers are included in exported templates, so don't put credentials in them.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Method"), selection: customBinding(\.method, default: "GET")) { Text("GET").tag("GET"); Text("POST").tag("POST") }
            Toggle(L("Allow HTTP (for local services, for example)"), isOn: customBinding(\.allowsHTTP, default: false))
            Text(L("Headers: one \"Name: value\" per line. For credentials use ${token}, ${cookie}, or ${userID}")).font(.caption)
            TextEditor(text: $headerText).font(.system(.caption, design: .monospaced)).frame(minHeight: 70)
            if account.custom?.method == "POST" { TextField(L("JSON request body"), text: customBinding(\.body, default: "")) }
            TextField(L("Account identity path (optional)"), text: customBinding(\.identityPath, default: ""))
            TextField(L("Plan name path (optional)"), text: customBinding(\.planPath, default: ""))
            if let custom = account.custom {
                ForEach(custom.mappings) { mapping in
                    MappingEditor(mapping: mappingBinding(mapping)) {
                        account.custom?.mappings.removeAll { $0.id == mapping.id }
                    }
                }
            }
            Button(L("Add metric")) { account.custom?.mappings.append(.init(title: L("New metric"), kind: .balance, valuePath: "", unit: "")) }
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
                guard pair.count == 2 else { throw MonitorError.message(L("Headers must use the \"Name: value\" format")) }
                let key = pair[0].trimmingCharacters(in: .whitespaces)
                guard headers.keys.allSatisfy({ $0.lowercased() != key.lowercased() }) else { throw MonitorError.message(L("Duplicate header")) }
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
        ["token": "API Key / OAuth Token", "cookie": account.sourceID == "windsurf" ? L("Windsurf JSON session bundle") : L("Cookie header"),
         "userID": L("User ID"), "accessKey": "AccessKey ID / SecretId", "secretKey": "SecretAccessKey / SecretKey",
         "accountID": L("ChatGPT Account ID (optional)"), "projectID": L("Google project ID (optional)"),
         "organization": L("Zhipu team organization ID"), "project": L("Zhipu team project ID")][name] ?? name
    }
}

struct MappingEditor: View {
    @Binding var mapping: MetricMapping
    var remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("Metric name"), text: $mapping.title)
                Picker(L("Type"), selection: $mapping.kind) { ForEach(MetricKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                Button(L("Remove"), role: .destructive, action: remove)
            }
            TextField(L("Value path, such as data.balance or data.items[0].remaining"), text: $mapping.valuePath)
            HStack { TextField(L("Unit: USD / CNY / tokens / uses"), text: $mapping.unit); TextField(L("Scale factor"), value: $mapping.scale, format: .number) }
            Picker(L("Value meaning"), selection: $mapping.mode) { ForEach(MappingMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            TextField(L("Total path (optional)"), text: $mapping.totalPath)
            TextField(L("Reset time path (ISO 8601 / seconds / milliseconds, optional)"), text: $mapping.resetPath)
            TextField(L("Period in minutes (optional)"), text: Binding(get: { mapping.durationMinutes.map(String.init) ?? "" }, set: { mapping.durationMinutes = Int($0) }))
            DisclosureGroup(L("Extract several metrics from an array")) {
                TextField(L("Array path"), text: $mapping.rowsPath)
                TextField(L("Name path within array items"), text: $mapping.labelPath)
            }
        }.padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
