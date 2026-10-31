import SwiftUI

/// GIF 参数（对应 VC_Child_GifParams 的 gifMode / scale / fps）
struct GifParams: Equatable {
    /// true = 最高质量（两遍调色板），false = 快速
    var highQuality = true
    /// 0.25 ~ 1.0
    var scale: Double = 1.0
    /// 5 ~ 30
    var fps: Int = 12
    /// 估算锁：锁住后不再随素材自动改
    var estimateLocked = false

    var displayText: String {
        "\(highQuality ? "高质量" : "快速") · \(Int(scale * 100))% · \(fps)fps"
    }
}

/// 对应小工具集 VC_Child_GifParams（34 个控件里真正有用的那几个）
///
/// 原版是底部面板：模式分段 + 缩放滑杆 + 帧率滑杆 + 大小估算 + 超限警告 + 估算锁。
struct GifParamsSheet: View {
    @Binding var params: GifParams
    /// 源视频时长（秒）与像素，用于估算
    var duration: Double = 0
    var pixelSize: CGSize = .zero
    var limitMB: Double = 0

    @Environment(\.dismiss) private var dismiss
    @State private var draft = GifParams()

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // segmentMode
                    Picker("", selection: $draft.highQuality) {
                        Text("最高质量").tag(true)
                        Text(L10n.t("gif.mode_normal")).tag(false)
                    }
                    .pickerStyle(.segmented)

                    // sliderScale + buttonScale + labelScaleHint
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("缩放").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(Int(draft.scale * 100))%")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.secondary)
                        }
                        Slider(value: $draft.scale, in: 0.25...1.0, step: 0.05)
                            .tint(accent)
                        HStack(spacing: 8) {
                            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                                Button {
                                    draft.scale = value
                                } label: {
                                    Text("\(Int(value * 100))%")
                                        .font(.system(size: 12, weight: draft.scale == value ? .semibold : .regular))
                                        .foregroundColor(draft.scale == value ? .white : accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(RoundedRectangle(cornerRadius: 7)
                                            .fill(draft.scale == value ? accent : Color(uiColor: .tertiarySystemFill)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(outPixelText)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondary)
                    }

                    // sliderFPS + buttonFPS + labelFPSHint
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.t("gif.fps")).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(draft.fps) fps")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(Theme.secondary)
                        }
                        Slider(value: Binding(get: { Double(draft.fps) },
                                              set: { draft.fps = Int($0.rounded()) }),
                               in: 5...30, step: 1)
                            .tint(accent)
                        HStack(spacing: 8) {
                            ForEach([8, 12, 15, 24], id: \.self) { value in
                                Button {
                                    draft.fps = value
                                } label: {
                                    Text("\(value)")
                                        .font(.system(size: 12, weight: draft.fps == value ? .semibold : .regular))
                                        .foregroundColor(draft.fps == value ? .white : accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(RoundedRectangle(cornerRadius: 7)
                                            .fill(draft.fps == value ? accent : Color(uiColor: .tertiarySystemFill)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("帧率越高越流畅，文件也越大")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondary)
                    }

                    // stackEstimate / labelEstimate / buttonEstimateLock
                    VStack(spacing: 10) {
                        HStack {
                            Text("预计大小")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(estimateText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(overLimit ? Color(red: 0.82, green: 0.24, blue: 0.2) : Theme.secondary)
                            Button {
                                draft.estimateLocked.toggle()
                            } label: {
                                Image(systemName: draft.estimateLocked ? "lock.fill" : "lock.open")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(accent)
                            }
                            .buttonStyle(.plain)
                        }
                        if overLimit {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                Text("超过上限 \(Int(limitMB))MB，建议降低缩放或帧率")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color(red: 0.82, green: 0.24, blue: 0.2))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                }
                .padding(18)
            }
            .background(Color(red: 0.949, green: 0.949, blue: 0.965))
            .navigationTitle("GIF 参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("g.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("g.finish")) {
                        params = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = params }
        }
        .presentationDetents([.height(520), .large])
    }

    private var overLimit: Bool { limitMB > 0 && estimatedMB > limitMB }

    private var outPixelText: String {
        guard pixelSize.width > 0 else { return "按原尺寸输出" }
        let w = Int(pixelSize.width * draft.scale)
        let h = Int(pixelSize.height * draft.scale)
        return "输出 \(w)×\(h)"
    }

    /// 粗略估算：像素 × 帧数 × 压缩系数（GIF LZW 大约 0.35 字节/像素/帧）
    private var estimatedMB: Double {
        guard duration > 0, pixelSize.width > 0 else { return 0 }
        let w = pixelSize.width * draft.scale
        let h = pixelSize.height * draft.scale
        let frames = duration * Double(draft.fps)
        let factor = draft.highQuality ? 0.42 : 0.55
        return w * h * frames * factor / 1048576.0
    }

    private var estimateText: String {
        let mb = estimatedMB
        guard mb > 0 else { return "—" }
        if mb < 1 { return String(format: "%.0f KB", mb * 1024) }
        return String(format: "%.1f MB", mb)
    }
}
