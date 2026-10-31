import SwiftUI
import UIKit

/// 下载页：实时进度、暂停/继续、滑动删除、多选批量操作
struct DownloadsView: View {
    @ObservedObject var downloadManager: DownloadManager

    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var shareItems: [Any] = []
    @State private var previewItem: ResourceItem?
    @State private var taskFilter: TaskFilter = .active

    enum TaskFilter: String, CaseIterable, Identifiable {
        case active = "进行中"
        case done = "已完成"
        var id: String { rawValue }
    }

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private var tasks: [DownloadTask] { downloadManager.tasks }

    private var filteredTasks: [DownloadTask] {
        switch taskFilter {
        case .active:
            return tasks.filter { !$0.isDone }
        case .done:
            return tasks.filter { $0.isDone }
        }
    }

    private func count(for filter: TaskFilter) -> Int {
        switch filter {
        case .active: return tasks.filter { !$0.isDone }.count
        case .done: return tasks.filter { $0.isDone }.count
        }
    }

    private var allSelected: Bool { !filteredTasks.isEmpty && selected.count >= filteredTasks.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !tasks.isEmpty {
                    filterBar
                }
                Group {
                    if tasks.isEmpty {
                        emptyState
                    } else if filteredTasks.isEmpty {
                        emptyFiltered
                    } else {
                        list
                    }
                }
            }
            .navigationTitle(selecting ? "已选 \(selected.count) 项" : "下载")
            .navigationBarTitleDisplayMode(selecting ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting {
                        Button(allSelected ? "取消全选" : "全选") { toggleAll() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !tasks.isEmpty {
                        Button(selecting ? "完成" : "选择") {
                            selecting.toggle()
                            if !selecting { selected.removeAll() }
                        }
                    }
                }
            }
            // 批量操作条：用 safeAreaInset 贴在内容底部，不会和系统标签栏打架
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting {
                    selectionBar
                }
            }
        }
        .sheet(isPresented: Binding(get: { !shareItems.isEmpty },
                                    set: { if !$0 { shareItems = [] } })) {
            ShareSheet(items: shareItems)
        }
        .sheet(item: $previewItem) { item in
            PreviewSheet(item: item)
        }
    }

    // MARK: - 列表

    private var filterBar: some View {
        Picker("", selection: $taskFilter) {
            ForEach(TaskFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var emptyFiltered: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("这个分类下还没有任务")
                .font(.system(size: 14))
                .foregroundColor(Theme.secondary)
            Spacer()
        }
    }

    private var list: some View {
        List {
            ForEach(filteredTasks) { task in
                row(task)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            downloadManager.remove(task)
                            selected.remove(task.id)
                        } label: {
                            Label(L10n.t("g.delete"), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if task.isRunning {
                            Button {
                                downloadManager.pause(task)
                            } label: {
                                Label(L10n.t("m3.task_manage.pause"), systemImage: "pause")
                            }
                            .tint(.orange)
                        } else if task.isPaused {
                            Button {
                                downloadManager.resume(task)
                            } label: {
                                Label("继续", systemImage: "play")
                            }
                            .tint(.green)
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ task: DownloadTask) -> some View {
        if selecting {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundColor(selected.contains(task.id) ? accent : Theme.tertiary)

                icon(task)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.item.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(statusText(task))
                        .font(.system(size: 11))
                        .foregroundColor(statusColor(task))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .background(selected.contains(task.id)
                        ? Color(red: 0.92, green: 0.94, blue: 0.98)
                        : Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { toggleSelect(task.id) }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    icon(task)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.item.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Text(statusText(task))
                            .font(.system(size: 11))
                            .foregroundColor(statusColor(task))
                            .lineLimit(1)
                    }
                    Spacer()
                    trailingAction(task)
                }

                if let note = task.note, !task.isRunning {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                if task.isRunning || task.isPaused || isConverting(task) {
                    ProgressView(value: min(max(task.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(accent)
                }

                if task.isDone {
                    HStack(spacing: 18) {
                        Button {
                            if let local = task.localURL { saveToAlbum(task, local: local) }
                        } label: {
                            label("相册", symbol: "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let local = task.localURL { shareItems = [local] }
                        } label: {
                            label("分享", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)

                        Button {
                            previewItem = task.item
                        } label: {
                            label("播放", symbol: "play.circle")
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            downloadManager.remove(task)
                        } label: {
                            label("删除", symbol: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func icon(_ task: DownloadTask) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
            Image(systemName: task.item.kind.symbol)
                .font(.system(size: 15))
                .foregroundColor(.white)
        }
        .frame(width: 40, height: 40)
    }

    @ViewBuilder
    private func trailingAction(_ task: DownloadTask) -> some View {
        switch task.status {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 20))
                .foregroundColor(Theme.secondary)
        case .running:
            Button {
                downloadManager.pause(task)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        case .converting:
            ProgressView().scaleEffect(0.8)
        case .paused:
            Button {
                downloadManager.resume(task)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(Color(red: 0.13, green: 0.13, blue: 0.14))
        case .failed:
            Button(L10n.t("m3.create.retry")) { downloadManager.retry(task) }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accent)
        }
    }

    private func statusText(_ task: DownloadTask) -> String {
        switch task.status {
        case .queued:
            return "排队中 · 等待空闲"
        case .running:
            let pct = Int(task.progress * 100)
            let base = task.item.kind == .hls ? "m3u8 合成中 \(pct)%" : "\(pct)%"
            if task.speed > 1024 {
                let speed = ByteCountFormatter.string(fromByteCount: Int64(task.speed), countStyle: .file)
                return base + " · " + speed + "/s"
            }
            return base
        case .paused:
            return "已暂停 \(Int(task.progress * 100))%"
        case .converting:
            return "正在转封装为 MP4…（请保持前台）"
        case .done:
            if task.note != nil { return "已完成 · 未转成 MP4（诊断见下方）" }
            return "已完成"
        case .failed(let msg):
            return msg
        }
    }

    private func isConverting(_ task: DownloadTask) -> Bool {
        if case .converting = task.status { return true }
        return false
    }

    private func statusColor(_ task: DownloadTask) -> Color {
        if case .failed = task.status { return .red }
        if task.isPaused { return .orange }
        return Theme.secondary
    }

    private func label(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(accent)
    }

    private func saveToAlbum(_ task: DownloadTask, local: URL) {
        if task.item.kind == .image {
            downloadManager.saveImageToAlbum(local) { _ in }
        } else {
            downloadManager.saveVideoToAlbum(local) { _ in }
        }
    }

    // MARK: - 多选

    /// 底部批量操作条（实心白底 + 顶部分割线，位于系统标签栏之上）
    private var selectionBar: some View {
        HStack(spacing: 0) {
            Button {
                bulkPause()
            } label: {
                barItem("暂停", symbol: "pause.fill")
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)

            Divider().frame(height: 22)

            Button {
                bulkResume()
            } label: {
                barItem("继续", symbol: "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)

            Divider().frame(height: 22)

            Button {
                bulkDelete()
            } label: {
                barItem("删除", symbol: "trash", tint: .red)
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white)
        .overlay(Divider(), alignment: .top)
    }

    private func barItem(_ title: String, symbol: String, tint: Color = Color(red: 0.11, green: 0.11, blue: 0.12)) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            Text(title).font(.system(size: 14, weight: .medium))
        }
        .foregroundColor(selected.isEmpty ? Theme.tertiary : tint)
        .frame(maxWidth: .infinity)
    }

    private func toggleSelect(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        if allSelected {
            selected.removeAll()
        } else {
            selected = Set(filteredTasks.map { $0.id })
        }
    }

    private func bulkPause() {
        for task in tasks where selected.contains(task.id) && task.isRunning {
            downloadManager.pause(task)
        }
    }

    private func bulkResume() {
        for task in tasks where selected.contains(task.id) && task.isPaused {
            downloadManager.resume(task)
        }
    }

    private func bulkDelete() {
        for task in tasks where selected.contains(task.id) {
            downloadManager.remove(task)
        }
        selected.removeAll()
        selecting = false
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.tertiary)
            Text("还没有下载任务")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Theme.secondary)
            Text("在浏览页点右上角嗅探按钮，\n选一个资源点「下载」")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}
