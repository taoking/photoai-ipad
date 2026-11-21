// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/VolumeScanner.swift。改了：只有一张卡，扫描根固定 `DCIM`；
// 只收相机型号 `ILCE-7CM2` 的照片，别的跳过并计数（功能列表 F-02）；去掉只扫一棵子树。
import Foundation

/// 一次扫描的结果与进度。
public struct ScanSummary: Sendable, Equatable {
    public var directoriesComplete = 0
    /// 没扫完的目录（相对卡根目录）与原因。
    public var incompleteDirectories: [String: String] = [:]
    public var filesSeen = 0
    /// 大小和修改时间都没变，没读 EXIF。
    public var unchanged = 0
    /// 读了 EXIF、身份没变，只更新大小或时间。
    public var updated = 0
    public var added = 0
    /// 历史位置原样放回，恢复为现存。
    public var restored = 0
    /// 同一路径换了照片。
    public var replaced = 0
    /// 完整列出的目录里不见了，改为历史位置。
    public var vanished = 0
    public var newPhotos = 0
    /// 相机型号不对、跳过的文件（F-02）。
    public var otherCamera = 0
    public var importBatchID: Int?
    /// 卡上所有目录都完整扫完。
    public var isComplete = false

    public init() {}
}

/// 按目录扫描卡上的 `DCIM`。见 Mac 版 docs/设计/数据模型.md §5。
///
/// 每个目录先完整列出；列不完就记为没扫完，保留上次结果。文件按批提交，网格边扫边出现。
/// 大小和修改时间都没变的文件不读 EXIF；其余的并行读 EXIF（慢速卡上单个文件要零点几秒）。
public struct CardScanner: Sendable {
    /// 只扫卡上的这个目录（视频在 `PRIVATE/M4ROOT`，不扫）。
    public static let scanRoot = "DCIM"
    /// A7C II 的 EXIF 型号。
    public static let cameraModels: Set<String> = ["ILCE-7CM2"]

    public var library: Library
    public var lister: any DirectoryListing
    public var metadataReader: any MetadataReading
    /// 只收这些型号；nil 表示不限。
    public var acceptedModels: Set<String>?
    public var concurrency: Int
    public var batchSize: Int

