// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Where the Claude bearer token came from. Only affects diagnostics.
enum ClaudeTokenSource: Equatable, Sendable {
    /// `CODEX_METER_CLAUDE_TOKEN` — mostly for development and CI.
    case environment
    /// The long-lived `claude setup-token` value in this app's own Keychain item.
    case keychain
}

/// Resolves the long-lived token used to read Claude's quota.
///
/// This deliberately does *not* read Claude Code's own `Claude Code-credentials` Keychain item.
/// That token expires roughly every 8 hours and is refreshed only while the CLI is actually
/// running, so a meter built on it goes blank whenever you haven't used Claude Code for a while —
/// which is exactly the failure this app is fixing. A `claude setup-token` value lasts about a
/// year, is owned solely by us, and needs no refresh, so there is no rotation race to lose.
enum ClaudeCredentialsStore {
    struct Credentials {
        let accessToken: String
        let source: ClaudeTokenSource
    }

    static let keychainService = "CodexMeter Claude Token"
    static let keychainAccount = "claude-usage-token"

    static func read() -> Credentials? {
        if let token = ProcessInfo.processInfo.environment["CODEX_METER_CLAUDE_TOKEN"], !token.isEmpty {
            return Credentials(accessToken: token, source: .environment)
        }
        return readKeychainToken().map { Credentials(accessToken: $0, source: .keychain) }
    }

    static func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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
}

/// Reads Claude subscription quota from the `anthropic-ratelimit-unified-*` response headers that
/// ride along with every billed inference response.
///
/// The obvious endpoint, `GET /api/oauth/usage`, is not usable here: it requires the `user:profile`
/// scope, and `claude setup-token` mints an inference-only token, so it answers 403. The headers
/// carry the same two windows we display and only need `user:inference`, which that token has.
///
/// The cost is one deliberately minimal request per refresh (a single-token reply on the cheapest
/// model). Error responses carry no rate-limit headers, so there is no way to read them without
/// billing a request — verified against 404 and 403 responses.
struct ClaudeUsageClient: Sendable {
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Cheapest model available to a subscription token; kept minimal so a refresh costs ~10 tokens.
    private static let probeModel = "claude-haiku-4-5-20251001"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Primary channel first; if it can't produce a snapshot, fall back to Claude Code's own
    /// session, refreshing it through the CLI when it has lapsed. The primary error is what
    /// surfaces if everything fails, since that's the one the user can act on.
    func fetch() async throws -> ClaudeUsageSnapshot {
        do {
            return try await fetchFromRateLimitHeaders()
        } catch {
            if let snapshot = try? await fetchFromUsageEndpoint() { return snapshot }
            throw error
        }
    }

    /// Fallback: `GET /api/oauth/usage` using Claude Code's own session token. Richer than the
    /// header channel and costs no quota, but only works while that short-lived token is valid.
    private func fetchFromUsageEndpoint() async throws -> ClaudeUsageSnapshot {
        var session = ClaudeCodeSessionStore.read()
        if session == nil || session?.isExpired == true {
            // Let the CLI rewrite its own Keychain item rather than racing its token rotation.
            if ClaudeStatusRefresher.refresh() {
                session = ClaudeCodeSessionStore.read()
            }
        }
        guard let session, !session.isExpired else {
            throw MeterError.claudeRequestFailed("Claude Code 会话令牌不可用")
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MeterError.claudeRequestFailed("usage 接口 HTTP \(code)")
        }
        return try ClaudeUsageParser().parse(data: data)
    }

    private func fetchFromRateLimitHeaders() async throws -> ClaudeUsageSnapshot {
        guard let credentials = ClaudeCredentialsStore.read() else {
            throw MeterError.claudeNotConfigured
        }

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        // A cold TLS handshake to api.anthropic.com can take well over 10s on a freshly woken
        // machine, which showed up as spurious "request timed out" failures.
        request.timeoutInterval = 25
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Self.probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ])

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw MeterError.claudeRequestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MeterError.claudeRequestFailed("no HTTP response")
        }

        // Parse headers before looking at the status. A 429 for an exhausted window is precisely
        // when the meter matters most, and that response still describes the quota.
        if let snapshot = ClaudeRateLimitHeaderParser().parse(headers: http.allHeaderFields) {
            return snapshot
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw MeterError.claudeTokenRejected
        }
        throw MeterError.claudeRequestFailed("HTTP \(http.statusCode) 且无限额响应头")
    }
}
