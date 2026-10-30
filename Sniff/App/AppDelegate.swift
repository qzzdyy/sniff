import UIKit

/// 后台 URLSession 的事件必须由 AppDelegate 转交，否则 AVAssetDownloadURLSession
/// 的 delegate 永远收不到回调（表现为下载一直等到超时）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        NativeHLSDownloader.backgroundCompletion = completionHandler
    }
}
