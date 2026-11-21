import PhotoAICore
import UIKit

/// 网格缩略图的内存缓存。480 的预览在后台解码好再交给界面，滚动时主线程不解 JPEG（PF-2）。
final class ThumbnailCache: @unchecked Sendable {
    private let cache: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        // 一张 480×320 解码后约 600 KB，留 150 MB 约 250 张，够两三屏。
        cache.totalCostLimit = 150 << 20
        return cache
    }()
    let store: PreviewStore

    init(store: PreviewStore) { self.store = store }

    func cached(_ id: PhotoID) -> UIImage? { cache.object(forKey: NSNumber(value: id)) }

    /// 读文件、解码。文件不在（还没做预览）返回 nil。
    func load(_ id: PhotoID) async -> UIImage? {
        if let image = cached(id) { return image }
        let url = store.url(for: id, size: .thumb)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled, let image = UIImage(contentsOfFile: url.path) else { return nil }
            return await image.byPreparingForDisplay()
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: NSNumber(value: id), cost: cost)
        }
        return image
    }

    /// 预览文件重做了（比如核对后补做）：丢掉旧的。
    func remove(_ id: PhotoID) { cache.removeObject(forKey: NSNumber(value: id)) }
}
