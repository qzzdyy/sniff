import SwiftUI
import WebKit

/// 设置页（按小工具集截图还原：分组卡片 + 左侧线框图标 + 右侧箭头/值）
struct SettingsView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager

    @AppStorage("compressDoneAlert") private var compressDoneAlert = true

    @State private var cacheText = "0 B"
    @State private var showM3 = false
    @State private var toast: String?

    var body: some View {
        Form {
            // 1. 探索
            Section("探索") {
                NavigationLink { BrowserSettings(webViewStore: webViewStore, resourceStore: resourceStore) } label: {
                    rowLabel(L10n.t("settings.ins.b_settings"), "safari")
                }
                NavigationLink { FilterSettings() } label: {
                    rowLabel(L10n.t("settings.ins.default_filter"), "line.3.horizontal.decrease.circle")
                }
                NavigationLink { SnapshotSettings() } label: {
                    rowLabel(L10n.t("settings.ins.snapshot"), "camera")
                }
            }

            // 2. 线程配置
            Section("线程配置") {
                Button { showM3 = true } label: {
                    rowLabel(L10n.t("settings.m3.task"), "list.bullet.indent")
                }
                NavigationLink { MultiTaskAdvanced() } label: {
                    rowLabel(L10n.t("settings.m3.multitask"), "square.stack.3d.down.right")
                }
            }

            // 3. 其他
            Section("其他") {
                row(L10n.t("settings.clear_cache"), "trash", value: cacheText) { clearCache() }
                Toggle(isOn: $compressDoneAlert) {
                    rowLabel(L10n.t("settings.video_compress_sound_switch"), "bell")
                }
                NavigationLink { MoreSettings() } label: {
                    rowLabel(L10n.t("settings.about"), "info.circle")
                }
            }
        }
        .navigationTitle("设置")
        .onAppear(perform: updateCacheText)
        .sheet(isPresented: $showM3) { M3TaskManagerView() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 26)
            }
        }
    }

    // MARK: - 行

    private func row(_ title: String, _ symbol: String, value: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                rowLabel(title, symbol)
                Spacer()
                if let value {
                    Text(value).font(.system(size: 16)).foregroundColor(.secondary)
                }
            }
        }
    }

    private func rowLabel(_ title: String, _ symbol: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(Theme.label)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 17))
                .foregroundColor(.primary)
            if let value {
                Text(value)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: - 行为

    private func updateCacheText() {
        let bytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        cacheText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func clearCache() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            URLCache.shared.removeAllCachedResponses()
            DispatchQueue.main.async {
                updateCacheText()
                withAnimation { toast = "缓存已清除" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { toast = nil }
                }
            }
        }
    }
}

// MARK: - 子页

struct BrowserSettings: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @AppStorage("uaPreset") private var uaPresetRaw: String = UserAgentPreset.iphone.rawValue
    @State private var toast: String?

    var body: some View {
        Form {
            Section("模拟设备") {
                ForEach(UserAgentPreset.allCases) { preset in
                    Button {
                        uaPresetRaw = preset.rawValue
                        webViewStore.applyUserAgent()
                        withAnimation { toast = "已切换为 \(preset.title)" }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title).foregroundColor(.primary)
                                Text(preset.detail).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if uaPresetRaw == preset.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(red: 0.11, green: 0.11, blue: 0.12))
                            }
                        }
                    }
                }
            }

            Section("清理") {
                Button("清除 Cookie") { clearCookies() }
                Button("清空嗅探记录") {
                    resourceStore.clear()
                    toast = "已清空"
                }
            }

            Section {
                Text("部分站点会按 UA 下发不同页面。切换后需要重新加载网页才生效。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("settings.ins.b_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.footnote).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, 24)
            }
        }
    }

    private func clearCookies() {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            for c in cookies { store.httpCookieStore.delete(c) }
            DispatchQueue.main.async { toast = "Cookie 已清除" }
        }
    }
}

struct MultiTaskSettings: View {
    @ObservedObject var downloadManager: DownloadManager

