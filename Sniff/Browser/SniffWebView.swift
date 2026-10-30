import SwiftUI
import UIKit
import WebKit

/// SwiftUI 包装的 WKWebView：注入嗅探脚本 + 导航回调
struct SniffWebView: UIViewRepresentable {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore

    func makeCoordinator() -> Coordinator {
        Coordinator(webViewStore: webViewStore)
    }

    func makeUIView(context: Context) -> WKWebView {
        // 切 Tab 回来时复用同一个 WebView，避免重新加载页面
        if let existing = webViewStore.webView {
            return existing
        }

        let config = WKWebViewConfiguration()

        // 注意：http/https 是 WebKit 内置 scheme，绝不能注册 WKURLSchemeHandler，
        // 否则 setURLSchemeHandler 会抛 NSInvalidArgumentException 直接闪退。
        let content = WKUserContentController()
        content.add(SniffMessageHandler(store: resourceStore), name: "sniff")
        content.addUserScript(WKUserScript(source: SniffScript.source(),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        config.userContentController = content

        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = UserAgentPreset.current.ua
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        // 空白首页：透明底 + 浅灰背景，about:blank 时呈现为灰页
        webView.isOpaque = false
        webView.backgroundColor = UIColor.systemGray6
        webView.scrollView.backgroundColor = UIColor.systemGray6
        webViewStore.webView = webView

        if let last = webViewStore.lastVisitedURL {
            webView.load(URLRequest(url: last))
        } else if let blank = URL(string: "about:blank") {
            webView.load(URLRequest(url: blank))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let ua = UserAgentPreset.current.ua
        if uiView.customUserAgent != ua {
            uiView.customUserAgent = ua
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let webViewStore: WebViewStore

        init(webViewStore: WebViewStore) {
            self.webViewStore = webViewStore
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            webViewStore.isLoading = true
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webViewStore.isLoading = false
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webViewStore.isLoading = false
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webViewStore.isLoading = false
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 非 http/https 的 scheme（微信/淘宝/App 跳转等）交给系统
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               !["http", "https", "about", "blob", "data"].contains(scheme) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
