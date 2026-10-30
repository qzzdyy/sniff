import SwiftUI

/// 轻量分享面板封装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 导出到「文件」App（支持一次多个文件）
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

struct ContentView: View {
    @StateObject private var webViewStore = WebViewStore()
    @StateObject private var resourceStore = ResourceStore()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var siteStore = SiteStore()

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        TabView {
            NavigationStack {
                ToolboxView(webViewStore: webViewStore,
                            resourceStore: resourceStore,
                            downloadManager: downloadManager,
                            siteStore: siteStore)
            }
            .tabItem { Label("工具", systemImage: "square.grid.2x2") }

            NavigationStack {
                SiteListView(webViewStore: webViewStore,
                             resourceStore: resourceStore,
                             downloadManager: downloadManager,
                             siteStore: siteStore)
            }
            .tabItem { Label("浏览", systemImage: "safari") }

            DownloadsView(downloadManager: downloadManager)
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
        }
        .tint(accent)
    }
}

#Preview {
    ContentView()
}
