// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/LibraryReader.swift。改了：库里的照片都可见，
// 去掉 `present_location_count > 0` 的条件（= 0 的标“卡上已删”）；卷的查询改成卡的；去掉人物、地点、搜索、导入批次。
import Foundation

/// 库的查询。没有“无卷关联照片”：库里的照片都显示，卡上没有了的只加一个标记（功能列表 §1）。
public struct LibraryReader: Sendable {
    let db: Database

    // MARK: - 卡

    public func card() throws -> CardRecord {
        try db.first("SELECT bookmark, last_seen_at, last_scanned_at FROM volumes WHERE id = ?;", [Library.cardVolumeID]) { row in
            CardRecord(bookmark: row.blob(0), lastSeenAt: row.date(1), lastScannedAt: row.date(2))
        } ?? CardRecord()
    }

    public func cardStats() throws -> CardStats {
        var stats = CardStats()
        try db.query(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(thumb_state = 'ready' AND preview_state = 'ready'), 0),
                   COALESCE(SUM(present_location_count > 0 AND (thumb_state = 'pending' OR preview_state = 'pending')), 0),
                   COALESCE(SUM(thumb_state = 'failed' OR preview_state = 'failed'), 0),
                   COALESCE(SUM(present_location_count = 0), 0)
            FROM photos;
            """
        ) { row in
            stats.photoCount = row.int(0)
            stats.previewReadyCount = row.int(1)
            stats.previewPendingCount = row.int(2)
            stats.previewFailedCount = row.int(3)
            stats.missingFromCardCount = row.int(4)
        }
        stats.incompleteDirectoryCount = try db.scalarInt(
            "SELECT COUNT(*) FROM scan_dirs WHERE volume_id = ? AND state = 'incomplete';", [Library.cardVolumeID]
        )
        return stats
    }

    // MARK: - 照片

    public func photos(in scope: PhotoScope, sort: PhotoSort = .captureDateDescending) throws -> [PhotoSummary] {
        let (condition, arguments) = Self.condition(for: scope)
        let order = switch sort {
        case .captureDateDescending: "p.capture_date IS NULL, p.capture_date DESC, p.capture_subsec DESC, p.base_name DESC"
        case .captureDateAscending: "p.capture_date IS NULL, p.capture_date, p.capture_subsec, p.base_name"
        }
        let labels = try photoLabels(in: scope == .all ? nil : scope)
        return try db.all(
            """
            SELECT p.id, p.base_name, p.capture_date, p.width, p.height, p.rating, p.flag, p.thumb_state,
                   EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.kind = 'raw'),
                   EXISTS (SELECT 1 FROM files f WHERE f.photo_id = p.id AND f.kind = 'jpeg'),
                   p.present_location_count > 0
            FROM photos p
            WHERE \(condition)
            ORDER BY \(order);
            """,
            arguments
        ) { row in
            PhotoSummary(
                id: row.int(0),
                baseName: row.text(1) ?? "",
                captureDate: row.text(2),
                width: row.optionalInt(3),
                height: row.optionalInt(4),
                rating: row.int(5),
                flag: Flag(rawValue: row.text(6) ?? "") ?? .none,
                thumbState: PreviewState(rawValue: row.text(7) ?? "") ?? .pending,
                hasRaw: row.int(8) != 0,
                hasJPEG: row.int(9) != 0,
                isOnCard: row.int(10) != 0,
                labelIDs: labels[row.int(0)] ?? []
            )
        }
    }

    public func photoCount(in scope: PhotoScope = .all) throws -> Int {
        let (condition, arguments) = Self.condition(for: scope)
        return try db.scalarInt("SELECT COUNT(*) FROM photos p WHERE \(condition);", arguments)
    }

    /// “卡上已删”：一个现存位置都没有的照片。
    public func missingFromCardPhotoIDs() throws -> [PhotoID] {
        try db.all("SELECT id FROM photos WHERE present_location_count = 0 ORDER BY id;") { $0.int(0) }
    }

    public func dayCounts() throws -> [DayCount] {
        try db.all(
            """
            SELECT substr(capture_date, 1, 10) AS day, COUNT(*) FROM photos
            WHERE capture_date IS NOT NULL
            GROUP BY day ORDER BY day DESC;
            """
        ) { DayCount(day: $0.text(0) ?? "", count: $0.int(1)) }
    }

    public func undatedCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM photos WHERE capture_date IS NULL;")
    }

    public func detail(of id: PhotoID) throws -> PhotoDetail? {
        guard var detail = try db.first(
            """
            SELECT p.id, p.base_name, p.capture_date, p.width, p.height, p.rating, p.flag, p.thumb_state,
                   p.camera_make, p.camera_model, p.lens, p.focal_length, p.aperture, p.shutter, p.iso,
                   p.preview_state, p.present_location_count,
                   p.focus_state, p.focus_x, p.focus_y, p.focus_w, p.focus_h, p.last_exported_at
            FROM photos p WHERE p.id = ?;
            """,
            [id],
            { row in
                PhotoDetail(
                    summary: PhotoSummary(
                        id: row.int(0),
                        baseName: row.text(1) ?? "",
                        captureDate: row.text(2),
                        width: row.optionalInt(3),
                        height: row.optionalInt(4),
                        rating: row.int(5),
                        flag: Flag(rawValue: row.text(6) ?? "") ?? .none,
                        thumbState: PreviewState(rawValue: row.text(7) ?? "") ?? .pending,
                        hasRaw: false,
                        hasJPEG: false,
                        isOnCard: row.int(16) > 0
                    ),
                    cameraMake: row.text(8),
                    cameraModel: row.text(9),
                    lens: row.text(10),
                    focalLength: row.optionalDouble(11),
                    aperture: row.optionalDouble(12),
                    shutter: row.optionalDouble(13),
                    iso: row.optionalInt(14),
                    previewState: PreviewState(rawValue: row.text(15) ?? "") ?? .pending,
                    presentLocationCount: row.int(16),
                    extensions: [],
                    locations: [],
                    focusState: row.text(17) ?? "pending",
                    focus: row.text(17) == "found"
                        ? FocusArea(x: row.double(18), y: row.double(19), width: row.double(20), height: row.double(21)) : nil,
                    lastExportedAt: row.date(22)
                )
            }
        ) else { return nil }
        let kinds = try db.all("SELECT extension, kind FROM files WHERE photo_id = ? ORDER BY kind DESC;", [id]) {
            ($0.text(0) ?? "", $0.text(1) ?? "")
        }
        detail.extensions = kinds.map { $0.0.uppercased() }
        detail.summary.hasRaw = kinds.contains { $0.1 == FileKind.raw.rawValue }
        detail.summary.hasJPEG = kinds.contains { $0.1 == FileKind.jpeg.rawValue }
        detail.summary.labelIDs = try db.all(
            """
            SELECT pl.label_id FROM photo_labels pl JOIN labels l ON l.id = pl.label_id
            WHERE pl.photo_id = ? AND l.name != '' ORDER BY l.sort_order;
            """,
            [id]
        ) { $0.int(0) }
        detail.collectionNames = try collectionNames(of: id)
        detail.locations = try db.all(
            """
            SELECT l.relative_path, l.status = 'present'
            FROM locations l JOIN files f ON f.id = l.file_id
            WHERE f.photo_id = ? ORDER BY l.status = 'present' DESC, l.relative_path;
            """,
            [id]
        ) { PhotoDetail.Location(relativePath: $0.text(0) ?? "", isPresent: $0.int(1) != 0) }
        return detail
    }

    public func rating(of id: PhotoID) throws -> Int? {
        try db.first("SELECT rating FROM photos WHERE id = ?;", [id]) { $0.int(0) }
    }

    public func photoID(identityKey: String) throws -> PhotoID? {
        try db.first("SELECT id FROM photos WHERE identity_key = ?;", [identityKey]) { $0.int(0) }
    }

    public func presentLocationCount(of id: PhotoID) throws -> Int? {
        try db.first("SELECT present_location_count FROM photos WHERE id = ?;", [id]) { $0.int(0) }
    }

    /// 冗余计数与实际现存位置数不一致的照片。正常情况下应为空（测试与自检用）。
    public func inconsistentLocationCounts() throws -> [PhotoID] {
        try db.all(
            """
            SELECT p.id FROM photos p
            WHERE p.present_location_count != (
                SELECT COUNT(*) FROM locations l JOIN files f ON f.id = l.file_id
                WHERE f.photo_id = p.id AND l.status = 'present'
            );
            """
        ) { $0.int(0) }
    }

    public func collectionMembers(_ collection: CollectionID) throws -> [PhotoID] {
        try db.all(
            "SELECT photo_id FROM collection_members WHERE collection_id = ? ORDER BY photo_id;",
            [collection]
        ) { $0.int(0) }
    }

    public func scanDirectoryStates() throws -> [String: String] {
        var states: [String: String] = [:]
        try db.query("SELECT dir_path, state FROM scan_dirs WHERE volume_id = ?;", [Library.cardVolumeID]) {
            states[$0.text(0) ?? ""] = $0.text(1)
        }
        return states
    }

    /// 卡上某个路径的所有位置：(照片身份, 状态)，按记录先后排列。测试用。
    public func locations(relativePath: String) throws -> [(identityKey: String, status: String)] {
        try db.all(
            """
            SELECT p.identity_key, l.status FROM locations l
            JOIN files f ON f.id = l.file_id JOIN photos p ON p.id = f.photo_id
            WHERE l.volume_id = ? AND l.relative_path = ? ORDER BY l.id;
            """,
            [Library.cardVolumeID, relativePath]
        ) { ($0.text(0) ?? "", $0.text(1) ?? "") }
    }

    // MARK: - 预览

    /// 需要生成预览、并且卡上有现存位置的照片，新拍的在前。
    /// 每张照片列出所有可用的来源，ARW 排在 JPG 前面（F-04：预览用 ARW 内嵌图）。
    public func photosNeedingPreviews(limit: Int, excluding: Set<PhotoID> = []) throws -> [PreviewJob] {
        let candidates = try db.all(
            """
            SELECT p.id, p.thumb_state = 'pending', p.preview_state = 'pending' FROM photos p
            WHERE p.present_location_count > 0
              AND (p.thumb_state = 'pending' OR p.preview_state = 'pending')
            ORDER BY p.capture_date DESC
            LIMIT ?;
            """,
            [limit + excluding.count]
        ) { ($0.int(0), $0.int(1) != 0, $0.int(2) != 0) }
        var jobs: [PreviewJob] = []
        for (id, needsThumb, needsPreview) in candidates where !excluding.contains(id) {
            guard jobs.count < limit else { break }
            let sources = try db.all(
                """
                SELECT f.id, f.kind, l.relative_path FROM files f
                JOIN locations l ON l.file_id = f.id
                WHERE f.photo_id = ? AND l.status = 'present';
                """,
                [id]
            ) { row in
                PreviewJob.Source(
                    fileID: row.int(0),
                    kind: FileKind(rawValue: row.text(1) ?? "") ?? .raw,
                    relativePath: row.text(2) ?? ""
                )
            }
            .sorted { $0.kind.previewPriority < $1.kind.previewPriority }
            jobs.append(PreviewJob(photoID: id, needsThumb: needsThumb, needsPreview: needsPreview, sources: sources))
        }
        return jobs
    }

    /// 卡上有文件、预览还没做完的照片数。
    public func pendingPreviewCount() throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM photos WHERE present_location_count > 0 AND (thumb_state = 'pending' OR preview_state = 'pending');"
        )
    }

    /// 状态是 `ready` 的照片 id，启动时核对文件还在不在。
    public func photosWithReadyPreviews() throws -> [(id: PhotoID, thumb: Bool, preview: Bool)] {
        try db.all(
            "SELECT id, thumb_state = 'ready', preview_state = 'ready' FROM photos WHERE thumb_state = 'ready' OR preview_state = 'ready';"
        ) { ($0.int(0), $0.int(1) != 0, $0.int(2) != 0) }
    }

    // MARK: - 内部

    static func condition(for scope: PhotoScope) -> (String, [any SQLBindable]) {
        switch scope {
        case .all:
            ("1", [])
        case .datePrefix(let prefix):
            // 用范围比较走索引：`2026-08` ≤ capture_date < `2026-08~`。
            ("p.capture_date >= ? AND p.capture_date < ?", [prefix, prefix + "~"])
        case .undated:
            ("p.capture_date IS NULL", [])
        case .collection(let id):
            ("p.id IN (SELECT photo_id FROM collection_members WHERE collection_id = ?)", [id])
        }
    }
}

/// 一张照片的预览生成任务。
public struct PreviewJob: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public var fileID: FileID
        public var kind: FileKind
        /// 相对卡根目录。
        public var relativePath: String
    }

    public var photoID: PhotoID
    public var needsThumb: Bool
    public var needsPreview: Bool
    public var sources: [Source]
}
