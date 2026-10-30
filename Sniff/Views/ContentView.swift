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
    @StateObject private var m3Store = M3TaskStore.shared

    @AppStorage("m3.floatWindow") private var floatWindow = false
    @AppStorage("hasSeenTips") private var hasSeenTips = false

    @State private var showM3Manager = false
    @State private var showTips = false
    @State private var ballOffset: CGSize = .zero
    @State private var lastBallOffset: CGSize = .zero

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView {
                NavigationStack {
                    ToolboxView(webViewStore: webViewStore,
                                resourceStore: resourceStore,
                                downloadManager: downloadManager,
                                siteStore: siteStore)
                }
                .tabItem { Label("工具", systemImage: "square.grid.2x2") }

                NavigationStack {
                    BrowserView(webViewStore: webViewStore,
                                resourceStore: resourceStore,
                                downloadManager: downloadManager,
                                siteStore: siteStore)
                        .navigationBarHidden(true)
                }
                .tabItem { Label("浏览", systemImage: "safari") }

                DownloadsView(downloadManager: downloadManager)
                    .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            }
            .tint(accent)

            if floatWindow, let active = m3Store.currentActive {
                floatingBall(active)
            }
        }
        .sheet(isPresented: $showM3Manager) {
            M3TaskManagerView()
        }
        .fullScreenCover(isPresented: $showTips) {
            TipsView { hasSeenTips = true; showTips = false }
        }
        .onAppear {
            if !hasSeenTips { showTips = true }
        }
    }

    /// 悬浮球（原版 buttonShowM3UIMgr 的浮窗）
    private func floatingBall(_ task: M3Task) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color(white: 0.88), lineWidth: 3)
                    .frame(width: 42, height: 42)
                Circle()
                    .trim(from: 0, to: max(0.03, task.progress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 42, height: 42)
                Text("\(Int(task.progress * 100))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(accent)
            }
            Text("M3U8")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(white: 0.4))
        }
        .padding(8)
        .background(Circle().fill(.regularMaterial))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .offset(x: -18 + ballOffset.width, y: -96 + ballOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    ballOffset = CGSize(width: lastBallOffset.width + value.translation.width,
                                        height: lastBallOffset.height + value.translation.height)
                }
                .onEnded { _ in lastBallOffset = ballOffset }
        )
        .onTapGesture { showM3Manager = true }
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview {
    ContentView()
}
