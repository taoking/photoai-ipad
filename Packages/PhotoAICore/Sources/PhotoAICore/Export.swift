// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Export.swift。改了：只有一张卡，没有卷和“在线卷”；只留平铺
// （功能列表 F-31）；卡拔了就停下，不逐张报失败；导出成功的照片记下“导出过”（`last_exported_at`，清卡检查用）；
// 目标里有同名文件就算导出过，不比内容、不改名（只有一台相机、编号不会循环，用户定的）。
import Darwin
import Foundation

/// 导出原文件（F-30 – F-32）：只复制、不覆盖，目标里已有同名文件就跳过（中断后再导一次就是续传）。
public struct ExportRequest: Sendable, Equatable {
    public enum Files: String, Sendable, CaseIterable {
        /// 只导出 RAW；没有 RAW 的导出 JPEG。
        case raw
        /// 只导出 JPEG（或 HEIF）；没有的导出 RAW。
        case jpeg
        case both
    }

    public var photoIDs: [PhotoID]
    public var files: Files
    /// 平铺：所有文件直接放在这个文件夹里。
    public var destination: URL

    public init(photoIDs: [PhotoID], files: Files, destination: URL) {
        self.photoIDs = photoIDs
        self.files = files
        self.destination = destination
    }
}

/// 一张照片要导出哪些文件：先试 `primary`，一个都没导出时再试 `fallback`（“没有 RAW 的导出 JPEG”）。
/// 每一项是同一个文件的全部现存位置。
struct ExportFilePick {
    var primary: [[OriginalSource]]
    var fallback: [[OriginalSource]]

    init(_ sources: [OriginalSource], files: ExportRequest.Files) {
        var groups: [[OriginalSource]] = []
        var index: [FileID: Int] = [:]
        for source in sources {
            if let position = index[source.fileID] {
                groups[position].append(source)
            } else {
                index[source.fileID] = groups.count
                groups.append([source])
            }
        }
        // RAW 在前，和相机里的顺序一样。
        groups.sort { $0[0].kind.previewPriority < $1[0].kind.previewPriority }
        let raws = groups.filter { $0[0].kind == .raw }
        let others = groups.filter { $0[0].kind != .raw }
        switch files {
        case .both: (primary, fallback) = (groups, [])
        case .raw: (primary, fallback) = raws.isEmpty ? (others, []) : (raws, others)
        case .jpeg: (primary, fallback) = others.isEmpty ? (raws, []) : (others, raws)
        }
    }
}

/// 导出面板上的概况：多少张能导、要复制几个文件、大约多大。
public struct ExportPlan: Sendable, Equatable {
    public var exportablePhotoIDs: [PhotoID] = []
    /// 卡上已经没有文件的照片（“卡上已删”），导不了。
    public var missingPhotoIDs: [PhotoID] = []
    public var fileCount = 0
    /// 按上次扫描的大小算。
    public var byteCount = 0

    public init(photoIDs: [PhotoID], sources: [PhotoID: [OriginalSource]], files: ExportRequest.Files) {
        for id in photoIDs {
            let pick = ExportFilePick(sources[id] ?? [], files: files)
            guard !pick.primary.isEmpty else {
                missingPhotoIDs.append(id)
                continue
            }
            exportablePhotoIDs.append(id)
            fileCount += pick.primary.count
            byteCount += pick.primary.reduce(0) { $0 + $1[0].fileSize }
        }
    }
}

