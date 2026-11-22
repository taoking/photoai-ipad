// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Originals.swift。改了：只有一张卡，`OriginalFinder` 用卡根目录和
// “卡还连着吗”代替挂载点和卷 UUID；找文件发现不在了只标“卡上已删”；100% 放大只用 JPG / HEIF（iPadOS 的 ImageIO 不解 RAW）。
import Darwin
import Foundation
import ImageIO

/// 一个文件的一个现存位置。导出、100% 放大读原文件时按顺序尝试。
public struct OriginalSource: Sendable, Equatable {
    public var photoID: PhotoID
    public var fileID: FileID
    public var kind: FileKind
    /// 文件扩展名，保持卡上的大小写。
    public var fileExtension: String
    public var locationID: Int
    /// 相对卡根目录，如 `DCIM/100MSDCF/DSC01926.JPG`。
    public var relativePath: String
    /// 上次扫描时的大小。
    public var fileSize: Int

    public var fileName: String { (relativePath as NSString).lastPathComponent }
}

extension LibraryReader {
    /// 照片在卡上的全部现存位置，按照片分组，同一张照片按位置记录的先后排列。
    public func presentSources(of photoIDs: [PhotoID]) throws -> [PhotoID: [OriginalSource]] {
        var result: [PhotoID: [OriginalSource]] = [:]
        for chunk in photoIDs.chunked(into: 4_000) {
            let list = chunk.map(String.init).joined(separator: ",")
            try db.query(
                """
                SELECT f.photo_id, f.id, f.kind, f.extension, l.id, l.relative_path, l.file_size
                FROM files f JOIN locations l ON l.file_id = f.id
                WHERE f.photo_id IN (\(list)) AND l.status = 'present'
                ORDER BY f.photo_id, l.id;
                """
            ) { row in
                let path = row.text(5) ?? ""
                let source = OriginalSource(
                    photoID: row.int(0),
                    fileID: row.int(1),
                    kind: FileKind(rawValue: row.text(2) ?? "") ?? .raw,
                    fileExtension: (path as NSString).pathExtension.isEmpty ? (row.text(3) ?? "") : (path as NSString).pathExtension,
                    locationID: row.int(4),
                    relativePath: path,
                    fileSize: row.int(6)
                )
                result[source.photoID, default: []].append(source)
            }
        }
        return result
    }

    /// 位置上次扫描时记下的修改时间（验收核对源文件没被改动用）。
    public func scannedModificationTime(location: Int) throws -> Double? {
        try db.first("SELECT file_mtime FROM locations WHERE id = ?;", [location]) { $0.optionalDouble(0) } ?? nil
    }
}

extension Library {
    /// 读原文件时发现文件已经不在（卡还连着）：这些位置改为历史。
    /// 返回因此没有现存位置、变成“卡上已删”的照片（照常显示，清卡时一起删，F-06）。
    @discardableResult
    public func markLocationsMissing(_ locationIDs: [Int]) throws -> [PhotoID] {
        guard !locationIDs.isEmpty else { return [] }
        return try db.transaction {
            let list = locationIDs.map(String.init).joined(separator: ",")
            let photos = try db.all(
                "SELECT DISTINCT f.photo_id FROM locations l JOIN files f ON f.id = l.file_id WHERE l.id IN (\(list));"
            ) { $0.int(0) }
            try markHistorical(locationIDs: locationIDs)
            let missing = photos.map(String.init).joined(separator: ",")
            return try db.all("SELECT id FROM photos WHERE id IN (\(missing)) AND present_location_count = 0 ORDER BY id;") { $0.int(0) }
        }
    }
}

/// 在卡上找原文件。只有卡确实还连着、文件却不在，才算“卡上已删”；
/// 拔卡时路径也会消失，那不是文件被删，不能改成历史位置。
public struct OriginalFinder: Sendable {
    /// 卡根目录（书签解析出来的，调用方负责安全范围的访问）。
    public var root: URL
    /// 卡是否还连着（还能列出 `DCIM`）。
    public var isCardReachable: @Sendable () -> Bool

    public init(root: URL, isCardReachable: @escaping @Sendable () -> Bool) {
        self.root = root
        self.isCardReachable = isCardReachable
    }

    /// 用“还能不能列出 DCIM”判断卡还在不在。
    public init(root: URL) {
        let dcim = root.appendingPathComponent("DCIM", isDirectory: true).path
        self.init(root: root) { (try? FileManager.default.contentsOfDirectory(atPath: dcim)) != nil }
    }

