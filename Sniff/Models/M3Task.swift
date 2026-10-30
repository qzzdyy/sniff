import Foundation
import UIKit
import Combine

/// M3U8 任务（对应小工具集 CCellM3PendingTask 背后的模型）
///
/// 原版是 **8 态**状态机，不是 4 态：
/// 初始化 → 正在下载 → 下载完成 → 正在合并 → 合并完成 → 正在转码 → 转码完成 → 已完成
/// 失败分支：下载密钥失败 / 合并失败 / 转码失败 / 超过最大重试次数 / 已暂停 / 已删除
struct M3Task: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case pending
        case downloading
        case downloaded
        case merging
        case merged
        case transcoding
        case transcoded
        case finished
        case paused
        case failed

        var isActive: Bool {
            switch self {
            case .pending, .downloading, .downloaded, .merging, .merged, .transcoding, .transcoded:
                return true
            default:
                return false
            }
        }

        var isFinished: Bool { self == .finished }
    }

    var id = UUID()
    var name: String
    var urlString: String
    var state: State = .pending
    var progress: Double = 0
    var detail: String = ""
    var outputPath: String?
    var createdAt = Date()
    var byteText: String = ""

    var url: URL? { URL(string: urlString) }

    /// 卡片上那行进度文字
    var stateText: String {
        switch state {
        case .pending:     return "初始化"
        case .downloading: return "正在下载…"
        case .downloaded:  return "下载完成"
        case .merging:     return "正在合并…"
        case .merged:      return "合并完成"
        case .transcoding: return "正在转码…"
        case .transcoded:  return "转码完成"
        case .finished:    return "已完成"
        case .paused:      return "已暂停"
        case .failed:      return detail.isEmpty ? "失败" : "失败：\(detail)"
        }
    }

    var canStart: Bool { state == .paused || state == .failed }
    var canPause: Bool { state.isActive }
}

/// 任务管理器（对应原版 webTaskManager / VC_M3_TaskMgr 的数据源）
final class M3TaskStore: ObservableObject {
    static let shared = M3TaskStore()

    @Published private(set) var tasks: [M3Task] = []

    private var jobs: [UUID: HLSDownloader] = [:]
    private let key = "m3.tasks.v1"
    private var persistWork: DispatchWorkItem?

    private init() {
        load()
    }

    var pendingTasks: [M3Task] { tasks.filter { !$0.state.isFinished } }
    var finishedTasks: [M3Task] { tasks.filter { $0.state.isFinished } }
    var activeCount: Int { tasks.filter { $0.state.isActive }.count }

    /// 最靠前的一条活跃任务（浮窗用）
    var currentActive: M3Task? { tasks.first { $0.state.isActive } }

    // MARK: - 对外

    @discardableResult
    func add(url: URL, name: String) -> M3Task {
        var task = M3Task(name: name.isEmpty ? (url.lastPathComponent.isEmpty ? "M3U8 任务" : url.lastPathComponent) : name,
                          urlString: url.absoluteString)
        if task.name.isEmpty { task.name = "M3U8 任务" }
        task.detail = "等待开始"
        tasks.insert(task, at: 0)
        persist()
        return task
    }

    func start(_ task: M3Task) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard let url = tasks[index].url else { return }

        tasks[index].state = .downloading
        tasks[index].progress = 0
        tasks[index].detail = ""
        persist()

        let host = url.host ?? ""
        let referer = host.isEmpty ? "" : "https://\(host)/"
        let downloader = HLSDownloader(referer: referer,
                                       userAgent: UserAgentPreset.current.ua,
                                       workDir: Self.workDir())
        jobs[task.id] = downloader

        let bgID = UIApplication.shared.beginBackgroundTask(withName: "m3.task") { }

        downloader.run(playlistURL: url, progress: { [weak self] p in
            DispatchQueue.main.async {
                guard let self, let i = self.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                // 进度 0~0.88 下载；0.88~0.94 合并；0.94~1 转码
                switch p {
                case ..<0.88:
                    self.tasks[i].state = .downloading
                    self.tasks[i].progress = max(0.02, p)
                case ..<0.94:
                    self.tasks[i].state = .merging
                    self.tasks[i].progress = p
                default:
                    self.tasks[i].state = .transcoding
                    self.tasks[i].progress = p
                }
                self.schedulePersist()
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, let i = self.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                self.jobs.removeValue(forKey: task.id)
                if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) }
                switch result {
                case .success(let fileURL):
                    self.tasks[i].state = .finished
                    self.tasks[i].progress = 1
                    self.tasks[i].outputPath = fileURL.path
                    self.tasks[i].detail = ""
                    if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64,
                       size > 0 {
                        self.tasks[i].byteText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                    }
                case .failure(let error):
                    let msg = error.localizedDescription
                    self.tasks[i].state = .failed
                    if msg.contains("密钥") { self.tasks[i].detail = "下载密钥失败" }
                    else if msg.contains("合并") || msg.contains("m3u8") { self.tasks[i].detail = "合并失败" }
                    else if msg.contains("转码") { self.tasks[i].detail = "转码失败" }
                    else { self.tasks[i].detail = msg }
                    self.tasks[i].progress = 0
                }
                self.persist(force: true)
            }
        })
    }

    func pause(_ task: M3Task) {
        jobs[task.id]?.pause()
        jobs[task.id]?.cancel()
        jobs.removeValue(forKey: task.id)
        update(task.id) {
            $0.state = .paused
        }
    }

    func resume(_ task: M3Task) {
        start(task)
    }

    func delete(_ task: M3Task) {
        jobs[task.id]?.cancel()
        jobs.removeValue(forKey: task.id)
        if let path = task.outputPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        tasks.removeAll { $0.id == task.id }
        persist(force: true)
    }

    func deleteAllFinished() {
        let finished = finishedTasks
        for t in finished { delete(t) }
    }

    /// 报告：把这条任务的排障信息复制出来
    func report(_ task: M3Task) -> String {
        """
        任务：\(task.name)
        地址：\(task.urlString)
        状态：\(task.stateText)
        进度：\(Int(task.progress * 100))%
        输出：\(task.outputPath ?? "-")
        诊断：\(HLSDownloader.lastDiagnostic)
        """
    }

    // MARK: - 私有

    private func update(_ id: UUID, _ change: (inout M3Task) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        persist()
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func persist(force: Bool = false) {
        if force { persistWork?.cancel() }
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([M3Task].self, from: data) else { return }
        // 重启后还在「进行中」的一律转已暂停，避免出现永远不动的任务
        tasks = saved.map { task in
            var t = task
            if t.state.isActive { t.state = .paused; t.detail = "" }
            return t
        }
    }

    static func workDir() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("M3Tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