/// 一次导出的结果。只有确实写完、落盘、改名到位的文件才计入成功。
public struct ExportReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var photoID: PhotoID
        /// 文件名，例如 `DSC01926.ARW`。
        public var name: String
        public var reason: String

        public init(photoID: PhotoID, name: String, reason: String) {
            self.photoID = photoID
            self.name = name
            self.reason = reason
        }
    }

    public var destination: URL
    /// 至少有一个文件导出成功（或目标里已有同名文件）的照片。这些照片记下了“导出过”。
    public var exportedPhotoIDs: [PhotoID] = []
    public var copiedFiles = 0
    /// 目标里已经有同名文件（上次导出过），没有再复制。
    public var alreadyExportedFiles = 0
    public var bytesCopied = 0
    /// 选的格式读不到，改导出了另一种格式的照片。
    public var usedOtherKind = 0
    /// 一开始就没有现存文件的照片（卡上已删）。
    public var skippedMissingPhotos = 0
    /// 导出时才发现卡上没有了、标成“卡上已删”的照片。
    public var newlyMissingPhotoIDs: [PhotoID] = []
    public var failures: [Failure] = []
    public var cancelled = false
    /// 卡拔了、目标写不进去（写满、没有权限）时停下，后面的照片没有导出。
    public var stoppedBy: String?
    /// 取消或停下时还没轮到的照片。
    public var notAttempted = 0
    public var elapsed: TimeInterval = 0

    public init(destination: URL) { self.destination = destination }

    public var exportedPhotos: Int { exportedPhotoIDs.count }

    public var megabytesPerSecond: Double {
        elapsed > 0 ? Double(bytesCopied) / 1_000_000 / elapsed : 0
    }
}

public struct ExportProgress: Sendable, Equatable {
    public var photosDone: Int
    public var photoTotal: Int
    public var bytesCopied: Int
    /// 正在复制的文件名。
    public var fileName: String

    public init(photosDone: Int, photoTotal: Int, bytesCopied: Int, fileName: String) {
        self.photosDone = photosDone
        self.photoTotal = photoTotal
        self.bytesCopied = bytesCopied
        self.fileName = fileName
    }
}

/// 执行导出。源文件只用 `O_RDONLY` 打开，卡上一个字节都不动；一块一块流式复制，内存不随文件大小和张数涨。
public struct Exporter: Sendable {
    public var library: Library
    public var finder: OriginalFinder
    /// 每次读写的块大小。
    var chunkSize = 4 << 20
    /// 导出成功就记“导出过”。存到“照片”时先复制到临时文件夹，存进“照片”之后才记，这里关掉。
    public var marksExported = true

    public init(library: Library, finder: OriginalFinder) {
        self.library = library
        self.finder = finder
    }

    public func run(
        _ request: ExportRequest,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        progress: (@Sendable (ExportProgress) -> Void)? = nil
    ) throws -> ExportReport {
        let started = Date()
        var report = ExportReport(destination: request.destination)
        let sources = try library.reader.presentSources(of: request.photoIDs)
        let context = ExportContext(exporter: self, destination: request.destination, isCancelled: isCancelled)
        do {
            try context.prepare()
        } catch ExportStop.stopped(let message) {
            report.stoppedBy = message
            report.notAttempted = request.photoIDs.count
            return report
        }

        for (index, photoID) in request.photoIDs.enumerated() {
            if isCancelled() {
                report.cancelled = true
                report.notAttempted = request.photoIDs.count - index
                break
            }
            let pick = ExportFilePick(sources[photoID] ?? [], files: request.files)
            guard !pick.primary.isEmpty else {
                report.skippedMissingPhotos += 1
                continue
            }
            progress?(ExportProgress(
                photosDone: index, photoTotal: request.photoIDs.count, bytesCopied: report.bytesCopied,
                fileName: pick.primary[0][0].fileName
            ))
            var photo = PhotoExport(context: context)
            do {
                var exported = try photo.export(pick.primary, report: &report)
                if exported == 0, !pick.fallback.isEmpty {
                    // 选的格式一个都读不到：照“没有 RAW 的导出 JPEG”改导出另一种。
                    exported = try photo.export(pick.fallback, report: &report)
                    if exported > 0 { report.usedOtherKind += 1 }
                }
                if exported > 0 {
                    report.exportedPhotoIDs.append(photoID)
                    // 一张一张记：中途停下，已经导出的照片也算“导出过”。
                    if marksExported { try library.markExported([photoID]) }
                }
            } catch ExportStop.cancelled {
                report.cancelled = true
                report.notAttempted = request.photoIDs.count - index
            } catch ExportStop.stopped(let message) {
                report.stoppedBy = message
                report.notAttempted = request.photoIDs.count - index
            }
            if !photo.missingLocationIDs.isEmpty {
                report.newlyMissingPhotoIDs += try library.markLocationsMissing(photo.missingLocationIDs)
            }
            if report.cancelled || report.stoppedBy != nil { break }
        }
        progress?(ExportProgress(
            photosDone: request.photoIDs.count - report.notAttempted, photoTotal: request.photoIDs.count,
            bytesCopied: report.bytesCopied, fileName: ""
        ))
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    static let partSuffix = ".photoai-part"
}

extension Library {
    /// 记下“导出过”（清卡检查的“选过但没导出”看它）。
    public func markExported(_ photoIDs: [PhotoID]) throws {
        let time = now().timeIntervalSince1970
        try db.transaction {
            for chunk in photoIDs.chunked(into: 4_000) {
                let list = chunk.map(String.init).joined(separator: ",")
                try db.run("UPDATE photos SET last_exported_at = ? WHERE id IN (\(list));", [time])
            }
        }
    }
}

enum ExportStop: Error {
    case cancelled
    /// 卡拔了、目标写不进去：后面的照片也导不了，整批停下。
    case stopped(String)
}

/// 一次导出共用的东西：目标文件夹、取消。
struct ExportContext {
    let exporter: Exporter
    let destination: URL
    let isCancelled: @Sendable () -> Bool

