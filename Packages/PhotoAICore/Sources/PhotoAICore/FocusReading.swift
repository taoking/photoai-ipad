// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/FocusReading.swift。只有一张卡：不按卷筛，`FocusRunner` 直接给卡的根目录；
// 来源按 `previewPriority` 排（ARW 在前，M0 实测 ARW 每张 0.5 ms、JPG 1.3 ms）；去掉了 `focusCounts`。
import Foundation

// MARK: - 读

extension LibraryReader {
    /// 照片的对焦框；没读过、相机没记都是 nil。
    public func focusArea(of photo: PhotoID) throws -> FocusArea? {
        try db.first(
            "SELECT focus_x, focus_y, focus_w, focus_h FROM photos WHERE id = ? AND focus_state = 'found';", [photo]
        ) { FocusArea(x: $0.double(0), y: $0.double(1), width: $0.double(2), height: $0.double(3)) }
    }

    /// 还没读对焦框、卡上有文件的照片数。
    public func pendingFocusCount() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM photos WHERE focus_state = 'pending' AND present_location_count > 0;")
    }

    /// 还没读对焦框、卡上有文件的照片，每张列出卡上的文件。
    public func photosNeedingFocus(limit: Int, excluding: Set<PhotoID> = []) throws -> [PreviewJob] {
        let candidates = try db.all(
            "SELECT id FROM photos WHERE focus_state = 'pending' AND present_location_count > 0 LIMIT ?;",
            [limit + excluding.count]
        ) { $0.int(0) }
        var jobs: [PreviewJob] = []
        for id in candidates where !excluding.contains(id) {
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
                    fileID: row.int(0), kind: FileKind(rawValue: row.text(1) ?? "") ?? .raw, relativePath: row.text(2) ?? ""
                )
            }
            .sorted { $0.kind.previewPriority < $1.kind.previewPriority }
            jobs.append(PreviewJob(photoID: id, needsThumb: false, needsPreview: false, sources: sources))
        }
        return jobs
    }
}

// MARK: - 写

extension Library {
    /// 一批照片的对焦框，一个事务写完。
    public func saveFocus(_ results: [(PhotoID, FocusPointReader.Result)]) throws {
        guard !results.isEmpty else { return }
        try db.transaction {
            for (photo, result) in results {
                switch result {
                case .found(let area):
                    try db.run(
                        "UPDATE photos SET focus_state = 'found', focus_x = ?, focus_y = ?, focus_w = ?, focus_h = ? WHERE id = ?;",
                        [area.x, area.y, area.width, area.height, photo]
                    )
                case .notRecorded:
                    try db.run("UPDATE photos SET focus_state = 'none' WHERE id = ?;", [photo])
                }
            }
        }
    }
}

// MARK: - 后台读

/// 卡连着时读还没读过的对焦框（F-18）：每张只读文件头的几处。
/// 文件读不了（卡中途拔了）的这一轮跳过，下次插上再读。
public struct FocusRunner: Sendable {
    public let library: Library
    public var batchSize = 200

    public init(library: Library) {
        self.library = library
    }

    /// 返回这一轮读了多少张。`progress` 每批写完库调一次，给的是到目前读了多少张。
    @discardableResult
    public func run(
        cardURL: URL, shouldStop: @Sendable () -> Bool = { false }, progress: (Int) -> Void = { _ in }
    ) throws -> Int {
        var skipped: Set<PhotoID> = []
        var done = 0
        while !shouldStop() {
            let jobs = try library.reader.photosNeedingFocus(limit: batchSize, excluding: skipped)
            guard !jobs.isEmpty else { break }
            var results: [(PhotoID, FocusPointReader.Result)] = []
            for job in jobs {
                guard !shouldStop() else { break }
                let result = job.sources.lazy.compactMap {
                    FocusPointReader.read(at: cardURL.appendingPathComponent($0.relativePath))
                }.first
                if let result { results.append((job.photoID, result)) } else { skipped.insert(job.photoID) }
            }
            try library.saveFocus(results)
            done += results.count
            progress(done)
        }
        return done
    }
}
