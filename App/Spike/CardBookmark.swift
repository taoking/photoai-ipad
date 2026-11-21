import Foundation

/// 存储卡根目录的书签：选一次卡存下来，之后解析书签就能访问（开发计划 §6）。
enum CardBookmark {
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PhotoAI/spike", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("card.bookmark") }

    enum Resolution {
        /// 解析成功并且能列出 DCIM。
        case connected(URL, stale: Bool, dcimEntries: Int)
        /// 解析成功但访问不了（卡拔了、换了卡）。
        case unreachable(URL, stale: Bool, reason: String)
        case failed(String)
        case none
    }

    /// 用户在选择器里选了卡的根目录：存书签。调用时 URL 要已经在 `startAccessingSecurityScopedResource` 里。
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// 解析书签并试着列 DCIM。`keepAccess` 为 true 时不调用 stop，由调用方用完再停。
    static func resolve(keepAccess: Bool = false) -> Resolution {
        guard let data = try? Data(contentsOf: fileURL) else { return .none }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return .failed("\(error)")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing && !keepAccess { url.stopAccessingSecurityScopedResource() } }
        guard accessing else { return .unreachable(url, stale: stale, reason: "startAccessingSecurityScopedResource 返回 false") }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("DCIM").path)
            // 过期的书签能用就顺手重存一份（系统建议的做法）。
            if stale { try? save(url) }
            return .connected(url, stale: stale, dcimEntries: entries.count)
        } catch {
            if keepAccess { url.stopAccessingSecurityScopedResource() }
            return .unreachable(url, stale: stale, reason: "列 DCIM 失败：\((error as NSError).localizedDescription)")
        }
    }

    static func describe(_ resolution: Resolution) -> String {
        switch resolution {
        case let .connected(url, stale, count): "书签可用：\(url.path)，stale=\(stale)，DCIM 下 \(count) 项"
        case let .unreachable(url, stale, reason): "书签解析到 \(url.path)（stale=\(stale)），但访问不了：\(reason)"
        case let .failed(reason): "书签解析失败：\(reason)"
        case .none: "还没有选过卡"
        }
    }
}
