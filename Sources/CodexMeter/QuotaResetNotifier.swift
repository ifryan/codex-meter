// SPDX-License-Identifier: GPL-3.0-only
import OSLog
import UserNotifications

final class QuotaResetNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.codexmeter",
        category: "notification"
    )

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func prepare() {
        center.requestAuthorization(options: [.alert, .sound]) { [logger] _, error in
            if let error {
                logger.error("Failed to request notification authorization: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func notify(_ event: QuotaResetEvent) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 额度已重置"
        content.body = "主额度已恢复至 \(event.currentRemainingPercent)%"
        content.sound = .default
        content.threadIdentifier = "codex-quota"

        let timestamp = Int(event.detectedAt.timeIntervalSince1970)
        let request = UNNotificationRequest(
            identifier: "codex-primary-reset-\(timestamp)",
            content: content,
            trigger: nil
        )
        center.add(request) { [logger] error in
            if let error {
                logger.error("Failed to deliver quota reset notification: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
