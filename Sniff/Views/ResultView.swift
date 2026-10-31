import SwiftUI
import UIKit
import Photos
import QuickLook

/// 对应小工具集 VC_Result
///
/// 原版是独立的结果页，四个出口：result.files / result.folder / result.photo_library / result.share。
struct ResultView: View {
    let title: String
    var files: [URL] = []
    var message: String = ""
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    @State private var exporting: [URL]?
    @State private var toast: String?
    @State private var savedToAlbum = false

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if files.isEmpty {
                        if !message.isEmpty { messageBox }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                                Button {
                                    previewURL = url
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: symbol(for: url))
                                            .font(.system(size: 15))
                                            .foregroundColor(accent)
                                            .frame(width: 26)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(url.lastPathComponent)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(accent)
                                                .lineLimit(1)
                                            Text(sizeText(url))
                                                .font(.system(size: 11))
                                                .foregroundColor(Color(white: 0.5))
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(Color(white: 0.75))
                                    }
                                    .padding(.vertical, 11)
                                    .padding(.horizontal, 14)
                                }
                                .buttonStyle(.plain)
                                if index < files.count - 1 {
                                    Divider().padding(.leading, 50)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    }

                    if !files.isEmpty { actions }

                    if !files.isEmpty && !message.isEmpty { messageBox }
                }
                .padding(18)
            }
            .background(Color(red: 0.949, green: 0.949, blue: 0.965))
            .navigationTitle(L10n.t("g.finish"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        onDone?()
                        dismiss()
                    }
                    .foregroundColor(accent)
                }
            }
            .sheet(isPresented: Binding(get: { previewURL != nil },
                                        set: { if !$0 { previewURL = nil } })) {
                if let previewURL {
                    QuickLookView(url: previewURL)
                }
            }
            .sheet(isPresented: Binding(get: { exporting != nil },
                                        set: { if !$0 { exporting = nil } })) {
                if let exporting { DocumentExporter(urls: exporting) }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 26)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(red: 0.13, green: 0.6, blue: 0.35).opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Color(red: 0.13, green: 0.6, blue: 0.35))
            }
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(accent)
            if !files.isEmpty {
                Text("共 \(files.count) 个文件 · \(totalSize)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
            }
        }
        .padding(.top, 8)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                actionCard("存到「文件」", "folder", Color(red: 0.18, green: 0.45, blue: 0.85)) {
                    exporting = files
                }
                actionCard("存到相册", "photo.on.rectangle", Color(red: 0.13, green: 0.6, blue: 0.35)) {
                    saveToAlbum()
                }
            }
            HStack(spacing: 10) {
                actionCard("分享", "square.and.arrow.up", Color(red: 0.55, green: 0.35, blue: 0.82)) {
                    exporting = files
                }
                actionCard("文件夹", "folder.badge.gearshape", Color(white: 0.35)) {
                    revealInFiles()
                }
            }
        }
    }

    private func actionCard(_ title: String, _ symbol: String, _ color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    private var messageBox: some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(Color(white: 0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }

    // MARK: - 动作

    private func saveToAlbum() {
        let playable = files.filter { ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        guard !playable.isEmpty else { toast = "相册不支持这些格式"; return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { toast = "没有相册权限" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                for url in playable {
                    let ext = url.pathExtension.lowercased()
                    if ["mp4", "mov", "m4v"].contains(ext) {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                }
            } completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    savedToAlbum = ok
                    toast = ok ? "已保存到相册" : "保存失败"
                }
            }
        }
    }

    /// 打开「文件」App 的 On My iPhone 位置
    private func revealInFiles() {
        if let url = URL(string: "shareddocuments://") {
            UIApplication.shared.open(url)
        }
    }

    private func sizeText(_ url: URL) -> String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > 0 else { return url.pathExtension.uppercased() }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var totalSize: String {
        let total = files.reduce(Int64(0)) { partial, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return partial + size
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return "film"
        case "jpg", "jpeg", "png", "heic", "webp": return "photo"
        case "gif": return "photo.stack"
        case "m4a", "mp3", "wav", "aac", "flac": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "7z", "rar": return "archivebox"
        default: return "doc"
        }
    }
}

/// QuickLook 预览
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
