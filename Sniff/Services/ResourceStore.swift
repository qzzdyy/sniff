import Foundation

/// 资源仓库：抓取与过滤分离（照抄 WebTaskManager 的 collected / filtered 双轨思路）
final class ResourceStore: ObservableObject {
    @Published private(set) var items: [ResourceItem] = []
    @Published private(set) var newCount: Int = 0
    @Published var filter: ResourceItem.Kind?

    private var seen = Set<String>()
    /// master playlist 里出现过的子列表（host+path），这些不再单独列出
    private var variantKeys = Set<String>()
    private let lock = NSLock()

    /// JS 层上报
    /// - Parameter hint: DOM 节点名或 performance.initiatorType
    func add(url: URL, mime: String? = nil, hint: String? = nil, contentLength: Int64? = nil,
             pageURL: URL? = nil, pageTitle: String? = nil, source: String? = nil) {
        let key = url.absoluteString
        guard key.hasPrefix("http") else { return }

        let ext = url.pathExtension.lowercased()
        if Self.ignoredExts.contains(ext) { return }
        guard let kind = Self.classify(url: url, mime: mime, hint: hint) else { return }

        lock.lock()
        let isNew = !seen.contains(key)
        if isNew { seen.insert(key) }
        lock.unlock()
        guard isNew else { return }

        var item = ResourceItem(url: url, kind: kind, mime: mime,
                                contentLength: contentLength,
                                pageURL: pageURL, pageTitle: pageTitle)
        item.source = source ?? "net"
        item.isPreparing = (kind != .hls)

        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.newCount += 1
        }

