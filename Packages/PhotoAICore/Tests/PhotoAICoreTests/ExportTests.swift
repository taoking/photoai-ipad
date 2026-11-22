// 参考 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/ExportTests.swift，改成只有一张卡、只有平铺。
import Foundation
import Testing
@testable import PhotoAICore

/// 导出到文件夹（F-30 – F-32）。
@Suite struct ExportTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"

    final class Fixture {
        let temp: TemporaryLibrary
        let card: FakeCard
        let destination: URL

        init() throws {
            temp = try TemporaryLibrary()
            card = try FakeCard()
            destination = temp.root.appendingPathComponent("导出", isDirectory: true)
        }

        func scan() async throws { try await temp.scanner().scan(cardURL: card.root) }

        func id(_ baseName: String, _ date: String) throws -> PhotoID { try #require(try temp.photoID(baseName, date)) }

        func export(_ ids: [PhotoID], _ files: ExportRequest.Files, finder: OriginalFinder? = nil) throws -> ExportReport {
            let exporter = Exporter(library: temp.library, finder: finder ?? OriginalFinder(root: card.root))
            return try exporter.run(ExportRequest(photoIDs: ids, files: files, destination: destination))
        }

        var exportedNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).sorted()
        }

        func data(_ name: String) throws -> Data { try Data(contentsOf: destination.appendingPathComponent(name)) }
    }

    /// RAW + JPEG 两个都导：逐字节一致，保留修改时间，卡上的文件不变；照片记下“导出过”。
    @Test func exportsBothFilesByteForByte() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA, padding: 300)
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA, padding: 100)
        try await f.scan()
        let id = try f.id("DSC00001", dateA)
        let cardAttributes = try FileManager.default.attributesOfItem(atPath: f.card.url("DCIM/100MSDCF/DSC00001.ARW").path)

        let report = try f.export([id], .both)

        #expect(report.exportedPhotoIDs == [id] && report.copiedFiles == 2 && report.failures.isEmpty)
        #expect(f.exportedNames == ["DSC00001.ARW", "DSC00001.JPG"])
        #expect(try f.data("DSC00001.ARW") == Data(contentsOf: f.card.url("DCIM/100MSDCF/DSC00001.ARW")))
        #expect(try f.data("DSC00001.JPG") == Data(contentsOf: f.card.url("DCIM/100MSDCF/DSC00001.JPG")))
        let exported = try FileManager.default.attributesOfItem(atPath: f.destination.appendingPathComponent("DSC00001.ARW").path)
        #expect(exported[.modificationDate] as? Date == cardAttributes[.modificationDate] as? Date)
        #expect(try FileManager.default.attributesOfItem(atPath: f.card.url("DCIM/100MSDCF/DSC00001.ARW").path)[.modificationDate] as? Date
            == cardAttributes[.modificationDate] as? Date)
        #expect(try f.temp.reader.detail(of: id)?.lastExportedAt != nil)
    }

    /// 只要 RAW：没有 RAW 的照片导出 JPEG。
    @Test func rawFallsBackToJpeg() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await f.scan()
        let ids = [try f.id("DSC00001", dateA), try f.id("DSC00002", dateB)]

        let plan = ExportPlan(photoIDs: ids, sources: try f.temp.reader.presentSources(of: ids), files: .raw)
        #expect(plan.fileCount == 2 && plan.missingPhotoIDs.isEmpty)
        let report = try f.export(ids, .raw)

        #expect(f.exportedNames == ["DSC00001.ARW", "DSC00002.JPG"])
        #expect(report.exportedPhotos == 2)
    }

    /// 中断后再导一次就是续传：目标里有同名文件就算导出过，不比内容、不覆盖、不改名，也不去卡上读。
    @Test func rerunSkipsSameName() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try await f.scan()
        let id = try f.id("DSC00001", dateA)
        _ = try f.export([id], .both)

        let again = try f.export([id], .both)
        #expect(again.alreadyExportedFiles == 2 && again.copiedFiles == 0 && again.exportedPhotos == 1)

        // 只剩 JPG 同名（内容不一样也不管）：JPG 跳过，ARW 照常复制。卡拔了也不影响跳过的那个。
        try FileManager.default.removeItem(at: f.destination.appendingPathComponent("DSC00001.ARW"))
        try Data("别的内容".utf8).write(to: f.destination.appendingPathComponent("DSC00001.JPG"))
        let partly = try f.export([id], .both)
        #expect(partly.alreadyExportedFiles == 1 && partly.copiedFiles == 1 && partly.exportedPhotos == 1)
        #expect(f.exportedNames == ["DSC00001.ARW", "DSC00001.JPG"])
        #expect(try f.data("DSC00001.JPG") == Data("别的内容".utf8))

        let unplugged = OriginalFinder(root: f.card.root.appendingPathComponent("拔了")) { false }
        let offline = try f.export([id], .both, finder: unplugged)
        #expect(offline.alreadyExportedFiles == 2 && offline.stoppedBy == nil && offline.exportedPhotos == 1)
    }

    /// 上次中断留下的临时文件在开始时清掉。
    @Test func removesLeftoverPartFiles() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try await f.scan()
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
        try Data("半截".utf8).write(to: f.destination.appendingPathComponent(".DSC00009.JPG.x\(Exporter.partSuffix)"))

        _ = try f.export([try f.id("DSC00001", dateA)], .both)
        #expect(f.exportedNames == ["DSC00001.JPG"])
    }

    /// 卡连着、文件不在了：这张失败，照片标“卡上已删”，后面的照常导。
    @Test func missingFileFailsAndMarksPhoto() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await f.scan()
        let ids = [try f.id("DSC00001", dateA), try f.id("DSC00002", dateB)]
        try f.card.remove("DCIM/100MSDCF/DSC00001.JPG")

        let report = try f.export(ids, .both)

        #expect(report.failures.map(\.name) == ["DSC00001.JPG"])
        #expect(report.newlyMissingPhotoIDs == [ids[0]])
        #expect(report.exportedPhotoIDs == [ids[1]])
        #expect(try f.temp.reader.missingFromCardPhotoIDs() == [ids[0]])
        #expect(try f.temp.reader.detail(of: ids[0])?.lastExportedAt == nil)
    }

    /// 卡拔了：整批停下，不把照片当成“卡上已删”。
    @Test func unpluggedCardStops() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await f.scan()
        let ids = [try f.id("DSC00001", dateA), try f.id("DSC00002", dateB)]
        let unplugged = OriginalFinder(root: f.card.root.appendingPathComponent("拔了")) { false }

        let report = try f.export(ids, .both, finder: unplugged)

        #expect(report.stoppedBy == "卡没连接了")
        #expect(report.notAttempted == 2 && report.exportedPhotos == 0 && report.failures.isEmpty)
        #expect(try f.temp.reader.missingFromCardPhotoIDs().isEmpty)
    }

    /// 取消：停在当前文件，不留下半截文件。
    @Test func cancelLeavesNoPartialFiles() async throws {
        let f = try Fixture()
        try f.card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try f.card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await f.scan()
        let ids = [try f.id("DSC00001", dateA), try f.id("DSC00002", dateB)]
        let exporter = Exporter(library: f.temp.library, finder: OriginalFinder(root: f.card.root))

        let report = try exporter.run(ExportRequest(photoIDs: ids, files: .both, destination: f.destination), isCancelled: { true })

        #expect(report.cancelled && report.notAttempted == 2)
        #expect(f.exportedNames.isEmpty)
    }

    @Test func exportFolderBookmarkRoundTrips() throws {
        let temp = try TemporaryLibrary()
        #expect(try temp.reader.exportFolderBookmark() == nil)
        try temp.library.setExportFolderBookmark(Data([1, 2, 3]))
        try temp.library.setExportFolderBookmark(Data([4, 5]))
        #expect(try temp.reader.exportFolderBookmark() == Data([4, 5]))
    }
}
