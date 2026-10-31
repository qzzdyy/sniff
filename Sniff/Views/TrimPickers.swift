import SwiftUI
import UIKit
import AVFoundation

/// 对应小工具集 ViewVideoTrim / ViewVideoPick / ViewImagesPick
///
/// 缩略图条 + 左右两个手柄 + 时间戳，手柄拖动改起止点：
/// thumbStackView / trimMaskWrapperView / leftTimestamp / rightTimestamp / panGes
struct VideoTrimPicker: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// 已选中的时间点（抽帧用，可空）
    var markerTimes: [Double] = []

    @State private var thumbs: [UIImage] = []
    @State private var dragStart: Double?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let handleWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(width - handleWidth * 2, 1)
            let startX = handleWidth / 2 + usable * CGFloat(clamp(start) / max(duration, 0.01))
            let endX = handleWidth / 2 + usable * CGFloat(clamp(end) / max(duration, 0.01))

            ZStack(alignment: .leading) {
                // thumbStackView
                HStack(spacing: 0) {
                    if thumbs.isEmpty {
                        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                    } else {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width / CGFloat(max(thumbs.count, 1)), height: 68)
                                .clipped()
                        }
                    }
                }
                .frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // 左右遮罩
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, startX - handleWidth / 2), height: 68)
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: max(0, width - endX - handleWidth / 2), height: 68)
                    .offset(x: endX + handleWidth / 2)

                // 抽帧标记
                ForEach(Array(markerTimes.enumerated()), id: \.offset) { _, t in
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 1.5, height: 68)
                        .offset(x: handleWidth / 2 + usable * CGFloat(clamp(t) / max(duration, 0.01)))
                }

                // 左手柄
                handle
                    .offset(x: startX - handleWidth / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let delta = Double(value.translation.width / usable) * duration
                                start = clamp(start0 + delta, lower: 0, upper: end - 0.2)
                            }
                            .onEnded { _ in start0 = start }
                    )

                // 右手柄
                handle
                    .offset(x: endX - handleWidth / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let delta = Double(value.translation.width / usable) * duration
                                end = clamp(end0 + delta, lower: start + 0.2, upper: duration)
                            }
                            .onEnded { _ in end0 = end }
                    )
            }
            .onAppear {
                start0 = start
                end0 = end
                loadThumbs(width: width)
            }
            .onChange(of: url) { _ in loadThumbs(width: width) }
        }
        .frame(height: 68)
        .overlay(alignment: .bottom) {
            HStack {
                Text(timeText(start))
                Spacer()
                Text("已选 \(String(format: "%.1f", max(0, end - start))) 秒")
                    .foregroundColor(accent)
                Spacer()
                Text(timeText(end))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.secondary)
            .offset(y: 20)
        }
        .padding(.bottom, 22)
    }

    @State private var start0: Double = 0
    @State private var end0: Double = 0

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.white)
            .frame(width: handleWidth, height: 76)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accent.opacity(0.25), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 3) {
                    Capsule().fill(accent.opacity(0.5)).frame(width: 2.5, height: 12)
                    Capsule().fill(accent.opacity(0.5)).frame(width: 2.5, height: 12)
                }
            )
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), duration)
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func loadThumbs(width: CGFloat) {
        guard duration > 0 else { return }
        let count = 8
        VideoThumbs.generate(url: url, count: count) { images in
            DispatchQueue.main.async { thumbs = images }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 视频抽帧（横条缩略图）
enum VideoThumbs {
    static func generate(url: URL, count: Int, completion: @escaping ([UIImage]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 120)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero

            let duration = CMTimeGetSeconds(asset.duration)
            guard duration.isFinite, duration > 0 else { completion([]); return }

            var images: [UIImage] = []
            for index in 0..<count {
                let t = duration * (Double(index) + 0.5) / Double(count)
                let time = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                    images.append(UIImage(cgImage: cg))
                }
            }
            completion(images)
        }
    }
}

