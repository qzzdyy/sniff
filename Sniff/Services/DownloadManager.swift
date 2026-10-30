import Foundation
import UIKit
import Photos
import WebKit

/// 一条下载任务
struct DownloadTask: Identifiable, Equatable {
    let id: UUID
    let item: ResourceItem
    var progress: Double
    var status: Status
    var localURL: URL?
    /// 直链暂停后用于续传
    var resumeData: Data?
    /// 实时速度（字节/秒）
    var speed: Double = 0
    /// 转封装诊断摘要（仅用于排查，显示在完成项下方）
    var note: String?

    enum Status: Equatable {
        case running
        case paused
        case converting
        case done
        case failed(String)

        var text: String {
            switch self {
            case .running: return "下载中"
            case .paused:  return "已暂停"
            case .converting: return "正在转封装"
            case .done:    return "已完成"
            case .failed(let e): return "失败：\(e)"
            }
        }
    }

    init(item: ResourceItem) {
        self.id = UUID()
        self.item = item
        self.progress = 0
        self.status = .running
        self.localURL = nil
        self.resumeData = nil
        self.speed = 0
    }

    init(id: UUID, item: ResourceItem, progress: Double, status: Status, localURL: URL?) {
        self.id = id
        self.item = item
        self.progress = progress
        self.status = status
        self.localURL = localURL
        self.resumeData = nil
        self.speed = 0
    }

    var isRunning: Bool {
        if case .running = status { return true }
        if case .converting = status { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    var isDone: Bool {
        if case .done = status { return true }
        return false
    }
}

/// 下载管理：直链走 URLSession；m3u8 走 HLSDownloader（并发分片 + 解密 + 转封装）
/// 任务列表持久化到 Documents/Sniff/tasks.json，App 重启后仍在
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    @Published private(set) var tasks: [DownloadTask] = []

    private var session: URLSession!
    private var mapping: [Int: UUID] = [:]
    private var liveTasks: [UUID: URLSessionDownloadTask] = [:]
    private var hlsJobs: [UUID: HLSDownloader] = [:]
    private var retryCount: [UUID: Int] = [:]
    private var speedSample: [UUID: (bytes: Int64, time: Date)] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        loadPersisted()
    }

    // MARK: - 对外接口

    func download(_ item: ResourceItem) {
        guard !tasks.contains(where: { $0.item == item && $0.isRunning }) else { return }
        for old in tasks where old.item == item && !old.isRunning {
            remove(old)
        }
        let task = DownloadTask(item: item)
        DispatchQueue.main.async {
            self.tasks.insert(task, at: 0)
            self.persist(force: true)
        }

        // 先把网页里的 Cookie 同步给下载会话，否则防盗链站点下到一半就 403
        copyWebCookies {
            if item.kind == .hls {
                self.startHLS(task)
            } else {
                self.startDirect(task)
            }
        }
    }

