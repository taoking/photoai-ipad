// 搬自 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/RatingImportTests.swift、MatchingTests.swift，改成只有一张卡；加了导出星级文件。
import Foundation
import Testing
@testable import PhotoAICore

/// 按名字、编号找照片，从文件导入星级（F-51），导出星级文件（F-34）。
struct RatingImportTests {
    @Test func parsesOnlyTwoColumnLines() {
        let file = RatingFile(text: """
        # 新疆选片

        DSC01064  1
        DSC01065    4
        \t01066\t5
        1067 3
        dsc01068.arw 2
        _DSC01069.JPG 5
        DSC01070 0
        DSC01071 6
        DSC01072 4 好看
        - DSC01073 4
        IMG_1074 3
        DSC1075 3
        123456 3
        DSC01076 ４
        DSC01077 4.5
        """)
        #expect(file.entries.map(\.key) == ["DSC01064", "DSC01065", "01066", "1067", "dsc01068.arw", "_DSC01069.JPG"])
        #expect(file.entries.map(\.rating) == [1, 4, 5, 3, 2, 5])
        #expect(file.entries.map(\.line) == [3, 4, 5, 6, 7, 8])
        #expect(file.entries.map(\.term) == [
            .baseName("DSC01064"), .baseName("DSC01065"), .number(1066), .number(1067),
            .fileName(baseName: "dsc01068", extension: "arw"), .fileName(baseName: "_DSC01069", extension: "JPG")
        ])
        // 空行不算忽略；标题、星级不在 1–5、多一列、列表符号、别的命名、全角数字都忽略。
        #expect(file.ignored.map(\.line) == [1, 9, 10, 11, 12, 13, 14, 15, 16, 17])
        #expect(file.ignored.first?.text == "# 新疆选片")
        #expect(RatingFile(text: "DSC01064 1\r\nDSC01065 4\r\n").entries.map(\.rating) == [1, 4])
    }

    @Test func matchesFileNameBaseNameAndNumber() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC01926.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01926.JPG", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01927.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/100MSDCF/DSC01930.JPG", date: "2026-08-12 10:00:05")
        try await temp.scanner().scan(cardURL: card.root)
        let p1926 = try #require(try temp.photoID("DSC01926", "2026-08-12 10:00:01"))
        let p1927 = try #require(try temp.photoID("DSC01927", "2026-08-12 10:00:02"))
        let p1930 = try #require(try temp.photoID("DSC01930", "2026-08-12 10:00:05"))

        // 文件名、去扩展名的文件名都不分大小写；RAW + JPEG 是一张照片。
        #expect(try temp.reader.match([.fileName(baseName: "dsc01926", extension: "arw")]).photoIDs == [p1926])
        #expect(try temp.reader.match([.baseName("DSC01926")]).photos.first?.extensions == ["ARW", "JPG"])
        // 有这张照片、但没有这个扩展名的文件，算没匹配到。
        let wrongExtension = try temp.reader.match([.fileName(baseName: "DSC01927", extension: "ARW")])
        #expect(wrongExtension.photoIDs.isEmpty)
        #expect(wrongExtension.unmatched == ["DSC01927.ARW"])
        // 范围：命中的按编号排，没命中的连成段。
        let range = try temp.reader.match([.range(1924, 1932)])
        #expect(range.photoIDs == [p1926, p1927, p1930])
        #expect(range.unmatched == ["1924-1925", "1928-1929", "1931-1932"])
    }

    /// 两张卡上同号（没清卡又插了一张卡）：取拍摄时间最晚的，旧的列为跳过；“卡上已删”的照片也参与。
    @Test func sameNumberTakesLatest() async throws {
        let temp = try TemporaryLibrary()
        let oldCard = try FakeCard()
        let newCard = try FakeCard()
        try oldCard.put("DCIM/100MSDCF/DSC01926.JPG", date: "2019-05-01 09:00:00")
        try newCard.put("DCIM/101MSDCF/DSC01926.JPG", date: "2026-08-12 10:00:01")
        try await temp.scanner().scan(cardURL: oldCard.root)
        try await temp.scanner().scan(cardURL: newCard.root)
        let older = try #require(try temp.photoID("DSC01926", "2019-05-01 09:00:00"))
        let latest = try #require(try temp.photoID("DSC01926", "2026-08-12 10:00:01"))

        let byNumber = try temp.reader.match([.number(1926)])
        #expect(byNumber.photoIDs == [latest])
        #expect(byNumber.skipped.map(\.id) == [older])
        try newCard.remove("DCIM/101MSDCF/DSC01926.JPG")
        try await temp.scanner().scan(cardURL: newCard.root)
        #expect(try temp.reader.match([.number(1926)]).photoIDs == [latest])
    }

    @Test func plansAndAppliesUndoably() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC01064.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01064.JPG", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01065.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/100MSDCF/DSC01066.JPG", date: "2026-08-12 10:00:03")
        try await temp.scanner().scan(cardURL: card.root)
        let p1064 = try #require(try temp.photoID("DSC01064", "2026-08-12 10:00:01"))
        let p1065 = try #require(try temp.photoID("DSC01065", "2026-08-12 10:00:02"))
        let p1066 = try #require(try temp.photoID("DSC01066", "2026-08-12 10:00:03"))
        try temp.library.setRating(4, for: [p1065])

        let file = RatingFile(text: """
        DSC01064 1
        DSC01065 4
        1066 5
        DSC01099 3
        DSC01064.JPG 2
        说明 一行
        """)
        let plan = try temp.reader.planRatingImport(file)
        // RAW + JPEG 是一张；同一张写了两次以后面的为准。
        #expect(plan.changes.map(\.photo.id) == [p1064, p1065, p1066])
        #expect(plan.changes.map(\.rating) == [2, 4, 5])
        #expect(plan.changedCount == 2)
        #expect(plan.countsByRating == [2: 1, 4: 1, 5: 1])
        #expect(plan.conflicts.map(\.photo.id) == [p1064])
        #expect(plan.conflicts.first?.ratings == [1, 2])
        #expect(plan.unmatched.map(\.key) == ["DSC01099"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.ignored.map(\.line) == [6])

        try temp.library.apply(plan.edit)
        #expect(try temp.reader.match([.range(1064, 1066)]).photos.map(\.rating) == [2, 4, 5])
        // 撤销回到导入前。
        try temp.library.apply(plan.edit.inverse)
        #expect(try temp.reader.match([.range(1064, 1066)]).photos.map(\.rating) == [0, 4, 0])
    }

    /// 导出的星级文件：只有打过星的，按拍摄时间排；读回来星级一样（Mac 版用同一个 `RatingFile` 读）。
    @Test func exportRoundTrips() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC01065.JPG", date: "2026-08-12 10:00:02")
        try card.put("DCIM/100MSDCF/DSC01064.ARW", date: "2026-08-12 10:00:01")
        try card.put("DCIM/100MSDCF/DSC01066.JPG", date: "2026-08-12 10:00:03")
        try await temp.scanner().scan(cardURL: card.root)
        #expect(try temp.reader.ratingExport() == RatingExport(text: "", photoCount: 0))
        let p1064 = try #require(try temp.photoID("DSC01064", "2026-08-12 10:00:01"))
        let p1066 = try #require(try temp.photoID("DSC01066", "2026-08-12 10:00:03"))
        try temp.library.setRating(5, for: [p1066])
        try temp.library.setRating(3, for: [p1064])

        let export = try temp.reader.ratingExport()
        #expect(export.text == "DSC01064  3\nDSC01066  5\n")
        #expect(export.photoCount == 2)
        let plan = try temp.reader.planRatingImport(RatingFile(text: export.text))
        #expect(plan.changes.map(\.photo.id) == [p1064, p1066])
        #expect(plan.changedCount == 0 && plan.ignored.isEmpty && plan.unmatched.isEmpty)
    }
}
