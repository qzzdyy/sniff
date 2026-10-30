import Foundation
import UIKit
import AVFoundation

/// 工具箱里的实际转换能力（全部走 FFmpegKit，少量用系统框架）
enum MediaConverter {

    static var lastError = "-"

    /// 输出目录：Documents/Sniff/tools
    static func outputDir() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sniff/tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func outURL(for input: URL, suffix: String, ext: String) -> URL {
        let name = input.deletingPathExtension().lastPathComponent
        return outputDir().appendingPathComponent("\(name)\(suffix).\(ext)")
    }

    private static func q(_ s: String) -> String { "\"\(s)\"" }

    @discardableResult
    private static func ffmpeg(_ args: String) -> Bool {
        guard let session = FFmpegKit.execute("-hide_banner -y \(args)") else {
            lastError = "FFmpegKit 无法创建会话"
            return false
        }
        let code = session.getReturnCode()?.getValue() ?? -1
        if code == 0 { return true }
        let log = session.getOutput() ?? session.getAllLogsAsString() ?? ""
        let tail = log.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = tail.isEmpty ? "FFmpeg 退出码 \(code)" : String(tail.suffix(200))
        return false
    }

    // MARK: - 视频

    /// 转 MP4：能直拷就直拷，不行再重编码
    static func videoToMP4(_ input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            if ffmpeg("-i \(q(input.path)) -c copy -movflags +faststart \(q(out.path))"),
               exists(out) { return done(out, completion) }
            if ffmpeg("-i \(q(input.path)) -c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 160k -movflags +faststart \(q(out.path))"),
               exists(out) { return done(out, completion) }
            fail(completion)
        }
    }

    /// 压缩：限制高度，CRF 26，视频体积通常能降一半以上
    static func videoCompress(_ input: URL, height: Int = 720, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "_压缩", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -vf \"scale=-2:\(height)\" -c:v libx264 -preset veryfast -crf 26 -c:a aac -b:a 128k -movflags +faststart \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 按目标体积压：用时长反推目标码率
    static func videoCompress(toSizeMB mb: Double, input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dur = duration(of: input)
            guard dur > 1 else { return fail(completion) }
            let audioKbps = 96.0
            let totalKbps = mb * 8192 / dur          // MB → kbit
            let videoKbps = max(200, totalKbps - audioKbps)
            let out = outURL(for: input, suffix: "_\(Int(mb))M", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -c:v libx264 -preset veryfast -b:v \(Int(videoKbps))k -maxrate \(Int(videoKbps * 1.5))k -bufsize \(Int(videoKbps * 2))k -c:a aac -b:a \(Int(audioKbps))k -movflags +faststart \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 提取音频为 m4a
    static func extractAudio(_ input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "_音频", ext: "m4a")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -vn -c:a aac -b:a 192k \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 视频转 GIF
    static func videoToGIF(_ input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: "gif")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -vf \"fps=10,scale=360:-1:flags=lanczos\" -loop 0 \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// GIF 转 MP4
    static func gifToMP4(_ input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -movflags +faststart -pix_fmt yuv420p -vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\" \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 从视频抽一帧当封面
    static func grabFrame(_ input: URL, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "_封面", ext: "jpg")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -frames:v 1 -q:v 2 \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    // MARK: - 音频

    /// 音频格式转换（mp3 / m4a / wav / aac）
    static func audioConvert(_ input: URL, to ext: String, completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: ext)
            try? FileManager.default.removeItem(at: out)
            var codec = "-c:a aac -b:a 192k"
            if ext == "mp3" { codec = "-c:a libmp3lame -b:a 192k" }
            if ext == "wav" { codec = "-c:a pcm_s16le" }
            let ok = ffmpeg("-i \(q(input.path)) -vn \(codec) \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    // MARK: - 图片

    static func imageConvert(_ input: URL, to ext: String, quality: CGFloat = 0.9,
                             completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: input),
                  let img = UIImage(data: data) else { return fail(completion, "无法读取图片") }
            let out = outURL(for: input, suffix: "", ext: ext)
            var payload: Data?
            switch ext.lowercased() {
            case "jpg", "jpeg": payload = img.jpegData(compressionQuality: quality)
            case "png":         payload = img.pngData()
            case "heic":        payload = img.jpegData(compressionQuality: quality)   // 保底
            default:            payload = img.jpegData(compressionQuality: quality)
            }
            guard let payload else { return fail(completion, "编码失败") }
            do { try payload.write(to: out); done(out, completion) }
            catch { fail(completion, error.localizedDescription) }
        }
    }

    /// 等比缩放到最长边 pixel
    static func imageResize(_ input: URL, maxPixel: CGFloat,
                            completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: input),
                  let img = UIImage(data: data) else { return fail(completion, "无法读取图片") }
            let size = img.size
            let longest = max(size.width, size.height)
            guard longest > 0 else { return fail(completion, "图片尺寸异常") }
            let scale = min(1, maxPixel / longest)
            let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let renderer = UIGraphicsImageRenderer(size: target)
            let shrunk = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
            guard let payload = shrunk.jpegData(compressionQuality: 0.85) else {
                return fail(completion, "编码失败")
            }
            let out = outURL(for: input, suffix: "_\(Int(maxPixel))", ext: "jpg")
            do { try payload.write(to: out); done(out, completion) }
            catch { fail(completion, error.localizedDescription) }
        }
    }

    // MARK: - 工具

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func duration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : 0
    }

    private static func done(_ url: URL, _ completion: @escaping (Result<URL, String>) -> Void) {
        DispatchQueue.main.async { completion(.success(url)) }
    }

    private static func fail(_ completion: @escaping (Result<URL, String>) -> Void, _ msg: String? = nil) {
        let text = msg ?? lastError
        DispatchQueue.main.async { completion(.failure(text)) }
    }
}
