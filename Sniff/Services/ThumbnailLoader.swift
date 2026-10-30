import Foundation
import UIKit
import AVFoundation

/// 视频缩略图加载器（带 Referer，按 URL 缓存）
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "sniff.thumb", qos: .utility, attributes: .concurrent)

    /// 记录抽帧失败的 URL，避免反复重试
    private var failed = Set<String>()
    private let failLock = NSLock()

    private init() {
        cache.countLimit = 200
    }

    func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func hasFailed(_ url: URL) -> Bool {
        failLock.lock(); defer { failLock.unlock() }
        return failed.contains(url.absoluteString)
    }

    func image(for item: ResourceItem, completion: @escaping (UIImage?) -> Void) {
        let key = item.url.absoluteString as NSString
        if let img = cache.object(forKey: key) {
            completion(img)
            return
        }
        if hasFailed(item.url) {
            completion(nil)
            return
        }

        let headers = MediaHeaders.headers(for: item)
        queue.async {
            let asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            let cg = try? generator.copyCGImage(at: time, actualTime: nil)
            let img = cg.map { UIImage(cgImage: $0) }

            DispatchQueue.main.async {
                if let img {
                    self.cache.setObject(img, forKey: key)
                } else {
                    self.failLock.lock()
                    self.failed.insert(item.url.absoluteString)
                    self.failLock.unlock()
                }
                completion(img)
            }
        }
    }
}