    func retry(_ task: DownloadTask) {
        guard !task.isRunning else { return }
        let item = task.item
        remove(task)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.download(item)
        }
    }

    /// 暂停：直链用 resumeData 续传，HLS 在分片之间挂起
    func pause(_ task: DownloadTask) {
        guard task.isRunning else { return }
        lock.lock()
        let hls = hlsJobs[task.id]
        let live = liveTasks.removeValue(forKey: task.id)
        lock.unlock()

        if let hls {
            hls.pause()
            update(id: task.id) { $0.status = .paused }
            return
        }
        if let live {
            live.cancel(byProducingResumeData: { data in
                self.update(id: task.id) { $0.status = .paused; $0.resumeData = data }
            })
        } else {
            update(id: task.id) { $0.status = .paused }
        }
    }

    /// 继续
    func resume(_ task: DownloadTask) {
        guard task.isPaused else { return }

        lock.lock()
        let hls = hlsJobs[task.id]
        lock.unlock()
        if let hls {
            hls.resume()
            update(id: task.id) { $0.status = .running }
            return
        }

        update(id: task.id) { $0.status = .running }
        if let data = task.resumeData, !data.isEmpty {
            let urlTask = session.downloadTask(withResumeData: data)
            lock.lock()
            mapping[urlTask.taskIdentifier] = task.id
            liveTasks[task.id] = urlTask
            lock.unlock()
            urlTask.resume()
        } else {
            startDirect(task)
        }
    }

    func remove(_ task: DownloadTask) {
        lock.lock()
        if let t = liveTasks.removeValue(forKey: task.id) { t.cancel() }
        if let h = hlsJobs.removeValue(forKey: task.id) { h.cancel() }
        lock.unlock()
        // 删掉实际文件，以及同名的中间产物（.ts / .mp4 / .mov），否则「文件」App 里会留残留
        if let url = task.localURL {
            try? FileManager.default.removeItem(at: url)
            let base = url.deletingPathExtension()
            for ext in ["ts", "mp4", "mov"] {
                let candidate = base.appendingPathExtension(ext)
                if candidate.standardizedFileURL != url.standardizedFileURL {
                    try? FileManager.default.removeItem(at: candidate)
                }
            }
        } else {
            // 老任务没记本地路径：按文件名去下载目录里找一遍，别留垃圾
            let dir = documentsDir()
            let raw = task.item.url.lastPathComponent
            let name = raw.removingPercentEncoding ?? raw
            if !name.isEmpty {
                let base = dir.appendingPathComponent(name).deletingPathExtension()
                for ext in ["ts", "mp4", "mov", task.item.url.pathExtension.lowercased()] where !ext.isEmpty {
                    try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
                }
            }
        }
        DispatchQueue.main.async {
            self.tasks.removeAll { $0.id == task.id }
            self.persist(force: true)
        }
    }

    func task(for item: ResourceItem) -> DownloadTask? {
        tasks.first { $0.item == item }
    }

    private func copyWebCookies(_ completion: @escaping () -> Void) {
        CookieBridge.sync(completion)
    }

    private func legacyCopyWebCookies(_ completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - 直链下载

    private func startDirect(_ task: DownloadTask) {
        let request = MediaHeaders.request(for: task.item)
        let urlTask = session.downloadTask(with: request)
        lock.lock()
        mapping[urlTask.taskIdentifier] = task.id
        liveTasks[task.id] = urlTask
        lock.unlock()
        urlTask.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        let id = mapping.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let id else { return }

        guard let item = tasks.first(where: { $0.id == id })?.item else { return }
        var ext = (downloadTask.response?.suggestedFilename as NSString?)?.pathExtension ?? ""
        if ext.isEmpty { ext = item.url.pathExtension }
        if ext.isEmpty {
            switch item.kind {
            case .image: ext = "jpg"
            case .audio: ext = "m4a"
            default: ext = "mp4"
            }
        }
        let dest = destination(for: id, ext: ext.lowercased())
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            update(id: id) { $0.progress = 1; $0.status = .done; $0.localURL = dest }
        } catch {
            update(id: id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let id = mapping[downloadTask.taskIdentifier]
        lock.unlock()
        guard let id, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        let now = Date()
        lock.lock()
        let previous = speedSample[id]
        speedSample[id] = (totalBytesWritten, now)
        lock.unlock()

        if let previous {
            let dt = now.timeIntervalSince(previous.time)
            if dt >= 0.5 {
                let speed = Double(totalBytesWritten - previous.bytes) / dt
                update(id: id) { $0.progress = p; $0.speed = max(0, speed) }
                return
            }
        }
        update(id: id) { $0.progress = p }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let id = mapping.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let id, let error else { return }
        // 主动暂停/删除会触发 -999，不算失败
        if let urlError = error as? URLError, urlError.code == .cancelled { return }

        // 断线自动续传一次
        let nsError = error as NSError
        if let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !resume.isEmpty,
           retryCount[id, default: 0] < 1 {
            retryCount[id] = retryCount[id, default: 0] + 1
            let urlTask = session.downloadTask(withResumeData: resume)
            lock.lock()
            mapping[urlTask.taskIdentifier] = id
            liveTasks[id] = urlTask
            lock.unlock()
            urlTask.resume()
            return
        }

        update(id: id) { $0.status = .failed(error.localizedDescription) }
    }

    // MARK: - HLS 下载

    private func startHLS(_ task: DownloadTask) {
        // 切到后台时争取一段继续执行的时间（iOS 仍可能挂起，故 UI 上提示保持前台）
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "sniff.hls") { }
        let downloader = HLSDownloader(referer: MediaHeaders.referer(for: task.item),
                                       userAgent: UserAgentPreset.current.ua,
                                       workDir: documentsDir())
        lock.lock()
        hlsJobs[task.id] = downloader
        lock.unlock()

        downloader.run(playlistURL: task.item.url, progress: { [weak self] p in
            self?.update(id: task.id) {
                $0.progress = min(p, 0.9)
                if p >= 0.9 { $0.status = .converting }
                else if case .converting = $0.status { $0.status = .running }
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.hlsJobs.removeValue(forKey: task.id)
            self.lock.unlock()
            if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) }
            switch result {
            case .success(let url):
                let note = HLSDownloader.lastDiagnostic
                self.update(id: task.id) {
                    $0.progress = 1
                    $0.status = .done
                    $0.localURL = url
                    $0.note = url.pathExtension.lowercased() == "ts" ? note : nil
                }
            case .failure(let error):
                self.update(id: task.id) { $0.status = .failed(error.localizedDescription) }
            }
        })
    }

    // MARK: - 保存到相册

    func saveVideoToAlbum(_ local: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let ext = local.pathExtension.lowercased()
        if ext != "mp4" && ext != "mov" && ext != "m4v" {
            completion(.failure(NSError(domain: "Sniff", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "相册只支持 mp4/mov，当前文件是 .\(ext)"
            ])))
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(.failure(NSError(domain: "Sniff", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "没有相册写入权限，请到设置里允许"
                ])))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: local)
            }) { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        completion(.success(()))
                    } else {
                        completion(.failure(err ?? NSError(domain: "Sniff", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "视频格式不受支持"
                        ])))
                    }
                }
            }
        }
    }

    func saveImageToAlbum(_ local: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                completion(.failure(NSError(domain: "Sniff", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "没有相册写入权限，请到设置里允许"
                ])))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: local)
            }) { ok, err in
                DispatchQueue.main.async {
                    if ok {
                        completion(.success(()))
                    } else {
                        completion(.failure(err ?? NSError(domain: "Sniff", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "图片格式不受支持"
                        ])))
                    }
                }
            }
        }
    }

    // MARK: - 持久化

    private struct StoredTask: Codable {
        let id: UUID
        let url: String
        let kind: String
        let size: Int64?
        let page: String?
        let title: String?
        let progress: Double
        let status: String
        let message: String?
        let file: String?
    }

    private var storeURL: URL {
        documentsDir().appendingPathComponent("tasks.json")
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([StoredTask].self, from: data) else { return }

        var loaded: [DownloadTask] = []
        for s in stored {
            guard let url = URL(string: s.url) else { continue }
            let kind = ResourceItem.Kind(rawValue: s.kind) ?? .video
            let item = ResourceItem(url: url,
                                    kind: kind,
                                    mime: nil,
                                    contentLength: s.size,
                                    pageURL: s.page.flatMap { URL(string: $0) },
                                    pageTitle: s.title)
            let fileURL = s.file.map { URL(fileURLWithPath: $0) }
            let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

            var status: DownloadTask.Status
            switch s.status {
            case "done":
                status = exists ? .done : .failed("文件已丢失")
            case "failed":
                status = .failed(s.message ?? "失败")
            default:
                status = .paused
            }

            loaded.append(DownloadTask(id: s.id,
                                       item: item,
                                       progress: s.progress,
                                       status: status,
                                       localURL: exists ? fileURL : nil))
        }
        tasks = loaded
    }

    private var lastPersist = Date.distantPast

    private func persist(force: Bool = false) {
        if !force && Date().timeIntervalSince(lastPersist) < 1.0 { return }
        lastPersist = Date()
        let snapshot: [StoredTask] = tasks.map { t in
            StoredTask(id: t.id,
                       url: t.item.url.absoluteString,
                       kind: t.item.kind.rawValue,
                       size: t.item.contentLength,
                       page: t.item.pageURL?.absoluteString,
                       title: t.item.pageTitle,
                       progress: t.progress,
                       status: statusKey(t.status),
                       message: statusMessage(t.status),
                       file: t.localURL?.path)
        }
        let url = storeURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func statusKey(_ status: DownloadTask.Status) -> String {
        switch status {
        case .running: return "running"
        case .paused:  return "paused"
        case .converting: return "converting"
        case .done:    return "done"
        case .failed:  return "failed"
        }
    }

    private func statusMessage(_ status: DownloadTask.Status) -> String? {
        if case .failed(let msg) = status { return msg }
        return nil
    }

    // MARK: - 工具

    func documentsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Sniff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func destination(for id: UUID, ext: String) -> URL {
        documentsDir().appendingPathComponent("\(id.uuidString).\(ext)")
    }

    private func update(id: UUID, _ block: @escaping (inout DownloadTask) -> Void) {
        DispatchQueue.main.async {
            guard let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            var t = self.tasks[idx]
            block(&t)
            self.tasks[idx] = t
            self.persist()
        }
    }
}
