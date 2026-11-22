// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Library.swift。改了：库放在沙盒的 Application Support/PhotoAI，
// 预览目录不备份到 iCloud；卷的增删改成卡的书签；只有 JPG / HEIF 生成的预览才改照片尺寸；去掉旧库的尺寸校正。
import Foundation

/// 库的位置：数据库和预览文件。
public struct LibraryPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// 沙盒里的 `Library/Application Support/PhotoAI`（开发计划 §2）。覆盖安装保留，删掉应用就没了。
    public static var `default`: LibraryPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryPaths(root: support.appendingPathComponent("PhotoAI", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("library.sqlite") }
    public var previews: URL { root.appendingPathComponent("Previews", isDirectory: true) }

    /// 建好预览目录，标成不备份到 iCloud（一整张卡的预览 2–3 GB，丢了插卡就能重做）。
    public func preparePreviewDirectory() throws {
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var url = previews
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// 照片库：数据库的读写都从这里走。
///
/// 所有写入按字段更新，不整行覆盖；跨表的操作放在一个事务里，失败整体回滚并抛错。
public final class Library: @unchecked Sendable {
    /// 唯一那张卡在 `volumes` 表里的 id。
    static let cardVolumeID: VolumeID = 1

    public let paths: LibraryPaths
    let db: Database
    let now: @Sendable () -> Date

    public init(paths: LibraryPaths = .default, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.paths = paths
        self.now = now
        db = try Database(url: paths.database)
        try Schema.migrate(db)
    }

    /// 另开一个只读连接，给界面线程读网格用，不用排在扫描的写事务后面。
    public func makeReader() throws -> LibraryReader {
        LibraryReader(db: try Database(url: paths.database, readOnly: true))
    }

    public var reader: LibraryReader { LibraryReader(db: db) }

    public func dataVersion() throws -> Int { try db.dataVersion() }

    // MARK: - 卡

    /// 用户在选择器里选了卡：存下书签。传 nil 清掉（清卡时）。
    public func setCardBookmark(_ bookmark: Data?) throws {
        try db.run("UPDATE volumes SET bookmark = ? WHERE id = ?;", [bookmark, Self.cardVolumeID])
    }

    public func markCardSeen() throws {
        try db.run("UPDATE volumes SET last_seen_at = ? WHERE id = ?;", [now(), Self.cardVolumeID])
    }

    // MARK: - 预览状态

    /// 预览文件已写完并能解码之后才调用：在一个事务里把对应档位记为 `ready`，并记下用的是哪个文件。
    /// `pixelSize` 是生成预览的那个文件转正后的尺寸，给了就以它为准。ARW 生成的预览不给：
    /// iPadOS 的 ImageIO 只看得到 ARW 内嵌的 1616×1080，照片尺寸用扫描时从 JPG 或 EXIF 读到的。
    public func markPreviewsReady(
        photoID: PhotoID,
        thumb: Bool,
        preview: Bool,
        sourceFileID: FileID,
        pixelSize: (width: Int, height: Int)? = nil
    ) throws {
        try db.transaction {
            if thumb { try db.run("UPDATE photos SET thumb_state = 'ready' WHERE id = ?;", [photoID]) }
            if preview { try db.run("UPDATE photos SET preview_state = 'ready' WHERE id = ?;", [photoID]) }
            try db.run("UPDATE photos SET preview_file_id = ? WHERE id = ?;", [sourceFileID, photoID])
            if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
                try db.run("UPDATE photos SET width = ?, height = ? WHERE id = ?;", [pixelSize.width, pixelSize.height, photoID])
            }
        }
    }

    /// 原片能读但解码不了：记为 `failed`，不再反复重试。
    public func markPreviewsFailed(photoID: PhotoID) throws {
        try db.run(
            """
            UPDATE photos SET
                thumb_state = CASE thumb_state WHEN 'pending' THEN 'failed' ELSE thumb_state END,
                preview_state = CASE preview_state WHEN 'pending' THEN 'failed' ELSE preview_state END
            WHERE id = ?;
            """,
            [photoID]
        )
    }

    /// 文件缺失或解码失败的档位改回 `pending`，卡插上时续做。
    public func resetPreviews(_ items: [(photoID: PhotoID, thumb: Bool, preview: Bool)]) throws {
        try db.transaction {
            for item in items {
                if item.thumb { try db.run("UPDATE photos SET thumb_state = 'pending' WHERE id = ?;", [item.photoID]) }
                if item.preview { try db.run("UPDATE photos SET preview_state = 'pending' WHERE id = ?;", [item.photoID]) }
            }
        }
    }

    /// 诊断用（在真机上试后台继续处理，F-07）：卡上有文件的照片，1600 预览和对焦框都改回没做，插着卡就重做一遍。
    /// 缩略图、星级、选择、收藏夹都不动。返回现在待做预览的张数。
    public func redoPreviewsAndFocus() throws -> Int {
        try db.run("UPDATE photos SET preview_state = 'pending', focus_state = 'pending' WHERE present_location_count > 0;")
        return try reader.pendingPreviewCount()
    }

    // MARK: - 路径

    /// 去掉首尾的 `/`。空字符串表示卡根目录。
    static func normalizedDirectory(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `dir` 是 `root` 本身或在它下面（相对卡根目录的路径；空字符串是整张卡）。
    static func isDirectory(_ dir: String, inside root: String) -> Bool {
        root.isEmpty || dir == root || dir.hasPrefix(root + "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}
