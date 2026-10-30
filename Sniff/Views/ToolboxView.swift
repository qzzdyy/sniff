import SwiftUI
import UIKit
import AVFoundation
import PhotosUI
import Photos
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
    @State private var pendingChoice = ""
    @State private var showPicker = false
    @State private var running = false
    @State private var runningText = ""
    @State private var toast: String?
    @State private var choiceDialog = false
    @State private var lastOutput: URL?

    // 音频裁剪
    @State private var showTrim = false
    @State private var trimURL: URL?
    @State private var trimDuration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    // 实况照片
    @State private var showLivePicker = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let bg = Color(red: 0.949, green: 0.949, blue: 0.965)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                inspireCard
                section("图片", [
                    .imageConvert, .imageResize, .imageTargetSize, .livePhotoToVideo
                ])
                section("GIF / 动图", [
                    .videoToGIF, .livePhotoToGIF, .gifToMP4, .gifFrames
                ])
                section("视频", [
                    .videoToMP4, .videoCompress, .videoCompressSize, .videoGrabFrame, .videoExtractAudio
                ])
                section("音频", [
                    .audioConvert, .audioTrim, .audioMerge
                ])
                section("PDF", [.toPDF])
                section("解压 / 压缩", [.unzip, .zip])
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
            SettingsView(webViewStore: webViewStore,
                         resourceStore: resourceStore,
                         downloadManager: downloadManager)
        }
        .sheet(isPresented: $showLivePicker) {
            LivePhotoPicker { asset in
                showLivePicker = false
                handleLivePhoto(asset)
            }
        }
        .sheet(isPresented: $showTrim) { trimSheet }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: pendingTool?.allowedTypes ?? [.item],
                      allowsMultipleSelection: pendingTool?.multiple ?? false) { result in
            switch result {
            case .success(let urls):
                guard let tool = pendingTool, !urls.isEmpty else { return }
                if tool.needsTrim, let first = urls.first {
                    prepareTrim(first)
                } else {
                    start(urls)
                }
            case .failure:
                showToast("没有取到文件")
                pendingTool = nil
            }
        }
        .confirmationDialog(pendingTool?.dialogTitle ?? "选择",
                            isPresented: $choiceDialog,
                            titleVisibility: .visible) {
            ForEach(pendingTool?.options ?? [], id: \.self) { opt in
                Button(opt) {
                    pendingChoice = opt
                    showPicker = true
                }
            }
            Button("取消", role: .cancel) { pendingTool = nil }
        }
        .overlay(alignment: .bottom) { bottomBar }
    }

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
        if tool.usesLivePicker {
            showLivePicker = true
            return
        }
        if tool.options.isEmpty {
            showPicker = true
        } else {
            choiceDialog = true
        }
    }

    private func prepareTrim(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        if scoped { url.stopAccessingSecurityScopedResource() }

        trimURL = url
        trimDuration = seconds.isFinite ? seconds : 0
        trimStart = 0
        trimEnd = trimDuration
        showTrim = true
    }

    private var trimSheet: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("总时长", value: String(format: "%.1f 秒", trimDuration))
                    HStack {
                        Text("开始")
                        Spacer()
                        TextField("0", value: $trimStart, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("秒").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("结束")
                        Spacer()
                        TextField("0", value: $trimEnd, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("秒").foregroundColor(.secondary)
                    }
                } footer: {
                    Text("裁剪后输出 m4a。")
                }
            }
            .navigationTitle("裁剪音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showTrim = false
                        pendingTool = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        guard let url = trimURL else { return }
                        pendingChoice = "\(trimStart)|\(trimEnd)"
                        showTrim = false
                        start([url])
                    }
                    .disabled(trimEnd <= trimStart)
                }
            }
        }
        .presentationDetents([.height(330)])
    }

    private func handleLivePhoto(_ asset: PHAsset) {
        runningText = "正在提取实况照片…"
        running = true
        let tool = pendingTool
        LivePhotoExtractor.videoURL(from: asset) { result in
            running = false
            switch result {
            case .success(let url):
                if let tool { start([url], override: tool) }
            case .failure(let err):
                showToast("失败：\(err.message)")
                pendingTool = nil
            }
        }
    }

    private func start(_ urls: [URL], override: ToolAction? = nil) {
        guard let tool = override ?? pendingTool, !urls.isEmpty else { return }
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        runningText = "正在\(tool.title)…"
        running = true
        let choice = pendingChoice

        MediaConverter.perform(tool: tool, choice: choice, inputs: urls) { result in
            for (i, u) in urls.enumerated() where scoped[i] {
                u.stopAccessingSecurityScopedResource()
            }
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

    var multiple: Bool {
        switch self {
        case .toPDF, .zip, .audioMerge: return true
        default: return false
        }
    }

    var needsTrim: Bool { self == .audioTrim }

    var usesLivePicker: Bool {
        self == .livePhotoToVideo || self == .livePhotoToGIF
    }

    var dialogTitle: String {
        switch self {
        case .videoCompressSize, .imageTargetSize: return "压缩到多大"
        case .audioConvert, .imageConvert:         return "输出格式"
        default:                                   return "选择"
        }
    }

    var options: [String] {
        switch self {
        case .videoCompressSize: return ["10 MB", "50 MB", "100 MB", "200 MB"]
        case .imageTargetSize:   return ["100 KB", "200 KB", "500 KB", "1 MB"]
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
        case .gifToMP4, .gifFrames:
            return [.gif]
        case .imageConvert, .imageResize, .imageTargetSize, .toPDF:
            return [.image]
        case .audioConvert, .audioTrim, .audioMerge:
            return [.audio, .mp3, .mpeg4Audio, .wav]
        case .unzip:
            return [.zip, .archive]
        case .zip:
            return [.item]
        default:
            return [.item]
        }
    }
}

// MARK: - 分发

extension MediaConverter {
    static func perform(tool: ToolAction, choice: String, inputs: [URL],
                        completion: @escaping (Result<URL, MediaError>) -> Void) {
        guard let first = inputs.first else {
            completion(.failure(MediaError("没有选中文件")))
            return
        }
        switch tool {
        case .videoToMP4:
            videoToMP4(first, completion: completion)
        case .videoCompress:
            videoCompress(first, completion: completion)
        case .videoCompressSize:
            let mb = Double(choice.replacingOccurrences(of: " MB", with: "")) ?? 50
            videoCompress(toSizeMB: mb, input: first, completion: completion)
        case .videoGrabFrame:
            grabFrame(first, completion: completion)
        case .videoExtractAudio:
            extractAudio(first, completion: completion)
        case .videoToGIF:
            videoToGIF(first, completion: completion)
        case .gifToMP4:
            gifToMP4(first, completion: completion)
        case .gifFrames:
            gifFrames(first, completion: completion)
        case .imageConvert:
            imageConvert(first, to: choice.isEmpty ? "jpg" : choice, completion: completion)
        case .imageResize:
            imageResize(first, maxPixel: 1600, completion: completion)
        case .imageTargetSize:
            imageCompress(toBytes: parseSize(choice), input: first, completion: completion)
        case .audioConvert:
            audioConvert(first, to: choice.isEmpty ? "m4a" : choice, completion: completion)
        case .audioTrim:
            let parts = choice.split(separator: "|").compactMap { Double($0) }
            guard parts.count == 2 else {
                completion(.failure(MediaError("裁剪区间无效")))
                return
            }
            audioTrim(first, start: parts[0], end: parts[1], completion: completion)
        case .audioMerge:
            audioConcat(inputs, completion: completion)
        case .toPDF:
            imagesToPDF(inputs, completion: completion)
        case .zip:
            zipFiles(inputs, completion: completion)
        case .unzip:
            unzipFile(first, completion: completion)
        case .livePhotoToVideo:
            livePhotoToVideo(first, completion: completion)
        case .livePhotoToGIF:
            livePhotoToGIF(first, completion: completion)
        }
    }

    private static func parseSize(_ text: String) -> Int {
        if text.contains("MB"), let v = Double(text.replacingOccurrences(of: " MB", with: "")) {
            return Int(v * 1024 * 1024)
        }
        if let v = Double(text.replacingOccurrences(of: " KB", with: "")) {
            return Int(v * 1024)
        }
        return 200 * 1024
    }
}

// MARK: - 实况照片

enum LivePhotoExtractor {
    /// 从 PHAsset 取出配对视频，落到临时目录
    static func videoURL(from asset: PHAsset, completion: @escaping (Result<URL, MediaError>) -> Void) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let paired = resources.first(where: { $0.type == .pairedVideo })
                ?? resources.first(where: { $0.type == .fullSizeVideo }) else {
            DispatchQueue.main.async { completion(.failure(MediaError("这张照片没有视频轨"))) }
            return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("live_\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: paired, toFile: dest, options: options) { error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(MediaError(error.localizedDescription)))
                } else {
                    completion(.success(dest))
                }
            }
        }
    }
}

struct LivePhotoPicker: UIViewControllerRepresentable {
    var onPick: (PHAsset) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .livePhotos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (PHAsset) -> Void
        init(onPick: @escaping (PHAsset) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let id = results.first?.assetIdentifier else { return }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            if let asset = assets.firstObject { onPick(asset) }
        }
    }
}
