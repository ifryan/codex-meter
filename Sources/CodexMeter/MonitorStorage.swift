// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

enum MonitorFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexMeter", isDirectory: true)
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
                guard configuration.version == 1 else { throw MonitorError.message("配置版本比当前应用更新，请升级应用") }
                configuration.normalize()
            } catch {
                configuration = MonitorConfiguration(accounts: [])
                loadError = "配置无法读取，已保留原文件：\(url.lastPathComponent)。请备份后修复，避免覆盖已有连接。"
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
            do { try save(configuration) } catch { loadError = "无法保存初始连接配置，请检查应用数据目录权限" }
        }
    }

    private static func hasLegacyGLMItem() -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "CodexMeter GLM Coding Plan", kSecAttrAccount as String: "glm-coding-plan-api-key",
            kSecReturnAttributes as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
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
    private let service = "CodexMeter Connections"
    private let lock = NSLock()
    private var cache: [UUID: [String: String]] = [:]

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID, interactive: Bool = false) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        if !interactive {
            var attributes = query(id)
            attributes[kSecReturnRef as String] = true
            attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var reference: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &reference)
            if status == errSecItemNotFound { return [:] }
            guard status == errSecSuccess, let reference, CFGetTypeID(reference) == SecKeychainItemGetTypeID(),
                  ConnectionKeychainAccess.trustsReader(reference as! SecKeychainItem), ClaudeKeychainReader.isDefaultKeychainUnlocked,
                  let data = ClaudeKeychainReader.read(service: service, account: id.uuidString) else {
                throw MonitorError.message("请解锁钥匙串，或在连接设置中点击重新授权已保存凭据")
            }
            let secrets = try JSONDecoder().decode([String: String].self, from: data)
            cache[id] = secrets
            return secrets
        }
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw MonitorError.keychain(status) }
        let secrets = try JSONDecoder().decode([String: String].self, from: data)
        cache[id] = secrets
        return secrets
    }

    func save(_ secrets: [String: String], for id: UUID) throws {
        guard secrets.values.allSatisfy({ $0.utf8.count <= 32_768 && !$0.contains(where: \.isNewline) }) else {
            throw MonitorError.message("凭据不能包含换行，长度不能超过 32 KB")
        }
        let data = try JSONEncoder().encode(secrets)
        lock.lock()
        defer { lock.unlock() }
        let access = try ConnectionKeychainAccess.create(service: service)
        var status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data, kSecAttrAccess as String: access] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(id)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccess as String] = access
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MonitorError.keychain(status) }
        cache[id] = secrets
    }

    func remove(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitorError.keychain(status) }
        cache.removeValue(forKey: id)
    }

    func invalidate(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: id)
    }
}

enum ConnectionKeychainAccess {
    private static func fingerprint(_ app: SecTrustedApplication) -> Data? {
        var data: CFData?
        guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess else { return nil }
        return data as Data?
    }
    static func trustsReader(_ item: SecKeychainItem) -> Bool {
        var access: SecAccess?
        var reader: SecTrustedApplication?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecTrustedApplicationCreateFromPath("/usr/bin/security", &reader) == errSecSuccess, let reader,
              let expected = fingerprint(reader),
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return false }
        return acls.contains { acl in
            var apps: CFArray?; var label: CFString?; var prompt: SecKeychainPromptSelector = []
            guard SecACLCopyContents(acl, &apps, &label, &prompt) == errSecSuccess,
                  prompt.rawValue & 1 == 0, let apps = apps as? [SecTrustedApplication] else { return false }
            return apps.contains { fingerprint($0) == expected }
        }
    }
    static func create(service: String) throws -> SecAccess {
        var reader: SecTrustedApplication?; var app: SecTrustedApplication?; var access: SecAccess?
        guard SecTrustedApplicationCreateFromPath("/usr/bin/security", &reader) == errSecSuccess, let reader,
              SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app,
              SecAccessCreate(service as CFString, [reader, app] as CFArray, &access) == errSecSuccess, let access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else {
            throw MonitorError.message("无法建立应用专属钥匙串授权")
        }
        for acl in acls {
            guard SecACLSetContents(acl, [reader, app] as CFArray, service as CFString, []) == errSecSuccess else {
                throw MonitorError.message("无法保存应用专属钥匙串授权")
            }
        }
        return access
    }
}
