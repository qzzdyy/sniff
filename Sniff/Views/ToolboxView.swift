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
    @AppStorage("homeStyle") private var homeStyle = "image_text"

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
    @State private var runPayload: ToolRunPayload?

    // 音频裁剪
    @State private var showTrim = false
    @State private var trimURL: URL?
    @State private var trimDuration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0

    // 实况照片
    @State private var showLivePicker = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    // 原版 VC_Main 的分组顺序，标题与项名都取自 Localizable.strings
    private let sections: [(key: String, tools: [ToolAction])] = [
        ("main.photo",   [.imageResize, .imageTargetSize, .imageConvert, .livePhotoToVideo]),
        ("main.gif",     [.videoToGIF, .livePhotoToGIF, .gifToMP4, .gifFrames]),
        ("main.video",   [.videoCompress, .videoCompressSize, .videoToMP4,
                          .videoExtractAudio, .videoGrabFrame]),
        ("main.audio",   [.audioTrim, .audioConvert, .audioMerge]),
        ("main.pdf",     [.toPDF]),
        ("main.archive", [.unzip, .zip])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                inspirationBanner
                ForEach(sections, id: \.key) { section in
                    toolSection(section.key, section.tools)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .background(Theme.groupedBG)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Theme.label)
                }
            }
        }
        .fullScreenCover(isPresented: $showBrowser) {
            BrowserView(webViewStore: webViewStore,
                        resourceStore: resourceStore,
                        downloadManager: downloadManager,
                        siteStore: siteStore,
                        onClose: { showBrowser = false })
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
        .fullScreenCover(item: $runPayload) { payload in
            ToolRunView(tool: payload.tool, inputs: payload.urls)
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: pendingTool?.allowedTypes ?? [.item],
                      allowsMultipleSelection: pendingTool?.multiple ?? false) { result in
            switch result {
            case .success(let urls):
                guard let tool = pendingTool, !urls.isEmpty else { return }
                pendingTool = nil
                runPayload = ToolRunPayload(tool: tool, urls: urls)
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
            Button(L10n.t("g.cancel"), role: .cancel) { pendingTool = nil }
        }
        .overlay(alignment: .bottom) { bottomBar }
    }

    // MARK: - 探索灵感（顶部推广条，原版 VC_Main 的第一个区块）

    private var inspirationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("main.inspiration"))
                .font(.headline)
                .foregroundColor(Theme.label)

            Text(L10n.t("main.inspiration.tip"))
                .font(.footnote)
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button { showBrowser = true } label: {
                HStack(spacing: 2) {
                    Text(L10n.t("main.start_explore_inspiration"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.subheadline)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card)
        .cornerRadius(10)
    }

    // MARK: - 分组

    private func toolSection(_ key: String, _ items: [ToolAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(key))
                .font(Theme.sectionTitle)
                .foregroundColor(Theme.secondary)
                .padding(.leading, 4)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { tool in
                    Button { tap(tool) } label: {
                        ToolCard(tool: tool, textOnly: homeStyle == "text")
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
                        Text(L10n.t("m3.task_manage.start"))
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
                    Button(L10n.t("g.cancel")) {
                        showTrim = false
                        pendingTool = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("m3.task_manage.start")) {
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
    var textOnly: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            if !textOnly {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tool.symbol)
                        .font(Theme.tileIcon)
                        .foregroundColor(Theme.icon)
                        .frame(height: 30)

                    if let badge = tool.badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Theme.secondary)
                            .offset(x: 10, y: -2)
                    }
                }
            }

            Text(tool.title)
                .font(Theme.tileTitle)
                .foregroundColor(Theme.label)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: textOnly ? 40 : 76, alignment: textOnly ? .center : .top)
        .contentShape(Rectangle())
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

    /// 文案 key，全部来自原版 Localizable.strings
    var titleKey: String {
        switch self {
        case .imageResize:        return "main.photo.compress"
        case .imageTargetSize:    return "main.photo.compress_fixed_size"
        case .imageConvert:       return "main.photo.convert"
        case .livePhotoToVideo:   return "main.photo.lp_2_mp4"
        case .videoToGIF:         return "main.gif.mp4_2_gif"
        case .livePhotoToGIF:     return "main.gif.lp_2_gif"
        case .gifToMP4:           return "main.gif.gif_2_mp4"
        case .gifFrames:          return "main.gif.extract_image"
        case .videoCompress:      return "main.video.compress"
        case .videoCompressSize:  return "main.video.compress_fixed_size"
        case .videoToMP4:         return "main.video.convert"
        case .videoExtractAudio:  return "main.video.extract_audio"
        case .videoGrabFrame:     return "main.video.extract_image"
        case .audioTrim:          return "main.audio.trim"
        case .audioConvert:       return "main.audio.convert"
        case .audioMerge:         return "main.audio.concat"
        case .toPDF:              return "main.pdf.image_2_pdf"
        case .unzip:              return "main.archive.unzip"
        case .zip:                return "main.archive.zip"
        }
    }

    var title: String { L10n.t(titleKey) }

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
            let parts = choice.split(separator: "|").map(String.init)
            let height = parts.first.flatMap { Int($0) } ?? 720
            let mute = parts.count > 1 && parts[1] == "mute"
            videoCompress(first, height: height, removeAudio: mute, completion: completion)
        case .videoCompressSize:
            let parts = choice.split(separator: "|").map(String.init)
            let mb = Double((parts.first ?? "50").replacingOccurrences(of: " MB", with: "")) ?? 50
            videoCompress(toSizeMB: mb, input: first, completion: completion)
        case .videoGrabFrame:
            grabFrame(first, at: Double(choice) ?? 0, completion: completion)
        case .videoExtractAudio:
            extractAudio(first, completion: completion)
        case .videoToGIF:
            let p = choice.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if p.isEmpty || choice.isEmpty {
                videoToGIF(first, completion: completion)
            } else {
                let scale = Double(p[0]) ?? 1
                let fps = p.count > 1 ? (Int(p[1]) ?? 10) : 10
                var start: Double? = nil
                var end: Double? = nil
                if p.count > 2, !p[2].isEmpty, let v = Double(p[2]) { start = v }
                if p.count > 3, !p[3].isEmpty, let v = Double(p[3]) { end = v }
                let hq = p.count > 4 ? p[4] != "0" : true
                videoToGIF(first, scale: scale, fps: fps, start: start, end: end,
                           highQuality: hq, completion: completion)
            }
        case .gifToMP4:
            gifToMP4(first, completion: completion)
        case .gifFrames:
            gifFrames(first, completion: completion)
        case .imageConvert:
            let parts = choice.split(separator: "|").map(String.init)
            let fmt = parts.first ?? "jpg"
            let quality = parts.count > 1 ? (Double(parts[1]) ?? 0.9) : 0.9
            imageConvert(first, to: fmt.isEmpty ? "jpg" : fmt,
                         quality: CGFloat(quality), completion: completion)
        case .imageResize:
            imageResize(first, maxPixel: CGFloat(Double(choice) ?? 1600), completion: completion)
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
