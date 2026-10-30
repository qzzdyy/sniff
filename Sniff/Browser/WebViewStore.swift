import Foundation
import WebKit

/// 持有 WKWebView 引用，供 SwiftUI 工具栏发号施令
/// 注意：这里用强引用，保证切换 Tab 时页面不被销毁
final class WebViewStore: ObservableObject {
    var webView: WKWebView?
    /// WKUserContentController.add 是弱引用，必须由外部强持有，否则 JS 侧 postMessage 直接抛 TypeError
    var messageHandler: SniffMessageHandler?

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    /// 加载失败时的诊断信息（域 + 错误码），显示在页面上而不是白屏
    @Published var loadError: String?

    /// 上次关闭前的页面（下次启动自动恢复）
    private static let lastURLKey = "lastVisitedURL"

    var lastVisitedURL: URL? {
        guard let s = UserDefaults.standard.string(forKey: Self.lastURLKey),
              s.hasPrefix("http"), let u = URL(string: s) else { return nil }
        return u
    }

    private func remember(_ url: URL?) {
        guard let url, url.absoluteString.hasPrefix("http") else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
    }

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        guard let wv = webView else { return }
        loadError = nil
        if wv.url == nil, let s = UserDefaults.standard.string(forKey: Self.lastURLKey),
           let u = URL(string: s) {
            wv.load(URLRequest(url: u))
        } else {
            wv.reload()
        }
    }

    func stop() { webView?.stopLoading() }

    /// 回到空白页
    func loadBlank() {
        guard let blank = URL(string: "about:blank") else { return }
        webView?.load(URLRequest(url: blank))
        currentURL = nil
        pageTitle = ""
        canGoBack = false
        canGoForward = false
        loadError = nil
    }

    func load(_ text: String) {
        guard let s = Self.normalize(text), let url = URL(string: s) else { return }
        loadError = nil
        webView?.load(URLRequest(url: url))
        remember(url)
    }

    func refreshNavState() {
        guard let wv = webView else { return }
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        isLoading = wv.isLoading
        currentURL = wv.url
        pageTitle = wv.title ?? ""
        if !wv.isLoading { remember(wv.url) }
    }

    /// 设置页切换模拟设备时调用
    func applyUserAgent() {
        guard let wv = webView else { return }
        wv.customUserAgent = UserAgentPreset.current.ua
        wv.reload()
    }

    // MARK: - 地址归一化

    /// "bilibili.com" → "https://bilibili.com"；中文 → 搜索引擎；已是 URL 的原样返回
    static func normalize(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 已经是完整 URL：只把中间的空格编掉，不做其它改造
        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            if ["http", "https", "about", "file"].contains(scheme) {
                s = s.replacingOccurrences(of: " ", with: "%20")
                return URL(string: s) != nil ? s : nil
            }
        }

        // 形如 example.com / www.example.com/a?b=1
        let looksLikeHost = s.contains(".") && !s.contains(" ")
        if looksLikeHost && !s.hasPrefix(".") {
            let withScheme = "https://" + s
            if let u = URL(string: withScheme), let host = u.host, host.contains(".") {
                return withScheme
            }
        }

        // 其余当搜索词
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return "https://www.baidu.com/s?wd=\(q)"
    }
}
