import SwiftUI
import UIKit

/// 对应小工具集 VC_M3_TaskMgr
///
/// segment 切换「进行中 / 已完成」，scrollView 承载两个子列表，
/// 底部操作栏（全开始 / 全暂停 / 清理已完成 / 浮窗开关），
/// 每张卡四按钮：开始 · 暂停 · 删除 · 报告（CCellM3PendingTask）。
struct M3TaskManagerView: View {
    @ObservedObject var store: M3TaskStore = .shared
    @Environment(\.dismiss) private var dismiss

    @State private var segment = 0
    @AppStorage("m3.floatWindow") private var floatWindow = false
    @State private var reportText: String?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let bg = Color(red: 0.949, green: 0.949, blue: 0.965)

    private var list: [M3Task] {
        segment == 0 ? store.pendingTasks : store.finishedTasks
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text("进行中 \(store.pendingTasks.count)").tag(0)
                    Text("已完成 \(store.finishedTasks.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if list.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(list) { task in
                                card(task)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .background(bg)
            .navigationTitle("M3U8 任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.foregroundColor(accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { startAll() } label: { Label("全部开始", systemImage: "play.fill") }
                        Button { pauseAll() } label: { Label("全部暂停", systemImage: "pause.fill") }
                        Divider()
                        Button(role: .destructive) { store.deleteAllFinished() } label: {
                            Label("清理已完成", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundColor(accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    barBtn("全部开始", "play.circle") { startAll() }
                    barBtn("全部暂停", "pause.circle") { pauseAll() }
                    barBtn(floatWindow ? "浮窗开" : "浮窗关",
                           floatWindow ? "rectangle.on.rectangle.circle.fill" : "rectangle.on.rectangle.circle") {
                        floatWindow.toggle()
                    }
                }
                .frame(height: 54)
                .background(.regularMaterial)
                .overlay(Rectangle().fill(Theme.separator).frame(height: 0.5), alignment: .top)
            }
            .sheet(item: Binding(get: { reportText.map(ReportPayload.init) },
                                 set: { if $0 == nil { reportText = nil } })) { payload in
                ReportSheet(text: payload.text)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: segment == 0 ? "tray" : "checkmark.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(Theme.tertiary)
            Text(segment == 0 ? "没有进行中的任务" : "还没有完成的任务")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(accent)
            Text("在浏览器里嗅到 M3U8 后点「创建」，任务会出现在这里")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ task: M3Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(accent)
                        .lineLimit(2)
                    Text(task.urlString)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(task.byteText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.secondary)
            }

            // 进度条 + 状态
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .tertiarySystemFill))
                        Capsule()
                            .fill(task.state == .failed ? Color(red: 0.85, green: 0.25, blue: 0.2) : accent)
                            .frame(width: max(3, geo.size.width * CGFloat(task.progress)))
                    }
                }
                .frame(height: 5)

                Text(task.state.isFinished ? "100%" : "\(Int(task.progress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 6) {
                stateDot(task.state)
                Text(task.stateText)
                    .font(.system(size: 11))
                    .foregroundColor(task.state == .failed ? Color(red: 0.8, green: 0.22, blue: 0.18) : Theme.secondary)
                    .lineLimit(1)
                Spacer()
                Text(relative(task.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.secondary)
            }

            HStack(spacing: 8) {
                smallBtn("开始", "play.fill", enabled: task.canStart) { store.start(task) }
                smallBtn("暂停", "pause.fill", enabled: task.canPause) { store.pause(task) }
                smallBtn("删除", "trash", enabled: true, danger: true) { store.delete(task) }
                smallBtn("报告", "doc.text", enabled: true) { reportText = store.report(task) }
                if task.state == .finished, let path = task.outputPath {
                    smallBtn("分享", "square.and.arrow.up", enabled: true) {
                        share(URL(fileURLWithPath: path))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private func stateDot(_ state: M3Task.State) -> some View {
        Circle()
            .fill(state == .failed ? Color(red: 0.85, green: 0.25, blue: 0.2)
                  : (state == .finished ? Color(red: 0.13, green: 0.6, blue: 0.35) : Theme.secondary))
            .frame(width: 6, height: 6)
    }

    private func smallBtn(_ title: String, _ symbol: String, enabled: Bool,
                          danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(enabled ? (danger ? Color(red: 0.8, green: 0.22, blue: 0.18) : accent) : Theme.tertiary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func barBtn(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(accent)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startAll() {
        for task in store.pendingTasks where task.canStart { store.start(task) }
    }

    private func pauseAll() {
        for task in store.pendingTasks where task.canPause { store.pause(task) }
    }

    private func share(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.present(av, animated: true)
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct ReportPayload: Identifiable {
    let id = UUID()
    let text: String
    init(_ text: String) { self.text = text }
}

struct ReportSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("任务报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") { UIPasteboard.general.string = text }
                }
            }
        }
    }
}
