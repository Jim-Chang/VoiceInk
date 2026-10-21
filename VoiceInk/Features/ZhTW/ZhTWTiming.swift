import Foundation
import OSLog

/// voiceink-zhtw：延遲調查用的計時紀錄，只記時間和數量，不記內容。
/// XPC 子程序那邊有一份一樣的（VoiceInkRefineXPC/ZhTWTiming.swift）。
/// 查看：scripts/timing-report.sh
enum ZhTWTiming {
    static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ZhTWTiming")

    static func seconds(_ duration: Duration) -> String {
        let (wholeSeconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(wholeSeconds) + Double(attoseconds) / 1e18)
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
