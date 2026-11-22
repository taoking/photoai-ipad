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
        .modifier(CollectionPrompts(model: model, isActive: !model.isShowingSingle))
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
                .contextMenu { ExportItemButton(model: model, item: .all) }
            }
            SidebarCollections(model: model)
            ForEach(months, id: \.month) { group in
                Section(DayFormat.month(group.month)) {
                    ForEach(group.days, id: \.day) { day in
                        HStack {
                            Text(DayFormat.title(day.day))
                            Spacer()
                            Text("\(day.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(SidebarItem.day(day.day))
                        .contextMenu { ExportItemButton(model: model, item: .day(day.day)) }
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
                    .contextMenu { ExportItemButton(model: model, item: .undated) }
                }
            }
        }
        .navigationTitle(model.isSynthetic ? "PhotoAI · 性能测试库" : "PhotoAI")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
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

/// 侧栏按住一项出来的“导出…”：导这一项的全部照片。
struct ExportItemButton: View {
    let model: AppModel
    let item: SidebarItem

    var body: some View {
        Button("导出…", systemImage: "square.and.arrow.up") { model.showExport(for: item) }
    }
}

/// 详情栏：标题栏（卡的状态）、工具栏、网格、导入进度。
///
/// 右上角只留选片时常用的：撤销、筛选、“更多”（排序、导出当前结果）、选择。读卡挪进设置（插上卡就自动读，很少要点）；
/// 导出在选了照片以后的操作条里，或者在侧栏按住一项。
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 12) {
                    if model.isSelecting {
                        SelectionActionBar(model: model)
                    } else if model.staleCount > 0 {
                        RefreshResultButton(model: model)
                    }
                    ImportStatusBar(model: model, importer: model.importer)
                }
                .animation(.easeInOut(duration: 0.2), value: model.isSelecting)
                .animation(.easeInOut(duration: 0.2), value: model.staleCount > 0)
            }
            .navigationTitle(model.title(of: model.selection))
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
    }

    private var subtitle: String {
        if model.isSelecting { return "已选 \(model.selectedIDs.count) 张" }
        let count = model.currentFilter.isEmpty ? "\(model.photos.count) 张" : "筛选出 \(model.photos.count) / \(model.source.count) 张"
        var parts = [model.cardStatusText, count]
        if model.stats.missingFromCardCount > 0 { parts.append("卡上已删 \(model.stats.missingFromCardCount) 张") }
        return parts.joined(separator: " · ")
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
                Button(model.selectedIDs.count == model.photos.count ? "全不选" : "全选") {
                    model.selectedIDs = model.selectedIDs.count == model.photos.count ? [] : Set(model.photos.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) { UndoButtons(model: model) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { model.exitSelection() }
                    .fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { UndoButtons(model: model) }
            if model.stats.photoCount > 0 {
                ToolbarItem(placement: .topBarTrailing) { FilterButton(model: model) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $model.sort) {
                        Text("拍摄时间：新 → 旧").tag(PhotoSort.captureDateDescending)
                        Text("拍摄时间：旧 → 新").tag(PhotoSort.captureDateAscending)
                    }
                    .pickerStyle(.inline)
                    Section {
                        Button {
                            model.showExport()
                        } label: {
                            Label(
                                model.currentFilter.isEmpty ? "导出这 \(model.photos.count) 张…" : "导出筛选结果 \(model.photos.count) 张…",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .disabled(model.photos.isEmpty)
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("选择") { model.isSelecting = true }
                    .disabled(model.photos.isEmpty)
            }
        }
    }
}

/// 选择模式下网格底部浮着的操作条：打星、标记、收藏夹、导出，图标带字，手指够得着。
struct SelectionActionBar: View {
    let model: AppModel

    var body: some View {
        let isEmpty = model.selectedIDs.isEmpty
        HStack(spacing: 4) {
            Menu {
                ForEach((1...5).reversed(), id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { model.setRating(n) }
                }
                Button("清除星级", systemImage: "star.slash") { model.setRating(0) }
            } label: {
                actionLabel("打星", "star")
            }
            Menu {
                Button("Pick", systemImage: "flag.fill") { model.setFlag(.pick) }
                Button("Reject", systemImage: "xmark") { model.setFlag(.reject) }
                Button("清除标记", systemImage: "flag.slash") { model.setFlag(.none) }
            } label: {
                actionLabel("标记", "flag")
            }
            Menu {
                CollectionMenuItems(model: model)
            } label: {
                actionLabel("收藏夹", "rectangle.stack.badge.plus")
            }
            .accessibilityIdentifier("收藏夹菜单")
            Button {
                model.showExport()
            } label: {
                actionLabel("导出", "square.and.arrow.up")
            }
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
        .padding(6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(.capsule)
    }
}

/// 打星后结果不变（F-22），有照片已经不符合筛选时浮在网格底部。
struct RefreshResultButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.refreshResult()
        } label: {
            Label("刷新结果（\(model.staleCount) 张已不符合）", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor.opacity(0.35)).interactive(), in: .capsule)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
