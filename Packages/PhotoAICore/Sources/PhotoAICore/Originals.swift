// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Originals.swift 的 `OriginalDecoder` 和 `chunked`。
// 找原文件、读原片的部分到 M2（100% 放大）、M3（导出）再搬。
import Foundation
import ImageIO

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