    var body: some View {
        Form {
            if downloadManager.tasks.isEmpty {
                Section {
                    Text("还没有任务")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } else {
                Section("全部任务") {
                    ForEach(downloadManager.tasks) { task in
                        HStack {
                            Text(task.item.url.lastPathComponent)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text(task.status.text)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Section {
                Text("完整的任务列表在「下载」页。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("m3.task_manage.task_manage"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MultiTaskAdvanced: View {
    @AppStorage("maxConcurrent") private var maxConcurrent = 4
    @AppStorage("maxConcurrentTasks") private var maxConcurrentTasks = 1
    @AppStorage("downloadMode") private var downloadMode = "balance"
    @AppStorage("speedLimitKBps") private var speedLimitKBps = 0

    var body: some View {
        Form {
            Section("模式") {
                Picker("调度", selection: $downloadMode) {
                    Text(L10n.t("m3.mtask.mode_balance")).tag("balance")
                    Text(L10n.t("m3.mtask.mode_speed")).tag("speed")
                }
                .pickerStyle(.segmented)
                .onChange(of: downloadMode) { mode in
                    DownloadSettings.applyMode(speedFirst: mode == "speed")
                    maxConcurrentTasks = DownloadSettings.maxConcurrentTasks
                    maxConcurrent = DownloadSettings.maxConcurrent
                }
                Picker("同时下载任务数", selection: $maxConcurrentTasks) {
                    Text("1（省内存）").tag(1)
                    Text("2").tag(2)
                    Text("3（最快）").tag(3)
                }
                Picker("单任务分片数", selection: $maxConcurrent) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("4（推荐）").tag(4)
                    Text("8").tag(8)
                }
                Picker("限速", selection: $speedLimitKBps) {
                    Text("不限速").tag(0)
                    Text("1 MB/s").tag(1024)
                    Text("2 MB/s").tag(2048)
                    Text("5 MB/s").tag(5120)
                    Text("10 MB/s").tag(10240)
                }
                LabeledContent("设备最大线程数", value: "\(DownloadSettings.deviceMaxThreads)")
            }
            Section {
                Text("总线程 = 同时任务数 × 分片数，当前 \(maxConcurrentTasks * maxConcurrent)。超过设备上限不会更快，反而容易被限流。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("m3.mtask.mtask_setting"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SnapshotSettings: View {
    @State private var autoSnapshot = true
    @State private var showList = false
    var body: some View {
        Form {
            Section {
                Button {
                    showList = true
                } label: {
                    HStack {
                        Text("查看网页快照")
                        Spacer()
                        Text("\(SnapshotStore.all().count)")
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.separator)
                    }
                }
                Toggle("自动抓取网页快照", isOn: $autoSnapshot)
            } footer: {
                Text("快照会在嗅探到视频时同步保存一张页面截图，方便回看。")
            }
        }
        .sheet(isPresented: $showList) { InsSnapListView() }
        .navigationTitle(L10n.t("settings.ins.snapshot"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FilterSettings: View {
    @State private var hideSmall = true
    @State private var minKB = 50
    var body: some View {
        Form {
            Section {
                Toggle("隐藏小于阈值的资源", isOn: $hideSmall)
                Stepper("阈值 \(minKB) KB", value: $minKB, in: 0...2048, step: 50)
            } footer: {
                Text("用来过滤掉统计、埋点、1×1 像素这类噪音资源。")
            }
        }
        .navigationTitle(L10n.t("settings.ins.default_filter"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MoreSettings: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var body: some View {
        Form {
            Section("关于") {
                LabeledContent("版本", value: version)
                LabeledContent("嗅探内核", value: "WKWebView + JS 注入")
                LabeledContent("存储位置", value: "「文件」App / 嗅探")
            }
            Section {
                Text("嗅探内核：WKWebView 资源拦截 + JS 注入（DOM / XHR / 资源时间线 / 媒体事件）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("settings.about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HistoryView: View {
    @ObservedObject var resourceStore: ResourceStore
    var body: some View {
        List {
            if resourceStore.items.isEmpty {
                Text(L10n.t("history.no_records")).foregroundColor(.secondary)
            } else {
                ForEach(resourceStore.items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.url.lastPathComponent.isEmpty ? item.url.host ?? "资源" : item.url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                        Text(item.kind.title)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle(L10n.t("settings.history_actions"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OpenSourcePage: View {
    var body: some View {
        Form {
            Section {
                Text("本项目使用的开源组件：")
                    .font(.callout)
                Text("· FFmpeg / FFmpegKit（LGPL / GPL）\n· 界面基于 SwiftUI、WebKit 系统框架")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("settings.opensource"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SimpleTextPage: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("网页打不开怎么办").font(.headline)
                Text("1. 页面顶部如果出现橙色提示条，把上面的文字发出来，那就是真实原因。\n2. 先试「刷新」，再试切换 UA（浏览器 → 模拟设备 → 桌面 Safari）。\n3. 国内站点多数要求 HTTPS，纯 HTTP 地址可能被拦。\n4. 部分站点会主动唤起 App，本版本已阻止自动跳转，不会再被甩出应用。")
                    .font(.callout)
                Text("视频嗅探不到怎么办").font(.headline)
                Text("先点一次播放。绝大多数站点的地址在 play 事件之后才会出现，嗅探脚本会在那一刻上报。")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("帮助")
        .navigationBarTitleDisplayMode(.inline)
    }
}
