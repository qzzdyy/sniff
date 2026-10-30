import Foundation
import UIKit
import AVFoundation
import ImageIO

/// 转换失败原因（Result 的 Failure 必须符合 Error）
struct MediaError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

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
    static func videoToMP4(_ input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
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
    static func videoCompress(_ input: URL, height: Int = 720, removeAudio: Bool = false,
                              completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "_压缩", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            let audio = removeAudio ? "-an" : "-c:a aac -b:a 128k"
            let ok = ffmpeg("-i \(q(input.path)) -vf \"scale=-2:\(height)\" -c:v libx264 -preset veryfast -crf 26 \(audio) -movflags +faststart \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 按目标体积压：用时长反推目标码率
    static func videoCompress(toSizeMB mb: Double, input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
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
    static func extractAudio(_ input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "_音频", ext: "m4a")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -vn -c:a aac -b:a 192k \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 视频转 GIF（可截取片段、调缩放与帧率、两遍调色板）
    static func videoToGIF(_ input: URL, scale: Double = 1.0, fps: Int = 10,
                           start: Double? = nil, end: Double? = nil, highQuality: Bool = true,
                           completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: "gif")
            try? FileManager.default.removeItem(at: out)

            var seek = ""
            if let start, start > 0 { seek += "-ss \(String(format: "%.2f", start)) " }
            if let start, let end, end > start {
                seek += "-t \(String(format: "%.2f", end - start)) "
            }
            let width = max(80, Int(360 * max(0.2, min(1.0, scale))))
            let filter = "fps=\(fps),scale=\(width):-1:flags=lanczos"

            if highQuality {
                let palette = out.deletingLastPathComponent()
                    .appendingPathComponent("palette_\(UUID().uuidString).png")
                let ok1 = ffmpeg("\(seek)-i \(q(input.path)) -vf \"\(filter),palettegen=stats_mode=diff\" \(q(palette.path))")
                let ok2 = ok1 && ffmpeg("\(seek)-i \(q(input.path)) -i \(q(palette.path)) -lavfi \"\(filter)[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4\" -loop 0 \(q(out.path))")
                try? FileManager.default.removeItem(at: palette)
                if ok2 && exists(out) { done(out, completion) } else { fail(completion) }
            } else {
                let ok = ffmpeg("\(seek)-i \(q(input.path)) -vf \"\(filter)\" -loop 0 \(q(out.path))")
                ok && exists(out) ? done(out, completion) : fail(completion)
            }
        }
    }

    /// GIF 转 MP4
    static func gifToMP4(_ input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: "", ext: "mp4")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-i \(q(input.path)) -movflags +faststart -pix_fmt yuv420p -vf \"scale=trunc(iw/2)*2:trunc(ih/2)*2\" \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 从视频抽一帧（可指定时间点）
    static func grabFrame(_ input: URL, at time: Double = 0,
                          completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outURL(for: input, suffix: time > 0 ? "_\(Int(time))s" : "_封面", ext: "jpg")
            try? FileManager.default.removeItem(at: out)
            let seek = time > 0 ? "-ss \(String(format: "%.2f", time)) " : ""
            let ok = ffmpeg("\(seek)-i \(q(input.path)) -frames:v 1 -q:v 2 \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    // MARK: - 音频

    /// 音频格式转换（mp3 / m4a / wav / aac）
    static func audioConvert(_ input: URL, to ext: String, completion: @escaping (Result<URL, MediaError>) -> Void) {
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
                             completion: @escaping (Result<URL, MediaError>) -> Void) {
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
                            completion: @escaping (Result<URL, MediaError>) -> Void) {
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

    // MARK: - PDF

    /// 多张图片合成一个 PDF（A4 等比居中）
    static func imagesToPDF(_ inputs: [URL], completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard !inputs.isEmpty else { return fail(completion, "没有选中图片") }
            let page = CGRect(x: 0, y: 0, width: 595, height: 842)
            let out = outputDir().appendingPathComponent("合并_\(Int(Date().timeIntervalSince1970)).pdf")
            let renderer = UIGraphicsPDFRenderer(bounds: page)
            do {
                try renderer.writePDF(to: out) { ctx in
                    for url in inputs {
                        guard let data = try? Data(contentsOf: url),
                              let img = UIImage(data: data) else { continue }
                        let scale = min(page.width / img.size.width, page.height / img.size.height)
                        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                        let rect = CGRect(x: (page.width - size.width) / 2,
                                          y: (page.height - size.height) / 2,
                                          width: size.width, height: size.height)
                        ctx.beginPage()
                        img.draw(in: rect)
                    }
                }
                exists(out) ? done(out, completion) : fail(completion, "PDF 写入失败")
            } catch {
                fail(completion, error.localizedDescription)
            }
        }
    }

    /// 图片压到指定字节以内：先降质量，再缩尺寸
    static func imageCompress(toBytes limit: Int, input: URL,
                              completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: input),
                  var img = UIImage(data: data) else { return fail(completion, "无法读取图片") }

            var best = img.jpegData(compressionQuality: 0.9)
            for q in stride(from: 0.85, through: 0.2, by: -0.1) {
                if let d = img.jpegData(compressionQuality: CGFloat(q)), d.count <= limit {
                    best = d
                    break
                }
                if let d = img.jpegData(compressionQuality: CGFloat(q)) { best = d }
            }
            if let d = best, d.count <= limit {
                let out = outURL(for: input, suffix: "_压缩", ext: "jpg")
                try? d.write(to: out)
                return done(out, completion)
            }

            // 还不够小，按面积比例缩
            var scale: CGFloat = 0.8
            while scale > 0.15 {
                let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: target)
                img = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
                if let d = img.jpegData(compressionQuality: 0.8), d.count <= limit {
                    let out = outURL(for: input, suffix: "_压缩", ext: "jpg")
                    try? d.write(to: out)
                    return done(out, completion)
                }
                scale -= 0.1
            }
            fail(completion, "压不到目标大小，换更大的目标试试")
        }
    }

    /// GIF 拆帧：每帧存成 png
    static func gifFrames(_ input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
                return fail(completion, "无法读取 GIF")
            }
            let count = CGImageSourceGetCount(src)
            guard count > 0 else { return fail(completion, "GIF 里没有帧") }

            let name = input.deletingPathExtension().lastPathComponent
            let dir = outputDir().appendingPathComponent("\(name)_帧", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            var saved = 0
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                let url = dir.appendingPathComponent(String(format: "帧_%03d.png", i + 1))
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil)
                    if CGImageDestinationFinalize(dest) { saved += 1 }
                }
            }
            saved > 0 ? done(dir, completion) : fail(completion, "没有提取到任何帧")
        }
    }

    // MARK: - 音频

    /// 多个音频按顺序连接
    static func audioConcat(_ inputs: [URL], completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard inputs.count >= 2 else { return fail(completion, "至少选两个文件") }
            let list = outputDir().appendingPathComponent("concat_\(Int(Date().timeIntervalSince1970)).txt")
            let body = inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: "\n")
            do { try body.write(to: list, atomically: true, encoding: .utf8) }
            catch { return fail(completion, error.localizedDescription) }

            let out = outputDir().appendingPathComponent("连接_\(Int(Date().timeIntervalSince1970)).m4a")
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-f concat -safe 0 -i \(q(list.path)) -c:a aac -b:a 192k \(q(out.path))")
            try? FileManager.default.removeItem(at: list)
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    /// 裁剪音频片段
    static func audioTrim(_ input: URL, start: Double, end: Double,
                          completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard end > start else { return fail(completion, "结束时间要大于开始时间") }
            let ext = input.pathExtension.isEmpty ? "m4a" : input.pathExtension
            let out = outURL(for: input, suffix: "_裁剪", ext: ext)
            try? FileManager.default.removeItem(at: out)
            let ok = ffmpeg("-ss \(String(format: "%.2f", start)) -to \(String(format: "%.2f", end)) -i \(q(input.path)) -c:a aac -b:a 192k \(q(out.path))")
            ok && exists(out) ? done(out, completion) : fail(completion)
        }
    }

    // MARK: - 压缩包

    static func zipFiles(_ inputs: [URL], completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outputDir().appendingPathComponent("归档_\(Int(Date().timeIntervalSince1970)).zip")
            do {
                try ZipArchive.zip(inputs, to: out)
                done(out, completion)
            } catch {
                fail(completion, error.localizedDescription)
            }
        }
    }

    static func unzipFile(_ input: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let name = input.deletingPathExtension().lastPathComponent
            let dir = outputDir().appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try ZipArchive.unzip(input, to: dir)
                done(dir, completion)
            } catch {
                fail(completion, error.localizedDescription)
            }
        }
    }

    // MARK: - 实况照片

    /// 实况照片的第一段视频 -> MP4
    static func livePhotoToVideo(_ videoURL: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        videoToMP4(videoURL, completion: completion)
    }

    static func livePhotoToGIF(_ videoURL: URL, completion: @escaping (Result<URL, MediaError>) -> Void) {
        videoToGIF(videoURL, completion: completion)
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

    private static func done(_ url: URL, _ completion: @escaping (Result<URL, MediaError>) -> Void) {
        DispatchQueue.main.async { completion(.success(url)) }
    }

    private static func fail(_ completion: @escaping (Result<URL, MediaError>) -> Void, _ msg: String? = nil) {
        let text = msg ?? lastError
        DispatchQueue.main.async { completion(.failure(MediaError(text))) }
    }
}
