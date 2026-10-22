import Foundation
import OSLog

/// voiceink-zhtw：延遲調查用的計時紀錄，只記時間和數量，不記內容。
/// 查看：python3 -I scripts/timing_report.py
enum ZhTWTiming {
    static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ZhTWTiming")

    static func seconds(_ duration: Duration) -> String {
        let (wholeSeconds, attoseconds) = duration.components
        return String(format: "%.3f", Double(wholeSeconds) + Double(attoseconds) / 1e18)
    }
}
