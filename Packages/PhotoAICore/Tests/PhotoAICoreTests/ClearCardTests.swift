import Foundation
import Testing
@testable import PhotoAICore

/// 清卡检查和清卡（F-40 – F-42、功能列表 §5）。
@Suite struct ClearCardTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"
    let dateC = "2026-08-12 10:00:03"

    private func scanned() async throws -> (TemporaryLibrary, FakeCard) {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/100MSDCF/DSC00003.JPG", date: dateC)
        try await temp.scanner().scan(cardURL: card.root)
        return (temp, card)
    }

    /// “选过但没导出”：打过星或 Pick、一次都没导出过。Reject、没打的不算。
    @Test func checkCountsSelectedNotExported() async throws {
        let (temp, card) = try await scanned()
        let one = try #require(try temp.photoID("DSC00001", dateA))
        let two = try #require(try temp.photoID("DSC00002", dateB))
        let three = try #require(try temp.photoID("DSC00003", dateC))
        try temp.library.setRating(3, for: [one])
        try temp.library.setFlag(.pick, for: [two])
        try temp.library.setFlag(.reject, for: [three])
        #expect(try temp.reader.clearCheck().selectedNotExportedIDs == [one, two])

        let exporter = Exporter(library: temp.library, finder: OriginalFinder(root: card.root))
        _ = try exporter.run(ExportRequest(photoIDs: [two], files: .both, destination: temp.root.appendingPathComponent("导出")))

        let check = try temp.reader.clearCheck()
        #expect(check.photoCount == 3)
        #expect(check.selectedNotExportedIDs == [one])
        // 假卡的文本文件做不出预览：都算“预览没好”。
        #expect(check.previewNotReadyCount == 3)
    }

    /// 清卡后库、预览目录、书签和扫描记录都是空的；收藏夹名字和导出文件夹还在；卡上的文件一个不少。
    @Test func clearEmptiesLibraryKeepsCollectionsAndCardFiles() async throws {
        let (temp, card) = try await scanned()
        let one = try #require(try temp.photoID("DSC00001", dateA))
        let collection = try temp.library.createCollection(name: "精选")
        _ = try temp.library.addPhotos([one], to: collection)
        try temp.library.setCardBookmark(Data([9]))
        try temp.library.setExportFolderBookmark(Data([7]))
        let preview = PreviewStore(root: temp.library.paths.previews).url(for: one, size: .thumb)
        try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("预览".utf8).write(to: preview)
        let cardFiles = try FileManager.default.subpathsOfDirectory(atPath: card.root.path).sorted()

        let result = try temp.library.clearCard()

        #expect(result.deletedPhotos == 3)
        #expect(try temp.reader.photos(in: .all).isEmpty)
        #expect(try temp.reader.clearCheck() == ClearCheck())
        #expect(try temp.library.db.scalarInt("SELECT COUNT(*) FROM files;") == 0)
        #expect(try temp.library.db.scalarInt("SELECT COUNT(*) FROM locations;") == 0)
        #expect(try temp.library.db.scalarInt("SELECT COUNT(*) FROM scan_dirs;") == 0)
        #expect(try temp.library.db.scalarInt("SELECT COUNT(*) FROM import_batches;") == 0)
        #expect(try temp.reader.card().bookmark == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.library.paths.previews.path).isEmpty)
        #expect(try temp.reader.collections().map(\.name) == ["精选"])
        #expect(try temp.reader.collectionMembers(collection).isEmpty)
        #expect(try temp.reader.exportFolderBookmark() == Data([7]))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: card.root.path).sorted() == cardFiles)
    }

    /// 清卡后没格式化又读这张卡：照片作为新照片重新导入，星级不回来（F-42）。
    @Test func rescanAfterClearImportsAsNew() async throws {
        let (temp, card) = try await scanned()
        let one = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(5, for: [one])

        try temp.library.clearCard()
        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.newPhotos == 3)
        let photos = try temp.reader.photos(in: .all)
        #expect(photos.count == 3 && photos.allSatisfy { $0.rating == 0 && $0.isOnCard })
        #expect(try temp.expectConsistentCounts())
    }
}
