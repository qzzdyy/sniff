import SwiftUI
import UIKit

/// 浏览页：地址栏 + 工具栏 + 网页 + 嗅探面板入口
struct BrowserView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager
    /// 从首页进入时携带的目标地址
    var initialURL: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var didLoadInitial = false
    @State private var addressText = ""
    @State private var showResources = false
    @State private var editing = false

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            toolbar
            Divider()
            SniffWebView(webViewStore: webViewStore, resourceStore: resourceStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .sheet(isPresented: $showResources, onDismiss: { resourceStore.resetBadge() }) {
            ResourceListView(resourceStore: resourceStore, downloadManager: downloadManager)
        }
        .onAppear {
            guard !didLoadInitial else { return }
            didLoadInitial = true
            if let initialURL, !initialURL.isEmpty {
                addressText = initialURL
                webViewStore.load(initialURL)
            } else if addressText.isEmpty, let url = webViewStore.currentURL,
                      url.absoluteString != "about:blank" {
                addressText = url.absoluteString
            }
        }
        .onChange(of: webViewStore.currentURL) { url in
            guard !editing else { return }
            let text = url?.absoluteString ?? ""
            addressText = (text == "about:blank") ? "" : text
        }
    }

    // MARK: - 地址栏

    private var addressBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(white: 0.45))
                TextField("输入网址或搜索内容", text: $addressText, onEditingChanged: { began in
                    editing = began
                }, onCommit: {
                    editing = false
                    webViewStore.load(addressText)
                })
                .font(.system(size: 15))
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .keyboardType(.URL)
                .submitLabel(.go)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color(red: 0.96, green: 0.96, blue: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                showResources = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundColor(accent)
                    if resourceStore.newCount > 0 {
                        Text("\(min(resourceStore.newCount, 99))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 6, y: -6)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolButton("chevron.backward", enabled: webViewStore.canGoBack) { webViewStore.goBack() }
            toolButton("chevron.forward", enabled: webViewStore.canGoForward) { webViewStore.goForward() }
            toolButton(webViewStore.isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                webViewStore.isLoading ? webViewStore.stop() : webViewStore.reload()
            }
            toolButton("house") { dismiss() }
            toolButton("square.and.arrow.up") {
                if let url = webViewStore.currentURL {
                    UIPasteboard.general.string = url.absoluteString
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(white: 0.985))
    }

    private func toolButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(enabled ? accent : Color(white: 0.75))
                .frame(width: 44, height: 36)
        }
        .disabled(!enabled)
    }
}