    /// 开始前：建文件夹，清掉上次中断留下的临时文件。
    func prepare() throws {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ExportStop.stopped("建不了文件夹 \(destination.lastPathComponent)：\(error.localizedDescription)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        for name in leftovers where name.hasPrefix(".") && name.hasSuffix(Exporter.partSuffix) {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        }
    }
}

/// 导出一张照片。文件名和卡上的一样；目标里已有同名文件就当导出过，跳过。
struct PhotoExport {
    let context: ExportContext
    var missingLocationIDs: [Int] = []

    init(context: ExportContext) {
        self.context = context
    }

    private var folder: URL { context.destination }
    private var chunkSize: Int { context.exporter.chunkSize }
    private var isCancelled: Bool { context.isCancelled() }

    /// 导出这些文件，返回成功的文件数（含目标里已有同名的）。读不到的文件记进报告。
    mutating func export(_ groups: [[OriginalSource]], report: inout ExportReport) throws -> Int {
        var exported = 0
        for locations in groups {
            // 先看目标：已有同名文件就不去卡上读。正式名字只在写完、落盘后才出现，所以不会是半截文件。
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(locations[0].fileName).path) {
                report.alreadyExportedFiles += 1
                exported += 1
                continue
            }
            var done = false
            var problems: [String] = []
            for source in locations {
                switch context.exporter.finder.open(source) {
                case .missing:
                    missingLocationIDs.append(source.locationID)
                    problems.append("卡上已经没有 \(source.relativePath)")
                    continue
                case .offline:
                    throw ExportStop.stopped("卡没连接了")
                case .unreadable(let reason):
                    problems.append(reason)
                    continue
                case .file(let fd, _, let size, let modified):
                    defer { Darwin.close(fd) }
                    do {
                        switch try copy(fd: fd, size: size, modified: modified, name: source.fileName) {
                        case .copied:
                            report.copiedFiles += 1
                            report.bytesCopied += size
                        case .alreadyExported:
                            report.alreadyExportedFiles += 1
                        }
                        done = true
                    } catch CopyFailure.source(let reason, let code) {
                        // 读到一半出错多半是卡拔了：I/O 错误或者卡真的不在了就整批停下。
                        if OriginalFinder.meansCardGone(code) || !context.exporter.finder.isCardReachable() {
                            throw ExportStop.stopped("卡没连接了")
                        }
                        problems.append(reason)
                    }
                }
                if done { break }
            }
            if done {
                exported += 1
            } else {
                let reason = problems.isEmpty ? "读不到" : problems.joined(separator: "；")
                report.failures.append(ExportReport.Failure(photoID: locations[0].photoID, name: locations[0].fileName, reason: reason))
            }
        }
        return exported
    }

    enum CopyOutcome { case copied, alreadyExported }
    /// 读卡出错；`code` 是 errno（不是系统调用出的错时为 0）。
    enum CopyFailure: Error { case source(String, code: Int32) }

