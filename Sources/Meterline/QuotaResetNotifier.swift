// SPDX-License-Identifier: GPL-3.0-only
import OSLog
import UserNotifications

final class QuotaResetNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.ifryan.meterline",
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

    func notify(_ event: QuotaResetEvent, provider: MeterProvider) {
        let content = UNMutableNotificationContent()
        content.title = L("%@ quota has reset", "\(provider.displayName)")
        content.body = L("%1$@ is back to %2$@%%", "\(provider.windowLabel)", "\(event.currentRemainingPercent)")
        content.sound = .default
        content.threadIdentifier = provider.threadIdentifier

        let timestamp = Int(event.detectedAt.timeIntervalSince1970)
        let request = UNNotificationRequest(
            identifier: "\(provider.identifierPrefix)-reset-\(timestamp)",
            content: content,
            trigger: nil
        )
        center.add(request) { [logger] error in
            if let error {
                logger.error("Failed to deliver quota reset notification: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func notify(_ event: QuotaResetEvent, account: SourceAccount, metric: MonitorMetric) {
        let content = UNMutableNotificationContent()
        content.title = L("%@ quota has reset", "\(account.name)")
        content.body = L("%1$@ is back to %2$@%%", "\(metric.title)", "\(event.currentRemainingPercent)")
        content.sound = .default
        content.threadIdentifier = "account-\(account.id.uuidString)"
        let request = UNNotificationRequest(identifier: "\(account.id.uuidString)-\(metric.id)-\(Int(event.detectedAt.timeIntervalSince1970))", content: content, trigger: nil)
        center.add(request) { [logger] error in
            if error != nil { logger.error("Failed to deliver account quota notification") }
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
