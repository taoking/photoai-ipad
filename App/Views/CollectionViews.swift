import PhotoAICore
import SwiftUI

/// 收藏夹菜单（F-25）：加入上一次的、加入某一个、新建并加入；在收藏夹里时还能移出。网格多选和单张视图共用。
struct CollectionMenuItems: View {
    let model: AppModel

    var body: some View {
        if let last = model.lastCollection {
            Button("加入「\(last.name)」", systemImage: "rectangle.stack.badge.plus") { model.addToLastCollection() }
        }
        let others = model.collections.filter { $0.id != model.lastCollection?.id }
        if !others.isEmpty {
            Menu("加入…") {
                ForEach(others) { record in
                    Button("\(record.name)（\(record.photoCount)）") { model.addToCollection(record.id, photoIDs: model.targetIDs) }
                }
            }
        }
        Button("新建收藏夹并加入…", systemImage: "plus") { model.collectionPrompt = .new(adding: model.targetIDs) }
        if let current = model.currentCollection {
            Divider()
            Button("移出「\(current.name)」", systemImage: "minus.circle", role: .destructive) { model.removeFromCurrentCollection() }
        }
    }
}

/// 单张视图的收藏夹按钮：轻点加入上一次的收藏夹，按住出菜单。在任何收藏夹里时图标是实心的。
struct CollectionButton: View {
    let model: AppModel

    var body: some View {
        let inAny = model.currentDetail.map { $0.summary.id == model.currentPhotoID && !$0.collectionNames.isEmpty } ?? false
        Menu {
            CollectionMenuItems(model: model)
        } label: {
            Label(model.lastCollection.map { "加入「\($0.name)」" } ?? "收藏夹", systemImage: inAny ? "rectangle.stack.fill" : "rectangle.stack.badge.plus")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 40, height: 36)
        } primaryAction: {
            model.addToLastCollection()
        }
        .accessibilityIdentifier("single-收藏夹")
    }
}

/// 侧栏里的收藏夹一节：每个收藏夹一行（按住导出、改名、删除），最后一行“新建收藏夹”。
struct SidebarCollections: View {
    let model: AppModel

    var body: some View {
        Section("收藏夹") {
            ForEach(model.collections) { record in
                Label {
                    HStack {
                        Text(record.name)
                        Spacer()
                        Text("\(record.photoCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                }
                .tag(SidebarItem.collection(record.id))
                .contextMenu {
                    ExportItemButton(model: model, item: .collection(record.id))
                    Divider()
                    Button("改名…", systemImage: "pencil") { model.collectionPrompt = .rename(record) }
                    Button("删除…", systemImage: "trash", role: .destructive) { model.collectionToDelete = record }
                }
            }
            Button {
                model.collectionPrompt = .new(adding: [])
            } label: {
                Label("新建收藏夹", systemImage: "plus")
            }
            .accessibilityIdentifier("新建收藏夹")
        }
    }
}

/// 新建 / 改名的输入框和删除确认。挂在网格和单张视图上（单张视图是全屏盖上去的，网格那边弹不出来）。
struct CollectionPrompts: ViewModifier {
    @Bindable var model: AppModel
    /// 单张视图开着时网格那边不弹。
    var isActive: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(promptTitle, isPresented: Binding(
                get: { isActive && model.collectionPrompt != nil },
                set: { if !$0 { model.collectionPrompt = nil } }
            )) {
                TextField("名字", text: $name)
                Button("取消", role: .cancel) { model.collectionPrompt = nil }
                Button(confirmTitle) {
                    let prompt = model.collectionPrompt
                    model.collectionPrompt = nil
                    switch prompt {
                    case .new(let ids): model.createCollection(named: name, adding: ids)
                    case .rename(let record): model.renameCollection(record.id, to: name)
                    case nil: break
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                if case .new(let ids) = model.collectionPrompt, !ids.isEmpty { Text("建好后加入 \(ids.count) 张。") }
            }
            .onChange(of: model.collectionPrompt) { _, prompt in
                if case .rename(let record) = prompt { name = record.name } else { name = "" }
            }
            .alert("删除收藏夹「\(model.collectionToDelete?.name ?? "")」？", isPresented: Binding(
                get: { isActive && model.collectionToDelete != nil },
                set: { if !$0 { model.collectionToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let record = model.collectionToDelete { model.deleteCollection(record.id) }
                    model.collectionToDelete = nil
                }
                Button("取消", role: .cancel) { model.collectionToDelete = nil }
            } message: {
                Text("只删收藏夹，里面的 \(model.collectionToDelete?.photoCount ?? 0) 张照片还在。删除不能撤销。")
            }
    }

    private var promptTitle: String {
        if case .rename = model.collectionPrompt { return "收藏夹改名" }
        return "新建收藏夹"
    }

    private var confirmTitle: String {
        if case .rename = model.collectionPrompt { return "改名" }
        return "新建"
    }
}