    /// 复制一个文件。先写临时文件，写完、落盘后再改成正式的名字；改名不覆盖已有文件。
    private func copy(fd: Int32, size: Int, modified: timespec, name: String) throws -> CopyOutcome {
        let target = folder.appendingPathComponent(name)
        let temp = folder.appendingPathComponent(".\(name).\(UUID().uuidString)\(Exporter.partSuffix)")
        try write(fd: fd, size: size, modified: modified, to: temp)
        switch Self.renameExclusive(temp, to: target) {
        case 0:
            return .copied
        case EEXIST:
            // 复制的时候目标里出现了同名文件：照样当导出过。
            unlink(temp.path)
            return .alreadyExported
        case let code:
            unlink(temp.path)
            throw ExportStop.stopped("改名失败 \(target.lastPathComponent)：\(String(cString: strerror(code)))")
        }
    }

    private func write(fd: Int32, size: Int, modified: timespec, to temp: URL) throws {
        let out = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard out >= 0 else { throw ExportStop.stopped(Self.destinationMessage(errno, temp)) }
        var finished = false
        defer {
            Darwin.close(out)
            if !finished { unlink(temp.path) }
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Self.sourceFailure("读不了") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            if isCancelled { throw ExportStop.cancelled }
            let count = read(fd, buffer, chunkSize)
            if count < 0 { throw Self.sourceFailure("读到一半出错") }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = Darwin.write(out, buffer + offset, count - offset)
                guard written > 0 else { throw ExportStop.stopped(Self.destinationMessage(errno, temp)) }
                offset += written
            }
            total += count
        }
        guard total == size else { throw CopyFailure.source("读到的字节数（\(total)）和文件大小（\(size)）不一致", code: 0) }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
        futimens(out, &times)
        guard fsync(out) == 0 else { throw ExportStop.stopped(Self.destinationMessage(errno, temp)) }
        finished = true
    }

    /// 刚失败的系统调用的 errno 包成读卡错误。
    private static func sourceFailure(_ what: String) -> CopyFailure {
        let code = errno
        return .source("\(what)：\(String(cString: strerror(code)))", code: code)
    }

    /// 改名但不覆盖：`renamex_np(RENAME_EXCL)`；文件系统不支持时用硬链接，再不行先查再改。返回 0 或 errno。
    static func renameExclusive(_ from: URL, to: URL) -> Int32 {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { return code }
        if link(from.path, to.path) == 0 {
            unlink(from.path)
            return 0
        }
        let linkCode = errno
        if linkCode == EEXIST { return EEXIST }
        // exFAT 之类不支持硬链接：先确认目标不存在再改名。只有本应用在写这个文件夹，中间被别人占用的机会可以忽略。
        if FileManager.default.fileExists(atPath: to.path) { return EEXIST }
        return Darwin.rename(from.path, to.path) == 0 ? 0 : errno
    }

    static func destinationMessage(_ code: Int32, _ url: URL) -> String {
        switch code {
        case ENOSPC: "目标空间不够"
        case EROFS: "目标是只读的"
        case EACCES, EPERM: "没有权限写入 \(url.deletingLastPathComponent().lastPathComponent)"
        default: "写入失败：\(String(cString: strerror(code)))"
        }
    }
}

extension Library {
    /// 上次导出用的文件夹（书签，F-31 记住上次的）。存在 `library_meta` 里，清卡不删。
    public func setExportFolderBookmark(_ bookmark: Data?) throws {
        if let bookmark {
            try db.run(
                "INSERT INTO library_meta (key, value) VALUES ('export_folder', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                [bookmark.base64EncodedString()]
            )
        } else {
            try db.run("DELETE FROM library_meta WHERE key = 'export_folder';")
        }
    }
}

extension LibraryReader {
    public func exportFolderBookmark() throws -> Data? {
        try db.first("SELECT value FROM library_meta WHERE key = 'export_folder';") { $0.text(0) }
            .flatMap { $0 }
            .flatMap { Data(base64Encoded: $0) }
    }
}
