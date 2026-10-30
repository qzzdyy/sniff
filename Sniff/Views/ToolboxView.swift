import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 工具箱主页（对应截图里的「视频 / 音频 / 图片 / GIF / PDF / 解压」网格）
struct ToolboxView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var siteStore: SiteStore

    @AppStorage("compressDoneAlert") private var compressDoneAlert = true

    @State private var showSettings = false
    @State private var showBrowser = false
    @State private var pendingTool: ToolAction?
    @State private var showPicker = false
    @State private var running = false
    @State private var runningText = ""
    @State private var toast: String?
    @State private var choiceDialog = false
    @State private var lastOutput: URL?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let bg = Color(red: 0.949, green: 0.949, blue: 0.965)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                inspireCard
                section("图片", [
                    ToolAction.imageConvert,
                    ToolAction.imageResize,
                    ToolAction.imageTargetSize,
                    ToolAction.livePhotoToVideo
                ])
                section("GIF / 动图", [
                    ToolAction.videoToGIF,
                    ToolAction.livePhotoToGIF,
                    ToolAction.gifToMP4,
                    ToolAction.gifFrames
                ])
                section("视频", [
                    ToolAction.videoToMP4,
                    ToolAction.videoCompress,
                    ToolAction.videoCompressSize,
                    ToolAction.videoGrabFrame,
                    ToolAction.videoExtractAudio
                ])
                section("音频", [
                    ToolAction.audioConvert,
                    ToolAction.audioTrim,
                    ToolAction.audioMerge
                ])
                section("PDF", [ToolAction.toPDF])
                section("解压 / 压缩", [ToolAction.unzip, ToolAction.zip])
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 34)
        }
        .background(bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(white: 0.35))
                }
            }
        }
        .navigationDestination(isPresented: $showBrowser) {
            SiteListView(webViewStore: webViewStore,
                         resourceStore: resourceStore,
                         downloadManager: downloadManager,
                         siteStore: siteStore)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(webViewStore: webViewStore, resourceStore: resourceStore, downloadManager: downloadManager)
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: pendingTool?.allowedTypes ?? [.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { start(url) }
            case .failure:
                showToast("没有取到文件")
            }
        }
        .confirmationDialog("选择输出格式", isPresented: $choiceDialog, titleVisibility: .visible) {
            ForEach(pendingTool?.options ?? [], id: \.self) { opt in
                Button(opt) { pendingChoice = opt; showPicker = true }
            }
            Button("取消", role: .cancel) { pendingTool = nil }
        }
        .overlay(alignment: .bottom) { bottomBar }
    }

    @State private var pendingChoice: String = ""

    // MARK: - 探索灵感

    private var inspireCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("探索灵感")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(Color(white: 0.13))

            Button { showBrowser = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white)
                    VStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 27, weight: .light))
                            .foregroundColor(Color(white: 0.55))
                        Text("打开嗅探浏览器")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
                .frame(height: 96)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
    }

    // MARK: - 分组

    private func section(_ title: String, _ items: [ToolAction]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(Color(white: 0.13))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { tool in
                    Button { tap(tool) } label: {
                        ToolCard(tool: tool)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 点击

    private func tap(_ tool: ToolAction) {
        pendingTool = tool
        pendingChoice = ""
        guard tool.implemented else {
            showToast("\(tool.title) 下个版本接上")
            pendingTool = nil
            return
        }
        if tool.options.isEmpty {
            showPicker = true
        } else {
            choiceDialog = true
        }
    }

    private func start(_ url: URL) {
        guard let tool = pendingTool else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        runningText = "正在\(tool.title)…"
        running = true
        let choice = pendingChoice

        MediaConverter.perform(tool: tool, choice: choice, input: url) { result in
            if scoped { url.stopAccessingSecurityScopedResource() }
            running = false
            switch result {
            case .success(let out):
                lastOutput = out
                showToast("完成：\(out.lastPathComponent)")
                if compressDoneAlert { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            case .failure(let err):
                showToast("失败：\(err.message.prefix(60))")
            }
            pendingTool = nil
        }
    }

    // MARK: - 底部浮层

    private var bottomBar: some View {
        Group {
            if running {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.85)
                    Text(runningText).font(.footnote)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .foregroundColor(.white)
                .padding(.bottom, 20)
            } else if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 20)
                    .onTapGesture {
                        if let lastOutput { UIPasteboard.general.string = lastOutput.path }
                    }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { toast = nil }
        }
    }
}

// MARK: - 卡片

struct ToolCard: View {
    let tool: ToolAction

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: tool.symbol)
                    .font(.system(size: 25, weight: .light))
                    .foregroundColor(Color(white: 0.32))
                Spacer(minLength: 0)
                Text(tool.title)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(white: 0.18))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 6)
                Spacer().frame(height: 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let badge = tool.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(white: 0.45))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color(white: 0.75), lineWidth: 0.8)
                    )
                    .padding(6)
            }
        }
        .frame(height: 104)
    }
}

