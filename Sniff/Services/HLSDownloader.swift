import Foundation
import AVFoundation
import CommonCrypto

/// HLS（m3u8）下载器
/// - 主列表选最高码率
/// - 支持两种分片封装：MPEG-TS（拼 .ts）与 fMP4（EXT-X-MAP init + .m4s 直拼 .mp4）
/// - AES-128 解密、分片并发下载、失败重试并降级请求头
/// - 最后统一尝试转封装成标准 mp4（视频直拷、音频转 AAC）
final class HLSDownloader {

    enum HLError: LocalizedError {
        case requestFailed(Int)
        case segmentFailed(Int, Int, Int)
        case badPlaylist
        case noSegments
        case decryptFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code):
                return code == 0 ? "无法连接服务器（网络或域名不通）" : "播放列表请求失败（HTTP \(code)）"
            case .segmentFailed(let index, let total, let code):
                return "第 \(index)/\(total) 片失败（HTTP \(code)）"
            case .badPlaylist:   return "m3u8 解析失败"
            case .noSegments:    return "播放列表里没有分片"
            case .decryptFailed: return "分片解密失败"
            case .cancelled:     return "已取消"
            }
        }
    }

    private struct Segment {
        let url: URL
        let keyURL: URL?
        let iv: Data?
    }

    private struct Playlist {
        let segments: [Segment]
        let mapURL: URL?      // EXT-X-MAP：fMP4 的 init 段
        var isFMP4: Bool { mapURL != nil }
    }

    private enum FetchMode {
        case full
        case noReferer
        case plain
    }

    private let referer: String
    private let userAgent: String
    private let workDir: URL
    private var session: URLSession!
    private var cancelled = false
    private var paused = false
    private let lock = NSLock()
    private var keyCache: [String: Data] = [:]
    private let keyLock = NSLock()
    private var activeMuxer: TSRemuxer?
    private var nativeDownloader: NativeHLSDownloader?

    init(referer: String, userAgent: String, workDir: URL) {
        self.referer = referer
        self.userAgent = userAgent
        self.workDir = workDir
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpShouldSetCookies = true
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        session = URLSession(configuration: cfg)
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        keyLock.lock(); let m = activeMuxer; let n = nativeDownloader; keyLock.unlock()
        m?.cancel()
        n?.cancel()
        session.invalidateAndCancel()
    }

    func pause() {
        lock.lock(); paused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); paused = false; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    // MARK: - 入口

    func run(playlistURL: URL,
             progress: @escaping (Double) -> Void,
             completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = self.work(playlistURL: playlistURL, progress: progress)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 主流程

    private func work(playlistURL: URL, progress: @escaping (Double) -> Void) -> Result<URL, Error> {
        // 首选：系统未公开但稳定的 HLS 离线下载（TS/fMP4/AES 都由 AVFoundation 处理）
        var nativeHeaders: [String: String] = ["User-Agent": userAgent]
        if !referer.isEmpty { nativeHeaders["Referer"] = referer }

        let native = NativeHLSDownloader()
        keyLock.lock(); nativeDownloader = native; keyLock.unlock()
        let started = Date()

        if let pkg = native.download(playlistURL, headers: nativeHeaders, timeout: 600, progress: progress) {
            diag("native=ok \(Int(Date().timeIntervalSince(started)))s pkg=\(pkg.lastPathComponent)")
            let dest = workDir.appendingPathComponent("hls_\(UUID().uuidString).mp4")
            if let mp4 = NativeHLSDownloader.export(from: pkg, to: dest) {
                try? FileManager.default.removeItem(at: pkg)
                HLSDownloader.lastDiagnostic = "native=ok"
                diag("result=native-export-ok size=\((try? FileManager.default.attributesOfItem(atPath: mp4.path))?[.size] as? NSNumber ?? 0)")
                return .success(mp4)
            }
            diag("native-export-failed \(NativeHLSDownloader.lastError)")
        } else {
            diag("native=failed \(Int(Date().timeIntervalSince(started)))s \(NativeHLSDownloader.lastError)")
        }

        guard var text = fetchText(playlistURL) else { return .failure(HLError.requestFailed(0)) }
        var base = playlistURL

        // 主播放列表：选最高码率子列表
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariant(in: text, base: playlistURL),
                  let sub = fetchText(variant) else { return .failure(HLError.badPlaylist) }
            base = variant
            text = sub
        }

        let playlist = parse(text, base: base)
        guard !playlist.segments.isEmpty else { return .failure(HLError.noSegments) }

        let total = playlist.segments.count
        let ext = playlist.isFMP4 ? "mp4" : "ts"
        let output = workDir.appendingPathComponent("hls_\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: output) else { return .failure(HLError.badPlaylist) }

        // fMP4：先写 init 段（EXT-X-MAP），否则后续分片无法解析
        if let mapURL = playlist.mapURL {
            guard case .success(let initData) = fetchWithRetry(mapURL) else {
                try? handle.close()
                try? FileManager.default.removeItem(at: output)
                return .failure(HLError.requestFailed(0))
            }
            handle.write(initData)
        }

        let tmpDir = workDir.appendingPathComponent("hls_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let concurrency = DownloadSettings.maxConcurrent
        let stateLock = NSLock()
        var completed = 0
        var firstError: Error?

        let queue = DispatchQueue(label: "sniff.hls.segments", qos: .utility, attributes: .concurrent)
        let sem = DispatchSemaphore(value: concurrency)
        let group = DispatchGroup()

        for (index, seg) in playlist.segments.enumerated() {
            sem.wait()
            stateLock.lock()
            let stop = (firstError != nil) || cancelled
            stateLock.unlock()
            if stop { sem.signal(); break }

            group.enter()
            queue.async { [weak self] in
                defer { sem.signal(); group.leave() }
                guard let self else { return }

                while self.isPaused && !self.isCancelled {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                if self.isCancelled { return }

                let fetched = self.fetchWithRetry(seg.url, isSegment: true, index: index, total: total)
                var data: Data
                switch fetched {
                case .success(let d):
                    data = d
                case .failure(let error):
                    stateLock.lock()
                    if firstError == nil { firstError = error }
                    stateLock.unlock()
                    return
                }

                if let keyURL = seg.keyURL {
                    guard let keyData = self.key(for: keyURL) else {
                        stateLock.lock()
                        if firstError == nil { firstError = HLError.decryptFailed }
                        stateLock.unlock()
                        return
                    }
                    guard let plain = Self.aes128Decrypt(data, key: keyData,
                                                         iv: seg.iv ?? Self.sequenceIV(index)) else {
                        stateLock.lock()
                        if firstError == nil { firstError = HLError.decryptFailed }
                        stateLock.unlock()
                        return
                    }
                    data = plain
                }

                let partURL = tmpDir.appendingPathComponent(String(format: "%05d.part", index))
                try? data.write(to: partURL)

                BandwidthLimiter.shared.consume(data.count)

                stateLock.lock()
                completed += 1
                let p = Double(completed) / Double(total) * 0.9
                stateLock.unlock()
                progress(p)
            }
        }
        group.wait()

        stateLock.lock()
        let error = firstError
        let done = completed
        stateLock.unlock()

        if let error {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: tmpDir)
            return .failure(error)
        }
        if isCancelled {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: tmpDir)
            return .failure(HLError.cancelled)
        }
        if done < total {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: tmpDir)
            return .failure(HLError.segmentFailed(done + 1, total, 0))
        }

        // 按顺序把分片追加到输出
        for i in 0..<total {
            let partURL = tmpDir.appendingPathComponent(String(format: "%05d.part", i))
            if let data = try? Data(contentsOf: partURL) {
                handle.write(data)
            }
        }
        try? handle.close()
        try? FileManager.default.removeItem(at: tmpDir)

        // 不信 playlist 的标签，按真实字节判断容器（很多站写着 .ts、内容其实是 fMP4）
        let actual = Self.containerKind(of: output)
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let appVersion = "\(short)(\(build))"
        diag("app=\(appVersion)")
        diag("playlist=\(playlistURL.absoluteString)")
        diag("declaredFMP4=\(playlist.isFMP4) actual=\(actual) segments=\(total)")
        diag("head=\(Self.headHex(of: output))")

        var source = output
        if actual == .fmp4 && output.pathExtension.lowercased() != "mp4" {
            let renamed = output.deletingPathExtension().appendingPathExtension("mp4")
            try? FileManager.default.removeItem(at: renamed)
            if (try? FileManager.default.moveItem(at: output, to: renamed)) != nil {
                source = renamed
            }
        }

        switch actual {
        case .fmp4, .mp4:
            // 已是 mp4 家族：交给 AVFoundation 重排（补 moov），失败也能播
            if let mp4 = remux(from: source) {
                if source != output { try? FileManager.default.removeItem(at: output) }
                try? FileManager.default.removeItem(at: source)
                diag("result=remuxed \(mp4.lastPathComponent)")
                return .success(mp4)
            }
            diag("result=passthrough-mp4")
            return .success(source)

        case .ts:
            // 首选 FFmpeg：demux/mux 都交给它，能处理各种不规范封装
            let ffDest = source.deletingPathExtension().appendingPathExtension("mp4")
            if FFmpegRemuxer.remux(ts: source, to: ffDest) {
                try? FileManager.default.removeItem(at: source)
                diag("result=ffmpeg-ok")
                HLSDownloader.lastDiagnostic = "ffmpeg=ok"
                return .success(ffDest)
            }
            diag("ffmpeg=failed \(FFmpegRemuxer.lastError)")

            // 兜底：手写 demux
            let muxer = TSRemuxer()
            keyLock.lock(); activeMuxer = muxer; keyLock.unlock()
            if let mp4 = muxer.remux(tsURL: source, outputBase: source.deletingPathExtension()) {
                try? FileManager.default.removeItem(at: source)
                diag("result=ts-remuxed \(mp4.lastPathComponent)")
                return .success(mp4)
            }
            diag("result=ts-remux-failed")
            if !TSRemuxer.lastStats.isEmpty { diag("stats=\(TSRemuxer.lastStats)") }
            if let mp4 = remux(from: source) {
                try? FileManager.default.removeItem(at: source)
                diag("result=avfoundation-fallback")
                return .success(mp4)
            }
            return .success(source)

        default:
            diag("result=unknown-container")
            if let mp4 = remux(from: source) {
                try? FileManager.default.removeItem(at: source)
                return .success(mp4)
            }
            return .success(source)
        }
    }


    // MARK: - 容器判定 / 诊断

    enum Container { case ts, fmp4, mp4, unknown }

    /// 按文件头判断真实容器：TS 以 0x47 同步字节开头；ISO-BMFF 前部会出现 ftyp/styp/moof
    static func containerKind(of url: URL) -> Container {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        let head = handle.readData(ofLength: 4096)
        try? handle.close()
        guard head.count >= 8 else { return .unknown }

        if head[0] == 0x47 && head.count >= 188 && head[188] == 0x47 { return .ts }
        if head[0] == 0x47 { return .ts }

        let ascii = String(decoding: head, as: UTF8.self)
        if ascii.contains("ftyp") || ascii.contains("styp") || ascii.contains("moof") {
            return .fmp4
        }
        if ascii.contains("moov") || ascii.contains("mdat") { return .mp4 }
        return .unknown
    }

    static func headHex(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "?" }
        let head = handle.readData(ofLength: 16)
        try? handle.close()
        return head.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 最近一次转封装的诊断摘要（界面上直接显示，截图即可定位）
    static var lastDiagnostic = ""

    /// 诊断写盘：Documents/Sniff/hls-diag.txt（文件 App 里可见）
    private func diag(_ line: String) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("Sniff", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hls-diag.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        if line.hasPrefix("result=") || line.hasPrefix("declaredFMP4") || line.hasPrefix("head=")
            || line.hasPrefix("native=") || line.hasPrefix("stats=") {
            let brief = line
            let existing = Self.lastDiagnostic
            let merged = existing.isEmpty ? brief : (existing + " | " + brief)
            Self.lastDiagnostic = String(merged.suffix(160))
        }
        let text = "[\(stamp)] \(line)\n"
        if let data = text.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }

    private func key(for url: URL) -> Data? {
        let key = url.absoluteString
        keyLock.lock()
        let cached = keyCache[key]
        keyLock.unlock()
        if let cached { return cached }

        guard case .success(let data) = fetchWithRetry(url) else { return nil }
        keyLock.lock()
        keyCache[key] = data
        keyLock.unlock()
        return data
    }

    // MARK: - m3u8 解析

    private func bestVariant(in text: String, base: URL) -> URL? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var best: (bw: Int, url: URL)?
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            let attrs = attributes(line)
            let bw = Int(attrs["BANDWIDTH"] ?? "0") ?? 0
            var j = i + 1
            while j < lines.count && (lines[j].isEmpty || lines[j].hasPrefix("#")) { j += 1 }
            guard j < lines.count, let u = URL(string: lines[j], relativeTo: base)?.absoluteURL else { continue }
            if best == nil || bw > best!.bw { best = (bw, u) }
        }
        return best?.url
    }

    private func parse(_ text: String, base: URL) -> Playlist {
        var segments: [Segment] = []
        var keyURL: URL?
        var iv: Data?
        var mapURL: URL?

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(line)
                if let uri = attrs["URI"], let u = URL(string: uri, relativeTo: base)?.absoluteURL {
                    mapURL = u
                }
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(line)
                let method = (attrs["METHOD"] ?? "").uppercased()
                if method == "NONE" {
                    keyURL = nil
                    iv = nil
                } else if method == "AES-128" {
                    if let uri = attrs["URI"], let u = URL(string: uri, relativeTo: base)?.absoluteURL {
                        keyURL = u
                    }
                    if let hex = attrs["IV"] {
                        iv = Self.dataFromHex(hex)
                    }
                }
            } else if !line.hasPrefix("#") {
                guard let u = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                segments.append(Segment(url: u, keyURL: keyURL, iv: iv))
            }
        }
        return Playlist(segments: segments, mapURL: mapURL)
    }

    private func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let body = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for ch in body {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }

        var dict: [String: String] = [:]
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
            dict[key] = value
        }
        return dict
    }

    // MARK: - 网络

    private func rawFetch(_ url: URL, mode: FetchMode) -> (Data?, Int) {
        if isCancelled { return (nil, 0) }
        var data: Data?
        var status = 0
        let sem = DispatchSemaphore(value: 0)

        var req: URLRequest
        switch mode {
        case .full:
            req = MediaHeaders.request(url: url, referer: referer, userAgent: userAgent)
        case .noReferer:
            req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        case .plain:
            req = URLRequest(url: url)
        }

        session.dataTask(with: req) { d, resp, _ in
            data = d
            if let http = resp as? HTTPURLResponse {
                status = http.statusCode
            } else {
                status = (d == nil) ? 0 : 200
            }
            sem.signal()
        }.resume()

        _ = sem.wait(timeout: .now() + 45)
        return (data, status)
    }

    private func fetchWithRetry(_ url: URL, isSegment: Bool = false, index: Int = 0, total: Int = 0) -> Result<Data, Error> {
        let modes: [FetchMode] = [.full, .full, .noReferer, .plain]
        let delays: [TimeInterval] = [0.6, 1.5, 3.0]
        var lastStatus = 0

        for attempt in 0..<modes.count {
            let (data, status) = rawFetch(url, mode: modes[attempt])
            if let data, !data.isEmpty {
                return .success(data)
            }
            lastStatus = status
            if attempt < delays.count && !isCancelled {
                Thread.sleep(forTimeInterval: delays[attempt])
            }
        }
        if isSegment {
            return .failure(HLError.segmentFailed(index + 1, total, lastStatus))
        }
        return .failure(HLError.requestFailed(lastStatus))
    }

    private func fetchText(_ url: URL) -> String? {
        guard case .success(let data) = fetchWithRetry(url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - 转封装
    // 视频直拷（passthrough）、音频统一转 AAC（解决 TS 里 ADTS/AC-3 不被 MP4 接受的问题）

    private func remux(from source: URL) -> URL? {
        let asset = AVURLAsset(url: source)
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { return nil }

        for fileType in [AVFileType.mp4, AVFileType.mov] {
            if let url = write(asset: asset, video: videoTracks, audio: audioTracks,
                               near: source, fileType: fileType) {
                return url
            }
        }
        return nil
    }

    private func write(asset: AVURLAsset,
                       video: [AVAssetTrack],
                       audio: [AVAssetTrack],
                       near source: URL,
                       fileType: AVFileType) -> URL? {
        let ext = (fileType == .mov) ? "mov" : "mp4"
        let base = source.deletingPathExtension()
        var dest = base.appendingPathExtension(ext)
        // 源文件本身可能就是 mp4/mov：不能把目标设成源本身，否则会先把源删掉再读
        if dest.standardizedFileURL == source.standardizedFileURL {
            dest = URL(fileURLWithPath: base.path + "-out." + ext)
        }
        try? FileManager.default.removeItem(at: dest)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: dest, fileType: fileType) else { return nil }

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []

        for track in video {
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

        for track in audio {
            // 读 PCM，写 AAC：不管源是 AAC(ADTS) 还是 AC-3，都能落进 MP4
            let output: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let input: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: input)
            writerInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerInput) else { continue }

            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: output)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { continue }

            writer.add(writerInput)
            reader.add(readerOutput)
            pairs.append((readerOutput, writerInput))
        }

        guard !pairs.isEmpty else { return nil }
        guard reader.startReading(), writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        var active = pairs
        var appendedAny = false
        while !active.isEmpty {
            if reader.status == .failed { break }
            var progressed = false
            var index = active.count - 1
            while index >= 0 {
                let (output, input) = active[index]
                if input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        if input.append(sample) {
                            appendedAny = true
                            progressed = true
                        } else {
                            input.markAsFinished()
                            active.remove(at: index)
                            progressed = true
                        }
                    } else {
                        input.markAsFinished()
                        active.remove(at: index)
                        progressed = true
                    }
                }
                index -= 1
            }
            if !progressed {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 180)

        guard appendedAny, writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return dest
    }

    // MARK: - AES-128

    static func sequenceIV(_ index: Int) -> Data {
        var be = UInt64(index).bigEndian
        let bytes = withUnsafeBytes(of: &be) { Data($0) }
        var out = Data(repeating: 0, count: 8)
        out.append(bytes)
        return out
    }

    static func dataFromHex(_ hex: String) -> Data? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    static func aes128Decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var ivData = iv
        if ivData.count < 16 {
            ivData.append(Data(repeating: 0, count: 16 - ivData.count))
        }
        if ivData.count > 16 {
            ivData = Data(ivData.prefix(16))
        }

        let outLength = data.count + kCCBlockSizeAES128
        var out = Data(count: outLength)
        var moved = 0

        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            data.withUnsafeBytes { dataPtr -> CCCryptorStatus in
                key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    ivData.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outLength,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}
