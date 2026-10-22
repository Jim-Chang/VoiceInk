// punct-ct 工具用的替身:ZhTWPunctuator 載入失敗時會跳 App 的通知,工具裡只印出來。
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    func showNotification(title: String, type: AppNotificationView.NotificationType) {
        print("通知:\(title)")
    }
}

enum AppNotificationView {
    enum NotificationType { case warning }
}
