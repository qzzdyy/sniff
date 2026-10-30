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
        let handler = SniffMessageHandler(store: resourceStore)
        webViewStore.messageHandler = handler      // 必须强持有，add 是弱引用
        content.add(handler, name: "sniff")
        content.addUserScript(WKUserScript(source: SniffScript.source(),
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        config.userContentController = content

        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 允许 window.open / target=_blank 自行开窗，配合下面的 createWebViewWith 兜住
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        // 不写死 UA 版本，跟随真机系统版本
        webView.customUserAgent = UserAgentPreset.current.ua
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 透明底会让部分站点（尤其带 backdrop-filter / canvas 的）整页空白，这里保持不透明
        webView.isOpaque = true
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

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let webViewStore: WebViewStore

        init(webViewStore: WebViewStore) {
            self.webViewStore = webViewStore
        }

        // 一律不弹系统 JS 弹窗，避免站点用 alert 卡住页面
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            webViewStore.loadError = nil
            webViewStore.isLoading = true
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webViewStore.isLoading = false
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webViewStore.isLoading = false
            noteError(error, webView: webView)
            webViewStore.refreshNavState()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webViewStore.isLoading = false
            noteError(error, webView: webView)
            webViewStore.refreshNavState()
        }

        /// 进程崩溃（老机型大页面常见），自动重载一次
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private func noteError(_ error: Error, webView: WKWebView) {
            let ns = error as NSError
            // 用户主动停止 / 被新导航取代，不算错误
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }  // frame load interrupted
            let host = webView.url?.host ?? "页面"
            var hint = "\(ns.domain) \(ns.code)"
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: hint = "网络未连接"
            case NSURLErrorCannotFindHost:         hint = "找不到服务器（域名解析失败）"
            case NSURLErrorCannotConnectToHost:    hint = "服务器拒绝连接"
            case NSURLErrorTimedOut:               hint = "连接超时"
            case NSURLErrorSecureConnectionFailed: hint = "HTTPS 证书/握手失败"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: hint = "被 ATS 拦截（需要 HTTPS）"
            default: break
            }
            webViewStore.loadError = "\(host)：\(hint)"
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()

            // 只放行真正能在 WebView 里显示的 scheme
            guard ["http", "https", "about", "blob", "data", "file", "javascript", "ws", "wss"]
                .contains(scheme) else {
                // 关键：不再自动 UIApplication.open。国内外站点首屏几乎都有
                // weixin:// / openapp.xxx:// 之类的唤起，一 open 就把用户甩出 App，
                // 回来只会看到一个白页，看起来就像「打不开」。
                decisionHandler(.cancel)
                return
            }

            // target=_blank / window.open：新窗口没有 targetFrame，WebView 默认直接丢弃，
            // 表现就是「点了链接没反应」。这里改成同页打开。
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        /// 记录 HTTP 状态码：403/404/502 这类不会走 didFail，但页面其实是空的
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse,
               http.statusCode >= 400 {
                let host = webView.url?.host ?? "页面"
                webViewStore.loadError = "\(host)：服务器返回 HTTP \(http.statusCode)"
            }
            decisionHandler(.allow)
        }

        /// window.open / target=_blank 兜底：不出新窗口，复用当前 WebView
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               ["http", "https"].contains(scheme) {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
