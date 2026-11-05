// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Only this app's GLM key is managed here. Existing Claude and Codex credentials are untouched.
final class GLMCredentialsStore: @unchecked Sendable {
    private static let service = "Meterline GLM Coding Plan"
    /// Read as a fallback and copied forward. The old item stays until the key is removed.
    private static let legacyService = "CodexMeter GLM Coding Plan"
    static let services = [service, legacyService]
    static let account = "glm-coding-plan-api-key"
    private let lock = NSLock()
    private var cachedKey: String?
    private var query: [String: Any] { query(service: Self.service) }

    private func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    static func validated(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4_096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw GLMError.invalidKey
        }
        return key
    }

    func read(allowInteraction: Bool = false) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        for service in Self.services {
            guard let key = try readKey(service: service, allowInteraction: allowInteraction) else { continue }
            // A failed copy is retried on the next launch, because the old item is still there.
            if service == Self.legacyService { try? write(key) }
            cachedKey = key
            return key
        }
        return nil
    }

    private func readKey(service: String, allowInteraction: Bool) throws -> String? {
        switch AppKeychain.read(query(service: service), allowInteraction: allowInteraction) {
        case .notFound:
            return nil
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else { throw GLMError.keychainUnavailable }
            return try Self.validated(value)
        case .blocked:
            throw allowInteraction ? GLMError.keychainUnavailable : GLMError.keychainAuthorizationRequired
        }
    }

    func save(_ value: String) throws {
        let key = try Self.validated(value)
        lock.lock()
        defer { lock.unlock() }
        try write(key)
        cachedKey = key
    }

    private func write(_ key: String) throws {
        let data = Data(key.utf8)
        guard let access = AppKeychain.access(description: Self.service) else { throw GLMError.keychainWriteFailed }
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrAccess as String: access] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccess as String] = access
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GLMError.keychainWriteFailed }
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GLMError.keychainWriteFailed }
        // Removing the key must also remove the copy under the old name.
        _ = SecItemDelete(query(service: Self.legacyService) as CFDictionary)
        cachedKey = nil
    }
}
