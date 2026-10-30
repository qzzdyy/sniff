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
    /// 单个任务内的分片并发数
    static var maxConcurrent: Int {
        let v = UserDefaults.standard.object(forKey: "maxConcurrent") as? Int ?? 4
        return max(1, min(8, v))
    }

    /// 同时进行的任务数（超出后排队）
    static var maxConcurrentTasks: Int {
        let v = UserDefaults.standard.object(forKey: "maxConcurrentTasks") as? Int ?? 1
        return max(1, min(3, v))
    }

    static var speedLimitKBps: Int {
        UserDefaults.standard.object(forKey: "speedLimitKBps") as? Int ?? 0
    }

    /// 按物理内存推导设备可承受的最大线程总数
    static var deviceMaxThreads: Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb >= 8 { return 16 }
        if gb >= 6 { return 12 }
        if gb >= 4 { return 8 }
        if gb >= 3 { return 6 }
        return 4
    }

    static var modeIsSpeed: Bool {
        UserDefaults.standard.string(forKey: "downloadMode") == "speed"
    }

    /// 均衡 / 速度优先：一键写入任务数与分片数
    static func applyMode(speedFirst: Bool) {
        let d = UserDefaults.standard
        if speedFirst {
            d.set(3, forKey: "maxConcurrentTasks")
            d.set(min(8, deviceMaxThreads), forKey: "maxConcurrent")
            d.set("speed", forKey: "downloadMode")
        } else {
            d.set(1, forKey: "maxConcurrentTasks")
            d.set(min(4, deviceMaxThreads), forKey: "maxConcurrent")
            d.set("balance", forKey: "downloadMode")
        }
    }
}
