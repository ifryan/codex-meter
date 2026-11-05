// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import WebKit
import Combine

@MainActor
final class CookieLoginWindow: NSWindowController {
    private let webView: WKWebView
    private let source: SourceDescriptor
    private let complete: (String) -> Void
    private let status = NSTextField(labelWithString: L("After signing in, click Finish connecting at the bottom right"))

    init(source: SourceDescriptor, complete: @escaping (String) -> Void) {
        self.source = source
        self.complete = complete
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Connect ") + source.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView, let url = URL(string: source.dashboard), url.scheme == "https" else { return }
        let button = NSButton(title: L("Finish connecting"), target: self, action: #selector(finish))
        button.bezelStyle = .rounded
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        [webView, status, button, cancel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor), webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor), webView.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -10), cancel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), status.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12)
        ])
        webView.load(URLRequest(url: url)); window.center()
    }
    required init?(coder: NSCoder) { return nil }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    @objc private func finish() {
        if source.id == "windsurf" {
            guard let host = webView.url?.host, host == "windsurf.com" || host == "app.devin.ai" else { status.stringValue = L("Finish signing in to Windsurf first"); return }
            let script = "JSON.stringify(Object.fromEntries(['devin_session_token','devin_auth1_token','devin_account_id','devin_primary_org_id'].map(k=>{let v=localStorage.getItem(k);try{v=JSON.parse(v)}catch(e){}return [k,v]})))"
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, let text = value as? String, let data = text.data(using: .utf8),
                      let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String], dictionary.count == 4 else {
                    self?.status.stringValue = L("Didn't get a complete session. Sign in and try again, or paste a session bundle"); return
                }
                complete(text); close()
            }
            return
        }
        guard let expectedHost = URL(string: source.dashboard)?.host else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let applicable = cookies.filter {
                let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return expectedHost == domain || expectedHost.hasSuffix("." + domain)
            }
            guard !applicable.isEmpty else { status.stringValue = L("No sign-in cookie yet. Finish signing in first"); return }
            complete(applicable.map { $0.name + "=" + $0.value }.joined(separator: "; "))
            close()
        }
    }
    @objc private func cancel() { close() }
}

@MainActor
final class CopilotDeviceLogin: ObservableObject {
    @Published var code = ""
    @Published var status = ""
    @Published var active = false
    private var task: Task<Void, Never>?

    func start(complete: @escaping (String) -> Void) {
        guard !active else { return }
        active = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { active = false }
            do {
                let clientID = "Iv1.b507a08c87ecfe98"
                var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = CloudProviders.form(["client_id": clientID, "scope": "read:user"])
                let root = try await MonitorHTTP.shared.json(request)
                guard let device = JSONField.text(root, "device_code"), let user = JSONField.text(root, "user_code"),
                      let url = JSONField.text(root, "verification_uri"), let target = URL(string: url), target.host == "github.com", target.scheme == "https" else { throw MonitorError.invalidResponse }
                code = user; status = L("Enter this code in your browser to finish GitHub authorization")
                NSWorkspace.shared.open(target)
                let expires = Date().addingTimeInterval(min(1_800, NSDecimalNumber(decimal: JSONField.number(root, "expires_in") ?? 900).doubleValue))
                var interval = max(5, NSDecimalNumber(decimal: JSONField.number(root, "interval") ?? 5).doubleValue)
                while Date() < expires {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    var poll = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
                    poll.httpMethod = "POST"
                    poll.setValue("application/json", forHTTPHeaderField: "Accept")
                    poll.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    poll.httpBody = CloudProviders.form(["client_id": clientID, "device_code": device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                    let response = try await MonitorHTTP.shared.json(poll)
                    if let token = JSONField.text(response, "access_token") { status = L("Authorized. Takes effect once you save the connection"); code = ""; complete(token); return }
                    let error = JSONField.text(response, "error") ?? ""
                    if error == "slow_down" { interval = min(60, interval + 5) }
                    else if error != "authorization_pending" { throw MonitorError.message(L("GitHub authorization wasn't finished or was canceled")) }
                }
                throw MonitorError.message(L("The code has expired. Sign in again"))
            } catch is CancellationError { status = L("Sign-in canceled") }
            catch { status = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel(); task = nil; active = false; code = "" }
}
