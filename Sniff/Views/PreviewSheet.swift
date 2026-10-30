import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// 全屏预览：视频 / 音频 / 图片
struct PreviewSheet: View {
    let item: ResourceItem
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }.foregroundColor(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear(perform: loadVideoIfNeeded)
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        case .audio:
            AudioPlayerView(item: item)
        default:
            if let player {
                VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    private func loadVideoIfNeeded() {
        if item.kind == .image {
            loadImage()
            return
        }
        guard item.kind != .audio, player == nil else { return }
        let asset: AVURLAsset
        if let local = item.localFile, FileManager.default.fileExists(atPath: local.path) {
            asset = AVURLAsset(url: local)
        } else {
            asset = AVURLAsset(url: item.url,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: item)])
        }
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        p.play()
    }

    private func loadImage() {
        guard image == nil else { return }
        if let local = item.localFile,
           let data = try? Data(contentsOf: local),
           let img = UIImage(data: data) {
            image = img
            return
        }
        var request = URLRequest(url: item.url)
        for (k, v) in MediaHeaders.headers(for: item) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            DispatchQueue.main.async { image = img }
        }.resume()
    }
}

/// 简版音频播放器
struct AudioPlayerView: View {
    let item: ResourceItem

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.85))

            Text(item.displayName)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 24)

            Slider(value: $progress, in: 0...max(duration, 1)) { editing in
                if !editing { seek() }
            }
            .tint(.white)
            .padding(.horizontal, 32)

            HStack {
                Text(timeText(progress)).font(.caption).foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(timeText(duration)).font(.caption).foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 32)

            Button {
                toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    private func setup() {
        guard player == nil else { return }
        let asset = AVURLAsset(url: item.url,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: item)])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        p.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let p = self.player else { return }
            let current = p.currentTime().seconds
            if current.isFinite { progress = current }
            if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
            isPlaying = (p.rate != 0)
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        player?.pause()
    }

    private func toggle() {
        guard let p = player else { return }
        if p.rate == 0 {
            p.play()
            isPlaying = true
        } else {
            p.pause()
            isPlaying = false
        }
    }

    private func seek() {
        player?.seek(to: CMTime(seconds: progress, preferredTimescale: 600))
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
