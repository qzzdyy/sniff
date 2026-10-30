import Foundation
import SwiftUI

/// 首页的一个站点入口（对应小工具集的 Website 卡片）
struct SiteBookmark: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var urlString: String
    var symbol: String
    var tintHex: String
    var isBuiltin: Bool
    var lastVisited: Date?

    init(id: UUID = UUID(),
         title: String,
         urlString: String,
         symbol: String = "globe",
         tintHex: String = "3A3A3C",
         isBuiltin: Bool = false,
         lastVisited: Date? = nil) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.symbol = symbol
        self.tintHex = tintHex
        self.isBuiltin = isBuiltin
        self.lastVisited = lastVisited
    }

    var url: URL? { URL(string: urlString) }
    var host: String { url?.host ?? urlString }
    var tint: Color { Color(hex: tintHex) }
}

/// 站点仓库：内置站点 + 用户自建 + 最近访问，全部落在 UserDefaults
final class SiteStore: ObservableObject {
    @Published private(set) var sites: [SiteBookmark] = []
    @Published private(set) var recents: [SiteBookmark] = []

    private let sitesKey = "sniff.sites.v1"
    private let recentsKey = "sniff.recents.v1"
    private let maxRecents = 8

    init() {
        load()
        if sites.isEmpty { sites = Self.builtins }
    }

    // MARK: - 增删

    func add(title: String, urlString: String) {
        guard let normalized = Self.normalize(urlString) else { return }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = URL(string: normalized)?.host ?? normalized
        }
        let site = SiteBookmark(title: name,
                                urlString: normalized,
                                symbol: "globe",
                                tintHex: "3A3A3C")
        sites.append(site)
        persistSites()
    }

    func remove(id: UUID) {
        sites.removeAll { $0.id == id }
        recents.removeAll { $0.id == id }
        persistSites()
        persistRecents()
    }

    func move(from: IndexSet, to: Int) {
        sites.move(fromOffsets: from, toOffset: to)
        persistSites()
    }

    /// 记录一次访问，用于「最近打开」
    func touch(_ site: SiteBookmark) {
        var entry = site
        entry.lastVisited = Date()
        recents.removeAll { $0.urlString == site.urlString }
        recents.insert(entry, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        persistRecents()
    }

    func touch(url: URL) {
        let site = SiteBookmark(title: url.host ?? url.absoluteString,
                                urlString: url.absoluteString,
                                symbol: "globe",
                                tintHex: "3A3A3C")
        touch(site)
    }

    // MARK: - 持久化

    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: sitesKey),
           let list = try? decoder.decode([SiteBookmark].self, from: data) {
            sites = list
        }
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let list = try? decoder.decode([SiteBookmark].self, from: data) {
            recents = list
        }
    }

    private func persistSites() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: sitesKey)
        }
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    // MARK: - 工具

    /// 输入 "bilibili.com" → "https://bilibili.com"；输入中文 → 交给搜索引擎
    static func normalize(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains(".") || s.contains(" ") {
            let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            s = "https://www.baidu.com/s?wd=\(q)"
        } else if !s.lowercased().hasPrefix("http") {
            s = "https://" + s
        }
        guard URL(string: s) != nil else { return nil }
        return s
    }

    static let builtins: [SiteBookmark] = [
        SiteBookmark(title: "哔哩哔哩", urlString: "https://m.bilibili.com",
                     symbol: "play.rectangle.fill", tintHex: "FB7299", isBuiltin: true),
        SiteBookmark(title: "微博", urlString: "https://m.weibo.cn",
                     symbol: "bubble.left.fill", tintHex: "E6162D", isBuiltin: true),
        SiteBookmark(title: "小红书", urlString: "https://www.xiaohongshu.com",
                     symbol: "book.fill", tintHex: "FF2442", isBuiltin: true),
        SiteBookmark(title: "知乎", urlString: "https://www.zhihu.com",
                     symbol: "questionmark.circle.fill", tintHex: "0084FF", isBuiltin: true),
        SiteBookmark(title: "豆瓣", urlString: "https://m.douban.com",
                     symbol: "star.fill", tintHex: "2E963D", isBuiltin: true),
        SiteBookmark(title: "Vimeo", urlString: "https://vimeo.com",
                     symbol: "v.circle.fill", tintHex: "1AB7EA", isBuiltin: true),
        SiteBookmark(title: "Pexels", urlString: "https://www.pexels.com",
                     symbol: "photo.on.rectangle", tintHex: "05A081", isBuiltin: true),
        SiteBookmark(title: "Unsplash", urlString: "https://unsplash.com",
                     symbol: "camera.fill", tintHex: "111111", isBuiltin: true)
    ]
}

// MARK: - 颜色

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        } else {
            r = 0.23; g = 0.23; b = 0.24
        }
        self.init(red: r, green: g, blue: b)
    }
}
