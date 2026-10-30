import SwiftUI
import UIKit
import WebKit
import Photos

/// 浏览页：完全对齐小工具集 VC_Browser 的结构
/// leftToolbar / rightToolbar / 地址输入 / 进度条 / 网页 / 预览条 viewPreviewBar / 底部栏 viewBottomBar / 主页 vcBHome
struct BrowserView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var siteStore: SiteStore

    /// 从外部带入的地址（站点卡片、历史等）
    var initialURL: String? = nil
    /// 非 Tab 场景（全屏弹出）时显示关闭按钮
    var onClose: (() -> Void)? = nil

    @State private var addressText = ""
    @State private var editing = false
    @State private var didLoadInitial = false
    @State private var showHome = true
    @State private var showResources = false
    @State private var showHistory = false
    @State private var showBrowserSettings = false
    @State private var toast: String?
    @FocusState private var addressFocused: Bool

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let barBG = Color(white: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressLine

            ZStack(alignment: .top) {
                SniffWebView(webViewStore: webViewStore, resourceStore: resourceStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showHome {
                    SiteListView(siteStore: siteStore, onOpen: { open($0) })
                        .transition(.opacity)
                }

                if let err = webViewStore.loadError {
                    errorBar(err)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !previewItems.isEmpty && !showHome {
                previewBar
            }
            bottomBar
        }
        .background(Color.white)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sheet(isPresented: $showResources, onDismiss: { resourceStore.resetBadge() }) {
            ResourceListView(resourceStore: resourceStore, downloadManager: downloadManager)
        }
        .sheet(isPresented: $showHistory) {
            BrowserHistorySheet(store: siteStore, onOpen: { url in
                showHistory = false
                open(url)
            })
        }
        .sheet(isPresented: $showBrowserSettings) {
            BrowserSettingsSheet(webViewStore: webViewStore)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: loadInitialIfNeeded)
        .onChange(of: webViewStore.currentURL) { url in
            if !editing {
                let text = url?.absoluteString ?? ""
                addressText = (text == "about:blank") ? "" : text
            }
            if let url, url.absoluteString.hasPrefix("http") {
                showHome = false
            }
        }
    }

    private var previewItems: [ResourceItem] {
        Array(resourceStore.items.prefix(12))
    }

    private func loadInitialIfNeeded() {
        guard !didLoadInitial else { return }
        didLoadInitial = true
        if let initialURL, !initialURL.isEmpty {
            addressText = initialURL
            showHome = false
            webViewStore.load(initialURL)
        }
    }

    // MARK: - 顶部栏（leftToolbar + 地址 + rightToolbar）

    private var topBar: some View {
        HStack(spacing: 8) {
            if editing {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(white: 0.45))
                    TextField("输入网址或搜索内容", text: $addressText)
                        .font(.system(size: 15))
                        .focused($addressFocused)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { commitAddress() }
                    if !addressText.isEmpty {
                        Button { addressText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.95, blue: 0.96)))

                Button("取消") {
                    editing = false
                    addressFocused = false
                    addressText = webViewStore.currentURL?.absoluteString ?? ""
                }
                .font(.system(size: 15))
                .foregroundColor(accent)
            } else {
                if let onClose {
                    navButton("xmark", enabled: true) { onClose() }
                }
                navButton("chevron.backward", enabled: webViewStore.canGoBack) {
                    webViewStore.goBack()
                }
                navButton("chevron.forward", enabled: webViewStore.canGoForward) {
                    webViewStore.goForward()
                }

                Button { beginEditing() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: webViewStore.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(white: 0.5))
                        Text(displayTitle)
                            .font(.system(size: 14))
                            .foregroundColor(accent)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.95, green: 0.95, blue: 0.96)))
                }
                .buttonStyle(.plain)

                navButton(webViewStore.isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                    webViewStore.isLoading ? webViewStore.stop() : webViewStore.reload()
                }
                navButton("ellipsis", enabled: true) {
                    showBrowserSettings = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(barBG)
    }

    private var displayTitle: String {
        if let host = webViewStore.currentURL?.host, !host.isEmpty { return host }
        if !webViewStore.pageTitle.isEmpty { return webViewStore.pageTitle }
        return "搜索或输入网址"
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(enabled ? accent : Color(white: 0.75))
                .frame(width: 30, height: 38)
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }

    private func beginEditing() {
        addressText = webViewStore.currentURL?.absoluteString ?? ""
        editing = true
        addressFocused = true
    }

    private func commitAddress() {
        editing = false
        addressFocused = false
        guard let text = WebViewStore.normalize(addressText) else { return }
        showHome = false
        webViewStore.load(text)
    }

    // MARK: - 进度条

    private var progressLine: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if webViewStore.isLoading {
                IndeterminateBar()
            }
        }
        .frame(height: 2)
    }

    // MARK: - 错误条

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("重试") {
                webViewStore.loadError = nil
                webViewStore.reload()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(accent)
            Button {
                webViewStore.loadError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(red: 1.0, green: 0.97, blue: 0.92))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - 预览条（viewPreviewBar）

    private var previewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(previewItems) { item in
                    Button {
                        showResources = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(white: 0.93))
                                .frame(width: 64, height: 64)
                                .overlay(
                                    Image(systemName: item.kind.symbol)
                                        .font(.system(size: 20))
                                        .foregroundColor(Color(white: 0.45))
                                )
                            Text(item.kind.shortTag)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(accent.opacity(0.85)))
                                .padding(3)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showResources = true
                } label: {
                    VStack(spacing: 4) {
                        Text("\(resourceStore.items.count)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(accent)
                        Text("全部")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.95)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 80)
        .background(barBG)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 底部栏（viewBottomBar）

    private var bottomBar: some View {
        HStack(spacing: 0) {
            bottomButton("house", "主页", active: showHome) {
                showHome = true
                webViewStore.loadBlank()
                addressText = ""
            }
            bottomButton("clock", "历史", active: false) {
                showHistory = true
            }
            bottomButton("camera.viewfinder", "截长图", active: false) {
                captureLongScreenshot()
            }
            bottomButton("bookmark", "书签", active: false) {
                showHome = true
                siteStore.scrollToBookmarks += 1
            }

            Button {
                showResources = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 3) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundColor(accent)
                        Text("资源")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)

                    if resourceStore.newCount > 0 {
                        Text("\(min(resourceStore.newCount, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .offset(x: -14, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(height: 52)
        .background(barBG)
        .overlay(alignment: .top) { Divider() }
    }

    private func bottomButton(_ symbol: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(active ? accent : Color(white: 0.35))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(active ? accent : Color(white: 0.45))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func open(_ url: String) {
        showHome = false
        addressText = url
        webViewStore.load(url)
    }

    // MARK: - 网页截长图

    private func captureLongScreenshot() {
        guard let wv = webViewStore.webView else {
            showToast("页面还没准备好")
            return
        }
        let width = wv.bounds.width
        let height = max(wv.scrollView.contentSize.height, wv.bounds.height)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: min(height, 30000))
        wv.takeSnapshot(with: config) { image, _ in
            guard let image else {
                DispatchQueue.main.async { showToast("截长图失败") }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { showToast("没有相册权限") }
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { ok, _ in
                    DispatchQueue.main.async {
                        showToast(ok ? "已保存至相册" : "保存失败")
                    }
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil }
        }
    }
}

// MARK: - 进度条动画

private struct IndeterminateBar: View {
    @State private var x: CGFloat = -0.35
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
                .frame(width: geo.size.width * 0.35)
                .offset(x: geo.size.width * x)
                .onAppear {
                    withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                        x = 1.0
                    }
                }
        }
        .frame(height: 2)
    }
}

