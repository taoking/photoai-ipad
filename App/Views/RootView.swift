import PhotoAICore
import SwiftUI

/// 侧栏 + 网格（F-10、F-11）；轻点照片进单张视图（F-12）。
struct RootView: View {
    @Bindable var model: AppModel
    let cache: ThumbnailCache
    let previews: PreviewImageCache
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            LibraryScreen(model: model, cache: cache)
        }
        .fileImporter(isPresented: $model.isPickingCard, allowedContentTypes: [.folder]) { model.cardPicked($0) }
        .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .fullScreenCover(isPresented: Binding(get: { model.isShowingSingle }, set: { if !$0 { model.closeSingle() } })) {
            SingleView(model: model, thumbnails: cache, previews: previews)
        }
        .sheet(item: $model.exportScope) { scope in
            ExportSheet(model: model, scope: scope)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(model: model)
        }
        .task { model.launched() }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(to: phase) }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { if let item = $0 { model.selection = item } })) {
            Section {
                Label {
                    HStack {
                        Text("全部照片")
                        Spacer()
                        Text("\(model.stats.photoCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "photo.on.rectangle")
                }
                .tag(SidebarItem.all)
            }
            ForEach(months, id: \.month) { group in
                Section(DayFormat.month(group.month)) {
                    ForEach(group.days, id: \.day) { day in
                        HStack {
                            Text(DayFormat.title(day.day))
                            Spacer()
                            Text("\(day.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(SidebarItem.day(day.day))
                    }
                }
            }
            if model.undatedCount > 0 {
                Section {
                    HStack {
                        Text("日期未知")
                        Spacer()
                        Text("\(model.undatedCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(SidebarItem.undated)
                }
            }
        }
        .navigationTitle(model.isSynthetic ? "PhotoAI · 性能测试库" : "PhotoAI")
    }

    /// 按月分组，月和天的顺序跟着网格的排序走。
    private var months: [(month: String, days: [DayCount])] {
        let days = model.sort == .captureDateAscending ? model.days.reversed() : model.days
        var result: [(month: String, days: [DayCount])] = []
        for day in days {
            let month = String(day.day.prefix(7))
            if result.last?.month == month {
                result[result.count - 1].days.append(day)
            } else {
                result.append((month, [day]))
            }
        }
        return result
    }
}

/// 详情栏：标题栏（卡的状态）、工具栏、网格、导入进度。
struct LibraryScreen: View {
    @Bindable var model: AppModel
    let cache: ThumbnailCache

    var body: some View {
        GridView(model: model, cache: cache)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                if model.photos.isEmpty { emptyState }
            }
            .overlay { if !model.isShowingSingle { ToastView(toast: model.toast) } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.stats.photoCount > 0 { FilterBar(model: model) }
            }
            .safeAreaInset(edge: .bottom) {
                ImportStatusBar(model: model, importer: model.importer)
            }
            .navigationTitle(model.selection.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
    }

    private var subtitle: String {
        let count = model.currentFilter.isEmpty ? "\(model.photos.count) 张" : "筛选出 \(model.photos.count) / \(model.source.count) 张"
        var parts = [cardStatus, count]
        if model.stats.missingFromCardCount > 0 { parts.append("卡上已删 \(model.stats.missingFromCardCount) 张") }
        return parts.joined(separator: " · ")
    }

    private var cardStatus: String {
        if model.isSynthetic { return "性能测试库" }
        return switch model.cardState {
        case .connected: "卡已连接"
        case .noBookmark: "还没读过卡"
        case .unknown, .disconnected: "卡未连接"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.stats.photoCount == 0 {
            ContentUnavailableView {
                Label("还没有照片", systemImage: "sdcard")
            } description: {
                Text("把 A7C II 的卡插到 iPad 上，点“读取存储卡”，在“文件”里选存储卡（第一次要选，以后插上就自动读）。")
            } actions: {
                Button("读取存储卡") { model.readCardTapped() }
                    .buttonStyle(.borderedProminent)
            }
        } else if !model.currentFilter.isEmpty {
            ContentUnavailableView {
                Label("没有符合条件的照片", systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("清除筛选") { model.currentFilter = PhotoFilter() }
            }
        } else {
            ContentUnavailableView("这里没有照片", systemImage: "photo")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Text("已选 \(model.selectedIDs.count) 张").monospacedDigit()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 多选后批量打（F-20）。
                Menu {
                    ForEach((1...5).reversed(), id: \.self) { n in
                        Button(String(repeating: "★", count: n)) { model.setRating(n) }
                    }
                    Button("清除星级", systemImage: "star.slash") { model.setRating(0) }
                } label: {
                    Label("打星", systemImage: "star")
                }
                .disabled(model.selectedIDs.isEmpty)
                Menu {
                    Button("Pick", systemImage: "flag.fill") { model.setFlag(.pick) }
                    Button("Reject", systemImage: "xmark") { model.setFlag(.reject) }
                    Button("清除标记", systemImage: "flag.slash") { model.setFlag(.none) }
                } label: {
                    Label("标记", systemImage: "flag")
                }
                .disabled(model.selectedIDs.isEmpty)
                Button {
                    model.showExport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.selectedIDs.isEmpty)
                UndoButtons(model: model)
                Button(model.selectedIDs.count == model.photos.count ? "全不选" : "全选") {
                    model.selectedIDs = model.selectedIDs.count == model.photos.count ? [] : Set(model.photos.map(\.id))
                }
                Button("完成") { model.exitSelection() }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                UndoButtons(model: model)
                Button {
                    model.readCardTapped()
                } label: {
                    Label("读取存储卡", systemImage: "sdcard")
                }
                .disabled(model.importer.isRunning)

                Menu {
                    Picker("排序", selection: $model.sort) {
                        Text("拍摄时间：新 → 旧").tag(PhotoSort.captureDateDescending)
                        Text("拍摄时间：旧 → 新").tag(PhotoSort.captureDateAscending)
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    model.showExport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.photos.isEmpty)

                Button("选择") { model.isSelecting = true }
                    .disabled(model.photos.isEmpty)

                Button {
                    model.isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
    }
}
