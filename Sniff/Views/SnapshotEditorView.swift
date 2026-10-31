import SwiftUI
import UIKit
import Photos

/// 截长图结果包装（fullScreenCover 用）
struct SnapshotPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 网页截长图后的框选编辑器（对应原版 box_selection.json 的框选交互）
///
/// 整页截图往往很长，原版不是直接存相册，而是先让你框出要保留的区域。
struct SnapshotEditorView: View {
    let image: UIImage
    /// 保存完成回调（返回最终文件）
    var onSaved: ((URL?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var selection: CGRect = .zero
    @State private var dragStart: CGPoint?
    @State private var mode = 0          // 0 框选 1 预览
    @State private var exporting: [URL]?
    @State private var toast: String?
    @State private var cropped: UIImage?
    @State private var canvasSize: CGSize = .zero

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.label.ignoresSafeArea()

                GeometryReader { geo in
                    let fitted = fit(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)

                        if !selection.isEmpty {
                            // 选区外压暗（整块画布上挖洞）
                            Canvas { context, size in
                                var path = Path(CGRect(origin: .zero, size: size))
                                path.addRect(selection)
                                context.fill(path, with: .color(.black.opacity(0.5)),
                                             style: FillStyle(eoFill: true))
                            }
                            .allowsHitTesting(false)

                            Rectangle()
                                .stroke(Color.white, lineWidth: 1.5)
                                .frame(width: selection.width, height: selection.height)
                                .position(x: selection.midX, y: selection.midY)

                            cornerHandles()
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                if dragStart == nil { dragStart = value.startLocation }
                                guard let start = dragStart else { return }
                                let rect = CGRect(x: min(start.x, value.location.x),
                                                  y: min(start.y, value.location.y),
                                                  width: abs(value.location.x - start.x),
                                                  height: abs(value.location.y - start.y))
                                selection = rect.intersection(CGRect(origin: .zero, size: geo.size))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .onAppear {
                        canvasSize = geo.size
                        currentGeometry = geo.size
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(selection.isEmpty ? "拖动框选区域" : "已框选 \(Int(selection.width))×\(Int(selection.height))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("g.cancel")) {
                        onSaved?(nil)
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("g.select_all")) {
                        if let geo = currentGeometry {
                            selection = CGRect(origin: .zero, size: geo)
                        }
                    }
                    .foregroundColor(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    bottomBtn("存相册", "photo.on.rectangle") { saveToAlbum() }
                    bottomBtn("存文件", "folder") { exportFile() }
                    bottomBtn("分享", "square.and.arrow.up") { exportFile() }
                    bottomBtn(selection.isEmpty ? "整页保存" : "裁剪保存", "checkmark.circle.fill") {
                        saveCropped()
                    }
                }
                .frame(height: 62)
                .background(Color.black.opacity(0.55))
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.top, 6)
                }
            }
            .sheet(isPresented: Binding(get: { exporting != nil },
                                        set: { if !$0 { exporting = nil } })) {
                if let exporting { DocumentExporter(urls: exporting) }
            }
        }
        .preferredColorScheme(.dark)
    }

    @State private var currentGeometry: CGSize?

