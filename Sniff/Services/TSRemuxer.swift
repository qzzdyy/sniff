import Foundation
import AVFoundation
import CoreMedia

/// 把 MPEG-TS 转封装成 MP4。
///
/// 为什么不用 AVURLAsset 直接读 .ts：
/// iOS 的 AVFoundation 只在 HLS 播放链路里做 TS demux，直接打开一个本地拼起来的 .ts
/// 往往拿不到任何 track（remux 必然失败，于是只能留下 .ts，相册拒收）。
/// 这里自己解 TS → PES → 基本流，再把 H.264(AVCC) / AAC(裸帧) 交给 AVAssetWriter 封装。
final class TSRemuxer {

    private static let packetSize = 188

    private let lock = NSLock()
    /// 上一次转封装的统计（失败时用来定位）
    static var lastStats = ""

    private var cancelledFlag = false

    func cancel() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }
    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelledFlag
    }

    // MARK: - TS 层状态

    private var pmtPID = -1
    private var videoPID = -1
    private var audioPID = -1
    private var declaredAudio = false

    private var pesBuffers: [Int: Data] = [:]

    // MARK: - 编解码参数

    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var videoCodec: UInt8 = 0x1B      // 0x1B = H.264, 0x24 = HEVC
    private var codecDetected = false
    private var formatStatus: Int32 = -1
    private var canAddResult = "-"
    private var appendFail = "-"
    private var sampleFail = "-"
    private var aacObjectType: UInt8 = 2          // AAC-LC
    private var aacFreqIndex: UInt8 = 4           // 44100
    private var aacChannels: UInt8 = 2
    private var audioSampleRate: Double = 44100
    private var audioParamReady = false
    private var audioCarry: [UInt8] = []
    private var audioFrameIndex = 0
    private var audioBasePTS: Int64 = -1

    private static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000,
                                                24000, 22050, 16000, 12000, 11025, 8000, 7350]

    // MARK: - 输出

    private var writer: AVAssetWriter?
    /// writer 是否已经 add input 并 startWriting（writer 本身在 remux 开头就创建了，不能用 nil 判断）
    private var writerReady = false
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMFormatDescription?
    private var destURL: URL?

    private var pendingVideo: [(data: Data, pts: Int64, dts: Int64, key: Bool)] = []
    private var pendingVideoBytes = 0
    private var pendingAudio: [(data: Data, pts: Int64)] = []

    private var basePTS: Int64 = -1
    private var lastVideoPTS: Int64 = -1
    private var lastVideoDTS: Int64 = -1
    private var videoCount = 0
    private var videoPESCount = 0
    private var nalCount = 0
    private var audioCount = 0
    private var frameDuration: Int64 = 3000       // 90kHz，默认 30fps

    // MARK: - 入口

    /// - Returns: 生成的 mp4（或 mov）地址；失败返回 nil
    func remux(tsURL: URL, outputBase: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tsURL.path),
              let size = attrs[.size] as? NSNumber, size.int64Value > 0 else { return fail("badFile") }
        let totalBytes = size.int64Value

        let dest = outputBase.appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: dest)
        guard let w = try? AVAssetWriter(outputURL: dest, fileType: .mp4) else { return fail("writerInit") }
        writer = w
        destURL = dest

        guard let handle = try? FileHandle(forReadingFrom: tsURL) else { return fail("openFail") }
        defer { try? handle.close() }

        var carry = Data()
        var processed: Int64 = 0
        let chunkSize = 4 * 1024 * 1024

        while !isCancelled {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            carry.append(chunk)
            processed += Int64(chunk.count)

            let usable = carry.count / Self.packetSize * Self.packetSize
            if usable > 0 {
                process(carry, end: usable)
                carry = carry.subdata(in: usable..<carry.count)
            }

            if totalBytes > 0 {
                progress?(min(1.0, Double(processed) / Double(totalBytes)))
            }
        }

        // 收尾：flush 所有未完成 PES
        for pid in Array(pesBuffers.keys) { flush(pid: pid) }

        guard let writer else { return fail("writerNil") }
        guard writer.status == .writing else {
            recordStats("notWriting status=\(writer.status.rawValue)")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        _ = sem.wait(timeout: .now() + 60)

        guard writer.status == .completed, videoCount + audioCount > 0 else {
            recordStats("finishFail status=\(writer.status.rawValue)")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        // 有视频轨但一帧都没写进去：说明参数集/样本格式没对上，宁可回退 .ts 也不要交付坏 mp4
        if videoPID >= 0 && videoCount == 0 {
            recordStats("noVideoFrames")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        let destSize = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber
        guard (destSize?.int64Value ?? 0) > 2048 else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return dest
    }

    var progress: ((Double) -> Void)?

    private func fail(_ why: String) -> URL? {
        recordStats(why)
        return nil
    }

    private func recordStats(_ extra: String) {
        let err = writer?.error?.localizedDescription ?? "-"
        let s0 = sps?.first.map { String(format: "%02X", $0) } ?? "--"
        let p0 = pps?.first.map { String(format: "%02X", $0) } ?? "--"
        let werr = writer?.error.map { String(describing: $0).prefix(70) } ?? "-"
        Self.lastStats = "werr=\(werr) sf=\(sampleFail) af=\(appendFail) vpid=\(videoPID) apid=\(audioPID) codec=\(String(format: "%02X", videoCodec)) pes=\(videoPESCount) nal=\(nalCount) sps=\(sps?.count ?? 0) pps=\(pps?.count ?? 0) s0=\(s0) p0=\(p0) fmt=\(formatStatus) add=\(canAddResult) v=\(videoCount) a=\(audioCount) \(extra)"
    }

    // MARK: - TS 包遍历

    private func process(_ data: Data, end: Int) {
        var offset = 0
        while offset + Self.packetSize <= end {
            if data[offset] != 0x47 {
                offset += 1
                continue
            }
            let b1 = data[offset + 1]
            let b2 = data[offset + 2]
            let b3 = data[offset + 3]

            let pusi = (b1 & 0x40) != 0
            let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
            let afc = Int((b3 >> 4) & 0x03)

            var p = offset + 4
            let packetEnd = offset + Self.packetSize

            if afc == 0 || afc == 2 {          // 无 payload
                offset += Self.packetSize
                continue
            }
            if afc == 3 {                      // 有 adaptation field
                guard p < packetEnd else { offset += Self.packetSize; continue }
                let afLen = Int(data[p])
                p += 1 + afLen
            }
            guard p < packetEnd else { offset += Self.packetSize; continue }

            if pid == 0 {
                parsePAT(data.subdata(in: p..<packetEnd), pusi: pusi)
                offset += Self.packetSize
                continue
            }
            if pid == pmtPID && pmtPID > 0 {
                parsePMT(data.subdata(in: p..<packetEnd), pusi: pusi)
                offset += Self.packetSize
                continue
            }

            // PMT 不可靠（有的流 PSI 布局不标准，只给 SDT）：直接按 PES 头猜轨道
            if videoPID < 0 || audioPID < 0 {
                sniffPES(pid: pid, data: data, start: p, end: packetEnd, pusi: pusi)
            }

            if pid == videoPID || pid == audioPID {
                consume(pid: pid, payload: data.subdata(in: p..<packetEnd), pusi: pusi)
            }
            offset += Self.packetSize
        }
    }

    // MARK: - PSI

    private func parsePAT(_ payload: Data, pusi: Bool) {
        var p = 0
        if pusi {
            guard let first = payload.first else { return }
            p = 1 + Int(first)
        }
        guard p + 8 <= payload.count else { return }
        guard payload[p] == 0x00 else { return }              // table_id = PAT
        let len = (Int(payload[p + 1] & 0x0F) << 8) | Int(payload[p + 2])
        let end = min(payload.count, p + 3 + len - 4)
        var q = p + 8
        while q + 4 <= end {
            let program = (Int(payload[q]) << 8) | Int(payload[q + 1])
            let pid = ((Int(payload[q + 2] & 0x1F) << 8) | Int(payload[q + 3]))
            if program != 0 { pmtPID = pid; return }
            q += 4
        }
    }

    private func parsePMT(_ payload: Data, pusi: Bool) {
        var p = 0
        if pusi {
            guard let first = payload.first else { return }
            p = 1 + Int(first)
        }
        guard p + 12 <= payload.count, payload[p] == 0x02 else { return }
        let len = (Int(payload[p + 1] & 0x0F) << 8) | Int(payload[p + 2])
        let sectionEnd = min(payload.count, p + 3 + len - 4)

        let programInfoLen = ((Int(payload[p + 10] & 0x0F) << 8) | Int(payload[p + 11]))
        var q = p + 12 + programInfoLen

        var vPID = -1
        var aPID = -1
        while q + 5 <= sectionEnd {
            let streamType = payload[q]
            let pid = ((Int(payload[q + 1] & 0x1F) << 8) | Int(payload[q + 2]))
            let esLen = ((Int(payload[q + 3] & 0x0F) << 8) | Int(payload[q + 4]))
            switch streamType {
            case 0x1B: vPID = pid; videoCodec = 0x1B  // H.264
            case 0x24: if vPID < 0 { vPID = pid; videoCodec = 0x24 }   // HEVC
            case 0x0F, 0x11, 0x81, 0x87: if aPID < 0 { aPID = pid }  // AAC / LATM / AC-3 / E-AC-3
            default: break
            }
            q += 5 + esLen
        }
        if vPID >= 0 { videoPID = vPID }
        if aPID >= 0 { audioPID = aPID; declaredAudio = true }
    }

    // MARK: - PES 重组


    /// PES 起始码 + stream_id 判断轨道类型（不依赖 PMT）
    /// stream_id: 0xE0~0xEF 视频, 0xC0~0xDF 音频
    private func sniffPES(pid: Int, data: Data, start: Int, end: Int, pusi: Bool) {
        guard pusi, end - start >= 4 else { return }
        guard data[start] == 0, data[start + 1] == 0, data[start + 2] == 1 else { return }
        let streamID = data[start + 3]
        if streamID >= 0xE0 && streamID <= 0xEF {
            if videoPID < 0 { videoPID = pid }
        } else if streamID >= 0xC0 && streamID <= 0xDF {
            if audioPID < 0 { audioPID = pid; declaredAudio = true }
        }
    }

    private func consume(pid: Int, payload: Data, pusi: Bool) {
        if pusi {
            flush(pid: pid)
            pesBuffers[pid] = payload
        } else if pesBuffers[pid] != nil {
            pesBuffers[pid]!.append(payload)
        }
    }

    private func flush(pid: Int) {
        guard let buf = pesBuffers.removeValue(forKey: pid), buf.count > 9 else { return }
        guard buf[0] == 0, buf[1] == 0, buf[2] == 1 else { return }

        let flags = buf[7]
        let headerLen = Int(buf[8])
        guard buf.count >= 9 + headerLen else { return }

        var pts: Int64 = -1
        var dts: Int64 = -1
        if flags & 0x80 != 0, buf.count >= 14 {
            pts = Self.timestamp(buf, 9)
            dts = pts
            if flags & 0x40 != 0, buf.count >= 19 {
                dts = Self.timestamp(buf, 14)
            }
        }
        // PES_packet_length 覆盖从第 6 字节起的总长；用它截断，避免把填充字节当码流
        let declared = (Int(buf[4]) << 8) | Int(buf[5])
        var bodyEnd = buf.count
        if declared > 0 {
            let d = 6 + declared
            if d < bodyEnd { bodyEnd = d }
        }
        guard bodyEnd > 9 + headerLen else { return }
        let body = buf.subdata(in: (9 + headerLen)..<bodyEnd)
        if body.isEmpty { return }
        if pts < 0 { pts = lastVideoPTS >= 0 ? lastVideoPTS + frameDuration : 0 }

        if pid == videoPID {
            handleVideo(body, pts: pts, dts: dts < 0 ? pts : dts)
        } else if pid == audioPID {
            handleAudio(body, pts: pts)
        }
    }

    private static func timestamp(_ b: Data, _ o: Int) -> Int64 {
        ((Int64(b[o]) & 0x0E) << 29)
            | (Int64(b[o + 1]) << 22)
            | ((Int64(b[o + 2]) & 0xFE) << 14)
            | (Int64(b[o + 3]) << 7)
            | ((Int64(b[o + 4]) & 0xFE) >> 1)
    }

    // MARK: - H.264

    private func handleVideo(_ es: Data, pts: Int64, dts: Int64) {
        videoPESCount += 1
        let nals = Self.splitNAL(es)
        nalCount += nals.count
        guard !nals.isEmpty else { return }

        var avcc = Data()
        var isKey = false

        // 不依赖 PMT：用 NAL 头自动判定编码（HEVC 的 VPS/SPS/PPS 是 32/33/34）
        if !codecDetected {
            for nal in nals {
                guard let first = nal.first else { continue }
                let h264Type = first & 0x1F
                let hevcType = (first >> 1) & 0x3F
                if h264Type == 7 || h264Type == 8 || h264Type == 5 {
                    videoCodec = 0x1B; codecDetected = true; break
                }
                if hevcType == 32 || hevcType == 33 || hevcType == 34 {
                    videoCodec = 0x24; codecDetected = true; break
                }
            }
        }

        let isHEVC = (videoCodec == 0x24)

        for nal in nals {
            guard let first = nal.first else { continue }

            if isHEVC {
                let type = (first >> 1) & 0x3F
                switch type {
                case 32: vps = nal; continue
                case 33: sps = nal; continue
                case 34: pps = nal; continue
                case 35: continue                              // AUD
                case 16...23: isKey = true                     // IRAP
                default: break
                }
            } else {
                let type = first & 0x1F
                switch type {
                case 7: sps = nal; continue
                case 8: pps = nal; continue
                case 9: continue                               // AUD
                case 5: isKey = true
                default: break
                }
            }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        // 分片交界处时间戳会重复或回退，AVAssetWriter 遇到倒退会拒收该帧 → 直接丢
        if lastVideoDTS >= 0 && dts <= lastVideoDTS { return }

        if lastVideoDTS >= 0 {
            let delta = dts - lastVideoDTS
            if delta > 0 && delta < 90_000 { frameDuration = delta }
        }
        lastVideoDTS = dts
        // 基准必须用 DTS：与「丢弃 dts 倒退帧」的判据保持一致，
        // 否则 B 帧的 pts 会把多帧压到同一时间戳，AVAssetWriter 直接失败
        if basePTS < 0 { basePTS = dts }

        if !writerReady {
            if pendingVideo.count < 300 && pendingVideoBytes < 48 * 1024 * 1024 {
                pendingVideo.append((avcc, pts, dts, isKey))
                pendingVideoBytes += avcc.count
            }
            tryCreateWriter()
            return
        }
        appendVideo(avcc, pts: pts, dts: dts, key: isKey)
    }

    // MARK: - AAC

    private func handleAudio(_ es: Data, pts: Int64) {
        // ADTS 帧会跨 PES 边界，必须用连续缓冲累积后整体切帧，
        // 否则每块单独切会把跨界的帧切碎（实测会丢掉约 8% 的音频帧，音画不同步）
        if audioBasePTS < 0 { audioBasePTS = pts }
        audioCarry.append(contentsOf: es)

        var offset = 0
        let total = audioCarry.count

        while offset + 7 <= total {
            guard audioCarry[offset] == 0xFF, (audioCarry[offset + 1] & 0xF0) == 0xF0 else {
                offset += 1
                continue
            }
            let protectionAbsent = (audioCarry[offset + 1] & 0x01) == 1
            let headerLen = protectionAbsent ? 7 : 9

            let profile = (audioCarry[offset + 2] >> 6) & 0x03
            let freqIndex = (audioCarry[offset + 2] >> 2) & 0x0F
            let channels = ((audioCarry[offset + 2] & 0x01) << 2) | ((audioCarry[offset + 3] >> 6) & 0x03)
            let frameLen = (Int(audioCarry[offset + 3] & 0x03) << 11)
                | (Int(audioCarry[offset + 4]) << 3)
                | (Int((audioCarry[offset + 5] >> 5) & 0x07))

            guard freqIndex < Self.sampleRates.count, channels > 0, frameLen > headerLen else {
                offset += 1
                continue
            }
            guard offset + frameLen <= total else { break }   // 帧不完整，留到下一批

            if !audioParamReady {
                aacObjectType = UInt8(profile + 1)
                aacFreqIndex = UInt8(freqIndex)
                aacChannels = UInt8(channels)
                audioSampleRate = Self.sampleRates[Int(freqIndex)]
                audioParamReady = true
            }

            let raw = Data(audioCarry[(offset + headerLen)..<(offset + frameLen)])
            let rate = max(1, Int(audioSampleRate))
            let samplePTS = audioBasePTS + Int64(audioFrameIndex) * Int64(1024 * 90_000 / rate)

            if !writerReady {
                if pendingAudio.count < 6000 { pendingAudio.append((raw, samplePTS)) }
                tryCreateWriter()
            } else {
                appendAudio(raw, pts: samplePTS)
            }

            offset += frameLen
            audioFrameIndex += 1
        }

        if offset > 0 { audioCarry.removeFirst(offset) }
    }

    // MARK: - Writer

    private func tryCreateWriter() {
        guard !writerReady, writer != nil, videoInput == nil && audioInput == nil else { return }

        // 有视频轨就必须先拿到 SPS/PPS
        if videoPID >= 0 {
            if sps == nil || pps == nil { return }
            if videoCodec == 0x24 && vps == nil { return }

            // 参数集必须是纯 NAL：首字节应为 0x67(SPS) / 0x68(PPS)，不对就在内部找一次
            if let cur = sps, cur.first != 0x67, let idx = cur.firstIndex(of: 0x67) {
                sps = cur.subdata(in: idx..<cur.count)
            }
            if let cur = pps, cur.first != 0x68, let idx = cur.firstIndex(of: 0x68) {
                pps = cur.subdata(in: idx..<cur.count)
            }
            guard sps != nil, pps != nil else { return }
        }
        // PMT 声明有音频，就等音频参数；但不能无限等（静音轨会让缓存爆掉）
        if declaredAudio && audioPID >= 0 && !audioParamReady
            && pendingVideo.count < 300 && pendingVideoBytes < 48 * 1024 * 1024 {
            return
        }
        guard videoPID >= 0 || audioPID >= 0 else { return }

        var vIn: AVAssetWriterInput?
        var aIn: AVAssetWriterInput?

        if videoPID >= 0, let s = sps, let p = pps {
            var format: CMFormatDescription?

            if videoCodec == 0x24, let v = vps {
                v.withUnsafeBytes { vPtr in
                    s.withUnsafeBytes { sPtr in
                        p.withUnsafeBytes { pPtr in
                            var pointers: [UnsafePointer<UInt8>] = [
                                vPtr.bindMemory(to: UInt8.self).baseAddress!,
                                sPtr.bindMemory(to: UInt8.self).baseAddress!,
                                pPtr.bindMemory(to: UInt8.self).baseAddress!
                            ]
                            var sizes: [Int] = [v.count, s.count, p.count]
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: &pointers,
                                parameterSetSizes: &sizes,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &format)
                        }
                    }
                }
            } else {
                var st: OSStatus = -1
                s.withUnsafeBytes { sPtr in
                    p.withUnsafeBytes { pPtr in
                        var pointers: [UnsafePointer<UInt8>] = [
                            sPtr.bindMemory(to: UInt8.self).baseAddress!,
                            pPtr.bindMemory(to: UInt8.self).baseAddress!
                        ]
                        var sizes: [Int] = [s.count, p.count]
                        st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: &pointers,
                            parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
                formatStatus = st
            }
            guard let format else { return }
            videoFormat = format

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            canAddResult = writer!.canAdd(input) ? "yes" : "no"
            if writer!.canAdd(input) {
                writer!.add(input)
                vIn = input
            }
        }

        // 音频：用第一帧 ADTS 头推导的参数建格式描述
        if audioPID >= 0 && !pendingAudio.isEmpty {
            var cookie = Data()
            let asc: UInt16 = (UInt16(aacObjectType) << 11)
                | (UInt16(aacFreqIndex) << 7)
                | (UInt16(aacChannels) << 3)
            cookie.append(UInt8((asc >> 8) & 0xFF))
            cookie.append(UInt8(asc & 0xFF))

            var asbd = AudioStreamBasicDescription(
                mSampleRate: audioSampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 1024,
                mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(aacChannels),
                mBitsPerChannel: 0,
                mReserved: 0)

            var format: CMAudioFormatDescription?
            cookie.withUnsafeBytes { ptr in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: cookie.count,
                    magicCookie: ptr.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &format)
            }
            if let format {
                audioFormat = format
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                               sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                if writer!.canAdd(input) {
                    writer!.add(input)
                    aIn = input
                }
            }
        }

        guard vIn != nil || aIn != nil else { return }
        videoInput = vIn
        audioInput = aIn

        guard writer!.startWriting() else {
            recordStats("startWritingFail")
            writer = nil
            videoInput = nil
            audioInput = nil
            writerReady = false
            return
        }
        // 音视频统一基准：取两者的最早时间戳，避免任何一路减出负数被压成 0
        var earliest = Int64.max
        if let f = pendingVideo.first { earliest = min(earliest, f.dts) }
        if let f = pendingAudio.first { earliest = min(earliest, f.pts) }
        if earliest != Int64.max { basePTS = earliest }

        writer!.startSession(atSourceTime: .zero)
        writerReady = true

        // 补写缓存帧
        let pendingV = pendingVideo
        pendingVideo.removeAll()
        pendingVideoBytes = 0
        for f in pendingV { appendVideo(f.data, pts: f.pts, dts: f.dts, key: f.key) }

        let pendingA = pendingAudio
        pendingAudio.removeAll()
        for f in pendingA { appendAudio(f.data, pts: f.pts) }
    }

    private func appendVideo(_ avcc: Data, pts: Int64, dts: Int64, key: Bool) {
        guard let input = videoInput, let format = videoFormat, let writer,
              writer.status == .writing else { return }
        if basePTS < 0 { basePTS = pts }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: frameDuration, timescale: 90_000),
            presentationTimeStamp: CMTime(value: pts - basePTS, timescale: 90_000),
            decodeTimeStamp: CMTime(value: dts - basePTS, timescale: 90_000))

        guard let sample = Self.makeSample(avcc, format: format, timing: timing) else {
            if sampleFail == "-" { sampleFail = "nil/\(avcc.count)B" }
            return
        }
        var waited = 0.0
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing { return }
            if isCancelled { return }
            Thread.sleep(forTimeInterval: 0.002)
            waited += 0.002
            if waited > 5 { return }
        }
        if input.append(sample) {
            videoCount += 1
        } else if appendFail == "-" {
            appendFail = (writer.error?.localizedDescription ?? "appendFalse").prefix(60).description
        }
    }

    private func appendAudio(_ raw: Data, pts: Int64) {
        guard let input = audioInput, let format = audioFormat, let writer,
              writer.status == .writing else { return }
        if basePTS < 0 { basePTS = pts }

        let timescale = CMTimeScale(audioSampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1024, timescale: timescale),
            presentationTimeStamp: CMTime(value: Int64(Double(max(0, pts - basePTS)) / 90_000.0 * audioSampleRate),
                                          timescale: timescale),
            decodeTimeStamp: .invalid)

        guard let sample = Self.makeSample(raw, format: format, timing: timing) else { return }
        var waited = 0.0
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing { return }
            if isCancelled { return }
            Thread.sleep(forTimeInterval: 0.002)
            waited += 0.002
            if waited > 5 { return }
        }
        if input.append(sample) { audioCount += 1 }
    }

    // MARK: - 工具

    private static func makeSample(_ data: Data, format: CMFormatDescription,
                                   timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let bb = blockBuffer else { return nil }

        let copied = data.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!,
                                          blockBuffer: bb,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = timing
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Annex-B → NAL 列表（去掉尾部 0 padding）
    /// 有些封装的 PES 载荷不带起始码（PES 边界本身就是 NAL 边界），这里做兜底
    private static func splitNAL(_ data: Data) -> [Data] {
        let nals = splitByStartCode(data)
        if !nals.isEmpty { return nals }

        guard let first = data.first, (first & 0x80) == 0, data.count > 4 else { return [] }
        // 兜底 1：整段就是一个 NAL
        let h264Type = first & 0x1F
        let hevcType = (first >> 1) & 0x3F
        let looksLikeNAL = (h264Type >= 1 && h264Type <= 9) || (hevcType >= 32 && hevcType <= 35)
        if looksLikeNAL { return [data] }

        // 兜底 2：AVCC（4 字节长度前缀 + NAL）
        var result: [Data] = []
        var offset = 0
        while offset + 4 <= data.count {
            let len = (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            guard len > 0, len <= data.count - offset - 4 else { return [] }
            result.append(data.subdata(in: (offset + 4)..<(offset + 4 + len)))
            offset += 4 + len
        }
        return result
    }

    private static func splitByStartCode(_ data: Data) -> [Data] {
        var result: [Data] = []
        let n = data.count
        var i = 0
        var start = -1

        while i + 3 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if start >= 0, start < i { result.append(trim(data, start, i)) }
                start = i + 4
                i += 4
                continue
            }
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if start >= 0, start < i { result.append(trim(data, start, i)) }
                start = i + 3
                i += 3
                continue
            }
            i += 1
        }
        if start >= 0, start < n { result.append(trim(data, start, n)) }
        return result.filter { !$0.isEmpty }
    }

    private static func trim(_ data: Data, _ from: Int, _ to: Int) -> Data {
        var end = to
        while end > from && data[end - 1] == 0 { end -= 1 }
        guard end > from else { return Data() }
        return data.subdata(in: from..<end)
    }
}
