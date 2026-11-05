// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Persists the last successfully fetched Claude snapshot so a launch that can't reach the usage
/// endpoint — an expired session token, an offline laptop — shows the last known percentages
/// (labelled with their age) instead of an empty meter.
///
/// Deliberately best-effort: any read or write failure is swallowed, since a missing cache is only
/// ever a cosmetic degradation.
struct ClaudeSnapshotCache {
    /// Past this age the numbers are too stale to be worth showing at all.
    static let maximumUsefulAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL?

    init(fileURL: URL? = ClaudeSnapshotCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL? {
        guard
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let directory = base.appendingPathComponent(LegacyMigration.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("claude-usage.json")
    }

    func load(now: Date = Date()) -> ClaudeUsageSnapshot? {
        guard
            let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
        else {
            return nil
        }
        guard now.timeIntervalSince(snapshot.capturedAt) <= Self.maximumUsefulAge else { return nil }
        return snapshot
    }

    func save(_ snapshot: ClaudeUsageSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Renders how long ago a cached snapshot was captured, for the "数据于 X 前" staleness label.
enum StalenessFormatter {
    /// Below this the numbers are effectively current, so callers shouldn't label them at all.
    static let freshnessThreshold: TimeInterval = 10 * 60

    static func ageText(since capturedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(capturedAt))
        if seconds < 3_600 { return L("%@m ago", "\(Int(seconds / 60))") }
        if seconds < 86_400 { return L("%@h ago", "\(Int(seconds / 3_600))") }
        return L("%@d ago", "\(Int(seconds / 86_400))")
    }
}