    private func cornerHandles() -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .position(x: index % 2 == 0 ? selection.minX : selection.maxX,
                              y: index < 2 ? selection.minY : selection.maxY)
            }
        }
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

    // MARK: - 裁剪

    /// 把屏幕坐标里的选区换算回原图像素
    private func croppedImage() -> UIImage {
        guard !selection.isEmpty, let geo = currentGeometry, geo.width > 0 else { return image }
        let fitted = fit(image.size, in: geo)
        let originX = (geo.width - fitted.width) / 2
        let originY = (geo.height - fitted.height) / 2

        let scaleX = image.size.width / fitted.width
        let scaleY = image.size.height / fitted.height

        var rect = CGRect(x: (selection.minX - originX) * scaleX,
                          y: (selection.minY - originY) * scaleY,
                          width: selection.width * scaleX,
                          height: selection.height * scaleY)
        rect = rect.intersection(CGRect(origin: .zero, size: image.size))
        guard rect.width > 8, rect.height > 8 else { return image }

        guard let cg = image.cgImage?.cropping(to: rect) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func saveCropped() {
        let out = croppedImage()
        cropped = out
        var url: URL?
        if let data = out.jpegData(compressionQuality: 0.95) {
            let dir = SnapshotStore.directory()
            let file = dir.appendingPathComponent("snap_\(Int(Date().timeIntervalSince1970)).jpg")
            try? data.write(to: file)
            url = file
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    toast = "没有相册权限，已存到「文件」"
                    if let url { exporting = [url] }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: out)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    toast = ok ? "已保存到相册" : "保存失败"
                    if ok {
                        onSaved?(url)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
                    }
                }
            }
        }
    }

    private func saveToAlbum() { saveCropped() }

    private func exportFile() {
        let out = croppedImage()
        guard let data = out.jpegData(compressionQuality: 0.95) else { return }
        let dir = SnapshotStore.directory()
        let file = dir.appendingPathComponent("snap_\(Int(Date().timeIntervalSince1970)).jpg")
        try? data.write(to: file)
        onSaved?(file)
        exporting = [file]
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// 快照存储（对应原版 VC_InsSnapList 的数据源）
enum SnapshotStore {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func all() -> [URL] {
        let dir = directory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: [.creationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "png" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }
}

/// 对应 VC_InsSnapList：网页快照列表（网格 + 长按删除/分享）
struct InsSnapListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var preview: URL?
    @State private var toast: String?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 38, weight: .light))
                            .foregroundColor(Theme.tertiary)
                        Text("还没有网页快照")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(accent)
                        Text("在浏览器底栏点「截长图」，框选后就会存在这里")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                                  spacing: 8) {
                            ForEach(files, id: \.self) { url in
                                Button { preview = url } label: {
                                    ZStack {
                                        Color(uiColor: .tertiarySystemFill)
                                        if let img = UIImage(contentsOfFile: url.path) {
                                            Image(uiImage: img).resizable().scaledToFill()
                                        }
                                    }
                                    .aspectRatio(0.72, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(url.lastPathComponent.replacingOccurrences(of: "snap_", with: ""))
                                            .font(.system(size: 8))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4).padding(.vertical, 2)
                                            .background(Capsule().fill(Color.black.opacity(0.5)))
                                            .padding(4)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.image = UIImage(contentsOfFile: url.path)
                                    } label: { Label("复制", systemImage: "doc.on.doc") }
                                    Button {
                                        ShareSheetPresenter.present([url])
                                    } label: { Label(L10n.t("ins.b.save.share"), systemImage: "square.and.arrow.up") }
                                    Divider()
                                    Button(role: .destructive) {
                                        try? FileManager.default.removeItem(at: url)
                                        reload()
                                    } label: { Label(L10n.t("g.delete"), systemImage: "trash") }
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .background(Color(red: 0.949, green: 0.949, blue: 0.965))
            .navigationTitle("网页快照")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.foregroundColor(accent)
                }
                if !files.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            for f in files { try? FileManager.default.removeItem(at: f) }
                            reload()
                        } label: {
                            Image(systemName: "trash").foregroundColor(accent)
                        }
                    }
                }
            }
            .sheet(item: Binding(get: { preview.map(PreviewPayload.init) },
                                 set: { if $0 == nil { preview = nil } })) { payload in
                NavigationStack {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        if let img = UIImage(contentsOfFile: payload.url.path) {
                            ScrollView([.vertical, .horizontal]) {
                                Image(uiImage: img).resizable().scaledToFit()
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") { preview = nil }.foregroundColor(.white)
                        }
                    }
                    .toolbarColorScheme(.dark, for: .navigationBar)
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() { files = SnapshotStore.all() }
}

struct PreviewPayload: Identifiable {
    let id = UUID()
    let url: URL
    init(_ url: URL) { self.url = url }
}

/// 分享面板（UIKit 直present）
enum ShareSheetPresenter {
    static func present(_ items: [Any]) {
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(av, animated: true)
        }
    }
}
