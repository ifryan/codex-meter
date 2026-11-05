// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

/// Only this app's GLM key is managed here. Existing Claude and Codex credentials are untouched.
final class GLMCredentialsStore: @unchecked Sendable {
    private static let service = "CodexMeter GLM Coding Plan"
    private static let account = "glm-coding-plan-api-key"
    private let lock = NSLock()
    private var cachedKey: String?
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
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
        if !allowInteraction {
            guard ClaudeKeychainReader.isDefaultKeychainUnlocked else { throw GLMError.keychainUnavailable }
            guard let item = try itemReference() else { return nil }
            // Never invoke a potentially interactive tool until this exact item's ACL permits it.
            guard trustsSystemReader(item) else { throw GLMError.keychainAuthorizationRequired }
            guard let data = ClaudeKeychainReader.read(service: Self.service, account: Self.account),
                  let value = String(data: data, encoding: .utf8) else { throw GLMError.keychainUnavailable }
            let key = try Self.validated(value)
            cachedKey = key
            return key
        }
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw GLMError.keychainUnavailable }
        let key = try Self.validated(value)
        cachedKey = key
        return key
    }

    func save(_ value: String) throws {
        let key = try Self.validated(value)
        lock.lock()
        defer { lock.unlock() }
        let data = Data(key.utf8)
        let access = try readerAccess()
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrAccess as String: access] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccess as String] = access
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GLMError.keychainWriteFailed }
        cachedKey = key
    }

    private func itemReference() throws -> SecKeychainItem? {
        var attributes = query
        attributes[kSecReturnRef as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result,
              CFGetTypeID(result) == SecKeychainItemGetTypeID() else { throw GLMError.keychainUnavailable }
        return (result as! SecKeychainItem)
    }

    private func trustedData(_ application: SecTrustedApplication) -> Data? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess else { return nil }
        return data as Data?
    }

    private func trustsSystemReader(_ item: SecKeychainItem) -> Bool {
        var access: SecAccess?
        var reader: SecTrustedApplication?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecTrustedApplicationCreateFromPath("/usr/bin/security", &reader) == errSecSuccess, let reader,
              let expected = trustedData(reader),
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return false }
        return acls.contains { acl in
            var applications: CFArray?
            var description: CFString?
            var prompt: SecKeychainPromptSelector = []
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess,
                  prompt.rawValue & 0x0001 == 0,
                  let applications = applications as? [SecTrustedApplication] else { return false }
            return applications.contains { trustedData($0) == expected }
        }
    }

    /// Only invoked by an explicit save in the configuration window. Never grants all-app access.
    private func readerAccess() throws -> SecAccess {
        var reader: SecTrustedApplication?
        var application: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath("/usr/bin/security", &reader) == errSecSuccess, let reader,
              SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess, let application,
              SecAccessCreate(Self.service as CFString, [reader, application] as CFArray, &access) == errSecSuccess,
              let access else { throw GLMError.keychainWriteFailed }
        // A trusted reader needs no per-read passphrase; unlisted applications still require consent.
        guard let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else {
            throw GLMError.keychainWriteFailed
        }
        for acl in acls {
            guard SecACLSetContents(acl, [reader, application] as CFArray, Self.service as CFString, []) == errSecSuccess else {
                throw GLMError.keychainWriteFailed
            }
        }
        return access
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GLMError.keychainWriteFailed }
        cachedKey = nil
    }
}
