// 清卡（功能列表 F-40 – F-42、§5）。Mac 版没有这个；删照片的事务、删预览的写法参考 photoai-mac-v2 a291868
// `Orphans.swift` 的 `deleteOrphans`，副本核对、补副本都不要。
import Foundation

/// 清卡检查（F-40）：只是提醒，从不阻止清卡。
public struct ClearCheck: Sendable, Equatable {
    public var photoCount = 0
    /// 预览还没做好（待做或做失败）的照片。
    public var previewNotReadyCount = 0
    /// 选过但没导出：打过星、Pick 或者在收藏夹里，而且一次都没导出过。按拍摄时间排。
    public var selectedNotExportedIDs: [PhotoID] = []
    /// 卡上已删的照片（清卡时一起删）。
    public var missingFromCardCount = 0

    public init() {}
}

/// 清卡做了什么，给日志和提示用（PF-10）。
public struct ClearResult: Sendable, Equatable {
    public var deletedPhotos = 0
    public var databaseSeconds: TimeInterval = 0
    public var previewSeconds: TimeInterval = 0
}

extension LibraryReader {
    public func clearCheck() throws -> ClearCheck {
        var check = ClearCheck()
        try db.query(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(thumb_state != 'ready' OR preview_state != 'ready'), 0),
                   COALESCE(SUM(present_location_count = 0), 0)
            FROM photos;
            """
        ) { row in
            check.photoCount = row.int(0)
            check.previewNotReadyCount = row.int(1)
            check.missingFromCardCount = row.int(2)
        }
        check.selectedNotExportedIDs = try db.all(
            """
            SELECT id FROM photos
            WHERE (rating > 0 OR flag = 'pick' OR id IN (SELECT photo_id FROM collection_members)) AND last_exported_at IS NULL
            ORDER BY capture_date, capture_subsec, base_name, id;
            """
        ) { $0.int(0) }
        return check
    }
}

extension Library {
    /// 清卡（F-41、§5）：在一个事务里删掉全部照片（文件、位置、收藏夹成员随之删除）、扫描记录、导入批次和卡的书签；
    /// 提交后把预览目录整个删掉重建。收藏夹本身、`library_meta`（导出文件夹）保留。卡上的文件一概不碰。
    @discardableResult
    public func clearCard() throws -> ClearResult {
        var result = ClearResult()
        let started = Date()
        try db.transaction {
            result.deletedPhotos = try db.scalarInt("SELECT COUNT(*) FROM photos;")
            try db.run("DELETE FROM photos;")
            try db.run("DELETE FROM import_batches;")
            try db.run("DELETE FROM scan_dirs;")
            try db.run("UPDATE volumes SET bookmark = NULL, last_seen_at = NULL, last_scanned_at = NULL WHERE id = ?;", [Self.cardVolumeID])
        }
        let deleted = Date()
        result.databaseSeconds = deleted.timeIntervalSince(started)
        // 记录删掉之后再删预览文件：中途出错最多留下没人用的预览，不会出现有记录没预览。
        try? FileManager.default.removeItem(at: paths.previews)
        try paths.preparePreviewDirectory()
        result.previewSeconds = Date().timeIntervalSince(deleted)
        return result
    }
}
