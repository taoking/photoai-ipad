import CoreImage
import Foundation
import Observation
import PhotoAICore
import Synchronization
import UIKit

/// 读卡导入：扫描和生成预览同时跑，网格边扫边出现、预览边做边出（F-03、F-04、F-05）。
///
/// 导入时屏幕不自动锁。切到后台、拔卡时停下（扫描把没扫完的目录记下来，预览保持 pending），
/// 回到前台、重新插上再调 `start` 就是续做：没变的文件不再读 EXIF，做好的预览不再做。
@MainActor @Observable
final class ImportController {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        /// 中途停下的原因：切到后台、卡拔了、写不进本机。
        case stopped(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var scan = ScanSummary()
    private(set) var isScanFinished = false
    private(set) var previewsMade = 0
    private(set) var previewsFailed = 0
    /// 开始时卡上还没做预览的张数（扫描中会变多）。
    private(set) var previewsPending = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    var isRunning: Bool { phase == .running }

    /// 进度变了（节流后），模型据此刷新网格和概况。
    @ObservationIgnored var onProgress: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stopFlag: StopFlag?
    @ObservationIgnored private var lastProgressAt = Date.distantPast
    @ObservationIgnored private var didLogRawSample = false

    private let library: Library

    init(library: Library) {
        self.library = library
    }

    /// 开始（或续做）一次导入。`access` 由这里负责 `stop()`。
    func start(access: CardConnection.Access, previewConcurrency: Int) {
        guard !isRunning else {
            access.stop()
            return
        }
        let flag = StopFlag()
        stopFlag = flag
        phase = .running
        scan = ScanSummary()
        isScanFinished = false
        previewsMade = 0
        previewsFailed = 0
        previewsPending = (try? library.reader.pendingPreviewCount()) ?? 0
        startedAt = Date()
        finishedAt = nil
        UIApplication.shared.isIdleTimerDisabled = true
        appLog("导入开始：预览 \(previewConcurrency) 并发，待做预览 \(previewsPending) 张；\(MemoryProbe.describe())")

        let library = library
        let root = access.root
        task = Task {
            let started = DispatchTime.now().uptimeNanoseconds
            let elapsed: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
            let scanDone = Locked(false)
            let heartbeat = Task.detached {
                // 每 30 秒记一次内存和温度（PF-5、PF-13 的证据）。
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { break }
                    appLog(String(format: "导入进行中（%.0f 秒）：%@", elapsed(), MemoryProbe.describe()))
                }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        let summary = try await CardScanner(library: library).scan(
                            cardURL: root,
                            isCancelled: { flag.isStopped },
                            progress: { summary in Task { @MainActor in self.scanProgressed(summary) } }
                        )
                        await self.scanFinished(summary, seconds: elapsed())
                    } catch {
                        flag.stop("扫描写库出错：\(error)")
                    }
                    scanDone.set(true)
                }
                group.addTask {
                    await Self.makePreviews(
                        library: library, root: root, concurrency: previewConcurrency, flag: flag,
                        scanDone: { scanDone.value },
                        progress: { made, failed in Task { @MainActor in self.previewsProgressed(made: made, failed: failed) } }
                    )
                }
            }
            heartbeat.cancel()
            finish(reason: flag.reason, seconds: elapsed())
            access.stop()
        }
    }

    /// 停下正在做的导入，等它收好尾（扫描记下没扫完的目录）。
    func stop(reason: String) async {
        guard let task, isRunning else { return }
        stopFlag?.stop(reason)
        await task.value
    }

    // MARK: - 预览循环

    /// 扫描还在进行时，新照片不断进库：一轮做完就等一秒再看，直到扫描结束而且没有能做的了。
    nonisolated private static func makePreviews(
        library: Library,
        root: URL,
        concurrency: Int,
        flag: StopFlag,
        scanDone: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async {
        let runner = PreviewRunner(generator: PreviewGenerator(library: library), concurrency: concurrency)
        var made = 0
        var failed = 0
        while !flag.isStopped {
            let scanWasDone = scanDone()
            let base = (made, failed)
            do {
                let result = try await runner.run(cardURL: root, shouldStop: { flag.isStopped }) { current in
                    progress(base.0 + current.ready, base.1 + current.failed)
                }
                made += result.ready
                failed += result.failed
                if let writeError = result.writeError {
                    flag.stop(writeError)
                    break
                }
                if result.ready + result.failed == 0 {
                    if scanWasDone { break }
                    // 等扫描进新照片：最多一秒，扫描结束了马上再看一轮。
                    for _ in 0..<10 where !scanDone() && !flag.isStopped {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            } catch {
                flag.stop("预览写库出错：\(error)")
                break
            }
        }
        progress(made, failed)
    }

    // MARK: - 进度

    private func scanProgressed(_ summary: ScanSummary) {
        guard isRunning, !isScanFinished else { return }
        scan = summary
        notifyThrottled()
    }

    private func previewsProgressed(made: Int, failed: Int) {
        guard isRunning else { return }
        previewsMade = max(previewsMade, made)
        previewsFailed = max(previewsFailed, failed)
        notifyThrottled()
    }

    private func notifyThrottled() {
        // 网格重读 1 万条要几十毫秒，导入时 1.5 秒最多刷新一次。
        guard Date().timeIntervalSince(lastProgressAt) > 1.5 else { return }
        lastProgressAt = Date()
        previewsPending = (try? library.reader.pendingPreviewCount()) ?? previewsPending
        onProgress?()
    }

    private func scanFinished(_ summary: ScanSummary, seconds: Double) {
        scan = summary
        isScanFinished = true
        let incomplete = summary.incompleteDirectories.map { "\($0.key)（\($0.value)）" }.sorted().joined(separator: "，")
        appLog(String(
            format: "扫描结束 %.1f 秒：看了 %d 个文件，未变 %d，读 EXIF %d（新增位置 %d、更新 %d、放回 %d、换了照片 %d），新照片 %d，卡上已删 %d，别的相机 %d，%@；%@",
            seconds, summary.filesSeen, summary.unchanged, summary.filesSeen - summary.unchanged,
            summary.added, summary.updated, summary.restored, summary.replaced, summary.newPhotos, summary.vanished,
            summary.otherCamera, summary.isComplete ? "全部扫完" : "没扫完：\(incomplete)", MemoryProbe.describe()
        ))
        previewsPending = (try? library.reader.pendingPreviewCount()) ?? previewsPending
        onProgress?()
        logRawSampleOnce()
    }

    private func finish(reason: String?, seconds: Double) {
        UIApplication.shared.isIdleTimerDisabled = false
        finishedAt = Date()
        phase = reason.map(Phase.stopped) ?? .finished
        previewsPending = (try? library.reader.pendingPreviewCount()) ?? 0
        let perPhoto = previewsMade > 0 ? String(format: "，折合每张 %.0f ms（含扫描时间）", seconds * 1000 / Double(previewsMade)) : ""
        appLog(String(
            format: "导入%@ %.1f 秒：预览做好 %d 张、失败 %d 张%@，还剩 %d 张；%@",
            reason.map { "停下（\($0)）" } ?? "结束", seconds, previewsMade, previewsFailed, perPhoto, previewsPending,
            MemoryProbe.describe()
        ))
        onProgress?()
    }

    /// 开发计划 M1：只有 ARW 时照片尺寸该取 EXIF 的 PixelXDimension 还是 CIRAWFilter.nativeSize，抽一个 ARW 记下来比对。
    private func logRawSampleOnce() {
        guard !didLogRawSample, let path = try? library.reader.presentFilePaths(kind: .raw, limit: 1).first,
              let card = (try? library.reader.card())?.bookmark,
              case .success(let (access, _)) = CardConnection.open(card) else { return }
        didLogRawSample = true
        Task.detached {
            defer { access.stop() }
            let url = access.root.appendingPathComponent(path)
            let fields = ImageIOMetadataReader.identityFields(at: url)
            let native = CIRAWFilter(imageURL: url)?.nativeSize
            let metadata = try? ImageIOMetadataReader().metadata(at: url)
            appLog("ARW 尺寸抽样 \(path)：文件头 \(fields["PixelWidth"] ?? "?")×\(fields["PixelHeight"] ?? "?")，"
                + "EXIF \(fields["Exif.PixelXDimension"] ?? "无")×\(fields["Exif.PixelYDimension"] ?? "无")，方向 \(fields["Orientation"] ?? "?")，"
                + "CIRAWFilter \(native.map { "\(Int($0.width))×\(Int($0.height))" } ?? "打不开")，记进库的 \(metadata?.width ?? 0)×\(metadata?.height ?? 0)")
        }
    }
}

/// 停下的开关和原因。扫描、预览的 `isCancelled` 都看它。
final class StopFlag: Sendable {
    private let value = Mutex<String?>(nil)

    var isStopped: Bool { value.withLock { $0 != nil } }
    var reason: String? { value.withLock { $0 } }

    /// 只记第一次的原因。
    func stop(_ reason: String) {
        value.withLock { if $0 == nil { $0 = reason } }
    }
}

/// 加锁的一个值，跨任务共享用。
final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value { storage.withLock { $0 } }
    func set(_ newValue: Value) { storage.withLock { $0 = newValue } }
}
