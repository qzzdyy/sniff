import SwiftUI
import UIKit

/// 从 M3U8 创建下载任务，对齐小工具集 VC_M3_CreateFromMaster / VC_M3_CreateFromPlaylist：
/// 画面流 / 音频 / 字幕分组选择，失败可重试，可拷贝链接或在 Safari 打开
struct M3CreateView: View {
    let sourceURL: URL
    var suggestedName: String = ""
    @ObservedObject var downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss
    @State private var streams: [M3UStream] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var taskName = ""
    @State private var selectedVideo: UUID?
    @State private var selectedAudio: UUID?
    @State private var selectedSub: UUID?
    @State private var toast: String?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private var videos: [M3UStream] { streams.filter { $0.kind == .video } }
    private var audios: [M3UStream] { streams.filter { $0.kind == .audio } }
    private var subtitles: [M3UStream] { streams.filter { $0.kind == .subtitle } }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    loadingView
                } else if let errorText {
                    failedView(errorText)
                } else {
                    content
                }
            }
            .navigationTitle("从 M3U8 创建下载任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("g.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = sourceURL.absoluteString
                            showToast("已拷贝")
                        } label: {
                            Label(L10n.t("m3.create.copy_link"), systemImage: "doc.on.doc")
                        }
                        Button {
                            UIApplication.shared.open(sourceURL)
                        } label: {
                            Label("在 Safari 中打开", systemImage: "safari")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !loading && errorText == nil {
                    createBar
                }
            }
        }
        .onAppear(perform: load)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 90)
            }
        }
    }

    // MARK: - 加载 / 失败

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在解析播放列表...")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundColor(Theme.secondary)
            Text(L10n.t("m3.create.parse_failed"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                load()
            } label: {
                Text(L10n.t("m3.create.retry"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(accent))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 内容

    private var content: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Text(L10n.t("m3.create.name"))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.secondary)
                    TextField("未命名", text: $taskName)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }

            if !videos.isEmpty {
                Section("画面流") {
                    ForEach(videos) { s in
                        streamRow(s, selected: selectedVideo == s.id) {
                            selectedVideo = s.id
                        }
                    }
                }
            }

            if !audios.isEmpty {
                Section("音频") {
                    ForEach(audios) { s in
                        streamRow(s, selected: selectedAudio == s.id) {
                            selectedAudio = (selectedAudio == s.id) ? nil : s.id
                        }
                    }
                }
            }

            if !subtitles.isEmpty {
                Section("字幕") {
                    ForEach(subtitles) { s in
                        streamRow(s, selected: selectedSub == s.id) {
                            selectedSub = (selectedSub == s.id) ? nil : s.id
                        }
                    }
                }
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("画面流决定清晰度；音频和字幕可单独选择或不选。下载完成后自动合并为 MP4。")
                        .font(.system(size: 11))
                }
                .foregroundColor(Theme.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func streamRow(_ s: M3UStream, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: s.kind.symbol)
                    .font(.system(size: 15))
                    .foregroundColor(selected ? accent : Theme.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(.system(size: 14, weight: selected ? .medium : .regular))
                        .foregroundColor(accent)
                    HStack(spacing: 8) {
                        if let b = s.bandwidthText {
                            Text("带宽: \(b)")
                        }
                        if let c = s.channels {
                            Text("声道: \(c)")
                        }
                        if s.isDirect {
                            Text("直接下载")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundColor(selected ? accent : Theme.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部

    private var createBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: create) {
                Text("创建下载")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent))
            }
            .disabled(selectedVideo == nil && selectedAudio == nil)
            .opacity((selectedVideo == nil && selectedAudio == nil) ? 0.4 : 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - 动作

    private func load() {
        loading = true
        errorText = nil
        if taskName.isEmpty {
            taskName = suggestedName
        }
        M3UParser.parse(url: sourceURL) { result in
            loading = false
            switch result {
            case .success(let list):
                streams = list
                selectedVideo = list.first(where: { $0.kind == .video })?.id
                selectedAudio = list.first(where: { $0.kind == .audio })?.id
            case .failure(let err):
                errorText = err.message
            }
        }
    }

    private func create() {
        let chosen = streams.first { $0.id == selectedVideo }
            ?? streams.first { $0.id == selectedAudio }
        guard let chosen else { return }

        var item = ResourceItem(url: chosen.url, kind: .hls, pageURL: sourceURL)
        item.pageTitle = taskName.isEmpty ? nil : taskName
        downloadManager.download(item)
        dismiss()
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toast = nil }
    }
}
