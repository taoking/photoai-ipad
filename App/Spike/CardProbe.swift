import CoreImage
import Foundation
import ImageIO
import PhotoAICore
import UniformTypeIdentifiers

/// M0 的各项测量（开发计划 §6 的四个问题）。都在后台线程跑，结果写日志。
enum CardProbe {
    static let sampleCount = 20

    static var previewDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spike-previews", isDirectory: true)
    }

    // MARK: - 全部测一遍

    static func runAll(log: SpikeLog) {
        log("—— 开始测量 —— \(MemoryProbe.describe())")
        let (resolution, resolveTime) = measure { CardBookmark.resolve(keepAccess: true) }
        log("解析书签 \(ms(resolveTime))：\(CardBookmark.describe(resolution))")
        guard case let .connected(root, _, _) = resolution else {
            log("卡访问不了，停止。")
            return
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let files = listDCIM(root: root, log: log)
        let byKind = Dictionary(grouping: files) { $0.pathExtension.uppercased() }
        let jpegs = Array((byKind["JPG"] ?? []).prefix(sampleCount))
        let raws = Array((byKind["ARW"] ?? []).prefix(sampleCount))
        let heifs = Array((byKind["HIF"] ?? byKind["HEIF"] ?? []).prefix(sampleCount))

        for (name, urls) in [("JPG", jpegs), ("ARW", raws), ("HIF", heifs)] where !urls.isEmpty {
            readMetadata(urls, kind: name, log: log)
        }
        if let raw = raws.first { inspectRAW(raw, log: log) }
        if let heif = heifs.first { inspectEmbedded(heif, kind: "HIF", log: log) }

        try? FileManager.default.removeItem(at: previewDirectory)
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        for (name, urls) in [("JPG", jpegs), ("ARW", raws), ("HIF", heifs)] where !urls.isEmpty {
            makePreviews(urls, kind: name, log: log)
        }
        if !jpegs.isEmpty { makePreviewsInParallel(jpegs, kind: "JPG", log: log) }
        if !raws.isEmpty { makePreviewsInParallel(raws, kind: "ARW", log: log) }

        for (name, urls) in [("JPG", jpegs), ("ARW", raws), ("HIF", heifs)] where !urls.isEmpty {
            readFocus(urls, kind: name, log: log)
        }
        log("—— 测量结束 —— \(MemoryProbe.describe())")
    }

    // MARK: - 列 DCIM

    static func listDCIM(root: URL, log: SpikeLog) -> [URL] {
        let dcim = root.appendingPathComponent("DCIM", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let ((files, bytes), time) = measure { () -> ([URL], Int) in
            var files: [URL] = []
            var bytes = 0
            guard let enumerator = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return ([], 0)
            }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append(url)
                bytes += values.fileSize ?? 0
            }
            return (files.sorted { $0.path < $1.path }, bytes)
        }
        let counts = Dictionary(grouping: files) { $0.pathExtension.uppercased() }
            .map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: "，")
        let folders = Set(files.map { $0.deletingLastPathComponent().lastPathComponent }).sorted().joined(separator: " ")
        log("列 DCIM（含大小、修改时间）\(ms(time))：\(files.count) 个文件，\(bytes / 1_000_000) MB；\(counts)；目录 \(folders)")
        return files
    }

    // MARK: - EXIF

    static func readMetadata(_ urls: [URL], kind: String, log: SpikeLog) {
        var times: [Double] = []
        var missingDate = 0
        var models: Set<String> = []
        for url in urls {
            let (properties, time) = measure { () -> [CFString: Any]? in
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
                return CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
            }
            times.append(time)
            guard let properties else {
                log("  \(url.lastPathComponent)：读不出属性")
                continue
            }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if exif[kCGImagePropertyExifDateTimeOriginal] == nil { missingDate += 1 }
            models.insert("\(tiff[kCGImagePropertyTIFFMake] ?? "?") \(tiff[kCGImagePropertyTIFFModel] ?? "?")")
            if url == urls.first {
                log("  \(url.lastPathComponent)：DateTimeOriginal=\(exif[kCGImagePropertyExifDateTimeOriginal] ?? "无")，"
                    + "SubsecTimeOriginal=\(exif[kCGImagePropertyExifSubsecTimeOriginal] ?? "无")，"
                    + "\(properties[kCGImagePropertyPixelWidth] ?? "?")×\(properties[kCGImagePropertyPixelHeight] ?? "?")，"
                    + "方向 \(properties[kCGImagePropertyOrientation] ?? "?")，镜头 \(exif[kCGImagePropertyExifLensModel] ?? "?")")
            }
        }
        log("读 \(kind) EXIF：\(summary(times))；缺拍摄时间 \(missingDate) 个；相机 \(models.sorted().joined(separator: " / "))")
    }

    // MARK: - RAW 能不能读

    static func inspectRAW(_ url: URL, log: SpikeLog) {
        inspectEmbedded(url, kind: "ARW", log: log)
        let supported = CIRAWFilter.supportedCameraModels.filter { $0.localizedCaseInsensitiveContains("7C") && $0.localizedCaseInsensitiveContains("sony") }
        log("  CIRAWFilter 支持的索尼 7C 系列：\(supported.isEmpty ? "无" : supported.joined(separator: "，"))")
        let (filter, filterTime) = measure { CIRAWFilter(imageURL: url) }
        if let filter {
            let (image, renderTime) = measure { () -> CGImage? in
                filter.scaleFactor = 1600 / Float(max(filter.nativeSize.width, filter.nativeSize.height))
                guard let output = filter.outputImage else { return nil }
                return CIContext().createCGImage(output, from: output.extent)
            }
            log("  CIRAWFilter 打开 \(ms(filterTime))，原始尺寸 \(Int(filter.nativeSize.width))×\(Int(filter.nativeSize.height))，"
                + "解 RAW 缩到 1600 \(ms(renderTime))：\(image.map { "\($0.width)×\($0.height)" } ?? "失败")；\(MemoryProbe.describe())")
        } else {
            log("  CIRAWFilter 打不开这个 ARW")
        }
        let (full, fullTime) = measure { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        log("  ImageIO 完整解码 ARW \(ms(fullTime))：\(full.map { "\($0.width)×\($0.height)" } ?? "失败")；\(MemoryProbe.describe())")
    }

    /// 文件里有几张图、内嵌预览多大（不强制解码原图时 ImageIO 给出的缩略图）。
    static func inspectEmbedded(_ url: URL, kind: String, log: SpikeLog) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log("  \(kind) \(url.lastPathComponent)：ImageIO 打不开")
            return
        }
        let type = CGImageSourceGetType(source).map { $0 as String } ?? "?"
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 10_000
        ]
        let (embedded, time) = measure { CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) }
        log("  \(kind) \(url.lastPathComponent)：类型 \(type)，图像数 \(CGImageSourceGetCount(source))，"
            + "内嵌预览 \(embedded.map { "\($0.width)×\($0.height)" } ?? "无")（\(ms(time))）")
    }

    // MARK: - 预览（照 Mac 版 PreviewGenerator：先 1600，480 从写好的 1600 缩出来）

    static func makePreviews(_ urls: [URL], kind: String, log: SpikeLog) {
        var times: [Double] = []
        var failures = 0
        var bytes = 0
        for (index, url) in urls.enumerated() {
            let (written, time) = measure { writePreviews(for: url, name: "\(kind)-\(index)") }
            times.append(time)
            if let written { bytes += written } else { failures += 1 }
        }
        log("生成 \(kind) 预览（1600 + 480，单线程）：\(summary(times))；失败 \(failures)；平均每张写 \(bytes / max(urls.count - failures, 1) / 1024) KB；\(MemoryProbe.describe())")
    }

    static func makePreviewsInParallel(_ urls: [URL], kind: String, log: SpikeLog) {
        for workers in [2, 4] {
            let (_, total) = measure {
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = workers
                for (index, url) in urls.enumerated() {
                    queue.addOperation { _ = writePreviews(for: url, name: "\(kind)-p\(workers)-\(index)") }
                }
                queue.waitUntilAllOperationsAreFinished()
            }
            log("生成 \(kind) 预览（\(workers) 并发）：\(urls.count) 张共 \(ms(total))，折合每张 \(ms(total / Double(urls.count)))；\(MemoryProbe.describe())")
        }
    }

    /// 返回写出的字节数；失败返回 nil。
    static func writePreviews(for url: URL, name: String) -> Int? {
        autoreleasepool {
            guard let image = downsample(url, maximumPixelSize: 1600) else { return nil }
            let preview = previewDirectory.appendingPathComponent("\(name)-1600.jpg")
            let thumb = previewDirectory.appendingPathComponent("\(name)-480.jpg")
            guard encode(image, to: preview),
                  let source = CGImageSourceCreateWithURL(preview as CFURL, nil),
                  let small = thumbnail(source, maximumPixelSize: 480, always: true),
                  encode(small, to: thumb) else { return nil }
            let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            return size(preview) + size(thumb)
        }
    }

    /// 照搬 Mac 版 `ImageDownsampler`：内嵌预览够大（≥ 目标一半）就用，否则完整解码缩小。
    static func downsample(_ url: URL, maximumPixelSize: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        if let embedded = thumbnail(source, maximumPixelSize: maximumPixelSize, always: false),
           Double(max(embedded.width, embedded.height)) >= Double(maximumPixelSize) * 0.5 {
            return embedded
        }
        return thumbnail(source, maximumPixelSize: maximumPixelSize, always: true)
    }

    static func thumbnail(_ source: CGImageSource, maximumPixelSize: Int, always: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        if always { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - 对焦框

    static func readFocus(_ urls: [URL], kind: String, log: SpikeLog) {
        var times: [Double] = []
        var found = 0, notRecorded = 0, unreadable = 0
        var example = ""
        for url in urls {
            let (result, time) = measure { FocusPointReader.read(at: url) }
            times.append(time)
            switch result {
            case let .found(area):
                found += 1
                if example.isEmpty { example = String(format: "%@ 中心 (%.3f, %.3f)", url.lastPathComponent, area.centerX, area.centerY) }
            case .notRecorded: notRecorded += 1
            case nil: unreadable += 1
            }
        }
        log("读 \(kind) 对焦框：\(summary(times))；读到 \(found)，没记 \(notRecorded)，读不了 \(unreadable)；例：\(example.isEmpty ? "无" : example)")
    }

    // MARK: - 轮询书签的开销（问题 4）

    static func measurePolling(log: SpikeLog, rounds: Int = 100) {
        var times: [Double] = []
        var connected = 0
        for _ in 0..<rounds {
            let (resolution, time) = measure { CardBookmark.resolve() }
            times.append(time)
            if case .connected = resolution { connected += 1 }
        }
        log("轮询书签 \(rounds) 次（解析 + 开始访问 + 列 DCIM + 停止）：\(summary(times))；能访问 \(connected) 次；\(MemoryProbe.describe())")
    }
}
