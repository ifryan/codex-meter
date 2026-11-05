// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import Meterline

final class LegacyMigrationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    private var legacy: URL { root.appendingPathComponent("CodexMeter") }
    private var destination: URL { root.appendingPathComponent("Meterline") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("backups"), withIntermediateDirectories: true)
        try Data("config".utf8).write(to: legacy.appendingPathComponent("connections.json"))
        try Data("backup".utf8).write(to: legacy.appendingPathComponent("backups/old.bin"))
        suite = "LegacyMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testCopiesDataSkipsBackupsAndKeepsOriginal() throws {
        try LegacyMigration.migrate(from: legacy, to: destination, legacyDefaults: nil, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("connections.json")), Data("config".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("backups").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("connections.json").path))
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.completedKey))
    }

    func testDoesNotOverwriteExistingDestination() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: destination.appendingPathComponent("connections.json"))
        try LegacyMigration.migrate(from: legacy, to: destination, legacyDefaults: nil, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("connections.json")), Data("new".utf8))
    }

    func testCopiesPreferencesWithoutReplacingNewValues() throws {
        defaults.set("/new/codex", forKey: "codexExecutablePath")
        try LegacyMigration.migrate(from: legacy, to: destination,
                                    legacyDefaults: ["codexExecutablePath": "/old/codex", "meterAgentOrder": ["glm"]],
                                    defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "codexExecutablePath"), "/new/codex")
        XCTAssertEqual(defaults.stringArray(forKey: "meterAgentOrder"), ["glm"])
    }

    func testFailedCopyLeavesNoPartialDestination() throws {
        let unreadable = legacy.appendingPathComponent("usage.sqlite")
        try Data("db".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        XCTAssertThrowsError(try LegacyMigration.migrate(from: legacy, to: destination, legacyDefaults: nil, defaults: defaults))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["CodexMeter"])
        XCTAssertFalse(defaults.bool(forKey: LegacyMigration.completedKey))
    }

    func testEnvironmentPrefersNewPrefixAndFallsBack() {
        XCTAssertEqual(AppEnvironment.value("DEMO", in: ["METERLINE_DEMO": "1", "CODEX_METER_DEMO": "0"]), "1")
        XCTAssertEqual(AppEnvironment.value("DEMO", in: ["METERLINE_DEMO": "", "CODEX_METER_DEMO": "1"]), "1")
        XCTAssertNil(AppEnvironment.value("DEMO", in: [:]))
    }
}
