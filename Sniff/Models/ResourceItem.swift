import Foundation
import UIKit

/// 嗅探到的一条媒体资源（对应小工具集的 WebTask）
struct ResourceItem: Identifiable, Equatable, Hashable {
    enum Kind: String, CaseIterable {
        case video
        case audio
        case image
        case hls
        case live

        var title: String {
            switch self {
            case .video: return "视频"
            case .audio: return "音频"
            case .image: return "图片"
            case .hls:   return "M3U8"
            case .live:  return "其他"
            }
        }

        var symbol: String {
            switch self {
            case .video: return "video.fill"
            case .audio: return "waveform"
            case .image: return "photo.fill"
            case .hls:   return "list.bullet.rectangle"
            case .live:  return "paperclip"
            }
        }
    }

    let id = UUID()
    let url: URL
    var kind: Kind
    var mime: String?
    var contentLength: Int64?
    var pageURL: URL?
    var pageTitle: String?
    let date: Date = Date()

    // 嗅探后立即落地到临时文件（照抄 WebTask 的 fileURL 思路）
    var localFile: URL?
    var pixelSize: CGSize?
    var videoSize: CGSize?
    var duration: Double?
    var thumbnail: UIImage?
    var isPreparing: Bool = false

    /// m3u8 校验状态：拉过内容、确认有分片才算 valid
    enum HLSState: Equatable { case unknown, valid, invalid }
    var hlsState: HLSState = .unknown

    /// 嗅探来源：dom / xhr / perf / html。html 是扫源码扫出来的，可信度最低
    var source: String = "net"

    var isWeakSource: Bool { source == "html" }

    init(url: URL, kind: Kind, mime: String? = nil, contentLength: Int64? = nil,
         pageURL: URL? = nil, pageTitle: String? = nil) {
        self.url = url
        self.kind = kind
        self.mime = mime
        self.contentLength = contentLength
        self.pageURL = pageURL
        self.pageTitle = pageTitle
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? (url.host ?? "未命名资源") : name
    }

    var sizeText: String? {
        guard let bytes = contentLength, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1920×1080 · 03:24" 这类副标题
    var metaText: String? {
        var parts: [String] = []
        if let size = videoSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        } else if let size = pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let duration, duration > 0 {
            let total = Int(duration)
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if let size = sizeText {
            parts.append(size)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func == (lhs: ResourceItem, rhs: ResourceItem) -> Bool {
        lhs.url.absoluteString == rhs.url.absoluteString
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.absoluteString)
    }
}
