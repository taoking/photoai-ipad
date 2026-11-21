import Foundation

/// 卡的书签（开发计划 §6，M0 的 `CardBookmark` 挪过来的）。书签本身存在库里，清卡时一起清掉。
///
/// 选择器里选的可以是卡的根目录，也可以是 `DCIM`：选的是 `DCIM` 时，卡根目录取它的上一级
/// （只访问 `DCIM` 下面的文件，安全范围够用）。
enum CardConnection {
    /// 一次打开的访问。用完调 `stop()`；`root` 是卡根目录，扫描和预览的相对路径都相对它。
    struct Access: @unchecked Sendable {
        let root: URL
        fileprivate let scoped: URL
        fileprivate let accessing: Bool

        var dcim: URL { root.appendingPathComponent("DCIM", isDirectory: true) }

        func stop() {
            if accessing { scoped.stopAccessingSecurityScopedResource() }
        }
    }

    enum Failure: Error, CustomStringConvertible {
        /// 书签解析不了。冷启动时偶尔会暂时报 `NSFileProviderErrorDomain -2001`，不能当定论（技术验证 §1.2）。
        case unresolvable(String)
        /// 解析到了但访问不了、列不出 DCIM：卡拔了、换了卡。
        case unreachable(String)
        /// 选的文件夹里没有 DCIM。
        case notACard

        var description: String {
            switch self {
            case .unresolvable(let reason): "书签解析失败：\(reason)"
            case .unreachable(let reason): "卡访问不了：\(reason)"
            case .notACard: "选的文件夹里没有 DCIM"
            }
        }
    }

    /// 选择器返回的文件夹：确认能列出 DCIM，做成书签。
    static func makeBookmark(for picked: URL) throws -> Data {
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        guard (try? FileManager.default.contentsOfDirectory(atPath: dcim(of: picked).path)) != nil else {
            throw Failure.notACard
        }
        return try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 解析书签、开始访问、试着列 `DCIM`。成功时调用方负责 `stop()`。
    /// 书签过期但还能用时返回重做的书签，调用方存回库里（系统建议的做法）。
    static func open(_ bookmark: Data) -> Result<(Access, refreshed: Data?), Failure> {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            let error = error as NSError
            return .failure(.unresolvable("\(error.domain) \(error.code)"))
        }
        let accessing = url.startAccessingSecurityScopedResource()
        let access = Access(root: root(of: url), scoped: url, accessing: accessing)
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: access.dcim.path)
        } catch {
            access.stop()
            return .failure(.unreachable((error as NSError).localizedDescription))
        }
        let refreshed = stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return .success((access, refreshed))
    }

    /// 只看连没连上（前台轮询用），不保留访问。M0 实测一次 7.7 ms。
    static func probe(_ bookmark: Data) -> Result<Void, Failure> {
        open(bookmark).map { access, _ in access.stop() }
    }

    private static func isDCIM(_ url: URL) -> Bool {
        url.lastPathComponent.uppercased() == "DCIM"
    }

    private static func root(of picked: URL) -> URL {
        isDCIM(picked) ? picked.deletingLastPathComponent() : picked
    }

    private static func dcim(of picked: URL) -> URL {
        isDCIM(picked) ? picked : picked.appendingPathComponent("DCIM", isDirectory: true)
    }
}
