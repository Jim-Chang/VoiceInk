import AppKit
import SwiftUI

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var notificationWindow: NSPanel?
    private var dismissTimer: Timer?
    private var notificationID: UUID?
    private var usesRecorderPosition = false
    private var recorderOverlayFrame: NSRect?

    private init() {}

    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, action: () -> Void)? = nil,
        atRecorderPosition: Bool = false
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let notificationID = UUID()
        self.notificationID = notificationID
        usesRecorderPosition = atRecorderPosition

        if let existingWindow = notificationWindow {
            existingWindow.close()
            notificationWindow = nil
        }

        // Play esc sound for error notifications
        if type == .error {
            SoundManager.shared.playEscSound()
        }

        let notificationView = AppNotificationView(
            title: title,
            type: type,
            duration: duration,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.dismissNotification(ifCurrent: notificationID)
                }
            },
            onTap: onTap,
            actionButton: actionButton
        )
        let hostingController = NSHostingController(rootView: notificationView)
        let size = hostingController.view.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingController.view
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.mainMenu
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false

        if atRecorderPosition {
            guard positionRecorderNotification(panel) else { return }
        } else {
            positionWindow(panel)
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil as Any?)

        self.notificationWindow = panel

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })

        // Schedule a new timer to dismiss the new notification.
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissNotification(ifCurrent: notificationID)
            }
        }
    }

    func setRecorderOverlayFrame(_ frame: NSRect?) {
        recorderOverlayFrame = frame
        if usesRecorderPosition, let window = notificationWindow {
            _ = positionRecorderNotification(window)
        }
    }

    private func positionRecorderNotification(_ window: NSWindow) -> Bool {
        guard var metrics = MiniRecorderPanel.calculateWindowMetrics(size: window.frame.size) else { return false }
        // A learned notification must not cover another suggestion's actions.
        if let overlay = recorderOverlayFrame, overlay.intersects(metrics) {
            metrics.origin.y = overlay.maxY + 8
        }
        window.setFrameOrigin(metrics.origin)
        return true
    }

    private func positionWindow(_ window: NSWindow) {
        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenRect = activeScreen.visibleFrame
        let notificationRect = window.frame

        // Position notification centered horizontally on screen
        let notificationX = screenRect.midX - (notificationRect.width / 2)

        // Position notification near bottom of screen with appropriate spacing
        let bottomPadding: CGFloat = 24
        let componentHeight: CGFloat = 34
        let notificationSpacing: CGFloat = 16
        let notificationY = screenRect.minY + bottomPadding + componentHeight + notificationSpacing

        window.setFrameOrigin(NSPoint(x: notificationX, y: notificationY))
    }

    func dismissNotification() {
        guard let window = notificationWindow else { return }

        notificationWindow = nil
        notificationID = nil
        usesRecorderPosition = false

        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.close()

            })
    }

    private func dismissNotification(ifCurrent notificationID: UUID) {
        guard self.notificationID == notificationID else { return }
        dismissNotification()
    }
}
