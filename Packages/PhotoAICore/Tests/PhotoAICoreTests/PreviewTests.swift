// 搬自 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/PreviewTests.swift。改了：只有一张卡；预览 ARW 内嵌图优先（F-04），
// 照片尺寸以 JPG 为准；去掉旧库尺寸校正的用例。
import Foundation
import Testing
@testable import PhotoAICore

/// 预览生成与“预览就绪”。对应功能列表 F-04。
@Suite struct PreviewTests {
    /// 一张真实 JPEG 卡：`count` 张横拍照片，可选每张配一个假的 ARW（同一张 JPEG 改名）。
    func makeCard(count: Int, withRaw: Bool = false) throws -> FakeCard {
        let card = try FakeCard()
        for index in 1...count {
            let name = String(format: "DSC%05d", index)
            let date = String(format: "2026:08:12 10:00:%02d", index)
            try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/\(name).JPG"), width: 2400, height: 1600, captureDate: date)
            if withRaw {
                // 用同一张 JPEG 冒充 RAW，让它有同样的拍摄时间、能合组。
                try FileManager.default.copyItem(at: card.url("DCIM/100MSDCF/\(name).JPG"), to: card.url("DCIM/100MSDCF/\(name).ARW"))
            }
        }
        return card
    }

    func importCard(_ card: FakeCard, into temp: TemporaryLibrary) async throws {
        try await CardScanner(library: temp.library).scan(cardURL: card.root)
    }

