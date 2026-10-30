import Foundation
import WebKit

/// 把 WKWebView 里的 Cookie 灌进 HTTPCookieStorage，
/// 让 URLSession 发起的下载/校验请求带上登录态（国内站点防盗链的关键）。
enum CookieBridge {
    static func sync(_ completion: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            DispatchQueue.main.async { completion?() }
        }
    }
}
