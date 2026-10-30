import SwiftUI
import UIKit
import AVFoundation

/// 对应小工具集 18 个工具执行页的统一骨架
///
/// 原版每个工具都是同一个模板：`cv`（文件列表）+ `stackFileDesc`（文件名 / 大小）
/// + `stackPanel`（参数面板）+ `buttonStart`，只是面板里的控件不同。
struct ToolRunView: View {
    let tool: ToolAction
    let inputs: [URL]
    /// 传入时直接进裁剪（音频裁剪 / GIF 区间 / 抽帧时间点）
    var initialChoice: String = ""

    @Environment(\.dismiss) private var dismiss

    // 参数
    @State private var maxPixel: CGFloat = 1600
    @State private var quality: Double = 0.85
    @State private var imageFormat = "jpg"
    @State private var targetSize = "200 KB"
    @State private var videoHeight = 720
    @State private var videoTargetSize = "50 MB"
    @State private var removeAudio = false
    @State private var audioFormat = "m4a"
    @State private var gif = GifParams()
    @State private var showGifParams = false

    // 时间轴
    @State private var mediaDuration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var grabTime: Double = 0

    // 执行
    @State private var running = false
    @State private var runningText = ""
    @State private var resultFiles: [URL] = []
    @State private var showResult = false
    @State private var errorText: String?
    @State private var extraInputs: [URL] = []

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let bg = Color(red: 0.949, green: 0.949, blue: 0.965)

    private var allInputs: [URL] { inputs + extraInputs }

