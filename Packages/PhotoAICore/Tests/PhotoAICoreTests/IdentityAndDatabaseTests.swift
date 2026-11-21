// 搬自 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/IdentityAndDatabaseTests.swift。改了：只有一张卡；预览来源 ARW 排第一；
// 加了 ARW 尺寸取 EXIF、卡的书签的用例。
import Foundation
import ImageIO
import Testing
@testable import PhotoAICore

@Suite struct IdentityTests {
    @Test func namesThatDifferAreDifferentPhotos() {
        let date = "2026-08-12 10:00:01"
        #expect(PhotoIdentity.key(baseName: "DSC01926", captureDate: date, fileSize: 1)
            != PhotoIdentity.key(baseName: "DSC01926 (1)", captureDate: date, fileSize: 1))
        // 只统一大小写。
        #expect(PhotoIdentity.key(baseName: "dsc01926", captureDate: date, fileSize: 1)
            == PhotoIdentity.key(baseName: "DSC01926", captureDate: date, fileSize: 2))
    }

    @Test func withoutCaptureDateFallsBackToSize() {
        #expect(PhotoIdentity.key(baseName: "IMG_1", captureDate: nil, fileSize: 100)
            != PhotoIdentity.key(baseName: "IMG_1", captureDate: nil, fileSize: 200))
    }

    @Test func baseNameAndNumber() {
        #expect(PhotoIdentity.baseName(ofFileName: "DSC01926.ARW") == "DSC01926")
        #expect(PhotoIdentity.baseName(ofFileName: "DSC01926 (1).JPG") == "DSC01926 (1)")
        #expect(PhotoIdentity.fileNumber(ofBaseName: "DSC01926") == 1926)
        #expect(PhotoIdentity.fileNumber(ofBaseName: "_MG_0042") == 42)
        #expect(PhotoIdentity.fileNumber(ofBaseName: "DSC01926 (1)") == 1)
        #expect(PhotoIdentity.fileNumber(ofBaseName: "IMG") == nil)
        #expect(PhotoIdentity.fileNumber(ofBaseName: "20260812103000123") == nil)
    }

    @Test func exifDateNormalization() {
        #expect(CaptureDate.normalize(exif: "2026:08:12 10:00:01") == "2026-08-12 10:00:01")
        #expect(CaptureDate.normalize(exif: "2026:08:12 10:00:01\0") == "2026-08-12 10:00:01")
        #expect(CaptureDate.normalize(exif: "0000:00:00 00:00:00") == nil)
        #expect(CaptureDate.normalize(exif: "    :  :     :  :  ") == nil)
        #expect(CaptureDate.normalize(exif: "garbage") == nil)
    }

    @Test func fileKinds() {
        #expect(FileKind(extension: "ARW") == .raw)
        #expect(FileKind(extension: "jpeg") == .jpeg)
        #expect(FileKind(extension: "HIF") == .heif)
        #expect(FileKind(extension: "txt") == nil)
        #expect(FileKind(extension: "mov") == nil)
        // F-04：ARW 内嵌图优先，其次 JPG。
        #expect(FileKind.raw.previewPriority < FileKind.jpeg.previewPriority)
        #expect(FileKind.jpeg.previewPriority < FileKind.heif.previewPriority)
    }

    /// iPadOS 把 ARW 的文件头宽高报成内嵌图的 1616×1080：EXIF 的 PixelX/YDimension 更大时用它。
    @Test func rawDimensionsPreferLargerExifSize() {
        let embedded: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 1616, kCGImagePropertyPixelHeight: 1080, kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 7008, kCGImagePropertyExifPixelYDimension: 4672]
        ]
        let raw = ImageIOMetadataReader.metadata(from: embedded)
        #expect(raw.width == 4672 && raw.height == 7008)
        // EXIF 记的更小（缩过的 JPG）不用。
        let small: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 7008, kCGImagePropertyPixelHeight: 3944,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 1920, kCGImagePropertyExifPixelYDimension: 1080]
        ]
        let jpeg = ImageIOMetadataReader.metadata(from: small)
        #expect(jpeg.width == 7008 && jpeg.height == 3944)
    }

    /// 真实 JPEG 的拍摄时间（用 ImageIO 写出 EXIF 再读回）：RAW 带亚秒、JPEG 不带也能合组靠的是“精确到秒”。
    @Test func readsDateTimeOriginalFromRealJPEG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DSC00001.JPG")
        try SampleImages.writeJPEG(to: url, width: 64, height: 48, captureDate: "2026:08:12 10:00:01", subsec: "123")

        let metadata = try #require(try ImageIOMetadataReader().metadata(at: url))
        #expect(metadata.captureDate == "2026-08-12 10:00:01")
        #expect(metadata.cameraModel == "ILCE-7CM2")
        #expect(metadata.captureSubsec == "123")
        #expect(metadata.width == 64 && metadata.height == 48)

        // 不是图片的文件：能打开但读不出属性，返回 nil（跳过），不是抛错。
        let text = directory.appendingPathComponent("fake.JPG")
        try Data("not an image".utf8).write(to: text)
        #expect(try ImageIOMetadataReader().metadata(at: text) == nil)
        // 文件不在：抛错。
        #expect(throws: MetadataReadError.self) {
            try ImageIOMetadataReader().metadata(at: directory.appendingPathComponent("missing.JPG"))
        }
    }
}

