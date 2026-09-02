// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Reads the OAuth credentials Claude Code itself stores in the macOS Keychain so this app can
/// call the same private usage endpoint the `claude` CLI's `/usage` command uses. Read-only: we
/// never write back to this item, since Claude Code's own refresh-token rotation would race with
/// (and could be invalidated by) a second writer.
enum ClaudeCredentialsStore {
    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
    }

    private static let keychainService = "Claude Code-credentials"

    static func read() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
        return Credentials(accessToken: accessToken, expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) })
    }
}

/// Fetches Claude Code's subscription usage from the same private endpoint the CLI's `/usage`
/// command reads, reusing the CLI's own logged-in OAuth session — no separate login, no polling
/// of any Claude Code session state.
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
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            throw MeterError.claudeSessionExpired
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
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
            if http.statusCode == 401 { throw MeterError.claudeSessionExpired }
            throw MeterError.claudeRequestFailed("HTTP \(http.statusCode)")
        }

        return try ClaudeUsageParser().parse(data: data)
    }
}
