// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Where a Claude bearer token came from. The source decides how we report a failure: a rejected
/// long-lived token needs re-provisioning, while a rejected Claude Code session token just means
/// the CLI hasn't refreshed it lately.
enum ClaudeTokenSource: Equatable, Sendable {
    /// `CODEX_METER_CLAUDE_TOKEN` — mostly for development and CI.
    case environment
    /// A manually provisioned long-lived token in this app's own Keychain item.
    case longLived
    /// Claude Code's own rotating OAuth session, read out of its Keychain item.
    case claudeCode
}

/// Resolves a bearer token for the usage endpoint.
///
/// Claude Code's own OAuth access token only lives ~8 hours and is refreshed *only* while the CLI
/// is actually running, so a meter that reads it alone goes blank whenever you haven't used Claude
/// Code for a while. We deliberately do not refresh it ourselves: the token endpoint is rate
/// limited (it answers 429 when the CLI has refreshed recently) and writing the item back would
/// race Claude Code's own refresh-token rotation, which can invalidate the login outright.
///
/// Note that `claude setup-token` is *not* a usable substitute: the usage endpoint requires the
/// `user:profile` scope, and that command mints an inference-only token, so it answers 403
/// ("OAuth token does not meet scope requirement user:profile"). The override sources below exist
/// for a token that does carry `user:profile` — obtained through a separate OAuth authorization —
/// and are checked first so such a token can bypass Claude Code's short-lived session entirely.
enum ClaudeCredentialsStore {
    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let source: ClaudeTokenSource
    }

    /// Claude Code's own Keychain item. We only ever read this one.
    private static let claudeCodeService = "Claude Code-credentials"
    /// Our own item, holding a manually provisioned long-lived token as a bare string.
    static let longLivedService = "CodexMeter Claude Token"
    static let longLivedAccount = "claude-usage-token"

    static func read() -> Credentials? {
        if let token = ProcessInfo.processInfo.environment["CODEX_METER_CLAUDE_TOKEN"],
           !token.isEmpty {
            return Credentials(accessToken: token, expiresAt: nil, source: .environment)
        }
        if let token = readLongLivedToken() {
            // No expiry is stored alongside it, so we treat it as non-expiring and let a 401/403
            // be the signal to re-provision.
            return Credentials(accessToken: token, expiresAt: nil, source: .longLived)
        }
        return readClaudeCodeSession()
    }

    static func readLongLivedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: longLivedService,
            kSecAttrAccount as String: longLivedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private static func readClaudeCodeSession() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
        else {
            return nil
        }
        // Claude Code stores this as a JS Date.now()-style millisecond epoch.
        let expiresAtMs = oauth["expiresAt"] as? Double
        return Credentials(
            accessToken: accessToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) },
            source: .claudeCode
        )
    }
}

/// Fetches Claude Code's subscription usage from the same private endpoint the CLI's `/usage`
/// command reads — no separate login flow, no polling of any Claude Code session state.
struct ClaudeUsageClient: Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> ClaudeUsageSnapshot {
        guard let credentials = ClaudeCredentialsStore.read() else {
            throw MeterError.claudeNotLoggedIn
        }
        // A long-lived token has no local expiry to check; only the CLI's session token does.
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            throw MeterError.claudeSessionExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        // A cold TLS handshake to api.anthropic.com can take well over 10s on a freshly woken
        // machine, which showed up as spurious "request timed out" failures. We refresh only every
        // 5 minutes, so a generous timeout costs nothing.
        request.timeoutInterval = 25
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MeterError.claudeRequestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MeterError.claudeRequestFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw credentials.source == .claudeCode
                    ? MeterError.claudeSessionExpired
                    : MeterError.claudeTokenRejected
            }
            throw MeterError.claudeRequestFailed("HTTP \(http.statusCode)")
        }

        return try ClaudeUsageParser().parse(data: data)
    }
}
