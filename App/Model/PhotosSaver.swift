import Foundation
import Photos
import PhotoAICore

/// 存到“照片”App（F-33）：一张一张先用导出的那套复制到临时文件夹（流式、卡拔了停下），再交给“照片”，存好了才记“导出过”。
/// JPEG（或 HEIF）是照片本身；选“RAW + JPEG”时 ARW 作为同一张照片的 RAW 一起存；只有 RAW 的照片存 RAW。
/// 只申请“添加照片”的权限。不像文件夹那样能按名字认出存过的，同一张再存会多一份。
enum PhotosSaver {
    /// 没问过就问一次。返回能不能存。
    static func requestAuthorization() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: true
        case .notDetermined: [.authorized, .limited].contains(await PHPhotoLibrary.requestAuthorization(for: .addOnly))
        default: false
        }
    }

    static func run(
        _ photoIDs: [PhotoID], files: ExportRequest.Files, library: Library, cardRoot: URL,
        isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (ExportProgress) -> Void
    ) async -> ExportReport {
        let started = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("存到照片", isDirectory: true)
        var report = ExportReport(destination: root)
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var exporter = Exporter(library: library, finder: OriginalFinder(root: cardRoot))
        exporter.marksExported = false

        for (index, photoID) in photoIDs.enumerated() {
            if isCancelled() {
                report.cancelled = true
                report.notAttempted = photoIDs.count - index
                break
            }
            let folder = root.appendingPathComponent("\(index)", isDirectory: true)
            let bytesBefore = report.bytesCopied
            let one: ExportReport
            do {
                one = try exporter.run(
                    ExportRequest(photoIDs: [photoID], files: files, destination: folder), isCancelled: isCancelled,
                    progress: { step in
                        progress(ExportProgress(photosDone: index, photoTotal: photoIDs.count, bytesCopied: bytesBefore, fileName: step.fileName))
                    }
                )
            } catch {
                report.stoppedBy = "导出出错：\(error)"
                report.notAttempted = photoIDs.count - index
                break
            }
            report.copiedFiles += one.copiedFiles
            report.bytesCopied += one.bytesCopied
            report.usedOtherKind += one.usedOtherKind
            report.skippedMissingPhotos += one.skippedMissingPhotos
            report.newlyMissingPhotoIDs += one.newlyMissingPhotoIDs
            report.failures += one.failures
            if one.cancelled || one.stoppedBy != nil {
                report.cancelled = one.cancelled
                report.stoppedBy = one.stoppedBy
                report.notAttempted = photoIDs.count - index
                break
            }
            guard !one.exportedPhotoIDs.isEmpty else { continue }
            do {
                try await save(folder)
                try library.markExported([photoID])
                report.exportedPhotoIDs.append(photoID)
            } catch {
                // 存不进“照片”多半是权限或空间，后面的也存不进：整批停下。
                report.stoppedBy = "存不进“照片”：\(error.localizedDescription)"
                report.notAttempted = photoIDs.count - index
                break
            }
            try? FileManager.default.removeItem(at: folder)
        }
        progress(ExportProgress(
            photosDone: photoIDs.count - report.notAttempted, photoTotal: photoIDs.count, bytesCopied: report.bytesCopied, fileName: ""
        ))
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    /// 文件夹里一张照片的文件（RAW、JPEG 或两者）存成“照片”里的一张。
    private static func save(_ folder: URL) async throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        let urls = names.map { folder.appendingPathComponent($0) }
        let raw = urls.first { FileKind(extension: $0.pathExtension) == .raw }
        let picture = urls.first { FileKind(extension: $0.pathExtension).map { $0 != .raw } ?? false }
        guard let primary = picture ?? raw else { return }
        let alternate = picture == nil ? nil : raw
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.originalFilename = primary.lastPathComponent
            request.addResource(with: .photo, fileURL: primary, options: options)
            if let alternate {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.shouldMoveFile = true
                rawOptions.originalFilename = alternate.lastPathComponent
                request.addResource(with: .alternatePhoto, fileURL: alternate, options: rawOptions)
            }
        }
    }
}
