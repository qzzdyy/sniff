import SwiftUI

/// 对应小工具集 VC_Tips：首次启动引导，可翻页（tips / cv / pageControl）
struct TipsView: View {
    var onFinish: () -> Void

    @State private var page = 0

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "safari",
             title: "先用浏览器打开网页",
             body: "「浏览」页自带一个完整浏览器。播放视频、查看图片，资源会自动被抓出来。"),
        Page(symbol: "dot.radiowaves.left.and.right",
             title: "底部预览条实时出现",
             body: "网页里的视频、音频、图片、M3U8 会以缩略图排成一条，点开即可预览或保存。"),
        Page(symbol: "list.bullet.rectangle",
             title: "M3U8 转成 MP4",
             body: "嗅到 m3u8 后选流创建任务，下载 → 合并 → 转码全自动，完成后直接存相册。"),
        Page(symbol: "square.grid.2x2",
             title: "工具箱还有 18 件事",
             body: "压缩、转格式、抽帧、GIF、音频裁剪、PDF、压缩包，全在「工具」页。")
    ]

    var body: some View {
        ZStack {
            Color(red: 0.949, green: 0.949, blue: 0.965).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("跳过") { onFinish() }
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondary)
                        .padding(.horizontal, 18).padding(.top, 14)
                }

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 22) {
                            Spacer()
                            ZStack {
                                RoundedRectangle(cornerRadius: 30)
                                    .fill(Color.white)
                                    .frame(width: 148, height: 148)
                                Image(systemName: item.symbol)
                                    .font(.system(size: 54, weight: .light))
                                    .foregroundColor(accent)
                            }
                            Text(item.title)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(accent)
                            Text(item.body)
                                .font(.system(size: 14))
                                .foregroundColor(Theme.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.horizontal, 42)
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                HStack(spacing: 7) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? accent : Theme.tertiary)
                            .frame(width: index == page ? 18 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: page)
                    }
                }
                .padding(.bottom, 22)

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page == pages.count - 1 ? "开始使用" : "下一步")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 14).fill(accent))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }
        }
    }
}
