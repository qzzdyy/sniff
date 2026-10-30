import Foundation

/// 统一给媒体请求带上 Referer / User-Agent
/// 国内站点普遍校验 Referer，不带就是 403 或直接断流
enum MediaHeaders {

    static func referer(for item: ResourceItem) -> String {
        if let page = item.pageURL?.absoluteString, !page.isEmpty {
            return page
        }
        if let host = item.url.host, let scheme = item.url.scheme {
            return "\(scheme)://\(host)/"
        }
        return ""
    }

    static func headers(for item: ResourceItem) -> [String: String] {
        var h: [String: String] = [:]
        let ref = referer(for: item)
        if !ref.isEmpty {
            h["Referer"] = ref
            if let u = URL(string: ref), let scheme = u.scheme, let host = u.host {
                h["Origin"] = "\(scheme)://\(host)"
            }
        }
        h["User-Agent"] = UserAgentPreset.current.ua
        return h
    }

    static func request(for item: ResourceItem, url: URL? = nil) -> URLRequest {
        var req = URLRequest(url: url ?? item.url)
        for (k, v) in headers(for: item) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        return req
    }

    static func request(url: URL, referer: String, userAgent: String) -> URLRequest {
        var req = URLRequest(url: url)
        if !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
            if let u = URL(string: referer), let scheme = u.scheme, let host = u.host {
                req.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }
}
