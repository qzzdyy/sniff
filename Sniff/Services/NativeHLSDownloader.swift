import Foundation
import AVFoundation
import CoreMedia

/// 用系统自带的 HLS 离线下载（AVAssetDownloadURLSession）把 m3u8 落成离线资源，再导出 mp4。
///
/// 为什么不自己解 TS：
/// 自己 demux 要对 PAT/PMT/PES/ADTS/NAL 逐层解析，站点一旦不按标准写 PSI（比如 SDT 打头、
/// 没有 PMT），整条链路就空转。系统这套是播放器同源实现，TS / fMP4 / AES-128 / 字节范围
/// 全部由 AVFoundation 处理，稳定性远高于手写。
final class NativeHLSDownloader: NSObject, AVAssetDownloadDelegate {

    private var session: AVAssetDownloadURLSession?
    private var task: AVAssetDownloadTask?
    private var progressHandler: ((Double) -> Void)?
    /// 是否收到过任何 delegate 回调（用来识别「回调根本没来」）
    private var gotCallback = false

    /// 上一次失败的原因（诊断用）
    static var lastError = "-"

    /// 系统把后台会话事件交回来时，AppDelegate 会存下这个回调
    static var backgroundCompletion: (() -> Void)?

    private let done = DispatchSemaphore(value: 0)
    private var resultURL: URL?
    private var failure: Error?

    /// 同步阻塞，返回本地离线资源的 URL（.movpkg 目录）；失败返回 nil
    func download(_ playlist: URL,
                  headers: [String: String],
                  timeout: TimeInterval = 900,
                  progress: @escaping (Double) -> Void) -> URL? {
        progressHandler = progress

        let config = URLSessionConfiguration.background(withIdentifier: "sniff.hls.\(UUID().uuidString)")
        config.allowsCellularAccess = true
        config.httpAdditionalHeaders = headers
        config.timeoutIntervalForRequest = 60

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        let session = AVAssetDownloadURLSession(configuration: config,
                                                assetDownloadDelegate: self,
                                                delegateQueue: queue)
        self.session = session

        let asset = AVURLAsset(url: playlist, options: [
            "AVURLAssetHTTPHeaderFieldsKey": headers
        ])
        guard let task = session.makeAssetDownloadTask(
            asset: asset,
            assetTitle: "sniff",
            assetArtworkData: nil,
            options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 0]) else {
            return nil
        }
        self.task = task
        task.resume()

        // 轮询等待：40 秒内一次回调都没有就判定为「后台会话事件没送达」，快速失败
        let start = Date()
        var finished = false
        while Date().timeIntervalSince(start) < timeout {
            if done.wait(timeout: .now() + 1) == .success { finished = true; break }
            if !gotCallback, Date().timeIntervalSince(start) > 40 {
                task.cancel()
                session.invalidateAndCancel()
                Self.lastError = "noCallback40s"
                return nil
            }
        }

        if !finished || (resultURL == nil && failure == nil) {
            task.cancel()
            session.invalidateAndCancel()
            Self.lastError = finished ? "noResult" : "timeout\(Int(Date().timeIntervalSince(start)))s"
            return nil
        }
        if let failure {
            Self.lastError = "err=\(failure.localizedDescription.prefix(80))"
            return nil
        }
        Self.lastError = "ok"
        return resultURL
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        done.signal()
    }

    // MARK: - 进度

    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        gotCallback = true
        guard timeRangeExpectedToLoad.duration.seconds > 0 else { return }
        var loaded: Double = 0
        for value in loadedTimeRanges {
            loaded += value.timeRangeValue.duration.seconds
        }
        let p = min(1.0, loaded / timeRangeExpectedToLoad.duration.seconds)
        progressHandler?(p * 0.9)
    }

    func urlSession(_ session: URLSession,
                    assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        resultURL = location
        done.signal()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            NativeHLSDownloader.backgroundCompletion?()
            NativeHLSDownloader.backgroundCompletion = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        gotCallback = true
        if let error {
            failure = error
            done.signal()
        }
    }

    // MARK: - 导出 MP4

    /// 把离线资源重封装成标准 mp4（采样直拷，不重编码）
    static func export(from assetURL: URL, to dest: URL) -> URL? {
        let asset = AVURLAsset(url: assetURL)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { return nil }

        try? FileManager.default.removeItem(at: dest)
        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: dest, fileType: .mp4) else { return nil }

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []

        for track in videoTracks.prefix(1) {
            var hint: CMFormatDescription?
            if let first = track.formatDescriptions.first {
                hint = (first as! CMFormatDescription)
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }

            writer.add(input)
            reader.add(output)
            pairs.append((output, input))
        }

        for track in audioTracks.prefix(1) {
            var hint: CMFormatDescription?
            if let first = track.formatDescriptions.first {
                hint = (first as! CMFormatDescription)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }

            writer.add(input)
            reader.add(output)
            pairs.append((output, input))
        }

        guard !pairs.isEmpty, reader.startReading(), writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        var active = pairs
        var appended = false
        while !active.isEmpty {
            if reader.status == .failed { break }
            var progressed = false
            var i = active.count - 1
            while i >= 0 {
                let (output, input) = active[i]
                if input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        if input.append(sample) {
                            appended = true
                            progressed = true
                        } else {
                            input.markAsFinished()
                            active.remove(at: i)
                            progressed = true
                        }
                    } else {
                        input.markAsFinished()
                        active.remove(at: i)
                        progressed = true
                    }
                }
                i -= 1
            }
            if !progressed { Thread.sleep(forTimeInterval: 0.005) }
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 300)

        guard appended, writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return dest
    }
}
