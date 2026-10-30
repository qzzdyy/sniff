import Foundation

/// 下载带宽限速（令牌桶，简单够用）
/// 0 表示不限速，值单位 KB/s
final class BandwidthLimiter {
    static let shared = BandwidthLimiter()

    private let lock = NSLock()
    private var nextSlot = Date()

    private init() {}

    var limitKBps: Int {
        UserDefaults.standard.object(forKey: "speedLimitKBps") as? Int ?? 0
    }

    /// 下载完一段数据后调用，必要时阻塞等待
    func consume(_ bytes: Int) {
        let kbps = limitKBps
        guard kbps > 0, bytes > 0 else { return }

        let seconds = Double(bytes) / (Double(kbps) * 1024.0)
        lock.lock()
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(seconds)
        let wait = nextSlot.timeIntervalSince(now)
        lock.unlock()

        if wait > 0.02 {
            Thread.sleep(forTimeInterval: min(wait, 2.0))
        }
    }
}

/// 下载相关设置（与设置页 @AppStorage 共用 key）
enum DownloadSettings {
    static var maxConcurrent: Int {
        let v = UserDefaults.standard.object(forKey: "maxConcurrent") as? Int ?? 4
        return max(1, min(8, v))
    }

    static var speedLimitKBps: Int {
        UserDefaults.standard.object(forKey: "speedLimitKBps") as? Int ?? 0
    }
}
