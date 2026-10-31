import SwiftUI
import UIKit

/// 嗅探资源列表：缩略图 + 分类筛选 + 预览 + 下载
struct ResourceListView: View {
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var filter: ResourceItem.Kind?
    @State private var activeSheet: ActiveSheet?
    @State private var toast: String?

    // 多选与批量
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var exportingURLs: [URL]?
    @State private var batchBusy = false
    @State private var batchText = ""
    @State private var showDeleteConfirm = false
    @State private var pendingM3: ResourceItem?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private enum ActiveSheet: Identifiable {
        case preview(ResourceItem)
        case share([Any])

        var id: String {
            switch self {
            case .preview(let item): return item.id.uuidString
            case .share: return "share"
            }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                if resourceStore.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { batchBar }
            }
            .navigationTitle(selecting ? "已选 \(selected.count) 项" : "嗅探到的资源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(L10n.t("g.select_all")) {
                            selected = Set(filteredItems.map { $0.id })
                        }
                        .foregroundColor(accent)
                    } else {
                        Button("关闭") { dismiss() }.foregroundColor(accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !resourceStore.items.isEmpty {
                        if selecting {
                            Button(L10n.t("g.finish")) {
                                selecting = false
                                selected.removeAll()
                            }
                            .foregroundColor(accent)
                        } else {
                            HStack(spacing: 14) {
                                Button("选择") { selecting = true }
                                    .foregroundColor(accent)
                                Button("清空") { resourceStore.clear() }
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview(let item):
                PreviewSheet(item: item)
            case .share(let items):
                ShareSheet(items: items)
            }
        }
        .sheet(isPresented: Binding(
            get: { exportingURLs != nil },
            set: { if !$0 { exportingURLs = nil } }
        )) {
            DocumentExporter(urls: exportingURLs ?? [])
        }
        .sheet(item: $pendingM3) { item in
            M3CreateView(sourceURL: item.url,
                         suggestedName: item.pageTitle ?? item.displayName,
                         downloadManager: downloadManager)
        }
        .confirmationDialog("删除选中的 \(selected.count) 项？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.t("g.delete"), role: .destructive) { batchDelete() }
            Button(L10n.t("g.cancel"), role: .cancel) {}
        } message: {
            Text("本地已下载的文件会一起删掉，此操作不可恢复")
        }
        .overlay {
            if batchBusy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(batchText.isEmpty ? "处理中…" : batchText)
                        .font(.footnote)
                        .foregroundColor(Theme.label)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - 筛选条

    private var filteredItems: [ResourceItem] {
        guard let filter else { return resourceStore.items }
        return resourceStore.items.filter { $0.kind == filter }
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(title: "全部", count: resourceStore.items.count, active: filter == nil) { filter = nil }
                    ForEach(ResourceItem.Kind.allCases, id: \.self) { kind in
                        let n = resourceStore.items.filter { $0.kind == kind }.count
                        if n > 0 {
                            chip(title: kind.title, count: n, active: filter == kind) { filter = kind }
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 10)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func chip(title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(active ? .black.opacity(0.55) : .white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(active ? Color.white : Color.black.opacity(0.12)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Color(red: 0.93, green: 0.93, blue: 0.95) : Color.white))
            .foregroundColor(active ? accent : Theme.secondary)
            .overlay(Capsule().stroke(Theme.separator, lineWidth: active ? 0 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(filteredItems) { item in
                row(item)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    private func row(_ item: ResourceItem) -> some View {
        let task = downloadManager.task(for: item)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundColor(selected.contains(item.id) ? accent : Theme.tertiary)
                }
                // 只有左侧内容区响应点击预览，避免和右侧按钮、下方"重试"冲突
                HStack(spacing: 12) {
                    thumb(item)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.kind.title)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                                .foregroundColor(Theme.secondary)
                            if item.isPreparing {
                                Text("准备中…")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.secondary)
                            } else if let meta = item.metaText {
                                Text(meta)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.secondary)
                                    .lineLimit(1)
                            }
                            Text(item.url.host ?? "")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selecting { toggle(item) } else { activeSheet = .preview(item) }
                }

                if !selecting { actionButton(item, task: task) }
            }

            if let task {
                taskStatus(task, item: item)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func thumb(_ item: ResourceItem) -> some View {
        if let thumbnail = item.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else if item.isPreparing {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                ProgressView().scaleEffect(0.7)
            }
        } else if item.kind == .image {
            AsyncImage(url: item.url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    thumbPlaceholder(item.kind)
                }
            }
        } else {
            VideoThumb(item: item)
        }
    }

    private func thumbPlaceholder(_ kind: ResourceItem.Kind) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: kind.symbol)
                .font(.system(size: 18))
                .foregroundColor(Theme.secondary)
        }
    }

    @ViewBuilder
    private func actionButton(_ item: ResourceItem, task: DownloadTask?) -> some View {
        if let task, case .done = task.status {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.14))
        } else if let task, case .running = task.status {
            Text("\(Int(task.progress * 100))%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 44)
        } else if let task, case .queued = task.status {
            Text("排队中")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.secondary)
        } else if let task, case .paused = task.status {
            Button {
                downloadManager.resume(task)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle").font(.system(size: 13, weight: .medium))
                    Text("继续").font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if item.kind == .hls {
                    pendingM3 = item
                } else {
                    downloadManager.download(item)
                    showToast("开始下载：\(item.displayName)")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .medium))
                    Text(item.kind == .hls ? "缓存" : "下载").font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func taskStatus(_ task: DownloadTask, item: ResourceItem) -> some View {
        switch task.status {
        case .queued:
            Text("排队中，空闲后自动开始")
                .font(.caption)
                .foregroundColor(Theme.secondary)
        case .running:
            ProgressView(value: min(max(task.progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(accent)
        case .converting:
            ProgressView().scaleEffect(0.7)
        case .paused:
            HStack(spacing: 12) {
                Text("已暂停 \(Int(task.progress * 100))%")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button {
                    downloadManager.resume(task)
                } label: {
                    Text("继续")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        case .done:
            HStack(spacing: 18) {
                Button {
                    guard let local = task.localURL else { return }
                    if item.kind == .image {
                        downloadManager.saveImageToAlbum(local) { r in showResult(r) }
                    } else {
                        downloadManager.saveVideoToAlbum(local) { r in showResult(r) }
                    }
                } label: {
                    label("相册", symbol: "square.and.arrow.down")
                }
                .buttonStyle(.plain)

                Button {
                    if let local = task.localURL { activeSheet = .share([local]) }
                } label: {
                    label("分享", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    downloadManager.remove(task)
                } label: {
                    label("移除", symbol: "trash")
                }
                .buttonStyle(.plain)
            }
        case .failed(let msg):
            HStack(spacing: 12) {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                Spacer()
                Button {
                    downloadManager.retry(task)
                } label: {
                    Text(L10n.t("m3.create.retry"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 批量操作

    private var selectedItems: [ResourceItem] {
        filteredItems.filter { selected.contains($0.id) }
    }

    private func toggle(_ item: ResourceItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    private var batchBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                batchAction("相册", "square.and.arrow.down") { batchSaveAlbum() }
                batchAction("文件", "folder") { batchExportFiles() }
                batchAction("分享", "square.and.arrow.up") { batchShare() }
                batchAction("下载", "arrow.down.circle") { batchDownload() }
                batchAction("删除", "trash", destructive: true) { showDeleteConfirm = true }
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
        .background(Color.white)
    }

    private func batchAction(_ title: String, _ symbol: String,
                             destructive: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .foregroundColor(destructive ? .red : accent)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(batchBusy || selected.isEmpty)
    }

    private func batchDownload() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        for item in items { downloadManager.download(item) }
        showToast("已加入下载队列：\(items.count) 项")
    }

    private func batchSaveAlbum() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        BatchSaver.shared.requestAuth { granted in
            guard granted else {
                showToast("没有相册写入权限")
                return
            }
            batchBusy = true
            batchText = "准备保存…"
            BatchSaver.shared.saveToAlbum(items, progress: { done, total in
                DispatchQueue.main.async { batchText = "保存中 \(done)/\(total)" }
            }, completion: { summary in
                batchBusy = false
                batchText = ""
                showToast(summary.text)
            })
        }
    }

    private func batchExportFiles() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        batchBusy = true
        batchText = "准备文件…"
        BatchSaver.shared.materialize(items) { urls in
            batchBusy = false
            batchText = ""
            guard !urls.isEmpty else {
                showToast("没有可导出的文件")
                return
            }
            exportingURLs = urls
        }
    }

    private func batchShare() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        batchBusy = true
        batchText = "准备文件…"
        BatchSaver.shared.materialize(items) { urls in
            batchBusy = false
            batchText = ""
            guard !urls.isEmpty else {
                showToast("没有可分享的文件")
                return
            }
            activeSheet = .share(urls as [Any])
        }
    }

    private func batchDelete() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        for item in items {
            if let task = downloadManager.task(for: item) {
                downloadManager.remove(task)
            }
        }
        resourceStore.remove(ids: Set(items.map { $0.id }))
        selected.removeAll()
        showToast("已删除 \(items.count) 项")
    }

    private func label(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(accent)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.tertiary)
            Text("还没有嗅探到资源")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.secondary)
            Text("打开网页、点一下视频播放，\n图片 / 视频 / m3u8 会自动收集到这里")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private func showResult(_ result: Result<Void, Error>) {
        switch result {
        case .success: showToast("已保存到相册")
        case .failure(let e): showToast(e.localizedDescription)
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { toast = nil }
        }
    }
}

/// 视频缩略图（异步抽帧；HLS 直接用占位图标，避免长时间等待）
struct VideoThumb: View {
    let item: ResourceItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 18))
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(4)
                }
            }
        }
        .clipped()
        .onAppear {
            guard item.kind == .video else { return }
            if let cached = ThumbnailLoader.shared.cached(for: item.url) {
                image = cached
                return
            }
            ThumbnailLoader.shared.image(for: item) { img in
                if let img { image = img }
            }
        }
    }
}
