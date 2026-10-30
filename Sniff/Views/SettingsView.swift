import SwiftUI
import WebKit

/// 设置页：模拟设备、清理 Cookie / 缓存、清空嗅探记录
struct SettingsView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore

    @AppStorage("uaPreset") private var uaPresetRaw: String = UserAgentPreset.iphone.rawValue
    @AppStorage("maxConcurrent") private var maxConcurrent = 4
    @AppStorage("maxConcurrentTasks") private var maxConcurrentTasks = 1
    @AppStorage("downloadMode") private var downloadMode = "balance"
    @AppStorage("speedLimitKBps") private var speedLimitKBps = 0
    @State private var toast: String?
    @State private var cacheText = "计算中…"

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模拟设备") {
                    ForEach(UserAgentPreset.allCases) { preset in
                        Button {
                            uaPresetRaw = preset.rawValue
                            webViewStore.applyUserAgent()
                            showToast("已切换为 \(preset.title)")
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title).foregroundColor(.primary)
                                    Text(preset.detail)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if uaPresetRaw == preset.rawValue {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(accent)
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }
                    }
                }

                Section("下载") {
                    Picker("模式", selection: $downloadMode) {
                        Text("均衡").tag("balance")
                        Text("速度优先").tag("speed")
                    }
                    .onChange(of: downloadMode) { mode in
                        DownloadSettings.applyMode(speedFirst: mode == "speed")
                        maxConcurrentTasks = DownloadSettings.maxConcurrentTasks
                        maxConcurrent = DownloadSettings.maxConcurrent
                        showToast(mode == "speed" ? "已切换到速度优先" : "已切换到均衡")
                    }

                    Picker("同时下载任务数", selection: $maxConcurrentTasks) {
                        Text("1（省内存）").tag(1)
                        Text("2").tag(2)
                        Text("3（最快）").tag(3)
                    }
                    Picker("单任务分片数", selection: $maxConcurrent) {
                        Text("1（最省流量）").tag(1)
                        Text("2").tag(2)
                        Text("4（推荐）").tag(4)
                        Text("8（最快）").tag(8)
                    }
                    Picker("限速", selection: $speedLimitKBps) {
                        Text("不限速").tag(0)
                        Text("1 MB/s").tag(1024)
                        Text("2 MB/s").tag(2048)
                        Text("5 MB/s").tag(5120)
                        Text("10 MB/s").tag(10240)
                    }
                    LabeledContent("设备最大线程数", value: "\(DownloadSettings.deviceMaxThreads)")
                    Text("总线程数 = 同时下载任务数 × 单任务分片数，当前 \(maxConcurrentTasks * maxConcurrent) 条，设备上限 \(DownloadSettings.deviceMaxThreads)。调太高不会更快，反而容易被服务器限流。限速对下一次下载生效。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("清理") {
                    Button("清除 Cookie") { clearCookies() }
                    Button("清除网页缓存") { clearCache() }
                    Button("清空嗅探记录") {
                        resourceStore.clear()
                        showToast("已清空嗅探记录")
                    }
                }

                Section("存储") {
                    LabeledContent("网页缓存", value: cacheText)
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                    LabeledContent("嗅探内核", value: "WKWebView 资源拦截 + JS 注入（DOM / XHR / 资源时间线 / 媒体事件）")
                    LabeledContent("存储位置", value: "「文件」App / 嗅探")
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: updateCacheText)
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func updateCacheText() {
        let bytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        cacheText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func clearCookies() {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                store.httpCookieStore.delete(cookie)
            }
            DispatchQueue.main.async { showToast("Cookie 已清除") }
        }
    }

    private func clearCache() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            URLCache.shared.removeAllCachedResponses()
            DispatchQueue.main.async {
                updateCacheText()
                showToast("缓存已清除")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { toast = nil }
        }
    }
}
