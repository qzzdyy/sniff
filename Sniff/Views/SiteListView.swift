import SwiftUI

/// 首页：最近访问 + 站点网格 + 地址入口（对应小工具集的 WebsiteList）
struct SiteListView: View {
    @ObservedObject var webViewStore: WebViewStore
    @ObservedObject var resourceStore: ResourceStore
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var siteStore: SiteStore

    @State private var query = ""
    @State private var browserSite: SiteBookmark?
    @State private var showAdd = false
    @State private var draftTitle = ""
    @State private var draftURL = ""

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                searchBar
                if !siteStore.recents.isEmpty {
                    recentsSection
                }
                sitesSection
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .background(Color(white: 0.97))
        .navigationTitle("探索")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundColor(accent)
            }
        }
        .fullScreenCover(item: $browserSite) { site in
            BrowserView(webViewStore: webViewStore,
                        resourceStore: resourceStore,
                        downloadManager: downloadManager,
                        initialURL: site.urlString)
                .onAppear { siteStore.touch(site) }
        }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.45))
            TextField("输入网址或搜索内容", text: $query)
                .font(.system(size: 15))
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { open() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
    }

    private func open() {
        guard let normalized = SiteStore.normalize(query) else { return }
        let site = SiteBookmark(title: query, urlString: normalized)
        query = ""
        browserSite = site
    }

    // MARK: - 最近访问

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("最近打开")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(siteStore.recents) { site in
                        Button { browserSite = site } label: {
                            HStack(spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(site.tint.opacity(0.12))
                                    Image(systemName: site.symbol)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(site.tint)
                                }
                                .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(accent)
                                        .lineLimit(1)
                                    Text(site.host)
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(white: 0.55))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 120, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -18)
        }
    }

    // MARK: - 站点网格

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("我的站点")
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(siteStore.sites) { site in
                    Button { browserSite = site } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(site.tint.opacity(0.12))
                                Image(systemName: site.symbol)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(site.tint)
                            }
                            .frame(width: 60, height: 60)

                            Text(site.title)
                                .font(.system(size: 12))
                                .foregroundColor(accent)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            siteStore.remove(id: site.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(white: 0.42))
    }

    private var footer: some View {
        Text("长按站点可删除，点右上角 + 添加")
            .font(.system(size: 11))
            .foregroundColor(Color(white: 0.62))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - 添加站点

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可留空）", text: $draftTitle)
                    TextField("网址，例如 bilibili.com", text: $draftURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } footer: {
                    Text("只填域名会自动补 https://，中文会当成搜索词")
                }
            }
            .navigationTitle("添加站点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showAdd = false
                        draftTitle = ""
                        draftURL = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        siteStore.add(title: draftTitle, urlString: draftURL)
                        draftTitle = ""
                        draftURL = ""
                        showAdd = false
                    }
                    .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(280)])
    }
}
