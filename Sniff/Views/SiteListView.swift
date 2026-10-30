import SwiftUI

/// 浏览器主页，对齐小工具集 VC_BHome：
/// 横向分页 —— 左页欢迎（vcWelcome），右页书签网格（vcWebsiteList）
struct SiteListView: View {
    @ObservedObject var siteStore: SiteStore
    var onOpen: (String) -> Void

    @State private var page = 0
    @State private var showAdd = false
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var editingSite: SiteBookmark?

    private let accent = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(white: 0.975).ignoresSafeArea()

            TabView(selection: $page) {
                welcomePage.tag(0)
                bookmarkPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageDots
                .padding(.bottom, 14)
        }
        .onChange(of: siteStore.scrollToBookmarks) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { page = 1 }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $editingSite) { site in
            editSheet(site)
        }
    }

    // MARK: - 翻页指示

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Capsule()
                    .fill(i == page ? accent : Color(white: 0.78))
                    .frame(width: i == page ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }

    // MARK: - 欢迎页

    private var welcomePage: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(accent)
                            .frame(width: 66, height: 66)
                        Image(systemName: "sparkles")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 42)

                    HStack(spacing: 0) {
                        Text("探索 ")
                        Text("灵感").foregroundColor(accent).bold()
                        Text(" 和 ")
                        Text("创意").foregroundColor(accent).bold()
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(white: 0.25))
                    .padding(.top, 6)

                    Text("输入网址即可开始，浏览器会自动嗅探页面里的媒体资源")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if !siteStore.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近打开")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(white: 0.42))
                            .padding(.horizontal, 18)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(siteStore.recents) { site in
                                    Button { onOpen(site.urlString) } label: {
                                        VStack(spacing: 7) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                                    .fill(site.tint.opacity(0.12))
                                                Image(systemName: site.symbol)
                                                    .font(.system(size: 19, weight: .medium))
                                                    .foregroundColor(site.tint)
                                            }
                                            .frame(width: 54, height: 54)
                                            Text(site.title)
                                                .font(.system(size: 11))
                                                .foregroundColor(accent)
                                                .lineLimit(1)
                                                .frame(width: 62)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("常用")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(white: 0.42))
                        .padding(.horizontal, 18)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(siteStore.sites.prefix(8)) { site in
                            siteTile(site)
                        }
                    }
                    .padding(.horizontal, 18)
                }

                Button {
                    page = 1
                } label: {
                    HStack(spacing: 4) {
                        Text("我的书签")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))
                }
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
        }
    }

    private func siteTile(_ site: SiteBookmark) -> some View {
        Button { onOpen(site.urlString) } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(site.tint.opacity(0.12))
                    Image(systemName: site.symbol)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(site.tint)
                }
                .frame(width: 58, height: 58)

                Text(site.title)
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                editingSite = site
            } label: {
                Label("编辑书签", systemImage: "pencil")
            }
            Button(role: .destructive) {
                siteStore.remove(id: site.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 书签页

    private var bookmarkPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("我的书签")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(accent)
                    Spacer()
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(accent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 26)

                if siteStore.sites.isEmpty {
                    Text("还没有书签，点右上角 + 添加")
                        .font(.system(size: 13))
                        .foregroundColor(Color(white: 0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(siteStore.sites) { site in
                            siteTile(site)
                        }
                    }
                    .padding(.horizontal, 18)
                }

                Text("长按站点可编辑或删除")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - 添加 / 编辑书签

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（可留空）", text: $draftTitle)
                    TextField("网址，例如 bilibili.com", text: $draftURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } footer: {
                    Text("只填域名会自动补 https://，中文会当成搜索词")
                }
            }
            .navigationTitle("添加书签")
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
        .presentationDetents([.height(300)])
    }

    private func editSheet(_ site: SiteBookmark) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: Binding(
                        get: { draftTitle },
                        set: { draftTitle = $0 }
                    ))
                    TextField("网址", text: Binding(
                        get: { draftURL },
                        set: { draftURL = $0 }
                    ))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("编辑书签")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftTitle = site.title
                draftURL = site.urlString
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingSite = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        siteStore.update(id: site.id, title: draftTitle, urlString: draftURL)
                        editingSite = nil
                    }
                    .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}