    @Test func generatesBothSizesAndCountsReady() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 3)
        try await importCard(card, into: temp)
        #expect(try temp.reader.cardStats().photoCount == 3)
        #expect(try temp.reader.cardStats().previewReadyCount == 0)
        #expect(try temp.reader.cardStats().previewPendingCount == 3)

        let generator = PreviewGenerator(library: temp.library)
        let progress = try await PreviewRunner(generator: generator).run(cardURL: card.root)
        #expect(progress.ready == 3)
        #expect(try temp.reader.pendingPreviewCount() == 0)

        let ids = try temp.reader.photos(in: .all).map(\.id)
        for id in ids {
            let thumb = try #require(ImageDownsampler.image(at: generator.store.url(for: id, size: .thumb), maximumPixelSize: 5000))
            let preview = try #require(ImageDownsampler.image(at: generator.store.url(for: id, size: .preview), maximumPixelSize: 5000))
            #expect(max(thumb.width, thumb.height) == 480)
            #expect(max(preview.width, preview.height) == 1600)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: generator.store.temporaryDirectory.path)) ?? []
        #expect(leftovers.isEmpty)

        // 拔卡：用实际能解码的图片数核对“预览就绪”，照片照常显示。
        try FileManager.default.removeItem(at: card.root)
        #expect(try generator.audit(photoIDs: ids) == 3)
        #expect(try temp.reader.cardStats().previewReadyCount == 3)
        #expect(try temp.reader.photos(in: .all).count == 3)
    }

    /// F-04：RAW + JPEG 的照片用 ARW 内嵌图生成预览。
    @Test func prefersRawEmbeddedPreview() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 1, withRaw: true)
        try await importCard(card, into: temp)
        let photo = try #require(try temp.reader.photos(in: .all).first)
        #expect(photo.hasRaw && photo.hasJPEG)

        let job = try #require(try temp.reader.photosNeedingPreviews(limit: 10).first)
        #expect(job.sources.map(\.kind) == [.raw, .jpeg])
        try await PreviewRunner(generator: PreviewGenerator(library: temp.library)).run(cardURL: card.root)
        let rawFile = try temp.library.db.scalarInt("SELECT id FROM files WHERE kind = 'raw';")
        #expect(try temp.library.db.scalarInt("SELECT preview_file_id FROM photos WHERE id = ?;", [photo.id]) == rawFile)
    }

    /// ARW 读不出内嵌图（坏文件）时退到 JPG。
    @Test func fallsBackToJPEGWhenRawIsUnreadable() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let date = "2026:08:12 10:00:01"
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.JPG"), width: 2400, height: 1600, captureDate: date)
        try await importCard(card, into: temp)
        // 扫描以后才把 ARW 换成坏文件，让它已经合进这张照片。
        try FileManager.default.copyItem(at: card.url("DCIM/100MSDCF/DSC00001.JPG"), to: card.url("DCIM/100MSDCF/DSC00001.ARW"))
        try await importCard(card, into: temp)
        try Data("not an image".utf8).write(to: card.url("DCIM/100MSDCF/DSC00001.ARW"))

        let progress = try await PreviewRunner(generator: PreviewGenerator(library: temp.library)).run(cardURL: card.root)
        #expect(progress.ready == 1)
        let jpegFile = try temp.library.db.scalarInt("SELECT id FROM files WHERE kind = 'jpeg';")
        #expect(try temp.library.db.scalarInt("SELECT preview_file_id FROM photos;") == jpegFile)
    }

    /// 机内 16:9 裁切：RAW 是 3:2，JPEG 是 16:9。照片尺寸以 JPEG 为准，ARW 生成预览也不改（iPadOS 读不出 ARW 的真实尺寸）。
    @Test func dimensionsFollowJPEG() async throws {
        let temp = try TemporaryLibrary()
        let card = try FakeCard()
        let date = "2026:08:12 10:00:01"
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.ARW"), width: 2400, height: 1600, captureDate: date)
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00001.JPG"), width: 2400, height: 1350, captureDate: date)
        try SampleImages.writeJPEG(to: card.url("DCIM/100MSDCF/DSC00002.ARW"), width: 2400, height: 1600, captureDate: "2026:08:12 10:00:02")
        try await importCard(card, into: temp)
        let scanned = try temp.reader.photos(in: .all)
        #expect(scanned.map(\.baseName) == ["DSC00002", "DSC00001"])
        #expect(scanned[1].width == 2400 && scanned[1].height == 1350)
        #expect(scanned[0].width == 2400 && scanned[0].height == 1600)

        try await PreviewRunner(generator: PreviewGenerator(library: temp.library)).run(cardURL: card.root)
        let ready = try temp.reader.photos(in: .all)
        #expect(ready[1].width == 2400 && ready[1].height == 1350)
        #expect(ready[0].width == 2400 && ready[0].height == 1600)
    }

    /// 生成中拔卡：读不到来源的照片保持 pending；重新插上后续做。
    @Test func unplugDuringGenerationResumesLater() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 2)
        try await importCard(card, into: temp)
        let runner = PreviewRunner(generator: PreviewGenerator(library: temp.library))

        let gone = card.root.appendingPathComponent("not-mounted")
        let first = try await runner.run(cardURL: gone)
        #expect(first.ready == 0 && first.unavailable == 2)
        #expect(try temp.reader.pendingPreviewCount() == 2)

        let second = try await runner.run(cardURL: card.root)
        #expect(second.ready == 2)
        #expect(try temp.reader.pendingPreviewCount() == 0)
    }

    /// 卡上已删的照片没有来源，不排进预览队列，也不算“待做”。
    @Test func photosMissingFromCardAreNotQueued() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 2)
        try await importCard(card, into: temp)
        try card.remove("DCIM/100MSDCF/DSC00001.JPG")
        try await importCard(card, into: temp)

        #expect(try temp.reader.photosNeedingPreviews(limit: 10).count == 1)
        let stats = try temp.reader.cardStats()
        #expect(stats.previewPendingCount == 1)
        #expect(stats.missingFromCardCount == 1)
    }

    /// 中途退出 / 文件丢失：重启时发现 `ready` 但文件不在，改回 pending，再次插上时补做缺的那一档。
    @Test func missingPreviewFileIsDetectedOnLaunch() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 2)
        try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        try await PreviewRunner(generator: generator).run(cardURL: card.root)
        let photo = try #require(try temp.reader.photos(in: .all).first?.id)

        try FileManager.default.removeItem(at: generator.store.url(for: photo, size: .thumb))
        // 中途退出留下的临时文件。
        try FileManager.default.createDirectory(at: generator.store.temporaryDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: generator.store.temporaryDirectory.appendingPathComponent("x.jpg"))

        #expect(try generator.verifyReadyFiles() == 1)
        #expect(!FileManager.default.fileExists(atPath: generator.store.temporaryDirectory.path))
        #expect(try temp.reader.cardStats().previewReadyCount == 1)
        let job = try #require(try temp.reader.photosNeedingPreviews(limit: 10).first)
        #expect(job.photoID == photo && job.needsThumb && !job.needsPreview)

        try await PreviewRunner(generator: generator).run(cardURL: card.root)
        #expect(try temp.reader.cardStats().previewReadyCount == 2)
    }

    /// 预览文件损坏（能找到但解码不了）：核对时改回 pending。
    @Test func corruptPreviewIsResetByAudit() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 1)
        try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        try await PreviewRunner(generator: generator).run(cardURL: card.root)
        let photo = try #require(try temp.reader.photos(in: .all).first?.id)

        try Data("garbage".utf8).write(to: generator.store.url(for: photo, size: .preview))
        #expect(try generator.audit(photoIDs: [photo]) == 0)
        #expect(try temp.reader.cardStats().previewReadyCount == 0)
    }

    /// 写不进本机（模拟盘满）：状态保持 pending，队列停下并报告原因。
    @Test func writeFailureStopsQueueAndKeepsPending() async throws {
        let temp = try TemporaryLibrary()
        let card = try makeCard(count: 3)
        try await importCard(card, into: temp)
        let generator = PreviewGenerator(library: temp.library)
        // 在临时目录的位置放一个普通文件，目录建不出来，写入必然失败。
        try FileManager.default.createDirectory(at: generator.store.root, withIntermediateDirectories: true)
        try Data().write(to: generator.store.temporaryDirectory)

        let progress = try await PreviewRunner(generator: generator, concurrency: 1).run(cardURL: card.root)
        #expect(progress.writeError != nil)
        #expect(progress.ready == 0)
        #expect(try temp.reader.pendingPreviewCount() == 3)

        try FileManager.default.removeItem(at: generator.store.temporaryDirectory)
        let retry = try await PreviewRunner(generator: generator).run(cardURL: card.root)
        #expect(retry.ready == 3)
    }

    @Test func previewDirectoryIsExcludedFromBackup() throws {
        let temp = try TemporaryLibrary()
        try temp.library.paths.preparePreviewDirectory()
        let values = try temp.library.paths.previews.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
