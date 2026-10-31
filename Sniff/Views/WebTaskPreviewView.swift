import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// 对应小工具集 VC_WebTaskPreview
///
/// 原版不是「AVPlayer 弹窗」，而是一个**全类型预览器**：
/// 静态图 / 实况照片 / GIF / 视频（AVPlayerLayer）/ 音频（进度 + 时间戳），
/// 外加透明背景切换（transparentBGColorSegment）和不可播放兜底（notPlayableLabel）。
struct WebTaskPreviewView: View {
    let item: ResourceItem
    var downloadManager: DownloadManager? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var isPlaying = false
    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var bgMode = 0                 // 0 棋盘 / 1 黑 / 2 白
    @State private var notPlayable = false
    @State private var preparing = true
    @State private var timer: Timer?

    // 图片缩放
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    @State private var toast: String?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private var isAudio: Bool { item.kind == .audio }
    private var isImageKind: Bool { item.kind == .image }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                stage
                Spacer(minLength: 0)
                if isAudio { audioPanel }
                bottomBar
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 130)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(false)
        .onAppear(perform: prepare)
        .onDisappear {
            player?.pause()
            timer?.invalidate()
        }
        .onChange(of: current) { value in
            if duration > 0, value >= duration - 0.05 { isPlaying = false }
        }
    }

    // MARK: - 背景（transparentBG）

    @ViewBuilder
    private var background: some View {
        switch bgMode {
        case 1: Color.black
        case 2: Color.white
        default: CheckerBoard()
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(bgMode == 2 ? accent : .white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(bgMode == 2 ? Color.black.opacity(0.06) : Color.white.opacity(0.16)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(bgMode == 2 ? accent : .white)
                    .lineLimit(1)
                Text(item.metaText ?? item.url.host ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(bgMode == 2 ? Theme.secondary : Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            if isImageKind {
                // transparentBGColorSegment
                HStack(spacing: 0) {
                    segBtn("棋盘", 0)
                    segBtn("黑", 1)
                    segBtn("白", 2)
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func segBtn(_ title: String, _ value: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { bgMode = value }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: bgMode == value ? .semibold : .regular))
                .foregroundColor(bgMode == value ? accent : .white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    Capsule().fill(bgMode == value ? Color.white : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 舞台

    @ViewBuilder
    private var stage: some View {
        if notPlayable {
            // notPlayableLabel
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                Text("这个格式无法预览")
                    .font(.system(size: 15, weight: .medium))
                Text("可以先下载，再用其它 App 打开")
                    .font(.system(size: 12))
                    .opacity(0.7)
            }
            .foregroundColor(bgMode == 2 ? accent : .white)
        } else if isImageKind {
            imageStage
        } else if isAudio {
            audioStage
        } else {
            videoStage
        }
    }

    private var imageStage: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 6)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.02 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        scale = 1; lastScale = 1
                                        offset = .zero; lastOffset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                            else { scale = 2.4; lastScale = 2.4 }
                        }
                    }
            } else {
                ProgressView().tint(bgMode == 2 ? accent : .white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoStage: some View {
        ZStack {
            if let player {
                PlayerLayerView(player: player)
                    .onTapGesture { togglePlay() }
            } else if preparing {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在准备播放…")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            } else if notPlayable {
                EmptyView()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var audioStage: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 132, height: 132)
                Image(systemName: "waveform")
                    .font(.system(size: 46, weight: .light))
                    .foregroundColor(.white)
                    .scaleEffect(isPlaying ? 1.0 : 0.92)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                               value: isPlaying)
            }
            Text(item.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if notPlayable {
                Text("这个音频无法预览，可先下载")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 音频 / 视频控制条（playProgressView）

    private var audioPanel: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { min(current, max(duration, 0.01)) },
                                  set: { seek($0) }),
                   in: 0...max(duration, 0.01))
                .tint(.white)
            HStack {
                Text(timeText(current))
                Spacer()
                Text(timeText(duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.7))

            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(notPlayable)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    private var videoControls: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { min(current, max(duration, 0.01)) },
                                  set: { seek($0) }),
                   in: 0...max(duration, 0.01))
                .tint(.white)
                .padding(.horizontal, 20)
            HStack {
                Text(timeText(current))
                Spacer()
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer()
                Text(timeText(duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 24)
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if !isImageKind && !isAudio { videoControls }
            HStack(spacing: 0) {
                bottomBtn("下载", "arrow.down.circle") {
                    downloadManagerDownload()
                }
                bottomBtn("复制链接", "doc.on.doc") {
                    UIPasteboard.general.string = item.url.absoluteString
                    show("链接已复制")
                }
                bottomBtn("浏览器打开", "safari") {
                    UIApplication.shared.open(item.url)
                }
                bottomBtn("关闭", "xmark.circle") { dismiss() }
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func bottomBtn(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 逻辑

    private func prepare() {
        if item.kind == .hls {
            // m3u8 交给创建任务页，预览页只提示
            notPlayable = true
            preparing = false
            return
        }

        if isImageKind {
            loadImage()
            return
        }

        guard let url = item.localFile ?? URL(string: item.url.absoluteString) else {
            notPlayable = true; preparing = false; return
        }

        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: item)])
        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                let dur = try await asset.load(.duration)
                await MainActor.run {
                    guard playable else { notPlayable = true; preparing = false; return }
                    duration = CMTimeGetSeconds(dur)
                    let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player = p
                    preparing = false
                    startTimer()
                    if !isAudio {
                        p.play()
                        isPlaying = true
                    }
                }
            } catch {
                await MainActor.run {
                    notPlayable = true
                    preparing = false
                }
            }
        }
    }

    private func loadImage() {
        if let file = item.localFile, let data = try? Data(contentsOf: file) {
            image = decode(data)
            return
        }
        var request = URLRequest(url: item.url)
        for (k, v) in MediaHeaders.headers(for: item) { request.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data else {
                DispatchQueue.main.async {
                    if let thumb = item.thumbnail { image = thumb } else { notPlayable = true }
                }
                return
            }
            let decoded = decode(data)
            DispatchQueue.main.async {
                if let decoded { image = decoded } else if let thumb = item.thumbnail { image = thumb }
                else { notPlayable = true }
            }
        }.resume()
    }

    private func decode(_ data: Data) -> UIImage? {
        let ext = item.url.pathExtension.lowercased()
        if ext == "gif" || ext == "webp" { return Self.animatedImage(from: data) ?? UIImage(data: data) }
        return UIImage(data: data)
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, current >= duration - 0.1 {
                player.seek(to: .zero)
                current = 0
            }
            player.play()
            isPlaying = true
        }
    }

    private func seek(_ value: Double) {
        current = value
        player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard let player else { return }
            let t = CMTimeGetSeconds(player.currentTime())
            if t.isFinite { current = t }
            if let d = player.currentItem?.duration, duration <= 0 {
                let sec = CMTimeGetSeconds(d)
                if sec.isFinite { duration = sec }
            }
        }
    }

    private func downloadManagerDownload() {
        if let downloadManager {
            downloadManager.download(item)
            show("已加入下载列表")
        } else {
            NotificationCenter.default.post(name: .sniffQuickDownload, object: item)
            show("已发送到下载列表")
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { toast = nil }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// GIF / 动态 WebP 逐帧解码
    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        var frames: [UIImage] = []
        var total = 0.0
        for index in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let d = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, d > 0 { delay = d }
                else if let d = gif[kCGImagePropertyGIFDelayTime] as? Double, d > 0 { delay = d }
            }
            total += delay
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

extension Notification.Name {
    static let sniffQuickDownload = Notification.Name("sniff.quickDownload")
}

/// AVPlayerLayer 承载（playerLayer）
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// 透明底棋盘格
struct CheckerBoard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 14
            let cols = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for col in 0..<cols {
                    let rect = CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                      width: cell, height: cell)
                    let isDark = (row + col) % 2 == 0
                    context.fill(Path(rect), with: .color(isDark ? Theme.secondary : Theme.label))
                }
            }
        }
    }
}
