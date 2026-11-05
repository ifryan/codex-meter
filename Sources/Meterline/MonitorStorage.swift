// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

enum MonitorFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LegacyMigration.directoryName, isDirectory: true)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class AccountRepository {
    private let url: URL
    private(set) var configuration: MonitorConfiguration
    private(set) var loadError: String?

    init(url: URL = MonitorFiles.directory.appendingPathComponent("connections.json"), demo: Bool = false) {
        self.url = url
        if demo {
            configuration = MonitorConfiguration(accounts: MeterAgent.allCases.map {
                SourceAccount(sourceID: $0.rawValue, name: $0.title, pinned: true, authentication: .local)
            })
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                configuration = try JSONDecoder().decode(MonitorConfiguration.self, from: Data(contentsOf: url))
                guard configuration.version == 1 else { throw MonitorError.message(L("The configuration is newer than this app. Please update the app")) }
                configuration.normalize()
            } catch {
                configuration = MonitorConfiguration(accounts: [])
                loadError = L("Couldn't read the configuration. The original file was kept: %@. Back it up and repair it so your connections aren't overwritten.", "\(url.lastPathComponent)")
            }
        } else {
            let hasLegacy = UserDefaults.standard.object(forKey: MeterAgentOrder.defaultsKey) != nil
                || UserDefaults.standard.object(forKey: "codexExecutablePath") != nil
                || FileManager.default.fileExists(atPath: MonitorFiles.directory.appendingPathComponent("claude-usage.json").path)
                || Self.hasLegacyGLMItem()
            let order = hasLegacy ? MeterAgentOrder.normalized(UserDefaults.standard.stringArray(forKey: MeterAgentOrder.defaultsKey) ?? []) : []
            configuration = MonitorConfiguration(accounts: order.map {
                SourceAccount(sourceID: $0.rawValue, name: $0.title, pinned: true,
                              authentication: $0 == .glm ? .token : .local, legacyCredentials: true)
            })
            do { try save(configuration) } catch { loadError = L("Couldn't save the initial connection configuration. Check the app data folder's permissions") }
        }
    }

    private static func hasLegacyGLMItem() -> Bool {
        GLMCredentialsStore.services.contains { service in
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: GLMCredentialsStore.account,
                kSecReturnAttributes as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            var result: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        }
    }

    func save(_ proposed: MonitorConfiguration) throws {
        if let loadError { throw MonitorError.message(loadError) }
        var next = proposed
        next.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try MonitorFiles.write(try encoder.encode(next), to: url)
        configuration = next
    }
}

final class AccountSecrets: @unchecked Sendable {
    static let shared = AccountSecrets()
    private let service = "Meterline Connections"
    /// Read as a fallback and copied forward. The old item stays until its connection is removed.
    private let legacyService = "CodexMeter Connections"
    private let lock = NSLock()
    private var cache: [UUID: [String: String]] = [:]

    private func query(_ id: UUID, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID, interactive: Bool = false) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        for name in [service, legacyService] {
            guard let secrets = try readItem(id, service: name, interactive: interactive) else { continue }
            // A failed copy is retried on the next launch, because the old item is still there.
            if name == legacyService { try? write(secrets, for: id) }
            cache[id] = secrets
            return secrets
        }
        return [:]
    }

    private func readItem(_ id: UUID, service: String, interactive: Bool) throws -> [String: String]? {
        switch AppKeychain.read(query(id, service: service), allowInteraction: interactive) {
        case .notFound:
            return nil
        case .found(let data):
            return try JSONDecoder().decode([String: String].self, from: data)
        case .blocked(let status):
            if interactive { throw MonitorError.keychain(status) }
            throw MonitorError.message(L("Unlock the Keychain, or click Reauthorize saved credentials in Connections"))
        }
    }

    func save(_ secrets: [String: String], for id: UUID) throws {
        guard secrets.values.allSatisfy({ $0.utf8.count <= 32_768 && !$0.contains(where: \.isNewline) }) else {
            throw MonitorError.message(L("Credentials can't contain line breaks or exceed 32 KB"))
        }
        lock.lock()
        defer { lock.unlock() }
        try write(secrets, for: id)
        cache[id] = secrets
    }

    private func write(_ secrets: [String: String], for id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        guard let access = AppKeychain.access(description: service) else {
            throw MonitorError.message(L("Couldn't set up the app's Keychain authorization"))
        }
        var status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data, kSecAttrAccess as String: access] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccess as String] = access
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MonitorError.keychain(status) }
    }

    func remove(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitorError.keychain(status) }
        // Removing a connection must also remove the copy of its secret under the old name.
        _ = SecItemDelete(query(id, service: legacyService) as CFDictionary)
        cache.removeValue(forKey: id)
    }

    func invalidate(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: id)
    }
}

/// Reads this app's own Keychain items. A background read must never show a password prompt, so it
/// asks the Keychain directly with interaction turned off and reports `.blocked` instead. Going through
/// `/usr/bin/security` can't promise that: items this app creates aren't in that tool's partition, so
/// it prompts even when the item's ACL lists it.
enum AppKeychain {
    enum ReadResult {
        case found(Data)
        case notFound
        case blocked(OSStatus)
    }

    private static let lock = NSLock()

    static func read(_ query: [String: Any], allowInteraction: Bool) -> ReadResult {
        // The interaction setting is process-wide, so reads take turns.
        lock.lock()
        defer { lock.unlock() }
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(allowInteraction)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }

        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = result as? Data else { return .blocked(status) }
        return .found(data)
    }

    /// Grants only this app, for items it creates. Never grants all applications.
    static func access(description: String) -> SecAccess? {
        var app: SecTrustedApplication?
        var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app,
              SecAccessCreate(description as CFString, [app] as CFArray, &access) == errSecSuccess, let access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return nil }
        for acl in acls {
            guard SecACLSetContents(acl, [app] as CFArray, description as CFString, []) == errSecSuccess else { return nil }
        }
        return access
    }
}
