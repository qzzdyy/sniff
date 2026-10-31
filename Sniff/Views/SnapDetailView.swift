import SwiftUI
import UIKit

/// 对应小工具集 VC_SnapDetail / VC_WebTaskSelection
///
/// 原版把同一套模板实例化了两次，核心是**四个分类桶**（图片 / 音频 / 视频 / M3U8），
/// 共用一套底部工具栏（全选 · 保存 · 筛选）、共用长按菜单、共用图片折叠。
struct SnapDetailView: View {
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager

    @Environment(\.dismiss) private var dismiss

    /// 四个桶（原版 filteredImageItems / filteredAudioItems / filteredVideoItems / filteredM3uItems）
    @State private var showImages = true
    @State private var showAudios = true
    @State private var showVideos = true
    @State private var showM3U = true

    /// collapseBtnItem / isImageCollapse
    @State private var isImageCollapse = true

    @State private var selected: Set<UUID> = []
    @State private var activePreview: ResourceItem?
    @State private var pendingM3: ResourceItem?
    @State private var showFilter = false
    @State private var filter = SnapFilter()
    @State private var toast: String?
    @State private var exporting: [URL]?
    @State private var busy = false
    @State private var busyText = ""
    @State private var confirmDelete = false

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let bg = Color(red: 0.949, green: 0.949, blue: 0.965)

    // MARK: - 四个分类桶

    private var allFiltered: [ResourceItem] { resourceStore.filteredItems }

    private var imageItems: [ResourceItem] {
        filter.apply(allFiltered.filter { $0.kind == .image })
    }
    private var audioItems: [ResourceItem] {
        filter.apply(allFiltered.filter { $0.kind == .audio })
    }
    private var videoItems: [ResourceItem] {
        filter.apply(allFiltered.filter { $0.kind == .video })
    }
    private var m3uItems: [ResourceItem] {
        filter.apply(allFiltered.filter { $0.kind == .hls })
    }
    /// 其他（原版归到 live / 文件桶）
    private var otherItems: [ResourceItem] {
        filter.apply(allFiltered.filter { $0.kind == .live })
    }

    private var visibleImages: [ResourceItem] {
        guard isImageCollapse, imageItems.count > 9 else { return imageItems }
        return Array(imageItems.prefix(9))
    }

    private var selectedItems: [ResourceItem] {
        allFiltered.filter { selected.contains($0.id) }
    }

    private var isAllSelected: Bool {
        let ids = Set(allFiltered.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selected)
    }

