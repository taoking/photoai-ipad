import ImageIO
import PhotoAICore
import UIKit

/// 网格缩略图的内存缓存。480 的预览在后台按格子大小解码好再交给界面，滚动时主线程不解 JPEG（PF-2）。
///
/// 格子小时（每行 7 张以上、胶片条）解成长边 320 或 200 像素：解码快，交给渲染的数据少几倍，
/// 快速滚动时每帧要上传的图小。格子被复用时取消还没开始的解码，快速滚过去不白做。
final class ThumbnailCache: @unchecked Sendable {
    /// 解码的长边（像素）。`full` 就是 480 的文件原样。
    enum Size: Int, Sendable {
        case small = 200
        case medium = 320
        case full = 480

        /// 格子的长边（像素）用哪一档。
        static func fitting(pixels: CGFloat) -> Size {
            if pixels <= 200 { return .small }
            if pixels <= 320 { return .medium }
            return .full
        }
    }

    private let cache: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        // 一张 480×320 解码后约 600 KB，留 150 MB 约 250 张，够两三屏；小档能放下更多。
        cache.totalCostLimit = 150 << 20
        return cache
    }()
    let store: PreviewStore

    init(store: PreviewStore) { self.store = store }

    private func key(_ id: PhotoID, _ size: Size) -> NSNumber {
        NSNumber(value: id &* 4 &+ (size == .small ? 0 : size == .medium ? 1 : 2))
    }

    /// 内存里有这一档就用；没有时大一档的也行（缩放显示，不用等）。
    func cached(_ id: PhotoID, size: Size = .full) -> UIImage? {
        if let image = cache.object(forKey: key(id, size)) { return image }
        switch size {
        case .small: return cache.object(forKey: key(id, .medium)) ?? cache.object(forKey: key(id, .full))
        case .medium: return cache.object(forKey: key(id, .full))
        case .full: return nil
        }
    }

    /// 读文件、解码。文件不在（还没做预览）返回 nil。调用的任务被取消时不解码。
    /// 不用 `Task.detached`：非隔离的 async 函数本来就不在主线程上跑，而且取消能传进来。
    @concurrent func load(_ id: PhotoID, size: Size = .full) async -> UIImage? {
        if let image = cache.object(forKey: key(id, size)) { return image }
        guard !Task.isCancelled else { return nil }
        let url = store.url(for: id, size: .thumb)
        guard let image = Self.decode(url, maxPixelSize: size.rawValue) else { return nil }
        let cost = image.width * image.height * 4
        let result = UIImage(cgImage: image)
        cache.setObject(result, forKey: key(id, size), cost: cost)
        return result
    }

    /// 预览文件重做了（比如核对后补做）：丢掉旧的。
    func remove(_ id: PhotoID) {
        for size in [Size.small, .medium, .full] { cache.removeObject(forKey: key(id, size)) }
    }

    /// 清卡后：照片 id 会从 1 重新用起，旧图一张都不能留。
    func removeAll() { cache.removeAllObjects() }

    /// ImageIO 按长边缩小并当场解码（`ShouldCacheImmediately`），交给界面的是解好的位图。
    static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// 单张视图的 1600 预览缓存。翻页时前后几张先解码好（PF-7）；一张约 7 MB，留 12 张。
final class PreviewImageCache: @unchecked Sendable {
    private let cache: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 12
        return cache
    }()
    let store: PreviewStore

    init(store: PreviewStore) { self.store = store }

    func cached(_ id: PhotoID) -> UIImage? { cache.object(forKey: NSNumber(value: id)) }

    @concurrent func load(_ id: PhotoID) async -> UIImage? {
        if let image = cached(id) { return image }
        guard !Task.isCancelled else { return nil }
        let url = store.url(for: id, size: .preview)
        guard let image = UIImage(contentsOfFile: url.path), let prepared = await image.byPreparingForDisplay() else { return nil }
        cache.setObject(prepared, forKey: NSNumber(value: id))
        return prepared
    }

    /// 前后几张先解码好。
    func prefetch(_ ids: [PhotoID]) {
        for id in ids where cached(id) == nil {
            Task.detached(priority: .utility) { [self] in _ = await load(id) }
        }
    }

    func removeAll() { cache.removeAllObjects() }
}
