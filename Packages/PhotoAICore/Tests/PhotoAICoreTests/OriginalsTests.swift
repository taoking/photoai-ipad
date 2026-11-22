import Foundation
import Testing
@testable import PhotoAICore

/// 在卡上找原文件（F-13 的 100% 放大，M3 的导出也用）。
@Suite struct OriginalsTests {
    let date = "2026-08-12 10:00:01"

    private func scanned(_ files: [String]) async throws -> (TemporaryLibrary, FakeCard, PhotoID) {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        for file in files { try card.put(file, date: date) }
        _ = try await temp.scanner().scan(cardURL: card.root)
        let id = try #require(try temp.reader.photos(in: .all).first?.id)
        return (temp, card, id)
    }

    /// RAW + JPEG：100% 放大用 JPG，不用 ARW（iPadOS 只读得到 ARW 的内嵌预览）。
    @Test func viewingPrefersJPEGOverRaw() async throws {
        let (temp, card, id) = try await scanned(["DCIM/100MSDCF/DSC00001.ARW", "DCIM/100MSDCF/DSC00001.JPG"])
        let sources = try #require(try temp.reader.presentSources(of: [id])[id])
        #expect(Set(sources.map(\.kind)) == [.raw, .jpeg])

        let lookup = OriginalFinder(root: card.root).lookupForViewing(sources)
        #expect(lookup.found?.source.fileName == "DSC00001.JPG")
        #expect(lookup.missingLocationIDs.isEmpty)
    }

    @Test func rawOnlyHasNothingToView() async throws {
        let (temp, card, id) = try await scanned(["DCIM/100MSDCF/DSC00001.ARW"])
        let sources = try #require(try temp.reader.presentSources(of: [id])[id])
        let lookup = OriginalFinder(root: card.root).lookupForViewing(sources)
        #expect(lookup.found == nil)
        #expect(lookup.problems.isEmpty && !lookup.wasOffline)
    }

    /// 卡还连着、文件不在了：位置改成历史，照片变成“卡上已删”，照常在库里。
    @Test func missingFileOnReachableCardMarksPhotoMissing() async throws {
        let (temp, card, id) = try await scanned(["DCIM/100MSDCF/DSC00001.JPG"])
        try card.remove("DCIM/100MSDCF/DSC00001.JPG")
        let sources = try #require(try temp.reader.presentSources(of: [id])[id])

        let lookup = OriginalFinder(root: card.root).lookupForViewing(sources)
        #expect(lookup.found == nil)
        #expect(lookup.missingLocationIDs == sources.map(\.locationID))

        #expect(try temp.library.markLocationsMissing(lookup.missingLocationIDs) == [id])
        let photo = try #require(try temp.reader.photos(in: .all).first)
        #expect(photo.id == id && !photo.isOnCard)
        #expect(try temp.reader.presentSources(of: [id]).isEmpty)
        #expect(try temp.expectConsistentCounts())
    }

    /// 卡拔了：路径不在不能当成文件被删。
    @Test func offlineCardIsNotMissing() async throws {
        let (temp, card, id) = try await scanned(["DCIM/100MSDCF/DSC00001.JPG"])
        let sources = try #require(try temp.reader.presentSources(of: [id])[id])
        let unplugged = OriginalFinder(root: card.root.appendingPathComponent("拔了")) { false }

        let lookup = unplugged.lookupForViewing(sources)
        #expect(lookup.found == nil)
        #expect(lookup.wasOffline)
        #expect(lookup.missingLocationIDs.isEmpty)
    }

    /// 文件大小和扫描时不一样：读不了，但不改历史位置。
    @Test func changedSizeIsUnreadable() async throws {
        let (temp, card, id) = try await scanned(["DCIM/100MSDCF/DSC00001.JPG"])
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: date, padding: 10)
        let sources = try #require(try temp.reader.presentSources(of: [id])[id])

        let lookup = OriginalFinder(root: card.root).lookupForViewing(sources)
        #expect(lookup.found == nil)
        #expect(lookup.problems.count == 1)
        #expect(lookup.missingLocationIDs.isEmpty)
    }
}