// MARK: - 历史记录

struct BrowserHistorySheet: View {
    @ObservedObject var store: SiteStore
    var onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.history.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 34))
                            .foregroundColor(Color(white: 0.7))
                        Text("暂无记录")
                            .font(.system(size: 14))
                            .foregroundColor(Color(white: 0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.history) { item in
                            Button {
                                onOpen(item.urlString)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(item.host)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { idx in
                            store.removeHistory(at: idx)
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.history.isEmpty {
                        Button("清空") { store.clearHistory() }
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
}

// MARK: - 浏览器设置

struct BrowserSettingsSheet: View {
    @ObservedObject var webViewStore: WebViewStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("uaPreset") private var uaPresetRaw: String = UserAgentPreset.iphone.rawValue
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("常规") {
                    Picker("模拟浏览终端", selection: $uaPresetRaw) {
                        ForEach(UserAgentPreset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    .onChange(of: uaPresetRaw) { _ in
                        webViewStore.applyUserAgent()
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Text("清除所有网站数据和登录状态")
                    }
                } footer: {
                    Text("会清空 Cookie、缓存和本地存储，已登录的网站需要重新登录。")
                }
            }
            .navigationTitle("浏览器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("确定清除？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) { clearWebsiteData() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func clearWebsiteData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                DispatchQueue.main.async {
                    webViewStore.reload()
                    dismiss()
                }
            }
        }
    }
}