    private var needsTimeline: Bool {
        tool == .videoToGIF || tool == .videoGrabFrame
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    fileCard
                    if tool == .audioTrim {
                        audioTrimPanel
                    } else {
                        if needsTimeline { timelinePanel }
                        parameterPanel
                    }
                    startButton
                }
                .padding(16)
            }
            .background(bg)
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.foregroundColor(accent)
                }
            }
            .sheet(isPresented: $showGifParams) {
                GifParamsSheet(params: $gif, duration: max(0, trimEnd - trimStart), pixelSize: .zero)
            }
            .fullScreenCover(isPresented: $showResult) {
                ResultView(title: "处理完成", files: resultFiles) { dismiss() }
            }
            .overlay {
                if running {
                    ZStack {
                        Color.black.opacity(0.22).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text(runningText).font(.system(size: 13)).foregroundColor(.white)
                        }
                        .padding(26)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.84)))
                    }
                }
            }
            .alert("处理失败", isPresented: Binding(get: { errorText != nil },
                                                 set: { if !$0 { errorText = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .onAppear(perform: prepare)
    }

    // MARK: - 文件卡（cv + stackFileDesc）

    private var fileCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(allInputs.enumerated()), id: \.offset) { index, url in
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.95))
                        Image(systemName: symbol(for: url))
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(Color(white: 0.4))
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(accent)
                            .lineLimit(1)
                        Text(sizeText(url))
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.5))
                    }
                    Spacer()
                    if allInputs.count > 1 {
                        Button {
                            if index < inputs.count { return }
                            extraInputs.remove(at: index - inputs.count)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Color(white: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                if index < allInputs.count - 1 {
                    Divider().padding(.leading, 70)
                }
            }

            if tool.multiple {
                Button {
                    addMore()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text(tool == .audioMerge ? "继续添加音频" : "继续添加文件")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    // MARK: - 时间轴

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tool == .videoToGIF ? "截取片段" : "选择时间点")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.45))

            if let first = inputs.first, mediaDuration > 0 {
                if tool == .videoToGIF {
                    VideoTrimPicker(url: first, duration: mediaDuration,
                                    start: $trimStart, end: $trimEnd)
                } else {
                    VideoTrimPicker(url: first, duration: mediaDuration,
                                    start: $trimStart, end: $trimEnd,
                                    markerTimes: [grabTime])
                    HStack {
                        Text("抽帧位置")
                            .font(.system(size: 12))
                        Slider(value: $grabTime, in: 0...max(mediaDuration, 0.1))
                            .tint(accent)
                        Text(String(format: "%.1fs", grabTime))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(white: 0.45))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    private var audioTrimPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择保留区间")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.45))
            if let first = inputs.first, mediaDuration > 0 {
                AudioTrimView(url: first, duration: mediaDuration, start: $trimStart, end: $trimEnd)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    // MARK: - 参数面板（stackPanel）

    @ViewBuilder
    private var parameterPanel: some View {
        switch tool {
        case .imageResize:
            panel(title: "输出尺寸") {
                segmentRow(["480", "1080", "1600", "2560"], selected: "\(Int(maxPixel))") { value in
                    maxPixel = CGFloat(Double(value) ?? 1600)
                }
                hint("长边缩放到 \(Int(maxPixel)) 像素，等比缩放")
            }
        case .imageConvert:
            panel(title: "输出格式") {
                segmentRow(["jpg", "png"], selected: imageFormat) { imageFormat = $0 }
                sliderRow("质量", value: $quality, range: 0.4...1.0, text: "\(Int(quality * 100))%")
            }
        case .imageTargetSize:
            panel(title: "目标大小") {
                segmentRow(["100 KB", "200 KB", "500 KB", "1 MB"], selected: targetSize) { targetSize = $0 }
                hint("按目标体积反推压缩质量，尽量保留清晰度")
            }
        case .videoCompress:
            panel(title: "分辨率") {
                segmentRow(["480", "720", "1080"], selected: "\(videoHeight)") { value in
                    videoHeight = Int(value) ?? 720
                }
                toggleRow("移除音频", isOn: $removeAudio)
                hint("高度 \(videoHeight)p，CRF 26")
            }
        case .videoCompressSize:
            panel(title: "目标大小") {
                segmentRow(["10 MB", "50 MB", "100 MB", "200 MB"], selected: videoTargetSize) { videoTargetSize = $0 }
                toggleRow("移除音频", isOn: $removeAudio)
                hint("按时长反推码率，两遍之内压到目标体积附近")
            }
        case .videoToGIF:
            panel(title: "GIF 参数") {
                Button { showGifParams = true } label: {
                    HStack {
                        Text("质量 / 缩放 / 帧率")
                            .font(.system(size: 13))
                            .foregroundColor(accent)
                        Spacer()
                        Text(gif.displayText)
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.45))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.7))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        case .audioConvert:
            panel(title: "输出格式") {
                segmentRow(["mp3", "m4a", "wav"], selected: audioFormat) { audioFormat = $0 }
            }
        default:
            EmptyView()
        }
    }

    private func panel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.45))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }

    private func segmentRow(_ options: [String], selected: String,
                            action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button { action(option) } label: {
                    Text(option)
                        .font(.system(size: 13, weight: selected == option ? .semibold : .regular))
                        .foregroundColor(selected == option ? .white : accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selected == option ? accent : Color(white: 0.95)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(text).font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.45))
            }
            Slider(value: value, in: range).tint(accent)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 13)).foregroundColor(accent)
        }
        .tint(accent)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(white: 0.5))
    }

    // MARK: - 开始

    private var startButton: some View {
        Button {
            run()
        } label: {
            Text(running ? "处理中…" : "开始")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 14).fill(accent))
        }
        .buttonStyle(.plain)
        .disabled(running || allInputs.isEmpty)
        .padding(.top, 4)
    }

    private func run() {
        running = true
        runningText = "正在\(tool.title)…"
        let choice = choiceString()
        MediaConverter.perform(tool: tool, choice: choice, inputs: allInputs) { result in
            running = false
            switch result {
            case .success(let url):
                resultFiles = [url]
                showResult = true
            case .failure(let error):
                errorText = error.message
            }
        }
    }

    private func choiceString() -> String {
        switch tool {
        case .imageResize:
            return "\(Int(maxPixel))"
        case .imageConvert:
            return "\(imageFormat)|\(String(format: "%.2f", quality))"
        case .imageTargetSize:
            return targetSize
        case .videoCompress:
            return "\(videoHeight)|\(removeAudio ? "mute" : "keep")"
        case .videoCompressSize:
            return "\(videoTargetSize)|\(removeAudio ? "mute" : "keep")"
        case .videoToGIF:
            let start = trimStart > 0 ? String(format: "%.2f", trimStart) : ""
            let end = trimEnd > 0 ? String(format: "%.2f", trimEnd) : ""
            return "\(gif.scale)|\(gif.fps)|\(start)|\(end)|\(gif.highQuality ? "1" : "0")"
        case .videoGrabFrame:
            return String(format: "%.2f", grabTime)
        case .audioConvert:
            return audioFormat
        case .audioTrim:
            return String(format: "%.2f|%.2f", trimStart, trimEnd)
        default:
            return ""
        }
    }

    // MARK: - 准备

    private func prepare() {
        guard let first = inputs.first else { return }

        if !initialChoice.isEmpty {
            // 初始参数从调用方带入
            let parts = initialChoice.split(separator: "|").map(String.init)
            if tool == .audioTrim, parts.count == 2 {
                trimStart = Double(parts[0]) ?? 0
                trimEnd = Double(parts[1]) ?? 0
            }
        }

        guard tool == .videoToGIF || tool == .videoGrabFrame || tool == .audioTrim else { return }
        let asset = AVURLAsset(url: first)
        let seconds = CMTimeGetSeconds(asset.duration)
        DispatchQueue.main.async {
            mediaDuration = seconds.isFinite ? seconds : 0
            if trimEnd == 0 { trimEnd = mediaDuration }
            grabTime = mediaDuration / 2
        }
    }

    private func addMore() {
        // 走系统的文件选择，追加到 extraInputs
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: tool.allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = DocumentPickProxy.shared
        DocumentPickProxy.shared.onPick = { urls in
            extraInputs.append(contentsOf: urls)
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(picker, animated: true)
        }
    }

    private func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return "film"
        case "jpg", "jpeg", "png", "heic", "webp": return "photo"
        case "gif": return "photo.stack"
        case "mp3", "m4a", "wav", "aac", "flac": return "waveform"
        case "zip", "7z", "rar": return "archivebox"
        default: return "doc"
        }
    }

    private func sizeText(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else { return url.pathExtension.uppercased() }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 文档选择回调代理（追加文件用）
final class DocumentPickProxy: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickProxy()
    var onPick: (([URL]) -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick?(urls)
    }
}

/// 工具执行页的入参
struct ToolRunPayload: Identifiable {
    let id = UUID()
    let tool: ToolAction
    let urls: [URL]
}
