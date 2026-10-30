import SwiftUI

/// 对应小工具集 VC_Filter：类型 × 像素 × 体积 三维筛选
struct SnapFilter: Equatable {
    /// 空集合 = 全部类型
    var kinds: Set<ResourceItem.Kind> = []
    /// 图片 / GIF 格式
    var imageFormats: Set<String> = []
    /// 视频容器
    var videoFormats: Set<String> = []
    /// 最小像素（短边）：0 表示不限
    var minPixel: Int = 0
    /// 最小体积 MB：0 表示不限
    var minSizeMB: Double = 0
    /// 最大体积 MB：0 表示不限
    var maxSizeMB: Double = 0

    var isActive: Bool {
        !kinds.isEmpty || !imageFormats.isEmpty || !videoFormats.isEmpty
            || minPixel > 0 || minSizeMB > 0 || maxSizeMB > 0
    }

    func apply(_ items: [ResourceItem]) -> [ResourceItem] {
        items.filter { item in
            if !kinds.isEmpty && !kinds.contains(item.kind) { return false }

            if !imageFormats.isEmpty {
                let ext = item.url.pathExtension.lowercased()
                if item.kind == .image && !imageFormats.contains(ext) { return false }
            }
            if !videoFormats.isEmpty {
                let ext = item.url.pathExtension.lowercased()
                if item.kind == .video && !videoFormats.contains(ext) { return false }
            }

            if minPixel > 0 {
                let size = item.pixelSize ?? item.videoSize
                guard let size else { return false }
                if Int(min(size.width, size.height)) < minPixel { return false }
            }

            if minSizeMB > 0 {
                guard let bytes = item.contentLength else { return false }
                if Double(bytes) / 1048576.0 < minSizeMB { return false }
            }
            if maxSizeMB > 0 {
                guard let bytes = item.contentLength else { return false }
                if Double(bytes) / 1048576.0 > maxSizeMB { return false }
            }
            return true
        }
    }
}

/// 筛选面板（底部弹出，三段式，对齐原版 hasApplyFilterForBegin / didSetFilter）
struct SnapFilterSheet: View {
    @Binding var filter: SnapFilter
    @Environment(\.dismiss) private var dismiss

    @State private var draft = SnapFilter()

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private let pixelOptions: [(String, Int)] = [
        ("不限", 0), ("480P", 480), ("720P", 720), ("1080P", 1080), ("2K", 1440), ("4K", 2160)
    ]
    private let sizeOptions: [(String, Double)] = [
        ("不限", 0), ("1MB", 1), ("5MB", 5), ("10MB", 10), ("50MB", 50), ("100MB", 100)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("类型") {
                        chipFlow(ResourceItem.Kind.allCases.map { ($0.title, $0) },
                                 selected: draft.kinds) { kind in
                            if draft.kinds.contains(kind) { draft.kinds.remove(kind) }
                            else { draft.kinds.insert(kind) }
                        }
                    }

                    section("图片格式") {
                        chipFlow([("PNG", "png"), ("JPG", "jpg"), ("GIF", "gif"), ("WEBP", "webp")],
                                 selected: draft.imageFormats) { fmt in
                            if draft.imageFormats.contains(fmt) { draft.imageFormats.remove(fmt) }
                            else { draft.imageFormats.insert(fmt) }
                        }
                    }

                    section("视频格式") {
                        chipFlow([("MP4", "mp4"), ("MOV", "mov"), ("WEBM", "webm"), ("M3U8", "m3u8")],
                                 selected: draft.videoFormats) { fmt in
                            if draft.videoFormats.contains(fmt) { draft.videoFormats.remove(fmt) }
                            else { draft.videoFormats.insert(fmt) }
                        }
                    }

                    section("最小分辨率") {
                        HStack(spacing: 8) {
                            ForEach(pixelOptions, id: \.1) { option in
                                pill(option.0, active: draft.minPixel == option.1) {
                                    draft.minPixel = option.1
                                }
                            }
                        }
                    }

                    section("文件大小") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("不小于").font(.system(size: 12)).foregroundColor(Color(white: 0.5))
                            HStack(spacing: 8) {
                                ForEach(sizeOptions, id: \.1) { option in
                                    pill(option.0, active: draft.minSizeMB == option.1) {
                                        draft.minSizeMB = option.1
                                    }
                                }
                            }
                            Text("不大于").font(.system(size: 12)).foregroundColor(Color(white: 0.5))
                            HStack(spacing: 8) {
                                ForEach(sizeOptions, id: \.1) { option in
                                    pill(option.0, active: draft.maxSizeMB == option.1) {
                                        draft.maxSizeMB = option.1
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(red: 0.949, green: 0.949, blue: 0.965))
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("重置") {
                        draft = SnapFilter()
                    }
                    .foregroundColor(Color(white: 0.4))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        filter = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(accent)
                }
            }
            .onAppear { draft = filter }
        }
        .presentationDetents([.medium, .large])
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.45))
            content()
        }
    }

    private func chipFlow<T: Hashable>(_ options: [(String, T)], selected: Set<T>,
                                       action: @escaping (T) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                pill(option.0, active: selected.contains(option.1)) { action(option.1) }
            }
        }
    }

    private func pill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? accent : Color.white)
                )
        }
        .buttonStyle(.plain)
    }
}
