import Foundation
import PhotoAICore

// 收藏夹（F-25）。做法照 Mac 版 `AppModel+Culling.swift` 的“收藏夹”一节：加入、移出进撤销；新建、改名、删除不进。
// “上一次的收藏夹”：本次运行里最后用过的；刚打开应用时取库里最近加过照片（或最近新建）的那个。

/// 收藏夹名字的输入框。
enum CollectionPrompt: Identifiable, Equatable {
    /// 新建，建好后把这些照片加进去（可以是空的）。
    case new(adding: [PhotoID])
    case rename(CollectionRecord)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let record): "rename-\(record.id)"
        }
    }
}

extension CullingEdit {
    /// 星级、标记（自动前进只对这些生效）。
    var isMarkEdit: Bool {
        if case .membership = self { return false }
        return true
    }
}

extension AppModel {
    func title(of item: SidebarItem) -> String {
        switch item {
        case .all: "全部照片"
        case .day(let day): DayFormat.title(day)
        case .undated: "日期未知"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "收藏夹"
        }
    }

    /// 当前侧栏项是收藏夹时就是它。
    var currentCollection: CollectionRecord? {
        guard case .collection(let id) = selection else { return nil }
        return collections.first { $0.id == id }
    }

    /// “加入上一次的收藏夹”加到哪个。
    var lastCollection: CollectionRecord? {
        if let id = lastCollectionID, let record = collections.first(where: { $0.id == id }) { return record }
        return collections.max { ($0.lastUsedAt ?? $0.createdAt) < ($1.lastUsedAt ?? $1.createdAt) }
    }

    /// 加入上一次的收藏夹；还没有收藏夹时弹出“新建”。
    func addToLastCollection() {
        let ids = targetIDs
        guard !ids.isEmpty else { return show("先选中照片") }
        if let last = lastCollection {
            addToCollection(last.id, photoIDs: ids)
        } else {
            collectionPrompt = .new(adding: ids)
        }
    }

    func addToCollection(_ collection: CollectionID, photoIDs ids: [PhotoID]) {
        guard !ids.isEmpty, let record = collections.first(where: { $0.id == collection }) else { return }
        do {
            let existing = try reader.members(of: collection, among: ids)
            var seen = Set<PhotoID>()
            let added = ids.filter { !existing.contains($0) && seen.insert($0).inserted }
            lastCollectionID = collection
            commit(.membership(collection: collection, added: added, removed: []), title: "加入「\(record.name)」")
            let already = ids.count - added.count
            if ids.count == 1 {
                show(added.isEmpty ? "已经在「\(record.name)」里" : "加入「\(record.name)」")
            } else {
                show("\(ids.count) 张加入「\(record.name)」" + (already > 0 ? "（其中 \(already) 张原本就在）" : ""))
            }
        } catch {
            message = "加入收藏夹失败：\(error)"
        }
    }

    /// 从当前的收藏夹里移出（照片本身不受影响）。
    func removeFromCurrentCollection() {
        guard let record = currentCollection else { return }
        let ids = targetIDs
        guard !ids.isEmpty, let members = try? reader.members(of: record.id, among: ids) else { return }
        let removed = ids.filter(members.contains)
        commit(.membership(collection: record.id, added: [], removed: removed), title: "移出「\(record.name)」")
        show("从「\(record.name)」移出 \(removed.count) 张，照片本身不受影响")
    }

    /// 新建收藏夹并加入照片。新建本身不进撤销，加入可以撤销。
    func createCollection(named name: String, adding ids: [PhotoID]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let id = try library.createCollection(name: name)
            collections.append(CollectionRecord(id: id, name: name, createdAt: Date(), lastUsedAt: nil, photoCount: 0))
            collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastCollectionID = id
            appLog("新建收藏夹「\(name)」，加入 \(ids.count) 张")
            if ids.isEmpty {
                show("新建了「\(name)」")
            } else {
                addToCollection(id, photoIDs: ids)
            }
        } catch {
            message = "新建收藏夹失败：\(error)"
        }
    }

    func renameCollection(_ id: CollectionID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try library.renameCollection(id, to: name)
            reloadCollections()
        } catch {
            message = "改名失败：\(error)"
        }
    }

    /// 删收藏夹不删照片，不进撤销（确认框里说明）。和它有关的撤销记录一并去掉。
    func deleteCollection(_ id: CollectionID) {
        do {
            try library.deleteCollection(id)
            appLog("删除收藏夹 \(id)")
            history.forget(collection: id)
            // 系统的 UndoManager 按条数登记，记录少了要重新登记；重做没法凭空登记，一起清掉。
            history.removeRedo()
            undoManager.removeAllActions()
            for entry in history.undoStack { registerUndo(title: entry.title) }
            if lastCollectionID == id { lastCollectionID = nil }
            collections.removeAll { $0.id == id }
            if selection == .collection(id) { selection = .all }
            reloadCollections()
        } catch {
            message = "删除收藏夹失败：\(error)"
        }
    }

    /// 加入、移出（含撤销、重做）之后：侧栏的张数、正在看的收藏夹、单张视图的信息。
    func membershipChanged(_ collection: CollectionID) {
        reloadCollections()
        if selection == .collection(collection) { reloadPhotos(keepResult: true) }
        if isShowingSingle { loadCurrentDetail() }
    }

    func reloadCollections() {
        let reader = reader
        Task {
            guard let records = await Task.detached(operation: { try? reader.collections() }).value else { return }
            collections = records
        }
    }
}