    public init(
        library: Library,
        lister: any DirectoryListing = FileSystemLister(),
        metadataReader: any MetadataReading = ImageIOMetadataReader(),
        acceptedModels: Set<String>? = CardScanner.cameraModels,
        concurrency: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)),
        batchSize: Int = 200
    ) {
        self.library = library
        self.lister = lister
        self.metadataReader = metadataReader
        self.acceptedModels = acceptedModels
        self.concurrency = concurrency
        self.batchSize = batchSize
    }

    /// 扫描卡。`cardURL` 是卡的根目录，调用方负责 `startAccessingSecurityScopedResource`。
    /// `isCancelled` 返回 true 时（取消、切到后台、拔卡）在下一个文件批次前停下，当前目录和之后的目录都记为没扫完。
    @discardableResult
    public func scan(
        cardURL: URL,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        progress: (@Sendable (ScanSummary) -> Void)? = nil
    ) async throws -> ScanSummary {
        let volumeID = Library.cardVolumeID
        let mountURL = cardURL
        let time = library.now()
        var summary = ScanSummary()
        var importBatchID: Int?
        var queue = [Self.scanRoot]
        var visited: Set<String> = []
        var interruption: String?

        while !queue.isEmpty {
            if isCancelled() {
                interruption = "扫描中断"
                break
            }
            let dir = queue.removeFirst()
            let entries: [DirectoryEntry]
            do {
                entries = try lister.list(Self.url(of: dir, in: mountURL))
            } catch {
                let reason = Self.reason(for: error)
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: reason)
                summary.incompleteDirectories[dir] = reason
                visited.insert(dir)
                continue
            }

            let subdirectories = Set(entries.filter(\.isDirectory).map(\.name))
            let files = entries
                .filter { !$0.isDirectory && FileKind(extension: ($0.name as NSString).pathExtension) != nil }
                .sorted { $0.name < $1.name }
                .map {
                    Library.ScanFile(
                        name: $0.name,
                        relativePath: Library.join(dir, $0.name),
                        dirPath: dir,
                        size: $0.size,
                        modificationTime: $0.modificationTime
                    )
                }
            let known = try library.presentLocations(volumeID: volumeID, dirPath: dir)
            var seen: Set<String> = []
            var finished = true
            var failure: String?

            for start in stride(from: 0, to: files.count, by: batchSize) {
                if isCancelled() {
                    finished = false
                    break
                }
                let chunk = files[start..<min(start + batchSize, files.count)]
                var unchanged: [Int] = []
                var toRead: [Library.ScanFile] = []
                for file in chunk {
                    seen.insert(file.relativePath)
                    if let location = known[file.relativePath],
                       location.size == file.size, location.modificationTime == file.modificationTime {
                        unchanged.append(location.id)
                    } else {
                        toRead.append(file)
                    }
                }
                let (read, readCount, otherCamera, readFailure) = await readMetadata(toRead, mountURL: mountURL, isCancelled: isCancelled)
                let counts = try library.applyScanBatch(
                    volumeID: volumeID, unchanged: unchanged, read: read, at: time, importBatchID: &importBatchID
                )
                summary.filesSeen += unchanged.count + readCount
                summary.unchanged += counts.unchanged
                summary.updated += counts.updated
                summary.added += counts.added
                summary.restored += counts.restored
                summary.replaced += counts.replaced
                summary.newPhotos += counts.newPhotos
                summary.otherCamera += otherCamera
                summary.importBatchID = importBatchID
                progress?(summary)
                if let readFailure {
                    failure = readFailure
                    break
                }
                if readCount < toRead.count {
                    finished = false
                    break
                }
            }

            if let failure {
                // 有文件读不了：这个目录不下结论，接着扫别的目录。
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: failure)
                summary.incompleteDirectories[dir] = failure
                visited.insert(dir)
                continue
            }
            // 下结论（没见到的改为历史）之前再确认一次没被取消：列目录的同时可能刚好拔卡。
            if !finished || isCancelled() {
                interruption = "扫描中断"
                try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: "扫描中断")
                summary.incompleteDirectories[dir] = "扫描中断"
                visited.insert(dir)
                break
            }

            summary.vanished += try library.finishDirectory(
                volumeID: volumeID, dirPath: dir, seenPaths: seen, subdirectories: subdirectories, at: time
            )
            summary.directoriesComplete += 1
            visited.insert(dir)
            queue.append(contentsOf: subdirectories.sorted().map { Library.join(dir, $0) })
            progress?(summary)
        }

        // 列出来了但没走到的目录，以及上级没列出来的已知目录，都记为没扫完。
        let reason = interruption ?? "上级目录没扫完"
        for dir in queue {
            try library.markDirectoryIncomplete(volumeID: volumeID, dirPath: dir, reason: reason)
            summary.incompleteDirectories[dir] = reason
            visited.insert(dir)
        }
        try library.markUnvisitedDirectoriesIncomplete(volumeID: volumeID, visited: visited, reason: reason)
        for (dir, state) in try library.reader.scanDirectoryStates()
        where state == "incomplete" && summary.incompleteDirectories[dir] == nil {
            summary.incompleteDirectories[dir] = reason
        }
        summary.isComplete = try library.finishVolumeScan(volumeID: volumeID, importBatchID: importBatchID, at: time)
        progress?(summary)
        return summary
    }

    private enum ReadOutcome: Sendable {
        case metadata(PhotoMetadata)
        case notAnImage
        case failed(String)
        case cancelled
    }

    /// 并行读 EXIF，保持原顺序。只返回第一次取消或读错之前的那一段：
    /// （读出的结果，处理掉的文件数，其中型号不对的文件数，读错的原因）。不是图片、型号不对的文件算处理掉了，但不登记。
    private func readMetadata(
        _ files: [Library.ScanFile],
        mountURL: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ([(Library.ScanFile, PhotoMetadata)], Int, Int, String?) {
        guard !files.isEmpty else { return ([], 0, 0, nil) }
        let reader = metadataReader
        var outcomes = [ReadOutcome](repeating: .cancelled, count: files.count)
        await withTaskGroup(of: (Int, ReadOutcome).self) { group in
            var next = 0
            func add() {
                let index = next
                let url = Self.url(of: files[index].relativePath, in: mountURL)
                group.addTask {
                    if isCancelled() { return (index, .cancelled) }
                    do {
                        if let metadata = try reader.metadata(at: url) { return (index, .metadata(metadata)) }
                        return (index, .notAnImage)
                    } catch {
                        return (index, .failed(Self.reason(for: error)))
                    }
                }
                next += 1
            }
            while next < min(concurrency, files.count) { add() }
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                if next < files.count { add() }
            }
        }
        var ordered: [(Library.ScanFile, PhotoMetadata)] = []
        var processed = 0
        var otherCamera = 0
        for (file, outcome) in zip(files, outcomes) {
            switch outcome {
            case .metadata(let metadata):
                if let acceptedModels, !acceptedModels.contains(metadata.cameraModel ?? "") {
                    otherCamera += 1
                } else {
                    ordered.append((file, metadata))
                }
            case .notAnImage:
                break
            case .failed(let reason):
                return (ordered, processed, otherCamera, reason)
            case .cancelled:
                return (ordered, processed, otherCamera, nil)
            }
            processed += 1
        }
        return (ordered, processed, otherCamera, nil)
    }

    static func url(of relativePath: String, in mountURL: URL) -> URL {
        relativePath.isEmpty ? mountURL : mountURL.appendingPathComponent(relativePath)
    }

    static func reason(for error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError): return "没有权限"
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)): return "目录不在了或卡已拔出"
        default:
            if let error = error as? MetadataReadError { return "文件读不了：\((error.path as NSString).lastPathComponent)" }
            return "读取出错：\(nsError.localizedDescription)"
        }
    }
}