        if kind == .hls {
            // m3u8 不落地：先校验能不能用（很多站会给一份打不开的幽灵列表）
            inspectHLS(item)
        } else {
            // 命中即落地 + 生成元数据（首帧/像素/时长），列表立刻有图
            MediaProbe.shared.probe(item) { [weak self] updated in
                self?.replace(updated)
            }
        }
    }

    private func replace(_ item: ResourceItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    /// 过滤视图（UI 用）
    ///
    /// m3u8 去重规则：同一个 host+path 只保留一条；已确认可用（valid）的优先，
    /// 拉不到内容的（invalid）直接不显示 —— 这就是「一个视频两条 m3u8、其中一条永远打不开」的解法。
    var filteredItems: [ResourceItem] {
        var realHosts = Set<String>()
        for item in items where item.kind == .hls && !item.isWeakSource {
            realHosts.insert((item.url.host ?? "").lowercased())
        }

        var validKeys = Set<String>()
        var validHosts = Set<String>()
        for item in items where item.kind == .hls && item.hlsState == .valid {
            validKeys.insert(Self.hlsKey(item.url))
            validHosts.insert((item.url.host ?? "").lowercased())
        }

        var shownHLS = Set<String>()
        var shownHLSHost = Set<String>()
        var result: [ResourceItem] = []
        for item in items {
            if item.kind == .hls {
                let key = Self.hlsKey(item.url)
                let host = (item.url.host ?? "").lowercased()
                if item.hlsState == .invalid { continue }
                if variantKeys.contains(key) { continue }   // master 的分支列表不再单列
                if item.hlsState == .unknown && validKeys.contains(key) { continue }
                // 同一站点已经有确认可用的 m3u8 时，不再展示还没校验通过的重复项
                if item.hlsState == .unknown && validHosts.contains(host) { continue }
                // 扫源码扫出来的 m3u8 可信度最低：同站点只要有一条真实加载过的，就不显示它
                if item.isWeakSource && realHosts.contains(host) { continue }
                if shownHLS.contains(key) { continue }
                // 一个视频只留一条：同站点下已展示过 m3u8 的，未确认可用的重复项一律不显示
                if item.hlsState != .valid && shownHLSHost.contains(host) { continue }
                shownHLS.insert(key)
                shownHLSHost.insert(host)
            }
            result.append(item)
        }
        if let filter { result = result.filter { $0.kind == filter } }
        return result
    }

    func count(of kind: ResourceItem.Kind) -> Int {
        filteredItems.filter { $0.kind == kind }.count
    }

    /// 忽略 query 的地址指纹
    static func hlsKey(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        return host + url.path
    }

    func clear() {
        lock.lock()
        seen.removeAll()
        lock.unlock()
        let files = items.compactMap { $0.localFile }
        DispatchQueue.main.async {
            self.items.removeAll()
            self.newCount = 0
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// 批量删除指定资源（同时清掉落地文件与去重记录，重新嗅探时可再次出现）
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        let removed = items.filter { ids.contains($0.id) }
        for item in removed { seen.remove(item.url.absoluteString) }
        lock.unlock()

        let files = removed.compactMap { $0.localFile }
        DispatchQueue.main.async {
            self.items.removeAll { ids.contains($0.id) }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func resetBadge() {
        DispatchQueue.main.async { self.newCount = 0 }
    }

    // MARK: - m3u8 校验

    /// 拉一次播放列表，确认它真的有分片；若是 master，顺便记下所有变体地址
    private func inspectHLS(_ item: ResourceItem) {
        var request = MediaHeaders.request(for: item)
        request.timeoutInterval = 8

        // 校验请求也要带上网页 Cookie，否则防盗链站点一律 403，好列表会被误判成幽灵
        CookieBridge.sync { [weak self] in
            self?.runHLSInspection(item, request: request)
        }
    }

    private func runHLSInspection(_ item: ResourceItem, request: URLRequest) {
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let http = response as? HTTPURLResponse

            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("#EXTM3U") else {
                // 只有明确拿到 200 却不是 m3u8，才判定为幽灵列表；
                // 超时 / 403 这类先保留（很多站要靠播放器的实时 Cookie 才给内容）
                if http?.statusCode == 200, let data, !data.isEmpty {
                    self.mark(item, state: .invalid)
                }
                return
            }

            // master：把子列表逐个记下来（后面它们再被嗅探到就不再单独列出）
            if text.contains("#EXT-X-STREAM-INF") {
                var keys: [String] = []
                let lines = text.components(separatedBy: "\n")
                for line in lines {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty || t.hasPrefix("#") { continue }
                    if let u = URL(string: t, relativeTo: item.url)?.absoluteURL {
                        keys.append(Self.hlsKey(u))
                    }
                }
                self.lock.lock()
                for k in keys { self.variantKeys.insert(k) }
                self.lock.unlock()
                self.mark(item, state: .valid)
                return
            }

            // media playlist：至少要有一个分片
            let hasSegment = text.components(separatedBy: "\n").contains { line in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !t.isEmpty && !t.hasPrefix("#")
            }
            self.mark(item, state: hasSegment ? .valid : .invalid)
        }.resume()
    }

    private func mark(_ item: ResourceItem, state: ResourceItem.HLSState) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].hlsState = state
            if state == .invalid {
                // 幽灵列表：直接移除，不打扰用户
                self.items.removeAll { $0.id == item.id }
            }
        }
    }

    // MARK: - 分类

    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "3gp", "wmv"]
    private static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "wma", "opus", "caf"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "svg", "ico"]

    private static let ignoredExts: Set<String> = [
        "html", "htm", "php", "asp", "aspx", "jsp", "do", "action",
        "js", "mjs", "css", "json", "xml", "txt", "map", "woff", "woff2", "ttf",
        "ts", "m4s", "zip", "pdf"
    ]

    static func classify(url: URL, mime: String?, hint: String? = nil) -> ResourceItem.Kind? {
        let m = (mime ?? "").lowercased()
        let ext = url.pathExtension.lowercased()

        if ext == "m3u8" || ext == "mpd" || m.contains("mpegurl") || m.contains("dash+xml") {
            return .hls
        }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        if m.hasPrefix("image/") { return .image }
        if videoExts.contains(ext) { return .video }
        if audioExts.contains(ext) { return .audio }
        if imageExts.contains(ext) { return .image }

        switch (hint ?? "").lowercased() {
        case "video": return .video
        case "audio": return .audio
        case "img", "image": return .image
        default: return nil
        }
    }
}