    var body: some View {
        NavigationStack {
            Group {
                if allFiltered.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(bg)
            .navigationTitle(selected.isEmpty ? "嗅探结果" : "已选 \(selected.count) 项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        resourceStore.clear()
                        selected.removeAll()
                        toast = "已清空"
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(Theme.secondary)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomToolbar }
            .fullScreenCover(item: $activePreview) { item in
                WebTaskPreviewView(item: item, downloadManager: downloadManager)
            }
            .sheet(item: $pendingM3) { item in
                M3CreateView(sourceURL: item.url,
                             suggestedName: item.displayName,
                             downloadManager: downloadManager)
            }
            .sheet(isPresented: $showFilter) {
                SnapFilterSheet(filter: $filter)
            }
            .sheet(isPresented: Binding(get: { exporting != nil },
                                        set: { if !$0 { exporting = nil } })) {
                if let exporting { DocumentExporter(urls: exporting) }
            }
            .alert("删除选中的 \(selected.count) 项？", isPresented: $confirmDelete) {
                Button(L10n.t("g.delete"), role: .destructive) {
                    let ids = selected
                    resourceStore.remove(ids: ids)
                    selected.removeAll()
                }
                Button(L10n.t("g.cancel"), role: .cancel) {}
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .padding(.bottom, 90)
                        .transition(.opacity)
                }
            }
            .overlay {
                if busy {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text(busyText).font(.system(size: 13)).foregroundColor(.white)
                        }
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.82)))
                    }
                }
            }
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                bucketHeader(.image, title: "图片", count: imageItems.count,
                             expanded: $showImages, extra: imageItems.count > 9 ? AnyView(collapseButton) : nil)
                if showImages {
                    imageGrid
                }

                bucketHeader(.video, title: "视频", count: videoItems.count, expanded: $showVideos, extra: nil)
                if showVideos {
                    ForEach(videoItems) { item in rowCard(item) }
                }

                bucketHeader(.audio, title: "音频", count: audioItems.count, expanded: $showAudios, extra: nil)
                if showAudios {
                    ForEach(audioItems) { item in rowCard(item) }
                }

                bucketHeader(.hls, title: "M3U8", count: m3uItems.count, expanded: $showM3U, extra: nil)
                if showM3U {
                    ForEach(m3uItems) { item in rowCard(item) }
                }

                if !otherItems.isEmpty {
                    Text("其他文件")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                        .padding(.horizontal, 16)
                    ForEach(otherItems) { item in rowCard(item) }
                }
            }
            .padding(.vertical, 14)
        }
    }

    private var collapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isImageCollapse.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(isImageCollapse ? "展开 \(imageItems.count) 张" : "收起")
                Image(systemName: isImageCollapse ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Theme.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white))
        }
    }

    private func bucketHeader(_ kind: ResourceItem.Kind, title: String, count: Int,
                              expanded: Binding<Bool>, extra: AnyView?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Theme.separator))
            Spacer()
            if let extra { extra }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private var imageGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(visibleImages) { item in
                Button {
                    activePreview = item
                } label: {
                    SnapThumb(item: item)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            selectionBadge(item)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected.contains(item.id) ? accent : Color.clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .contextMenu { cellMenu(item) }
            }
            if isImageCollapse && imageItems.count > 9 {
                Button {
                    withAnimation { isImageCollapse = false }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.white)
                        VStack(spacing: 2) {
                            Image(systemName: "ellipsis")
                            Text("+\(imageItems.count - 9)").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(Theme.secondary)
                    }
                }
                .buttonStyle(.plain)
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal, 16)
    }

    private func rowCard(_ item: ResourceItem) -> some View {
        HStack(spacing: 12) {
            Button {
                if item.kind == .hls {
                    pendingM3 = item
                } else {
                    activePreview = item
                }
            } label: {
                SnapThumb(item: item)
                    .frame(width: 74, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomLeading) {
                        Text(item.kind.shortTag)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(4)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)
                    .lineLimit(2)
                Text(item.metaText ?? item.url.host ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
                if item.kind == .hls {
                    Text(item.hlsState == .valid ? "可用 · 点按创建任务" : "校验中…")
                        .font(.system(size: 11))
                        .foregroundColor(item.hlsState == .valid ? Color(red: 0.13, green: 0.6, blue: 0.35) : Theme.secondary)
                }
            }
            Spacer(minLength: 6)

            if item.kind == .hls {
                Button {
                    pendingM3 = item
                } label: {
                    Text("创建")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            } else {
                actionButton(item)
            }
            selectionBadge(item)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected.contains(item.id) ? accent : Color.clear, lineWidth: 2)
        )
        .padding(.horizontal, 16)
        .contextMenu { cellMenu(item) }
    }

    private func selectionBadge(_ item: ResourceItem) -> some View {
        Button {
            toggle(item)
        } label: {
            Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(selected.contains(item.id) ? accent : Color.white.opacity(0.9))
                .background(
                    Circle().fill(selected.contains(item.id) ? Color.white : Color.black.opacity(0.18))
                        .frame(width: 18, height: 18)
                )
        }
        .buttonStyle(.plain)
        .padding(4)
    }

    @ViewBuilder
    private func actionButton(_ item: ResourceItem) -> some View {
        let task = downloadManager.tasks.first { $0.item == item }
        if let task {
            if task.isDone {
                Button {
                    activePreview = item
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            } else if task.isPaused {
                Button {
                    downloadManager.resume(task)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    Circle().stroke(Theme.separator, lineWidth: 3).frame(width: 24, height: 24)
                    Circle()
                        .trim(from: 0, to: max(0.02, task.progress))
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 24, height: 24)
                }
            }
        } else {
            Button {
                downloadManager.download(item)
                toast = "已加入下载"
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 24))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 长按菜单（原版 menuManagerForCellContext）

    @ViewBuilder
    private func cellMenu(_ item: ResourceItem) -> some View {
        Button {
            activePreview = item
        } label: {
            Label("预览", systemImage: "eye")
        }
        if item.kind == .hls {
            Button {
                pendingM3 = item
            } label: {
                Label(L10n.t("m3.create.create_task"), systemImage: "list.bullet.rectangle")
            }
        } else {
            Button {
                downloadManager.download(item)
                toast = "已加入下载"
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
        }
        Button {
            UIPasteboard.general.string = item.url.absoluteString
            toast = "链接已复制"
        } label: {
            Label(L10n.t("m3.create.copy_link"), systemImage: "doc.on.doc")
        }
        Button {
            UIApplication.shared.open(item.url)
        } label: {
            Label(L10n.t("m3.create.open_in_safari"), systemImage: "safari")
        }
        Button {
            toggle(item)
            if !selected.contains(item.id) { selected.insert(item.id) }
            saveMenuContent()
        } label: {
            Label(L10n.t("ins.b.save.share"), systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            resourceStore.remove(ids: [item.id])
            selected.remove(item.id)
        } label: {
            Label(L10n.t("g.delete"), systemImage: "trash")
        }
    }

    // MARK: - 底部工具栏（viewBottomBar / viewBottomToolbar）

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolButton(title: isAllSelected ? "取消全选" : "全选",
                       symbol: isAllSelected ? "circle" : "checkmark.circle",
                       enabled: true) {
                let ids = Set(allFiltered.map(\.id))
                if isAllSelected { selected.subtract(ids) } else { selected.formUnion(ids) }
            }
            Rectangle().fill(Theme.separator).frame(width: 1, height: 26)
            Menu {
                Button {
                    saveMenuContent()
                } label: { Label(L10n.t("ins.b.save.save_2_file"), systemImage: "folder") }
                Button {
                    saveToAlbum()
                } label: { Label(L10n.t("ins.b.save.save_2_album"), systemImage: "photo.on.rectangle") }
                Button {
                    shareSelected()
                } label: { Label(L10n.t("ins.b.save.share"), systemImage: "square.and.arrow.up") }
                Button {
                    downloadSelected()
                } label: { Label("开始下载", systemImage: "arrow.down.circle") }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: { Label(L10n.t("g.delete"), systemImage: "trash") }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .medium))
                    Text(L10n.t("g.save")).font(.system(size: 10))
                }
                .foregroundColor(selected.isEmpty ? Theme.separator : accent)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .disabled(selected.isEmpty)

            Rectangle().fill(Theme.separator).frame(width: 1, height: 26)
            toolButton(title: filter.isActive ? "已筛选" : "筛选",
                       symbol: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                       enabled: true) {
                showFilter = true
            }
        }
        .frame(height: 52)
        .background(.regularMaterial)
        .overlay(Rectangle().fill(Theme.separator).frame(height: 0.5), alignment: .top)
        .overlay(alignment: .bottom) {
            Text(toast ?? " ")
                .font(.system(size: 11))
                .foregroundColor(.clear)
                .padding(.bottom, 54)
        }
        .onChange(of: toast) { new in
            guard new != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if toast == new { withAnimation { toast = nil } }
            }
        }
    }

    private func toolButton(title: String, symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(enabled ? accent : Theme.separator)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.tertiary)
            Text("还没有嗅到资源")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(accent)
            Text("在「浏览」里打开网页，视频 / 音频 / 图片 / M3U8 会自动出现在这里")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 批量动作

    private func toggle(_ item: ResourceItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func saveMenuContent() {
        guard !selectedItems.isEmpty else { toast = "先选择资源"; return }
        busy = true; busyText = "正在准备文件…"
        BatchSaver.shared.materialize(selectedItems) { urls in
            busy = false
            if urls.isEmpty { toast = "文件准备失败" ; return }
            exporting = urls
        }
    }

    private func saveToAlbum() {
        guard !selectedItems.isEmpty else { toast = "先选择资源"; return }
        busy = true; busyText = "正在保存到相册…"
        BatchSaver.shared.saveToAlbum(selectedItems) { summary in
            busy = false
            toast = summary.text
        }
    }

    private func shareSelected() {
        guard !selectedItems.isEmpty else { toast = "先选择资源"; return }
        busy = true; busyText = "正在准备分享…"
        BatchSaver.shared.materialize(selectedItems) { urls in
            busy = false
            guard !urls.isEmpty else { toast = "文件准备失败"; return }
            exporting = urls
        }
    }

    private func downloadSelected() {
        let targets = selectedItems.filter { $0.kind != .image || true }
        for item in targets { downloadManager.download(item) }
        toast = "已加入下载 \(targets.count) 项"
        selected.removeAll()
    }
}

// MARK: - 缩略图

struct SnapThumb: View {
    let item: ResourceItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let thumb = item.thumbnail {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(Theme.secondary)
            }
        }
        .clipped()
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil, item.kind == .image else { return }
        if let thumb = item.thumbnail { image = thumb; return }
        if let file = item.localFile, let data = try? Data(contentsOf: file),
           let img = UIImage(data: data) {
            image = img
            return
        }
        ThumbnailLoader.shared.image(for: item) { loaded in
            if let loaded { image = loaded }
        }
    }
}
