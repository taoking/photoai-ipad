// 搬自 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/ScanTests.swift。改了：只有一张卡；文件没了的照片照常显示、标“卡上已删”；
// 去掉多卷、移除卷、整卷扫描的用例；加了只扫 DCIM、只收 A7C II、插另一张卡的用例。
import Foundation
import Testing
@testable import PhotoAICore

/// 扫描与“卡上已删”。对应功能列表 F-02、F-03、F-06 和 §5.6。
@Suite struct ScanTests {
    let dateA = "2026-08-12 10:00:01"
    let dateB = "2026-08-12 10:00:02"
    let dateC = "2026-08-13 09:30:00"

    @Test func importsAndGroupsRawWithJpeg() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/100MSDCF/notes.txt", date: nil)

        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.isComplete)
        #expect(summary.added == 3)
        #expect(summary.newPhotos == 2)
        let photos = try temp.reader.photos(in: .all)
        #expect(photos.map(\.baseName) == ["DSC00002", "DSC00001"])
        #expect(photos[1].hasRaw && photos[1].hasJPEG)
        #expect(!photos[0].hasRaw && photos[0].hasJPEG)
        #expect(photos.allSatisfy { $0.isOnCard })
        #expect(try temp.reader.presentLocationCount(of: photos[1].id) == 2)
        #expect(try temp.reader.card().lastScannedAt != nil)
        #expect(try temp.expectConsistentCounts())
    }

    /// 只扫 `DCIM`：视频（`PRIVATE/M4ROOT`）和卡根目录下的其他文件不看（F-02）。
    @Test func onlyScansDCIM() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", date: dateB)
        try card.put("DSC09999.JPG", date: dateC)
        let reader = FakeMetadataReader()
        let summary = try await temp.scanner(reader: reader).scan(cardURL: card.root)
        #expect(summary.isComplete)
        #expect(reader.readNames == ["DSC00001.JPG"])
        #expect(try temp.reader.photos(in: .all).map(\.baseName) == ["DSC00001"])
    }

    /// 相机型号不是 A7C II 的跳过、计数，不进库（F-02）。
    @Test func skipsOtherCameras() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/100MSDCF/DSC00003.JPG", date: dateC)
        let reader = FakeMetadataReader(otherCameraNames: ["DSC00002.JPG"])
        let summary = try await temp.scanner(reader: reader).scan(cardURL: card.root)
        #expect(summary.isComplete)
        #expect(summary.otherCamera == 1)
        #expect(summary.newPhotos == 2)
        #expect(try temp.reader.photos(in: .all).map(\.baseName) == ["DSC00003", "DSC00001"])
    }

    @Test func rescanSkipsUnchangedFiles() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        for index in 1...7 {
            try card.put("DCIM/100MSDCF/DSC0000\(index).JPG", date: "2026-08-12 10:00:0\(index)")
        }
        let reader = FakeMetadataReader()
        try await temp.scanner(reader: reader).scan(cardURL: card.root)
        #expect(reader.readNames.count == 7)

        reader.resetReads()
        try card.put("DCIM/100MSDCF/DSC00008.JPG", date: "2026-08-12 10:00:08")
        let summary = try await temp.scanner(reader: reader).scan(cardURL: card.root)
        #expect(reader.readNames == ["DSC00008.JPG"])
        #expect(summary.unchanged == 7)
        #expect(summary.added == 1)
        #expect(summary.newPhotos == 1)

        reader.resetReads()
        let quiet = try await temp.scanner(reader: reader).scan(cardURL: card.root)
        #expect(reader.readNames.isEmpty)
        #expect(quiet.importBatchID == nil)
    }

    /// 在相机里删了：照片标“卡上已删”，照常显示，星级还在（F-06）。
    @Test func missingFileIsMarkedAndKeepsRating() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await temp.scanner().scan(cardURL: card.root)
        let first = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(4, for: [first])

        try card.remove("DCIM/100MSDCF/DSC00001.JPG")
        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.vanished == 1)
        let photos = try temp.reader.photos(in: .all)
        #expect(photos.map(\.baseName) == ["DSC00002", "DSC00001"])
        #expect(photos.map(\.isOnCard) == [true, false])
        #expect(try temp.reader.missingFromCardPhotoIDs() == [first])
        #expect(try temp.reader.cardStats().missingFromCardCount == 1)
        #expect(try temp.reader.rating(of: first) == 4)
        #expect(try temp.reader.locations(relativePath: "DCIM/100MSDCF/DSC00001.JPG").map(\.status) == ["historical"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 原样放回：大小和修改时间都和删掉前一样，也必须恢复成“在卡上”。
    @Test func fileRestoredUnchangedIsOnCardAgain() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        let mtime = try card.put(path, date: dateA)
        try await temp.scanner().scan(cardURL: card.root)
        let photo = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(5, for: [photo])

        try card.remove(path)
        try await temp.scanner().scan(cardURL: card.root)
        #expect(try temp.reader.missingFromCardPhotoIDs() == [photo])

        try card.put(path, date: dateA, mtime: mtime)
        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.restored == 1)
        #expect(summary.added == 0)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [photo])
        #expect(try temp.reader.missingFromCardPhotoIDs().isEmpty)
        #expect(try temp.reader.rating(of: photo) == 5)
        #expect(try temp.reader.locations(relativePath: path).map(\.status) == ["present"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 同一路径换了照片（格式化后编号重置）：旧照片标“卡上已删”，新照片不继承旧星级。
    @Test func samePathNewPhotoDoesNotInheritRating() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        try card.put(path, date: dateA)
        try await temp.scanner().scan(cardURL: card.root)
        let old = try #require(try temp.photoID("DSC00001", dateA))
        try temp.library.setRating(5, for: [old])

        try card.put(path, date: dateC)
        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.replaced == 1)
        let new = try #require(try temp.photoID("DSC00001", dateC))
        #expect(new != old)
        #expect(try temp.reader.rating(of: new) == 0)
        #expect(try temp.reader.rating(of: old) == 5)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [new, old])
        #expect(try temp.reader.missingFromCardPhotoIDs() == [old])
        #expect(try temp.reader.locations(relativePath: path).map(\.status) == ["historical", "present"])
        #expect(try temp.expectConsistentCounts())

        // 旧照片又放回这个路径：新照片的位置变历史，旧照片恢复，星级还在。
        try card.put(path, date: dateA)
        let back = try await temp.scanner().scan(cardURL: card.root)
        #expect(back.replaced == 1 && back.restored == 1)
        #expect(try temp.reader.missingFromCardPhotoIDs() == [new])
        #expect(try temp.reader.rating(of: old) == 5)
        #expect(try temp.expectConsistentCounts())
    }

    /// 没清卡就插了另一张卡（或格式化过的同一张）：新照片导入，旧照片都标“卡上已删”（功能列表 §5.6）。
    @Test func anotherCardMarksOldPhotosMissing() async throws {
        let temp = try TemporaryLibrary()
        let first = try FakeCard()
        try first.put("DCIM/100MSDCF/DSC00001.ARW", date: dateA)
        try first.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try first.put("DCIM/100MSDCF/DSC00002.JPG", date: dateB)
        try await temp.scanner().scan(cardURL: first.root)
        let old = try temp.reader.photos(in: .all).map(\.id)
        try temp.library.setRating(3, for: old)

        let second = try FakeCard()
        try second.put("DCIM/100MSDCF/DSC00001.JPG", date: dateC)
        let summary = try await temp.scanner().scan(cardURL: second.root)

        #expect(summary.isComplete)
        #expect(summary.newPhotos == 1)
        // DSC00001.JPG 同一路径换了照片；旧的 ARW 和 DSC00002 不见了。
        #expect(summary.replaced == 1)
        #expect(summary.vanished == 2)
        let photos = try temp.reader.photos(in: .all)
        #expect(photos.count == 3)
        #expect(Set(try temp.reader.missingFromCardPhotoIDs()) == Set(old))
        #expect(photos.filter(\.isOnCard).map(\.captureDate) == [dateC])
        #expect(try temp.reader.rating(of: old[0]) == 3)
        #expect(try temp.expectConsistentCounts())
    }

    @Test func deletedSubdirectoryIsMarkedMissing() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/101MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/101MSDCF/deep/DSC00003.JPG", date: dateC)
        try await temp.scanner().scan(cardURL: card.root)
        #expect(try temp.reader.photoCount() == 3)
        #expect(Set(try temp.reader.scanDirectoryStates().keys)
            == ["DCIM", "DCIM/100MSDCF", "DCIM/101MSDCF", "DCIM/101MSDCF/deep"])

        try FileManager.default.removeItem(at: card.url("DCIM/101MSDCF"))
        let summary = try await temp.scanner().scan(cardURL: card.root)

        #expect(summary.vanished == 2)
        #expect(summary.isComplete)
        #expect(try temp.reader.photos(in: .all).filter(\.isOnCard).map(\.baseName) == ["DSC00001"])
        #expect(try temp.reader.missingFromCardPhotoIDs().count == 2)
        #expect(Set(try temp.reader.scanDirectoryStates().keys) == ["DCIM", "DCIM/100MSDCF"])
        #expect(try temp.expectConsistentCounts())
    }

    /// 扫描中断：两个子目录，在第二个子目录前中断（拔卡、切后台）。
    /// 没读到的部分照片、位置、收藏夹都不变，卡不记为扫完；下次续扫。
    @Test(arguments: [InterruptingLister.Mode.cancel, .throwError])
    func interruptedScanKeepsUnreadDirectories(mode: InterruptingLister.Mode) async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/101MSDCF/DSC00002.JPG", date: dateB)
        try card.put("DCIM/101MSDCF/DSC00003.JPG", date: dateC)
        try await temp.scanner().scan(cardURL: card.root)
        let firstScan = try #require(try temp.reader.card().lastScannedAt)
        let second = try #require(try temp.photoID("DSC00002", dateB))
        let collection = try temp.library.createCollection(name: "精选")
        try temp.library.addPhotos([second], to: collection)
        try temp.library.setRating(3, for: [second])

        // 卡上 101 里的文件其实已经删了，但这次扫描到不了那里，不能下结论。
        try card.remove("DCIM/101MSDCF/DSC00002.JPG")
        try card.remove("DCIM/101MSDCF/DSC00003.JPG")
        let flag = CancelFlag()
        let lister = InterruptingLister(failingDirectory: "DCIM/101MSDCF", mode: mode, cancelFlag: flag)
        let summary = try await temp.scanner(lister: lister).scan(cardURL: card.root, isCancelled: { flag.isCancelled })

        #expect(!summary.isComplete)
        #expect(summary.vanished == 0)
        #expect(summary.incompleteDirectories.keys.contains("DCIM/101MSDCF"))
        #expect(try temp.reader.missingFromCardPhotoIDs().isEmpty)
        #expect(try temp.reader.collectionMembers(collection) == [second])
        #expect(try temp.reader.rating(of: second) == 3)
        #expect(try temp.reader.locations(relativePath: "DCIM/101MSDCF/DSC00002.JPG").map(\.status) == ["present"])
        #expect(try temp.reader.scanDirectoryStates()["DCIM/101MSDCF"] == "incomplete")
        #expect(try temp.reader.scanDirectoryStates()["DCIM/100MSDCF"] == "complete")
        #expect(try temp.reader.card().lastScannedAt == firstScan)
        #expect(try temp.reader.cardStats().incompleteDirectoryCount == 1)
        #expect(try temp.expectConsistentCounts())

        // 下次完整扫完，才确认那两个文件确实不在了。
        let resumed = try await temp.scanner().scan(cardURL: card.root)
        #expect(resumed.isComplete)
        #expect(resumed.vanished == 2)
        #expect(try temp.reader.missingFromCardPhotoIDs().count == 2)
        #expect(try temp.reader.collectionMembers(collection) == [second])
        #expect(try temp.reader.cardStats().incompleteDirectoryCount == 0)
    }

    /// 上级目录读不了时，它下面的已知子目录也不下结论。
    @Test func unreadableParentKeepsDescendants() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try card.put("DCIM/100MSDCF/sub/DSC00002.JPG", date: dateB)
        try await temp.scanner().scan(cardURL: card.root)

        let lister = InterruptingLister(failingDirectory: "DCIM/100MSDCF", mode: .throwError, cancelFlag: CancelFlag())
        let summary = try await temp.scanner(lister: lister).scan(cardURL: card.root)

        #expect(!summary.isComplete)
        #expect(Set(summary.incompleteDirectories.keys) == ["DCIM/100MSDCF", "DCIM/100MSDCF/sub"])
        #expect(try temp.reader.missingFromCardPhotoIDs().isEmpty)
    }

    /// 卡拔了（DCIM 列不出来）：什么都不下结论。
    @Test func unpluggedCardChangesNothing() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        try card.put("DCIM/100MSDCF/DSC00001.JPG", date: dateA)
        try await temp.scanner().scan(cardURL: card.root)

        let summary = try await temp.scanner().scan(cardURL: card.root.appendingPathComponent("not-mounted"))
        #expect(!summary.isComplete)
        #expect(summary.vanished == 0)
        #expect(try temp.reader.missingFromCardPhotoIDs().isEmpty)
        #expect(try temp.reader.scanDirectoryStates()["DCIM"] == "incomplete")
    }

    /// 读文件时出错（比如读到一半拔卡）不能当成“没有拍摄时间”，否则会误判成同一路径换了照片。
    @Test func unreadableFileLeavesDirectoryIncomplete() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let path = "DCIM/100MSDCF/DSC00001.JPG"
        try card.put(path, date: dateA)
        try await temp.scanner().scan(cardURL: card.root)
        let photo = try #require(try temp.photoID("DSC00001", dateA))

        try card.put(path, date: dateA)  // 修改时间变了，要重读
        let summary = try await temp.scanner(reader: FakeMetadataReader(failingNames: ["DSC00001.JPG"]))
            .scan(cardURL: card.root)

        #expect(!summary.isComplete)
        #expect(summary.replaced == 0)
        #expect(try temp.reader.photos(in: .all).map(\.id) == [photo])
        #expect(try temp.reader.missingFromCardPhotoIDs().isEmpty)
        #expect(try temp.reader.scanDirectoryStates()["DCIM/100MSDCF"] == "incomplete")
    }
}
