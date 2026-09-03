// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import Security

/// Reads — never writes — the OAuth session Claude Code keeps in its own Keychain item.
///
/// This is the fallback credential: the token lasts only ~8 hours and is renewed solely while the
/// CLI runs, so it cannot be relied on alone. It is still worth having, because it carries the
/// `user:profile` scope that `GET /api/oauth/usage` requires and a `claude setup-token` value does
/// not, so it reaches a richer endpoint than the header channel.
enum ClaudeCodeSessionStore {
    struct Session {
        let accessToken: String
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    private static let keychainService = "Claude Code-credentials"

    private static func rawItem() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func read() -> Session? {
        guard
            let data = rawItem(),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
        else {
            return nil
        }
        // Claude Code stores this as a JS Date.now()-style millisecond epoch.
        let expiresAtMs = oauth["expiresAt"] as? Double
        return Session(
            accessToken: accessToken,
            expiresAt: expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
    }

    /// A digest of the stored item, used to tell whether the CLI rewrote it. Hashed rather than
    /// compared directly so no token material is held in memory longer than the read itself.
    static func tokenFingerprint() -> String? {
        guard let data = rawItem() else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
