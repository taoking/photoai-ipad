import Foundation
import Observation
import PhotoAICore
import Synchronization
import UIKit

/// 导出到文件夹（F-30 – F-32）或存到“照片”（F-33）：在后台一张一张流式复制，进度和结果给导出面板显示，耗时、速度、内存记进日志（PF-9）。
///
/// 导出时屏幕常亮。张数多时申请系统的“继续处理任务”（F-07），批了的话切到后台接着导，系统显示进度；
/// 没批（或张数少）切到后台系统给的时间用完就停下（停在一个文件之前），回来再导一次就是续传。
@MainActor @Observable
final class ExportController {
    enum Phase: Equatable {
        case idle
        case running
        case finished(ExportReport)
    }

    enum Target: String, CaseIterable {
        case folder
        /// “照片”App（F-33）。
        case photos

        var title: String {
            switch self {
            case .folder: "文件夹"
            case .photos: "“照片”App"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: ExportProgress?
    private(set) var startedAt: Date?
    /// 上次选的导出文件夹的名字（F-31 记住上次的）；nil 是还没选过或书签失效了。
    private(set) var folderName: String?
    var files: ExportRequest.Files {
        didSet { UserDefaults.standard.set(files.rawValue, forKey: DefaultsKey.exportFiles) }
    }
    var target: Target {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: DefaultsKey.exportTarget) }
    }
    /// 正在跑（或刚跑完）的这次导出到哪儿。
    private(set) var runningTarget: Target = .folder

    var isRunning: Bool { phase == .running }
    /// 导出完成后调（刷新网格：导出时发现卡上没了的照片变成“卡上已删”）。
    var onFinished: (() -> Void)?

    private let library: Library
    @ObservationIgnored private var cancelFlag = ExportCancelFlag()
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var continued: ContinuedProcessing?
    /// 这么多张以上才申请继续处理任务（M3：27 张 21 秒，少的切到后台系统给的时间够导完）。
    private static let continuedMinimumPhotos = 30