/// 对应小工具集 ViewAudioTrim（30 个控件：波形 + 播放控制 + 双向手柄 + 时间戳）
struct AudioTrimView: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double

    @State private var samples: [CGFloat] = []
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var cursor: Double = 0
    @State private var timer: Timer?
    @State private var start0: Double = 0
    @State private var end0: Double = 0

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let width = geo.size.width
                let startX = width * CGFloat(min(max(start / max(duration, 0.01), 0), 1))
                let endX = width * CGFloat(min(max(end / max(duration, 0.01), 0), 1))

                ZStack(alignment: .leading) {
                    // audio_middle_valid_mask / 左右 invalid mask
                    waveform(height: geo.size.height)
                        .frame(height: geo.size.height)

                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: max(0, startX))
                    Rectangle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)

                    // audio_current_indicator
                    Rectangle()
                        .fill(Color(red: 0.85, green: 0.25, blue: 0.2))
                        .frame(width: 1.5)
                        .offset(x: width * CGFloat(min(max(cursor / max(duration, 0.01), 0), 1)))

                    // 手柄
                    handleBar
                        .offset(x: max(0, startX - 2))
                        .gesture(
                            DragGesture().onChanged { value in
                                let delta = Double(value.translation.width / max(width, 1)) * duration
                                start = min(max(start0 + delta, 0), end - 0.2)
                            }.onEnded { _ in start0 = start }
                        )
                    handleBar
                        .offset(x: min(width - 3, endX - 2))
                        .gesture(
                            DragGesture().onChanged { value in
                                let delta = Double(value.translation.width / max(width, 1)) * duration
                                end = min(max(end0 + delta, start + 0.2), duration)
                            }.onEnded { _ in end0 = end }
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        cursor = Double(value.location.x / max(width, 1)) * duration
                        player?.currentTime = cursor
                    }
                )
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))

            HStack {
                Text(timeText(start))
                Spacer()
                Text("已选 \(String(format: "%.1f", max(0, end - start))) 秒")
                    .foregroundColor(accent)
                Spacer()
                Text(timeText(end))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.secondary)

            HStack(spacing: 24) {
                Button {
                    cursor = start
                    player?.currentTime = start
                    seekAndPlay(from: start)
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)

                Button {
                    start = max(0, cursor - 0.1)
                } label: {
                    Image(systemName: "gobackward.5")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    end = min(duration, cursor + 0.1)
                } label: {
                    Image(systemName: "goforward.5")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear(perform: prepare)
        .onDisappear {
            player?.stop()
            timer?.invalidate()
        }
    }

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 4)
            .overlay(
                RoundedRectangle(cornerRadius: 2).stroke(accent.opacity(0.4), lineWidth: 1)
            )
    }

    private func waveform(height: CGFloat) -> some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = max(1.2, size.width / CGFloat(samples.count) * 0.62)
            let step = size.width / CGFloat(samples.count)
            for (index, value) in samples.enumerated() {
                let h = max(2, value * size.height * 0.88)
                let rect = CGRect(x: CGFloat(index) * step,
                                  y: (size.height - h) / 2,
                                  width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(accent.opacity(0.55)))
            }
        }
    }

    private func prepare() {
        start0 = start
        end0 = end
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()

        AudioWaveform.samples(url: url, count: 160) { result in
            DispatchQueue.main.async { samples = result }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            guard let player, player.isPlaying else { return }
            cursor = player.currentTime
            if cursor >= end {
                player.pause()
                playing = false
            }
        }
    }

    private func seekAndPlay(from time: Double) {
        if playing {
            player?.pause()
            playing = false
            return
        }
        player?.currentTime = time
        player?.play()
        playing = true
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 读 PCM 算振幅包络，画真波形
enum AudioWaveform {
    static func samples(url: URL, count: Int, completion: @escaping ([CGFloat]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let file = try? AVAudioFile(forReading: url) else {
                completion(Self.placeholder(count)); return
            }
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(min(file.length, 4_000_000))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                completion(Self.placeholder(count)); return
            }
            do {
                try file.read(into: buffer)
            } catch {
                completion(Self.placeholder(count)); return
            }
            guard let data = buffer.floatChannelData?[0] else {
                completion(Self.placeholder(count)); return
            }
            let total = Int(buffer.frameLength)
            guard total > 0 else { completion(Self.placeholder(count)); return }

            let per = max(1, total / count)
            var result: [CGFloat] = []
            for index in 0..<count {
                let from = index * per
                let to = min(from + per, total)
                guard from < to else { result.append(0.02); continue }
                var peak: Float = 0
                var sum: Float = 0
                var i = from
                while i < to {
                    let v = abs(data[i])
                    if v > peak { peak = v }
                    sum += v
                    i += max(1, (to - from) / 200)
                }
                let avg = sum / Float(max(1, (to - from) / max(1, (to - from) / 200)))
                result.append(CGFloat(max(0.02, min(1, max(peak * 0.8, avg * 2.2)))))
            }
            completion(result)
        }
    }

    private static func placeholder(_ count: Int) -> [CGFloat] {
        (0..<count).map { i in
            0.18 + 0.16 * CGFloat(abs(sin(Double(i) * 0.42)))
        }
    }
}
