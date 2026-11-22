import Foundation
import PhotoAICore

/// 导出面板导哪些照片（F-30）。
struct ExportScope: Identifiable, Equatable {
    let id = UUID()
    /// “所选的 12 张”“当前结果 230 张”“选过但没导出的 8 张”。
    var title: String
    var photoIDs: [PhotoID]
}

// MARK: - 导出（F-30 – F-32）

extension AppModel {
    /// 工具栏的“导出”：选择模式下导所选的，否则导当前结果（筛选后的）。
    func showExport() {
        if isSelecting, !selectedIDs.isEmpty {
            exportScope = ExportScope(title: "所选的 \(selectedIDs.count) 张", photoIDs: targetIDs)
        } else {
            let title = currentFilter.isEmpty ? "\(selection.title) \(photos.count) 张" : "筛选结果 \(photos.count) 张"
            exportScope = ExportScope(title: title, photoIDs: photos.map(\.id))
        }
    }

    /// 导出前要满足的条件；满足返回 nil。
    var exportBlocker: String? {
        if isSynthetic { return "性能测试库没有原图，导不了" }
        if cardState != .connected { return "插上卡才能导出" }
        if importer.isRunning { return "正在读卡，读完再导出" }
        if exports.folderName == nil { return "先选一个导出文件夹" }
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
        if let error = exports.start(scope.photoIDs, cardBookmark: bookmark) { message = error }
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
