import Foundation
import OSLog

/// voiceink-zhtw：延遲調查用的計時紀錄，只記時間和數量，不記內容。
/// App 那邊有一份一樣的（VoiceInk/Features/ZhTW/ZhTWTiming.swift）；XPC 是另一個 target，看不到那個檔案。
/// 查看：scripts/timing-report.sh
enum ZhTWTiming {
    static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ZhTWTiming")

    static func seconds(_ duration: Duration) -> String {
        let (wholeSeconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(wholeSeconds) + Double(attoseconds) / 1e18)
    }

    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.3f", interval)
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// 0 nominal、1 fair、2 serious、3 critical
    static var thermalState: Int {
        ProcessInfo.processInfo.thermalState.rawValue
    }

    static var lowPowerMode: Int {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0
    }

    /// 33 userInteractive、25 userInitiated、21 default、17 utility、9 background
    static var currentQoS: UInt32 {
        qos_class_self().rawValue
    }
}
