# 嗅探 Sniff

一款极简的 iOS 资源嗅探工具：**内置浏览器 + 自动嗅探网页中的图片、音视频、m3u8**。
原生 SwiftUI 实现，零第三方依赖，所有处理都在本地完成。

> 起因：某款同类工具箱停服跑路、会员功能说关就关。索性自己写一个——
> 功能只留最核心的两件事：**内置浏览器**和**资源嗅探**。

## 功能特性

| 功能 | 说明 |
|---|---|
| 内置浏览器 | WKWebView 全功能浏览器，地址栏 / 前进后退 / 刷新 / 移动·桌面 UA 切换 |
| 双通道嗅探 | 网络层拦截 http/https 请求 + 网页 JS 扫描 DOM/performance/fetch，互补不漏 |
| 资源列表 | 自动去重，按视频 / 音频 / 图片 / HLS 分类筛选，显示类型与大小 |
| 一键下载 | 直链资源直接下载；下载完成后可存相册 / 分享 / 落到"文件"App |
| m3u8 捕获 | 捕获播放列表链接并一键复制（ts 合并见路线图） |
| 隐私 | 无任何统计与上报，无后台服务器，纯本地运行 |

## 快速开始

### 方式 A：有 Mac + Xcode（最省事，推荐）

1. 终端进入工程目录，生成 Xcode 工程：`brew install xcodegen && xcodegen generate`
2. 双击生成的 `Sniff.xcodeproj` 用 Xcode 打开（Xcode 15+）
3. 选中 `Sniff` target → **Signing & Capabilities** → Team 登录你的 Apple ID（**免费账号即可**）
4. Bundle Identifier 改成你自己的（默认 `com.sniff.ios`，若被占用改成 `com.你的名字.sniff`）
5. iPhone 连接电脑，Scheme 选真机，点 Run
6. 免费账号签名有效期 7 天，到期后重连 Xcode 再 Run 一次即自动续期

### 方式 B：没有 Mac（GitHub 云构建）

iOS 的 `.ipa` 最终必须经过 Apple 签名，但**编译**这一步可以在云端完成：

1. 在 GitHub 新建仓库，把本工程推送上去
2. 仓库页 → **Actions** → `build-ipa` → **Run workflow**
3. 跑完后下载 Artifact：`Sniff-unsigned-ipa`（未签名 IPA）
4. 用签名工具安装到手机（任选其一）：
   - **Sideloadly**（Mac/Win，免费 Apple ID 自签，7 天一续）
   - **AltStore**（需电脑配合，免费）
   - **爱思助手 / 牛蛙助手**（Windows，可免签直接安装 IPA）
   - 手机端 **Scarlet / Feather** 等（自签，按工具说明操作）

### 方式 C：有付费开发者账号（$99/年）

Xcode 中 Archive → Distribute App → 导出已签名 IPA，可长期免重签安装；
也可以配 fastlane + GitHub Actions 做到全自动出包（工程无绑定，直接可用）。

## 工程结构

```
Sniff/
├── project.yml                    # XcodeGen 工程描述（生成 Sniff.xcodeproj）
├── Sniff/
│   ├── App/SniffApp.swift             # @main 入口
│   ├── Models/ResourceItem.swift      # 资源模型 + 类型分类
│   ├── Services/ResourceStore.swift   # 全局资源仓库（去重/分类/角标）
│   ├── Services/DownloadManager.swift # 下载管理 + 存相册/落沙盒
│   ├── Browser/
│   │   ├── SniffWebView.swift         # SwiftUI × WKWebView，注册双通道嗅探
│   │   ├── SniffSchemeHandler.swift   # 拦截 http/https，流式转发 + 嗅探
│   │   ├── SniffScript.swift          # 注入网页的嗅探 JS
│   │   ├── SniffMessageHandler.swift  # JS → Swift 消息通道
│   │   └── WebViewStore.swift         # 浏览器命令与状态
│   ├── Views/
│   │   ├── ContentView.swift          # 主界面（地址栏 + 工具栏 + WebView）
│   │   └── ResourceListView.swift     # 嗅探资源面板
│   └── Resources/
│       ├── Info.plist                 # ATS/相册权限/文件共享等
│       └── Assets.xcassets/           # App 图标全套尺寸
├── Design/icon.svg                    # 图标矢量源文件（可交设计师改）
├── tools/
│   ├── make_icon.py                   # 重新生成全套图标
│   └── build_ipa.sh                   # 本地 macOS 一键出未签名 IPA
└── .github/workflows/build-ipa.yml    # 云构建流水线
```

> 工程文件不含 `Sniff.xcodeproj`：它由 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
> 根据 `project.yml` 生成。本地开发时先 `brew install xcodegen && xcodegen generate`，
> 云构建流水线里也已内置这两步。

## 技术原理（两条嗅探通道）

1. **网络层**：`WKURLSchemeHandler` 接管 WebView 的全部 http/https 请求，
   用 `URLSession` 流式转发响应（不全量进内存，视频 range 请求也扛得住），
   转发时按 `Content-Type` / URL 扩展名命中媒体资源。
2. **网页层**：`atDocumentStart` 注入 JS，扫描 DOM 中的 `video/audio/source/img`、
   performance 资源时间线，并包装 `fetch/XHR` 抓动态加载的地址；
   配 MutationObserver + 定时重扫兜底懒加载。

两路结果汇入 `ResourceStore` 去重，UI 实时刷新。

## 图标设计

"简与白"风格：纯白底 `#FFFFFF` + 墨色 `#1D1D1F` 细线**放大镜**，镜片内三道**信号弧**
寓意"探测/嗅探隐藏的资源"。矢量源文件在 `Design/icon.svg`，
想调整就改它再跑 `python3 tools/make_icon.py` 重新导出全套尺寸。

## 已知限制

- **m3u8** 目前只捕获链接并复制，不自动合并 ts 分片（见路线图）
- 抖音/淘宝等 **App 内嵌网页**不经过系统浏览器，嗅探不到——需复制链接到本 App 打开
- 少数使用证书绑定（SSL Pinning）或自定义私有协议的站点可能加载异常
- 最低系统要求 **iOS 16.0**

## 路线图

- [ ] m3u8 解析 + ts 分片下载合并
- [ ] 分享扩展：其他 App 里"分享到嗅探"直接解析
- [ ] 嗅探结果按站点分组 / 收藏
- [ ] 深色模式
- [ ] 批量下载队列

## 合规提示

本工具仅供下载**你本人有权获取**的资源；受版权保护的音视频请勿二次传播或商用，
由此产生的后果由使用者自行承担。