    public enum Opened {
        /// 打开了，调用方负责 `close(fd)`。
        case file(fd: Int32, url: URL, size: Int, modified: timespec)
        /// 卡还连着，文件不在了。
        case missing
        /// 卡没连着（或者刚被拔掉）。
        case offline
        /// 文件在，但读不了（权限、大小和上次扫描时不同）。不改历史位置。
        case unreadable(String)
    }

    /// 读卡时的这些错误就当卡拔了：拔卡后的一小会儿 `DCIM` 还列得出来，打开、读文件却报 I/O 错误（M3 真机验收 #25）。
    public static func meansCardGone(_ code: Int32) -> Bool {
        code == EIO || code == ENXIO || code == ENODEV
    }

    public func url(_ source: OriginalSource) -> URL {
        root.appendingPathComponent(source.relativePath)
    }

    public func open(_ source: OriginalSource) -> Opened {
        let url = url(source)
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return isCardReachable() ? .missing : .offline
            }
            guard !Self.meansCardGone(code), isCardReachable() else { return .offline }
            return .unreadable(String(cString: strerror(code)))
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            if Self.meansCardGone(code) { return .offline }
            return .unreadable(String(cString: strerror(code)))
        }
        guard Int(info.st_size) == source.fileSize else {
            Darwin.close(fd)
            return .unreadable("文件和上次扫描时不一样（大小变了），重新读卡后再试")
        }
        return .file(fd: fd, url: url, size: Int(info.st_size), modified: info.st_mtimespec)
    }

    public struct Lookup: Sendable {
        public var found: (source: OriginalSource, url: URL)?
        public var missingLocationIDs: [Int] = []
        public var problems: [String] = []
        /// 卡没连着，有位置没能试。
        public var wasOffline = false
    }

    /// 依次尝试各个位置，返回第一个能打开的文件，以及途中发现已经不在的位置。
    /// 只确认能打开，解码交给调用方。
    public func lookup(_ sources: [OriginalSource]) -> Lookup {
        var lookup = Lookup()
        for source in sources {
            switch open(source) {
            case .file(let fd, let url, _, _):
                Darwin.close(fd)
                lookup.found = (source, url)
                return lookup
            case .missing:
                lookup.missingLocationIDs.append(source.locationID)
            case .offline:
                lookup.wasOffline = true
            case .unreadable(let reason):
                lookup.problems.append("\(source.fileName)：\(reason)")
            }
        }
        return lookup
    }

    /// 100% 放大用：只看 JPG / HEIF。iPadOS 的 ImageIO 不解 RAW，ARW 只读得到内嵌的 1616 px 预览，
    /// 和本机的 1600 预览差不多，不值得去卡上读（技术验证 §2）。都有时取长边最大的，一样大取 JPG。
    /// 只有 RAW 的照片返回 `found == nil`。
    public func lookupForViewing(_ sources: [OriginalSource]) -> Lookup {
        var lookup = Lookup()
        var candidates: [(source: OriginalSource, url: URL, longEdge: Int)] = []
        let ordered = sources.enumerated()
            .filter { $0.element.kind != .raw }
            .sorted { ($0.element.kind.previewPriority, $0.offset) < ($1.element.kind.previewPriority, $1.offset) }
            .map(\.element)
        var opened: Set<FileID> = []
        for source in ordered where !opened.contains(source.fileID) {
            let one = self.lookup([source])
            lookup.missingLocationIDs += one.missingLocationIDs
            lookup.problems += one.problems
            lookup.wasOffline = lookup.wasOffline || one.wasOffline
            guard let found = one.found else { continue }
            opened.insert(source.fileID)
            let longEdge = OriginalDecoder.pixelSize(at: found.url).map { max($0.width, $0.height) } ?? 0
            candidates.append((found.source, found.url, longEdge))
        }
        let largest = candidates.map(\.longEdge).max() ?? 0
        lookup.found = candidates.first { $0.longEdge == largest }.map { ($0.source, $0.url) }
        return lookup
    }
}

/// 把原文件完整解码，按 EXIF 方向转正（100% 放大用）。
public enum OriginalDecoder {
    /// 转正之后的像素尺寸，只读文件头。
    public static func pixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// 解码成长边不超过 `maximumPixelSize` 的图，按方向转正（单张视图换原图用，计划 V-3）。
    /// 总是从完整图像缩：JPEG 内嵌的缩略图太小，RAW 的内嵌预览也只有 1616 px。
    public static func decode(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func decode(_ url: URL) -> CGImage? {
        guard let size = pixelSize(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
