import Foundation
import WebKit

/// 持有 WKWebView 引用，供 SwiftUI 工具栏发号施令
/// 注意：这里用强引用，保证切换 Tab 时页面不被销毁
final class WebViewStore: ObservableObject {
    var webView: WKWebView?
    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false

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
    func reload()    { webView?.reload() }
    func stop()      { webView?.stopLoading() }

    /// 回到空白页
    func loadBlank() {
        guard let blank = URL(string: "about:blank") else { return }
        webView?.load(URLRequest(url: blank))
        currentURL = nil
        pageTitle = ""
        canGoBack = false
        canGoForward = false
    }

    func load(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains(".") || s.contains(" ") {
            // 当成搜索词
            let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            s = "https://www.baidu.com/s?wd=\(q)"
        } else if !s.lowercased().hasPrefix("http") {
            s = "https://" + s
        }
        guard let url = URL(string: s) else { return }
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
}