// MARK: - 工具定义

enum ToolAction: String, Identifiable, CaseIterable {
    case imageConvert, imageResize, imageTargetSize, livePhotoToVideo
    case videoToGIF, livePhotoToGIF, gifToMP4, gifFrames
    case videoToMP4, videoCompress, videoCompressSize, videoGrabFrame, videoExtractAudio
    case audioConvert, audioTrim, audioMerge
    case toPDF
    case unzip, zip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageConvert:       return "格式转换"
        case .imageResize:        return "压缩 / 缩放"
        case .imageTargetSize:    return "压缩到指定大小"
        case .livePhotoToVideo:   return "实况照片 转 MP4"
        case .videoToGIF:         return "视频 转 GIF"
        case .livePhotoToGIF:     return "实况照片 转 GIF"
        case .gifToMP4:           return "GIF 转 MP4"
        case .gifFrames:          return "提取照片"
        case .videoToMP4:         return "转 MP4"
        case .videoCompress:      return "压缩"
        case .videoCompressSize:  return "压缩到指定大小"
        case .videoGrabFrame:     return "提取照片"
        case .videoExtractAudio:  return "提取音频"
        case .audioConvert:       return "格式转换"
        case .audioTrim:          return "裁剪"
        case .audioMerge:         return "连接"
        case .toPDF:              return "转 PDF"
        case .unzip:              return "解压"
        case .zip:                return "压缩"
        }
    }

    var symbol: String {
        switch self {
        case .imageConvert, .videoToMP4, .audioConvert: return "arrow.triangle.2.circlepath"
        case .imageResize, .videoCompress:              return "arrow.down.right.and.arrow.up.left"
        case .imageTargetSize, .videoCompressSize:      return "rectangle.compress.vertical"
        case .livePhotoToVideo, .livePhotoToGIF:        return "livephoto"
        case .videoToGIF:                               return "play.rectangle"
        case .gifToMP4:                                 return "rectangle.stack"
        case .gifFrames, .videoGrabFrame:               return "photo.on.rectangle"
        case .videoExtractAudio:                        return "music.note"
        case .audioTrim:                                return "scissors"
        case .audioMerge:                               return "link"
        case .toPDF:                                    return "doc.richtext"
        case .unzip:                                    return "archivebox"
        case .zip:                                      return "shippingbox"
        }
    }

    var badge: String? {
        switch self {
        case .videoToGIF, .livePhotoToGIF: return "AI"
        default: return nil
        }
    }

    /// 这一版真正能跑的能力
    var implemented: Bool {
        switch self {
        case .videoToMP4, .videoCompress, .videoCompressSize, .videoGrabFrame,
             .videoExtractAudio, .videoToGIF, .gifToMP4,
             .imageConvert, .imageResize, .audioConvert:
            return true
        default:
            return false
        }
    }

    /// 需要先选参数时的选项
    var options: [String] {
        switch self {
        case .videoCompressSize: return ["10 MB", "50 MB", "100 MB", "200 MB"]
        case .audioConvert:      return ["mp3", "m4a", "wav"]
        case .imageConvert:      return ["jpg", "png"]
        default:                 return []
        }
    }

    var allowedTypes: [UTType] {
        switch self {
        case .videoToMP4, .videoCompress, .videoCompressSize,
             .videoGrabFrame, .videoExtractAudio, .videoToGIF:
            return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .gifToMP4:
            return [.gif]
        case .imageConvert, .imageResize:
            return [.image]
        case .audioConvert:
            return [.audio, .mp3, .mpeg4Audio, .wav]
        default:
            return [.item]
        }
    }
}

// MARK: - 分发

extension MediaConverter {
    static func perform(tool: ToolAction, choice: String, input: URL,
                        completion: @escaping (Result<URL, MediaError>) -> Void) {
        switch tool {
        case .videoToMP4:
            videoToMP4(input, completion: completion)
        case .videoCompress:
            videoCompress(input, completion: completion)
        case .videoCompressSize:
            let mb = Double(choice.replacingOccurrences(of: " MB", with: "")) ?? 50
            videoCompress(toSizeMB: mb, input: input, completion: completion)
        case .videoGrabFrame:
            grabFrame(input, completion: completion)
        case .videoExtractAudio:
            extractAudio(input, completion: completion)
        case .videoToGIF:
            videoToGIF(input, completion: completion)
        case .gifToMP4:
            gifToMP4(input, completion: completion)
        case .imageConvert:
            imageConvert(input, to: choice.isEmpty ? "jpg" : choice, completion: completion)
        case .imageResize:
            imageResize(input, maxPixel: 1600, completion: completion)
        case .audioConvert:
            audioConvert(input, to: choice.isEmpty ? "m4a" : choice, completion: completion)
        default:
            completion(.failure(MediaError("暂未实现")))
        }
    }
}