    init(library: Library) {
        self.library = library
        files = ExportRequest.Files(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.exportFiles) ?? "") ?? .both
        target = Target(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.exportTarget) ?? "") ?? .folder
        refreshFolderName()
    }

    // MARK: - 文件夹

    /// 选择器返回的文件夹：存下书签。
    func folderPicked(_ result: Result<URL, any Error>) -> String? {
        switch result {
        case .failure(let error):
            return "选文件夹失败：\(error.localizedDescription)"
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                try library.setExportFolderBookmark(bookmark)
                folderName = url.lastPathComponent
                appLog("选了导出文件夹：\(url.lastPathComponent)")
                return nil
            } catch {
                return "存不了这个文件夹的书签：\(error.localizedDescription)"
            }
        }
    }

    private func refreshFolderName() {
        guard let bookmark = try? library.reader.exportFolderBookmark() else {
            folderName = nil
            return
        }
        var stale = false
        folderName = (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?.lastPathComponent
    }

    // MARK: - 导出

    /// 算导出面板上的概况（多少张、几个文件、多大）。
    nonisolated func plan(_ photoIDs: [PhotoID], files: ExportRequest.Files, reader: LibraryReader) -> ExportPlan? {
        guard let sources = try? reader.presentSources(of: photoIDs) else { return nil }
        return ExportPlan(photoIDs: photoIDs, sources: sources, files: files)
    }

    /// 开始导出。`cardBookmark` 是卡的书签（导出要求卡连着）。返回错误时没开始。
    func start(_ photoIDs: [PhotoID], cardBookmark: Data) -> String? {
        guard !isRunning else { return "正在导出" }
        let target = target
        let folderBookmark = try? library.reader.exportFolderBookmark()
        if target == .folder, folderBookmark == nil { return "先选一个导出文件夹" }
        runningTarget = target
        let flag = ExportCancelFlag()
        cancelFlag = flag
        phase = .running
        progress = ExportProgress(photosDone: 0, photoTotal: photoIDs.count, bytesCopied: 0, fileName: "")
        startedAt = Date()
        KeepAwake.begin()
        if photoIDs.count >= Self.continuedMinimumPhotos {
            continued = ContinuedProcessing.start(
                name: "export", title: "PhotoAI 导出 \(photoIDs.count) 张", subtitle: "到\(target == .photos ? "“照片”" : "文件夹")"
            ) { [weak self] in
                // 系统收回了（时间到了、或用户点了停）：停在下一个文件之前，回来再导一次接着导。
                Task { @MainActor in self?.cancel() }
            }
            continued?.update(completed: 0, total: photoIDs.count, subtitle: "0 / \(photoIDs.count) 张")
        }
        // 继续处理任务批了就不要这个：它的时间一到会把导出停掉。
        if continued == nil {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "导出") { [weak self] in
                // 切到后台系统给的时间用完了：停在下一个文件之前，回来再导一次接着导。
                appLog("导出：切到后台的时间用完了，停下")
                self?.cancel()
            }
        }
        let files = files
        let library = library
        let destination = target == .photos ? "“照片”" : folderName ?? "?"
        appLog("导出开始：\(photoIDs.count) 张，文件 \(files.title)，到 \(destination)；\(MemoryProbe.describe())")

        Task { [weak self] in
            let report = await Task.detached(priority: .userInitiated) { [weak self] () -> Result<ExportReport, ExportStartError> in
                guard case .success(let (card, _)) = CardConnection.open(cardBookmark) else { return .failure(.message("卡没连接")) }
                defer { card.stop() }
                if target == .photos {
                    return .success(await PhotosSaver.run(
                        photoIDs, files: files, library: library, cardRoot: card.root, isCancelled: { flag.isCancelled },
                        progress: { progress in Task { @MainActor in self?.update(progress) } }
                    ))
                }
                guard let folderBookmark else { return .failure(.message("先选一个导出文件夹")) }
                var stale = false
                guard let folder = try? URL(resolvingBookmarkData: folderBookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                    return .failure(.message("导出文件夹找不到了，请重新选一个"))
                }
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                let exporter = Exporter(library: library, finder: OriginalFinder(root: card.root))
                do {
                    let report = try exporter.run(
                        ExportRequest(photoIDs: photoIDs, files: files, destination: folder),
                        isCancelled: { flag.isCancelled },
                        progress: { progress in Task { @MainActor in self?.update(progress) } }
                    )
                    return .success(report)
                } catch {
                    return .failure(.message("导出出错：\(error)"))
                }
            }.value
            self?.finish(report, total: photoIDs.count)
        }
        return nil
    }

    func cancel() {
        guard isRunning else { return }
        cancelFlag.cancel()
    }

    /// 看完结果，回到选项（关掉面板时）。
    func reset() {
        guard !isRunning else { return }
        phase = .idle
        progress = nil
    }

    private func update(_ progress: ExportProgress) {
        guard isRunning else { return }
        let previous = self.progress?.photosDone ?? 0
        self.progress = progress
        continued?.update(
            completed: progress.photosDone, total: progress.photoTotal,
            subtitle: String(format: "%d / %d 张，%.0f MB", progress.photosDone, progress.photoTotal, Double(progress.bytesCopied) / 1_000_000)
        )
        // 每 10 张记一次速度和内存（PF-9、PF-13：内存不随张数涨）。
        if progress.photosDone / 10 > previous / 10, let startedAt {
            let seconds = Date().timeIntervalSince(startedAt)
            appLog(String(format: "导出 %d / %d 张：已复制 %.0f MB，%.1f MB/s；%@", progress.photosDone, progress.photoTotal,
                          Double(progress.bytesCopied) / 1_000_000, Double(progress.bytesCopied) / 1_000_000 / max(seconds, 0.001),
                          MemoryProbe.describe()))
        }
    }

    private func finish(_ result: Result<ExportReport, ExportStartError>, total: Int) {
        KeepAwake.end()
        if case .success(let report) = result {
            continued?.finish(success: !report.cancelled && report.stoppedBy == nil)
        } else {
            continued?.finish(success: false)
        }
        continued = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        switch result {
        case .success(let report):
            phase = .finished(report)
            appLog(String(
                format: "导出结束 %.1f 秒：成功 %d 张（复制 %d 个文件 %.0f MB、同名跳过 %d 个），换了格式 %d 张，卡上已删 %d 张，"
                    + "失败 %d 个文件，没轮到 %d 张%@%@；%.1f MB/s；%@",
                report.elapsed, report.exportedPhotos, report.copiedFiles, Double(report.bytesCopied) / 1_000_000,
                report.alreadyExportedFiles, report.usedOtherKind,
                report.skippedMissingPhotos + report.newlyMissingPhotoIDs.count, report.failures.count, report.notAttempted,
                report.cancelled ? "，取消了" : "", report.stoppedBy.map { "，停下：\($0)" } ?? "",
                report.megabytesPerSecond, MemoryProbe.describe()
            ))
            for failure in report.failures.prefix(20) { appLog("导出失败 \(failure.name)：\(failure.reason)") }
        case .failure(.message(let message)):
            var report = ExportReport(destination: URL(fileURLWithPath: "/"))
            report.stoppedBy = message
            report.notAttempted = total
            phase = .finished(report)
            appLog("导出没开始：\(message)")
        }
        onFinished?()
    }
}

enum ExportStartError: Error {
    case message(String)
}

final class ExportCancelFlag: Sendable {
    private let value = Mutex(false)
    func cancel() { value.withLock { $0 = true } }
    var isCancelled: Bool { value.withLock { $0 } }
}

extension ExportRequest.Files {
    var title: String {
        switch self {
        case .raw: "RAW"
        case .jpeg: "JPEG"
        case .both: "RAW + JPEG"
        }
    }
}
