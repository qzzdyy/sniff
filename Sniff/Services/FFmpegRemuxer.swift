import Foundation

/// 用 FFmpegKit 做 TS → MP4 转封装（照抄小工具集的做法：-c copy + aac_adtstoasc）
///
/// 这条路子比手写 demux 稳，因为 demux/mux 全交给 FFmpeg：
/// 它认得各种不规范的 PSI 布局、ADTS 边界、HEVC/AV1 变体，出问题还能把日志吐出来。
enum FFmpegRemuxer {

    static var lastError = "-"

    /// 失败时把 FFmpeg 的最后几行输出留下来，便于诊断
    private static func note(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lastError = String(trimmed.suffix(180)).replacingOccurrences(of: "\n", with: " ⏎ ")
        }
    }

    static func remux(ts: URL, to mp4: URL) -> Bool {
        lastError = "-"
        try? FileManager.default.removeItem(at: mp4)

        // 先试最省事的：纯转封装，音频加 aac_adtstoasc（TS 里的 ADTS 头必须去掉才能进 MP4）
        if run("-hide_banner -y -i \"\(ts.path)\" -c copy -bsf:a aac_adtstoasc -movflags +faststart \"\(mp4.path)\"") {
            return true
        }

        // 失败多半是音频不是 AAC（AC-3/E-AC-3）：视频直拷，音频转 AAC
        note(lastError)
        if run("-hide_banner -y -i \"\(ts.path)\" -c:v copy -c:a aac -b:a 128k -movflags +faststart \"\(mp4.path)\"") {
            return true
        }

        // 再退一步：音频也重编码不了就去掉音频，至少出个能看的画面
        if run("-hide_banner -y -i \"\(ts.path)\" -c:v copy -an -movflags +faststart \"\(mp4.path)\"") {
            lastError = "音频轨不兼容，已导出无声视频"
            return true
        }
        return false
    }

    private static func run(_ command: String) -> Bool {
        guard let session = FFmpegKit.execute(command) else {
            lastError = "FFmpegKit 无法创建会话"
            return false
        }
        let code = session.getReturnCode()?.getValue() ?? -1
        if code == 0 { return true }

        let output = session.getOutput() ?? ""
        let logs = session.getAllLogsAsString() ?? ""
        if !output.isEmpty { note(output) }
        else if !logs.isEmpty { note(logs) }
        else { lastError = code == -1 ? "FFmpeg 未返回" : "FFmpeg 退出码 \(code)" }
        return false
    }
}
