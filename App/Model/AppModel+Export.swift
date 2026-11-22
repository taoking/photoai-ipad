import Foundation
import PhotoAICore

/// 导出面板导哪些照片（F-30）。
struct ExportScope: Identifiable, Equatable {
    let id = UUID()
    /// “所选的 12 张”“收藏夹「111」· 26 张”“选过但没导出的 8 张”。名字和张数之间要隔开：收藏夹叫“111”时连着写就读成了“11126 张”。
    var title: String
    var photoIDs: [PhotoID]
}

// MARK: - 导出（F-30 – F-32）

extension AppModel {
    /// 选择模式下的“导出”导所选的；“更多”菜单里的“导出当前结果”导筛选后的。
    func showExport() {
        if isSelecting, !selectedIDs.isEmpty {
            exportScope = ExportScope(title: "所选的 \(selectedIDs.count) 张", photoIDs: targetIDs)
        } else {
            let name = scopeName(of: selection) + (currentFilter.isEmpty ? "" : "的筛选结果")
            exportScope = ExportScope(title: "\(name) · \(photos.count) 张", photoIDs: photos.map(\.id))
        }
    }

    /// 侧栏按住一项的“导出…”：导这一项的全部照片，不管它记着的筛选。
    func showExport(for item: SidebarItem) {
        let reader = reader
        let scope = item.scope
        let sort = sort
        let name = scopeName(of: item)
        Task {
            guard let photos = await Task.detached(operation: { try? reader.photos(in: scope, sort: sort) }).value else { return }
            guard !photos.isEmpty else { return show("\(name)里没有照片") }
            exportScope = ExportScope(title: "\(name) · \(photos.count) 张", photoIDs: photos.map(\.id))
        }
    }

    /// 导出范围里的名字：收藏夹带上“收藏夹「」”，免得和日期、张数混在一起。
    func scopeName(of item: SidebarItem) -> String {
        if case .collection = item { return "收藏夹「\(title(of: item))」" }
        return title(of: item)
    }

    /// 导出前要满足的条件；满足返回 nil。
    var exportBlocker: String? {
        if isSynthetic { return "性能测试库没有原图，导不了" }
        if cardState != .connected { return "插上卡才能导出" }
        if importer.isRunning { return "正在读卡，读完再导出" }
        if exports.target == .folder, exports.folderName == nil { return "先选一个导出文件夹" }
        return nil
    }

    func startExport(_ scope: ExportScope) {
        if let blocker = exportBlocker {
            message = blocker
            return
        }
        guard let bookmark = (try? reader.card())?.bookmark else {
            message = "插上卡才能导出"
            return
        }
        Task {
            if exports.target == .photos, !(await PhotosSaver.requestAuthorization()) {
                message = "PhotoAI 没有添加照片的权限：在“设置”→“隐私与安全性”→“照片”里打开，或者改成导出到文件夹。"
                return
            }
            if let error = exports.start(scope.photoIDs, cardBookmark: bookmark) { message = error }
        }
    }
}

// MARK: - 设置（F-50）

/// 存储用量：库、预览、iPad 剩余空间（字节）。
struct StorageUsage: Sendable, Equatable {
    var database: Int64 = 0
    var previews: Int64 = 0
    var previewFiles = 0
    var available: Int64?

    nonisolated static func measure(_ paths: LibraryPaths) -> StorageUsage {
        var usage = StorageUsage()
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = paths.database.path + suffix
            usage.database += (try? manager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        if let files = manager.enumerator(at: paths.previews, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let url as URL in files {
                guard let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { continue }
                usage.previews += Int64(size)
                usage.previewFiles += 1
            }
        }
        usage.available = try? paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return usage
    }
}

extension AppModel {
    /// 在后台算：预览目录一整张卡约 4,000 个文件。
    func storageUsage() async -> StorageUsage {
        let paths = library.paths
        return await Task.detached(priority: .utility) { StorageUsage.measure(paths) }.value
    }

    func clearCheck() async -> ClearCheck? {
        let reader = reader
        return await Task.detached { try? reader.clearCheck() }.value
    }
}

// MARK: - 星级文件（F-34、F-51）

extension AppModel {
    func ratingExport() async -> RatingExport? {
        let reader = reader
        return await Task.detached { try? reader.ratingExport() }.value
    }

    /// 读选中的文件、逐行找照片。读不了返回错误说明。
    func planRatingImport(_ url: URL) async -> Result<RatingImportPlan, RatingImportFailure> {
        let reader = reader
        return await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return .failure(RatingImportFailure(message: "读不了 \(url.lastPathComponent)")) }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                return .failure(RatingImportFailure(message: "\(url.lastPathComponent) 不是文本文件（要 UTF-8）"))
            }
            do {
                return .success(try reader.planRatingImport(RatingFile(text: text)))
            } catch {
                return .failure(RatingImportFailure(message: "\(error)"))
            }
        }.value
    }

    /// 确认后写库，进撤销。
    func applyRatingImport(_ plan: RatingImportPlan, fileName: String) {
        commit(plan.edit, title: "从文件导入星级")
        appLog("从文件导入星级 \(fileName)：对上 \(plan.changes.count) 张、改了 \(plan.changedCount) 张，没对上 \(plan.unmatched.count) 行，忽略 \(plan.ignored.count) 行")
    }
}

struct RatingImportFailure: Error {
    var message: String
}
