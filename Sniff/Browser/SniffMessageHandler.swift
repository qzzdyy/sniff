import Foundation
import WebKit

/// 接收网页 JS 发来的嗅探消息
final class SniffMessageHandler: NSObject, WKScriptMessageHandler {
    private let store: ResourceStore

    init(store: ResourceStore) {
        self.store = store
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "sniff",
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }

        let size = (body["size"] as? NSNumber)?.int64Value
        store.add(url: url,
                  mime: nil,
                  hint: body["type"] as? String,
                  contentLength: size,
                  pageURL: message.webView?.url,
                  pageTitle: message.webView?.title,
                  source: body["src"] as? String)
    }
}
