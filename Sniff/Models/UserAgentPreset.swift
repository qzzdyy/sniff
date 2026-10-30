import Foundation
import UIKit

/// 模拟设备（User-Agent）预设
///
/// 注意：UA 里的系统版本必须跟随真机，不能写死。
/// 写死 iOS 18 而内核是 iOS 26 时，站点读到的 UA 与 navigator 特性不一致，
/// 知乎 / 小红书 / 微博这类会做 UA 嗅探的站会直接下发空壳页或死循环，表现就是「白屏打不开」。
enum UserAgentPreset: String, CaseIterable, Identifiable {
    case iphone
    case ipad
    case android
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphone:  return "iPhone"
        case .ipad:    return "iPad"
        case .android: return "Android"
        case .desktop: return "桌面 Safari"
        }
    }

    var detail: String {
        switch self {
        case .iphone:  return "默认移动端 UA"
        case .ipad:    return "平板 UA，部分站点加载桌面版"
        case .android: return "安卓 UA，适配部分国内站点"
        case .desktop: return "桌面 UA，请求完整网页"
        }
    }

    /// 18.6 → 18_6
    private static var osToken: String {
        UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
    }

    /// 18.6 → 18.0（Safari 的 Version/ 只跟随大版本）
    private static var majorVersion: String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"
        return "\(major).0"
    }

    var ua: String {
        let os = Self.osToken
        let ver = Self.majorVersion
        switch self {
        case .iphone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(ver) Mobile/15E148 Safari/604.1"
        case .ipad:
            return "Mozilla/5.0 (iPad; CPU OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(ver) Mobile/15E148 Safari/604.1"
        case .android:
            return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
    }

    static var current: UserAgentPreset {
        let raw = UserDefaults.standard.string(forKey: "uaPreset") ?? UserAgentPreset.iphone.rawValue
        return UserAgentPreset(rawValue: raw) ?? .iphone
    }
}
