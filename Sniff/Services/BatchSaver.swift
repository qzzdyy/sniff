import Foundation
import Photos
import UIKit

/// 批量保存：相册 / 文件 / 分享。远程资源先落地到临时目录，再交给系统。
final class BatchSaver {
    static let shared = BatchSaver()

    struct Summary {
        var saved = 0
        var failed = 0
        var skipped = 0

        var text: String {
            var parts: [String] = []
            if saved > 0 { parts.append("完成 \(saved) 项") }
            if failed > 0 { parts.append("失败 \(failed) 项") }
            if skipped > 0 { parts.append("跳过 \(skipped) 项") }
            return parts.isEmpty ? "没有可处理的内容" : parts.joined(separator: "，")
        }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    // MARK: - 相册

    func requestAuth(_ completion: @escaping (Bool) -> Void) {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited {
            completion(true)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    /// 只处理图片和视频；m3u8 / 音频需要先下载，直接跳过并计数
    func saveToAlbum(_ items: [ResourceItem],
                     progress: ((Int, Int) -> Void)? = nil,
                     completion: @escaping (Summary) -> Void) {
        let usable = items.filter { $0.kind == .image || $0.kind == .video }
        var initial = Summary()
        initial.skipped = items.count - usable.count

        guard !usable.isEmpty else {
            DispatchQueue.main.async { completion(initial) }
            return
        }

        step(usable, index: 0, summary: initial, progress: progress, completion: completion)
    }

    private func step(_ items: [ResourceItem],
                      index: Int,
                      summary: Summary,
                      progress: ((Int, Int) -> Void)?,
                      completion: @escaping (Summary) -> Void) {
        if index >= items.count {
            DispatchQueue.main.async { completion(summary) }
            return
        }

        let item = items[index]
        let advance: (Bool) -> Void = { ok in
            var next = summary
            if ok { next.saved += 1 } else { next.failed += 1 }
            progress?(index + 1, items.count)
            self.step(items, index: index + 1, summary: next,
                      progress: progress, completion: completion)
        }

        if let local = item.localFile, FileManager.default.fileExists(atPath: local.path) {
            writeToAlbum(local, isVideo: item.kind == .video, completion: advance)
            return
        }

        download(item) { url in
            guard let url else { advance(false); return }
            self.writeToAlbum(url, isVideo: item.kind == .video) { ok in
                try? FileManager.default.removeItem(at: url)
                advance(ok)
            }
        }
    }

    private func writeToAlbum(_ url: URL, isVideo: Bool, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            if isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }) { ok, _ in
            completion(ok)
        }
    }

    // MARK: - 落地成本地文件（存「文件」/ 分享用）

    func materialize(_ items: [ResourceItem], completion: @escaping ([URL]) -> Void) {
        guard !items.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        var results = [URL?](repeating: nil, count: items.count)
        let lock = NSLock()
        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 3)

        for (index, item) in items.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()

                if let local = item.localFile, FileManager.default.fileExists(atPath: local.path) {
                    lock.lock()
                    results[index] = local
                    lock.unlock()
                    semaphore.signal()
                    group.leave()
                    return
                }

                self.download(item) { url in
                    if let url {
                        lock.lock()
                        results[index] = url
                        lock.unlock()
                    }
                    semaphore.signal()
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(results.compactMap { $0 })
        }
    }

    // MARK: - 下载

    private func download(_ item: ResourceItem, completion: @escaping (URL?) -> Void) {
        var request = MediaHeaders.request(for: item)
        request.timeoutInterval = 60

        session.downloadTask(with: request) { temp, response, error in
            guard let temp, error == nil else {
                completion(nil)
                return
            }

            var ext = item.url.pathExtension
            if ext.isEmpty, let suggested = response?.suggestedFilename {
                let s = suggested as NSString
                if !s.pathExtension.isEmpty { ext = s.pathExtension }
            }
            if ext.isEmpty { ext = "bin" }

            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("sniff-batch-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
                completion(dest)
            } catch {
                completion(nil)
            }
        }.resume()
    }
}
