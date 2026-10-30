import Foundation
import UIKit
import AVFoundation

/// 嗅探命中后：把资源下载到临时文件，并生成元数据（像素/分辨率/时长/首帧）
/// 对应小工具集 WebTask 的 imagePixelSize / videoSize / videoFirstImage / audioDuration
final class MediaProbe {
    static let shared = MediaProbe()

    private let queue = DispatchQueue(label: "sniff.probe", qos: .utility, attributes: .concurrent)
    private let gate = DispatchSemaphore(value: 2)   // 同时最多探测 2 个，避免刷爆网络
    private let session: URLSession
    private let workDir: URL

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 180
        cfg.httpShouldSetCookies = true
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        session = URLSession(configuration: cfg)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SniffProbe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workDir = base
    }

    func probe(_ item: ResourceItem, completion: @escaping (ResourceItem) -> Void) {
        var result = item

        // m3u8 不落地探测（可能是无限直播流），列表里用图标表示
        if item.kind == .hls {
            result.isPreparing = false
            DispatchQueue.main.async { completion(result) }
            return
        }

        queue.async {
            self.gate.wait()
            defer { self.gate.signal() }

            var request = URLRequest(url: item.url)
            for (k, v) in MediaHeaders.headers(for: item) {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let sem = DispatchSemaphore(value: 0)
            var localURL: URL?
            var length: Int64?

            let task = self.session.downloadTask(with: request) { location, response, _ in
                if let http = response as? HTTPURLResponse,
                   let raw = http.value(forHTTPHeaderField: "Content-Length"),
                   let value = Int64(raw) {
                    length = value
                }
                if let location {
                    var ext = (response?.suggestedFilename as NSString?)?.pathExtension ?? ""
                    if ext.isEmpty { ext = item.url.pathExtension }
                    if ext.isEmpty { ext = item.kind == .image ? "jpg" : "mp4" }
                    let dest = self.workDir
                        .appendingPathComponent(item.id.uuidString)
                        .appendingPathExtension(ext.lowercased())
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.moveItem(at: location, to: dest)
                    localURL = dest
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 120)

            guard let file = localURL,
                  FileManager.default.fileExists(atPath: file.path) else {
                result.isPreparing = false
                DispatchQueue.main.async { completion(result) }
                return
            }

            result.localFile = file
            if let length { result.contentLength = length }
            if result.contentLength == nil {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                result.contentLength = size
            }

            switch item.kind {
            case .image:
                if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                    result.pixelSize = image.size
                    result.thumbnail = image
                }
            case .video:
                let asset = AVURLAsset(url: file)
                let seconds = asset.duration.seconds
                if seconds.isFinite, seconds > 0 { result.duration = seconds }
                if let track = asset.tracks(withMediaType: .video).first {
                    let transformed = track.naturalSize.applying(track.preferredTransform)
                    result.videoSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 320)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
                if let cg = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600),
                                                       actualTime: nil) {
                    result.thumbnail = UIImage(cgImage: cg)
                }
            case .audio:
                let asset = AVURLAsset(url: file)
                let seconds = asset.duration.seconds
                if seconds.isFinite, seconds > 0 { result.duration = seconds }
            default:
                break
            }

            result.isPreparing = false
            DispatchQueue.main.async { completion(result) }
        }
    }
}