@Suite struct DatabaseTests {
    @Test func failedTransactionRollsBack() throws {
        let temp = try TemporaryLibrary()
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try temp.library.db.transaction {
                try temp.library.db.run("INSERT INTO photos (identity_key, base_name, imported_at) VALUES ('k', 'k', 0);")
                throw Boom()
            }
        }
        #expect(try temp.reader.photoCount() == 0)
    }

    @Test func writeErrorsAreVisible() throws {
        let temp = try TemporaryLibrary()
        #expect(throws: DatabaseError.self) {
            try temp.library.db.run("UPDATE photos SET rating = 9 WHERE 1;")
            try temp.library.db.run("INSERT INTO photos (identity_key, base_name, rating, imported_at) VALUES ('k', 'k', 9, 0);")
        }
    }

    @Test func onlyOnePresentLocationPerPath() throws {
        let temp = try TemporaryLibrary()
        let db = temp.library.db
        let cardID = Library.cardVolumeID
        try db.run("INSERT INTO photos (id, identity_key, base_name, imported_at) VALUES (1, 'a', 'a', 0), (2, 'b', 'b', 0);")
        try db.run("INSERT INTO files (id, photo_id, extension, kind, file_size) VALUES (1, 1, 'jpg', 'jpeg', 1), (2, 2, 'jpg', 'jpeg', 1);")
        let insert = """
            INSERT INTO locations (file_id, volume_id, relative_path, dir_path, file_size, file_mtime, status, last_seen_at)
            VALUES (?, ?, 'x.jpg', '', 1, 0, ?, 0);
            """
        try db.run(insert, [1, cardID, "historical"])
        try db.run(insert, [2, cardID, "historical"])
        try db.run(insert, [1, cardID, "present"])
        #expect(throws: DatabaseError.self) { try db.run(insert, [2, cardID, "present"]) }
    }

    /// 两个连接各写不同字段，互不覆盖。
    @Test func fieldWritesFromTwoConnectionsDoNotClobber() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/DSC00001.JPG", date: "2026-08-12 10:00:01")
        try await temp.scanner().scan(cardURL: card.root)
        let photo = try #require(try temp.reader.photos(in: .all).first?.id)

        let other = try Library(paths: temp.library.paths)
        let versionBefore = try temp.library.dataVersion()
        try temp.library.setRating(4, for: [photo])
        try other.setFlag(.pick, for: [photo])
        #expect(try temp.library.dataVersion() != versionBefore)

        let detail = try #require(try temp.reader.detail(of: photo))
        #expect(detail.summary.rating == 4)
        #expect(detail.summary.flag == .pick)
    }

    /// 只有一张卡：`volumes` 固定一行，书签能存、能清。
    @Test func cardBookmarkRoundTrip() throws {
        let temp = try TemporaryLibrary()
        #expect(try temp.reader.card() == CardRecord())
        try temp.library.setCardBookmark(Data([1, 2, 3]))
        try temp.library.markCardSeen()
        let card = try temp.reader.card()
        #expect(card.bookmark == Data([1, 2, 3]))
        #expect(card.lastSeenAt != nil)
        try temp.library.setCardBookmark(nil)
        #expect(try temp.reader.card().bookmark == nil)
        #expect(throws: DatabaseError.self) { try temp.library.db.run("INSERT INTO volumes (id) VALUES (2);") }
    }

    @Test func migrationIsIdempotent() throws {
        let temp = try TemporaryLibrary()
        let reopened = try Library(paths: temp.library.paths)
        #expect(try reopened.db.scalarInt("PRAGMA user_version;") == Schema.migrations.count)
    }

    @Test func descendantRangeHelpers() {
        #expect(Library.isDirectChild("DCIM/100", of: "DCIM"))
        #expect(!Library.isDirectChild("DCIM/100/a", of: "DCIM"))
        #expect(!Library.isDirectChild("DCIMX/100", of: "DCIM"))
        #expect(Library.isDirectChild("DCIM", of: ""))
        let (lower, upper) = Library.descendantRange(of: "DCIM/100")
        #expect("DCIM/100/sub" >= lower && "DCIM/100/sub" < upper)
        #expect(!("DCIM/1000" >= lower && "DCIM/1000" < upper))
        #expect(!("DCIM/100-x" >= lower && "DCIM/100-x" < upper))
    }
}
