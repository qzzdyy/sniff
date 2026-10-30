import Foundation

/// m3u8 主播放列表里的一条可下载流（对应原版 m3.create.* 的流选择项）
struct M3UStream: Identifiable, Equatable {
    enum Kind: String {
        case video = "视频"
        case audio = "音频"
        case subtitle = "字幕"

        var symbol: String {
            switch self {
            case .video: return "video.fill"
            case .audio: return "waveform"
            case .subtitle: return "text.bubble.fill"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var name: String
    var bandwidth: Int?
    var resolution: String?
    var frameRate: Double?
    var channels: String?
    var url: URL
    /// 是否为可直接下载的媒体列表（非 master）
    var isDirect: Bool

    var bandwidthText: String? {
        guard let bandwidth, bandwidth > 0 else { return nil }
        if bandwidth >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)
        }
        return "\(bandwidth / 1000) kbps"
    }

    static func == (lhs: M3UStream, rhs: M3UStream) -> Bool {
        lhs.url == rhs.url && lhs.kind == rhs.kind
    }
}

/// m3u8 解析：区分 master（多流）与 media（分片列表）
enum M3UParser {

    static func parse(url: URL, completion: @escaping (Result<[M3UStream], MediaError>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            HTTPCookie.requestHeaderFields(with: cookies).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    completion(.failure(MediaError(error?.localizedDescription ?? "下载播放列表失败")))
                }
                return
            }
            let streams = parseText(text, base: url)
            DispatchQueue.main.async {
                if streams.isEmpty {
                    completion(.failure(MediaError("不支持的 M3U8 文件")))
                } else {
                    completion(.success(streams))
                }
            }
        }.resume()
    }

    static func parseText(_ text: String, base: URL) -> [M3UStream] {
        let lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.contains("#EXTM3U") || text.contains("#EXTINF") || text.contains("#EXT-X-STREAM-INF") else {
            return []
        }

        var result: [M3UStream] = []

        // 1) 独立音轨 / 字幕轨（EXT-X-MEDIA）
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = attributes(line)
            let type = (attrs["TYPE"] ?? "").uppercased()
            guard let uri = attrs["URI"] else { continue }
            guard let u = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            let kind: M3UStream.Kind = type == "SUBTITLES" ? .subtitle : .audio
            result.append(M3UStream(kind: kind,
                                    name: attrs["NAME"] ?? (kind == .audio ? "音频" : "字幕"),
                                    bandwidth: nil,
                                    resolution: nil,
                                    frameRate: nil,
                                    channels: attrs["CHANNELS"],
                                    url: u,
                                    isDirect: false))
        }

        // 2) 画面流（EXT-X-STREAM-INF），URI 在下一行
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attrs = attributes(line)
            var j = i + 1
            while j < lines.count && (lines[j].isEmpty || lines[j].hasPrefix("#")) { j += 1 }
            guard j < lines.count, let u = URL(string: lines[j], relativeTo: base)?.absoluteURL else { continue }
            let bw = Int(attrs["BANDWIDTH"] ?? "0") ?? 0
            let res = attrs["RESOLUTION"]
            let fps = attrs["FRAME-RATE"].flatMap { Double($0) }
            var name = res ?? "画面流"
            if let fps { name += String(format: " · %.0ffps", fps) }
            result.append(M3UStream(kind: .video,
                                    name: name,
                                    bandwidth: bw > 0 ? bw : nil,
                                    resolution: res,
                                    frameRate: fps,
                                    channels: nil,
                                    url: u,
                                    isDirect: false))
        }

        // 3) 本身就是 media 列表：单流直接可下
        if result.isEmpty, text.contains("#EXTINF") {
            result.append(M3UStream(kind: .video,
                                    name: "单码率流",
                                    bandwidth: nil,
                                    resolution: nil,
                                    frameRate: nil,
                                    channels: nil,
                                    url: base,
                                    isDirect: true))
        }

        // 画面流按码率降序，音频字幕附后
        let videos = result.filter { $0.kind == .video }.sorted { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }
        let audios = result.filter { $0.kind == .audio }
        let subs = result.filter { $0.kind == .subtitle }
        return videos + audios + subs
    }

    private static func attributes(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return out }
        let body = String(line[line.index(after: colon)...])
        var key = ""
        var value = ""
        var inQuotes = false
        var current = ""
        for ch in body {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == "=" && !inQuotes && key.isEmpty {
                key = current.trimmingCharacters(in: .whitespaces)
                current = ""
                continue
            }
            if ch == "," && !inQuotes {
                if !key.isEmpty {
                    out[key.uppercased()] = current.trimmingCharacters(in: .whitespaces)
                }
                key = ""
                current = ""
                continue
            }
            current.append(ch)
        }
        if !key.isEmpty {
            out[key.uppercased()] = current.trimmingCharacters(in: .whitespaces)
        }
        _ = value
        return out
    }
}
