import Foundation
import Observation
import PhotoAICore
import SwiftUI
import UIKit

/// 侧栏的一项（F-10）。每一项各自记住筛选条件。
enum SidebarItem: Hashable, Sendable {
    case all
    /// `yyyy-MM-dd`
    case day(String)
    case undated
    /// 收藏夹（F-25）。
    case collection(CollectionID)

    var scope: PhotoScope {
        switch self {
        case .all: .all
        case .day(let day): .datePrefix(day)
        case .undated: .undated
        case .collection(let id): .collection(id)
        }
    }
}

/// 整个应用的状态：库、卡的连接、导入、侧栏和网格的数据。
@MainActor @Observable
final class AppModel {
    enum CardState: Equatable {
        case unknown
        /// 还没选过卡（或清卡后）。
        case noBookmark
        case connected
        case disconnected(String)
    }

    let library: Library
    let reader: LibraryReader
    let previewStore: PreviewStore
    let importer: ImportController
    let exports: ExportController
    /// 用的是 1 万张的合成库（性能测试，PF-1、PF-2），不读卡。
    let isSynthetic: Bool

    private(set) var cardState: CardState = .unknown
    var selection: SidebarItem = .all {
        didSet {
            guard selection != oldValue else { return }
            exitSelection()
            sidebarSwitchStarted = DispatchTime.now().uptimeNanoseconds
            reloadPhotos(keepResult: false)
        }
    }
    var sort: PhotoSort {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: DefaultsKey.sort)
            reloadPhotos(keepResult: true)
        }
    }
    /// 每个侧栏项的筛选条件（F-10）。只用星级和选择状态（F-22）。
    var filters: [SidebarItem: PhotoFilter] = [:]

    /// 当前侧栏项里的全部照片（筛选前），按排序排好。
    var source: [PhotoSummary] = []
    /// 筛选结果：网格和单张视图显示的就是它。打星后结果保持不变，点“刷新结果”才重新筛（F-22）。
    var photos: [PhotoSummary] = []
    /// 结果里已经不符合筛选条件的张数（“刷新结果”按钮上的数字）。
    private(set) var staleCount = 0
    @ObservationIgnored var sourceIndex: [PhotoID: Int] = [:]
    @ObservationIgnored var resultIndex: [PhotoID: Int] = [:]
    private(set) var days: [DayCount] = []
    private(set) var undatedCount = 0
    private(set) var stats = CardStats()
    /// 收藏夹（F-25），按名字排。
    var collections: [CollectionRecord] = []
    /// 打开着的“新建收藏夹”“改名”输入框。
    var collectionPrompt: CollectionPrompt?
    /// 等确认删除的收藏夹。
    var collectionToDelete: CollectionRecord?
    /// 本次运行里最后用过的收藏夹（“加入上一次的收藏夹”）。
    var lastCollectionID: CollectionID?

    var isSelecting = false
    var selectedIDs: Set<PhotoID> = []
    var isPickingCard = false
    /// 打开着的导出面板（F-30）：导哪些照片。
    var exportScope: ExportScope?
    var isShowingSettings = false
    var message: String?
    var toast: Toast?

    /// 单张视图正在看的照片（F-12）；nil 时在网格。
    var currentPhotoID: PhotoID?
    var isShowingSingle = false
    /// 当前这张的详细信息（拍摄参数、文件），翻页后在后台读。
    var currentDetail: PhotoDetail?
    /// 回到网格时滚到这张。
    var gridScrollTarget: PhotoID?

    /// 自动前进（F-21）：单张视图里打星、标记后跳到下一张。
    var autoAdvance: Bool {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: DefaultsKey.autoAdvance) }
    }
    /// 撤销记录（F-23）：本次运行内有效。系统的 `UndoManager` 只是入口（按钮、三指滑动、⌘Z），记录在这里。
    var history = EditHistory()
    /// 网格和单张视图做第一响应者时交出这个，三指滑动撤销、重做就作用在选片上。
    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1_000
        return manager
    }()

    var previewConcurrency: Int {
        didSet { UserDefaults.standard.set(previewConcurrency, forKey: DefaultsKey.previewConcurrency) }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    /// 导入因为切后台、拔卡停下了，下次连上要续做。
    @ObservationIgnored private var needsResume = false
    @ObservationIgnored private var reloadGeneration = 0
    /// 正在后台读的次数。读的过程中打了星，读到的可能是打星之前的值，要再读一次。
    @ObservationIgnored private var reloadsInFlight = 0
    @ObservationIgnored private var sidebarSwitchStarted: UInt64?
    @ObservationIgnored var pageStarted: UInt64?
    @ObservationIgnored private var didLogFirstGrid = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 清卡后清掉界面的图片缓存（照片 id 会从 1 重新用起）。
    @ObservationIgnored var onLibraryCleared: (() -> Void)?

    init() throws {
        let defaults = UserDefaults.standard
        isSynthetic = defaults.bool(forKey: DefaultsKey.useSyntheticLibrary)
        sort = PhotoSort(rawValue: defaults.string(forKey: DefaultsKey.sort) ?? "") ?? .captureDateDescending
        previewConcurrency = defaults.object(forKey: DefaultsKey.previewConcurrency) as? Int ?? 3
        autoAdvance = defaults.bool(forKey: DefaultsKey.autoAdvance)

        let paths: LibraryPaths
        if isSynthetic {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            paths = LibraryPaths(root: support.appendingPathComponent("PhotoAI-性能测试", isDirectory: true))
            if !FileManager.default.fileExists(atPath: paths.database.path) {
                let start = Date()
                try SyntheticLibrary.build(at: paths)
                appLog(String(format: "合成 1 万张性能测试库：%.1f 秒", Date().timeIntervalSince(start)))
            }
        } else {
            paths = .default
        }
        try paths.preparePreviewDirectory()
        library = try Library(paths: paths)
        reader = try library.makeReader()
        previewStore = PreviewStore(root: paths.previews)
        importer = ImportController(library: library)
        exports = ExportController(library: library)
        importer.onProgress = { [weak self] in self?.reloadAll() }
        exports.onFinished = { [weak self] in self?.reloadAll() }
        #if DEBUG
        // 模拟器上调试用：启动参数 `-debugCardPath <目录>` 把卡的书签指到这个目录（选择器没法用脚本点）。
        if let path = defaults.string(forKey: "debugCardPath"),
           let bookmark = try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            try library.setCardBookmark(bookmark)
        }
        #endif
    }

    // MARK: - 启动、前后台

    func launched() {
        let info = Bundle.main.infoDictionary ?? [:]
        let sinceLaunch = ProcessClock.millisecondsSinceLaunch().map { String(format: "进程启动后 %.0f ms", $0) } ?? ""
        appLog("启动（\(sinceLaunch)）：构建 \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))，"
            + "\(isSynthetic ? "性能测试库" : "正式库")，签名到期 \(ProvisioningInfo.expiration() ?? "读不到")；\(MemoryProbe.describe())")
        reloadAll()
        // 启动时核对预览文件：状态是 ready 但文件不在的改回 pending（中途退出、被系统清掉）。
        let generator = PreviewGenerator(library: library, store: previewStore)
        Task.detached {
            let (resets, time) = measure { (try? generator.verifyReadyFiles()) ?? 0 }
            appLog("核对预览文件 \(ms(time))：改回待做 \(resets) 张")
        }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            startPolling()
        case .background:
            pollTask?.cancel()
            pollTask = nil
            guard importer.isRunning else { return }
            // 系统给一点时间收尾：扫描记下没扫完的目录，预览停在下一张之前。
            needsResume = true
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "停下导入") { [weak self] in
                self?.endBackgroundTask()
            }
            Task {
                await importer.stop(reason: "切到后台")
                endBackgroundTask()
            }
        default:
            break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - 读卡（F-01）

    /// 前台每 3 秒看一次书签：从“未连接”变成“已连接”就自动重扫。
    private func startPolling() {
        guard pollTask == nil, !isSynthetic else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func pollOnce() async {
        guard let bookmark = (try? reader.card())?.bookmark else {
            setCardState(.noBookmark)
            return
        }
        let result = await Task.detached { CardConnection.probe(bookmark) }.value
        switch result {
        case .success:
            consecutiveFailures = 0
            let wasConnected = cardState == .connected
            setCardState(.connected)
            if (!wasConnected || needsResume) && !importer.isRunning {
                startImport()
            }
        case .failure(let failure):
            consecutiveFailures += 1
            setCardState(.disconnected(failure.description))
            // 解析失败一次不算数（冷启动时会暂时报 -2001）；连着两次才停下导入。
            if consecutiveFailures >= 2, importer.isRunning {
                needsResume = true
                await importer.stop(reason: "卡拔了")
            }
        }
    }

    private func setCardState(_ state: CardState) {
        guard state != cardState else { return }
        appLog("卡的状态：\(Self.describe(cardState)) → \(Self.describe(state))")
        cardState = state
    }

    /// 点“读取存储卡”：书签能连上就重扫；确实连不上（隔一秒再试一次）才打开选择器。
    func readCardTapped() {
        guard !isSynthetic else {
            message = "现在用的是性能测试库，不读卡。在“诊断”里关掉性能测试库、重新打开应用。"
            return
        }
        guard !importer.isRunning else { return }
        guard let bookmark = (try? reader.card())?.bookmark else {
            isPickingCard = true
            return
        }
        Task {
            for attempt in 1...2 {
                if case .success = await Task.detached(operation: { CardConnection.probe(bookmark) }).value {
                    setCardState(.connected)
                    startImport()
                    return
                }
                if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
            }
            isPickingCard = true
        }
    }

    func cardPicked(_ result: Result<URL, any Error>) {
        switch result {
        case .failure(let error):
            appLog("选择器返回错误：\(error)")
        case .success(let url):
            do {
                let bookmark = try CardConnection.makeBookmark(for: url)
                try library.setCardBookmark(bookmark)
                appLog("选了卡：\(url.lastPathComponent)")
                setCardState(.connected)
                startImport()
            } catch {
                appLog("存卡的书签失败：\(error)")
                message = "\(error)。请在“文件”的“位置”里选存储卡本身（或卡上的 DCIM 文件夹）。"
            }
        }
    }

    private func startImport() {
        guard let bookmark = (try? reader.card())?.bookmark else { return }
        switch CardConnection.open(bookmark) {
        case .success(let (access, refreshed)):
            if let refreshed { try? library.setCardBookmark(refreshed) }
            try? library.markCardSeen()
            needsResume = false
            importer.start(access: access, previewConcurrency: previewConcurrency)
        case .failure(let failure):
            setCardState(.disconnected(failure.description))
        }
    }

    // MARK: - 数据

    /// 重读侧栏、概况和当前网格。在后台读，读完回主线程换上；晚到的旧结果丢掉。
    /// 导入中的刷新保持结果不变：原来在结果里的照片留着，新照片按条件决定。
    func reloadAll() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let reader = reader
        let scope = selection.scope
        let sort = sort
        reloadsInFlight += 1
        Task {
            let result = await Task.detached { () -> Snapshot? in
                try? Snapshot(
                    photos: reader.photos(in: scope, sort: sort),
                    days: reader.dayCounts(),
                    undatedCount: reader.undatedCount(),
                    stats: reader.cardStats(),
                    collections: reader.collections()
                )
            }.value
            reloadsInFlight -= 1
            guard let result, generation == reloadGeneration else { return }
            days = result.days
            undatedCount = result.undatedCount
            stats = result.stats
            collections = result.collections
            setSource(result.photos, keepResult: true)
            // 启动时库是空的（第一次读卡）：之后网格出照片是导入的结果，不算冷启动（PF-1）。
            if photos.isEmpty { didLogFirstGrid = true }
        }
    }

    /// `keepResult == false`：换了侧栏项，按条件重新筛。
    func reloadPhotos(keepResult: Bool) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let reader = reader
        let scope = selection.scope
        let sort = sort
        reloadsInFlight += 1
        Task {
            let photos = await Task.detached { try? reader.photos(in: scope, sort: sort) }.value
            reloadsInFlight -= 1
            guard let photos, generation == reloadGeneration else { return }
            setSource(photos, keepResult: keepResult)
            if let started = sidebarSwitchStarted {
                sidebarSwitchStarted = nil
                // 下一帧画出来才算切换完（PF-3）。
                DispatchQueue.main.async { [count = self.photos.count] in
                    appLog("切换侧栏项：\(msSince(started))，\(count) 张")
                }
            }
        }
    }

    /// 写库之后调用：后台正在读的结果可能是写之前的，作废重读。
    func reloadIfStale() {
        if reloadsInFlight > 0 { reloadAll() }
    }

    /// 换上一组照片。`keepResult` 时不重新筛：原来在结果里的照片留着，
    /// 新出现的照片按条件决定，原来被筛掉的仍然不显示（Mac 版 `setSource` 的做法）。
    private func setSource(_ all: [PhotoSummary], keepResult: Bool) {
        let previousResult = keepResult ? resultIndex : nil
        let previousSource = sourceIndex
        source = all
        sourceIndex = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        let filter = currentFilter
        if filter.isEmpty {
            setResult(all)
        } else if let previousResult {
            setResult(all.filter { previousResult[$0.id] != nil || (previousSource[$0.id] == nil && filter.matches($0)) })
        } else {
            setResult(all.filter(filter.matches))
        }
    }

    func setResult(_ result: [PhotoSummary]) {
        photos = result
        resultIndex = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        selectedIDs = selectedIDs.filter { resultIndex[$0] != nil }
        updateStaleCount()
        // 单张视图正看的这张不在结果里了（比如刷新结果）：留在原来的位置附近，结果空了回网格。
        if let id = currentPhotoID, resultIndex[id] == nil {
            if result.isEmpty {
                closeSingle()
            } else {
                currentPhotoID = result[min(lastSingleIndex, result.count - 1)].id
                loadCurrentDetail()
            }
        }
    }

    func updateStaleCount() {
        let filter = currentFilter
        staleCount = filter.isEmpty ? 0 : photos.reduce(0) { $0 + (filter.matches($1) ? 0 : 1) }
    }

    /// 网格第一次画出照片（PF-1：冷启动到网格可见 ≤ 2 秒）。
    func gridDidShowPhotos() {
        guard !didLogFirstGrid, !photos.isEmpty else { return }
        didLogFirstGrid = true
        let launch = ProcessClock.millisecondsSinceLaunch().map { String(format: "%.0f ms", $0) } ?? "读不到"
        appLog("冷启动到网格可见：\(launch)，\(photos.count) 张；\(MemoryProbe.describe())")
    }

    // MARK: - 选择

    func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    // MARK: - 清卡（F-40 – F-42）

    /// 清卡：删掉本机库里全部照片的记录和预览、卡的书签和扫描记录。卡上的文件一概不碰。
    func clearCard() async {
        guard !importer.isRunning, !exports.isRunning else {
            message = "正在读卡或导出，等做完再清卡。"
            return
        }
        closeSingle()
        exitSelection()
        let library = library
        let result = await Task.detached { Result { try library.clearCard() } }.value
        switch result {
        case .success(let cleared):
            history = EditHistory()
            undoManager.removeAllActions()
            filters = [:]
            selection = .all
            needsResume = false
            exports.reset()
            onLibraryCleared?()
            setCardState(.noBookmark)
            reloadAll()
            appLog(String(format: "清卡：删了 %d 张，数据库 %.0f ms，预览目录 %.0f ms；%@", cleared.deletedPhotos,
                          cleared.databaseSeconds * 1000, cleared.previewSeconds * 1000, MemoryProbe.describe()))
            show("清卡完成：删了 \(cleared.deletedPhotos) 张")
        case .failure(let error):
            appLog("清卡失败：\(error)")
            message = "清卡失败：\(error)"
            reloadAll()
        }
    }

    // MARK: - 诊断

    func setSyntheticLibrary(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: DefaultsKey.useSyntheticLibrary)
        message = on
            ? "下次打开应用时换成 1 万张的性能测试库（第一次打开要先合成，几秒钟）。在多任务里划掉应用再打开。正式库不受影响。"
            : "下次打开应用时换回正式库。在多任务里划掉应用再打开。"
    }

    static func describe(_ state: CardState) -> String {
        switch state {
        case .unknown: "未知"
        case .noBookmark: "还没选过卡"
        case .connected: "已连接"
        case .disconnected(let reason): "未连接（\(reason)）"
        }
    }

    @ObservationIgnored var lastSingleIndex = 0

    private struct Snapshot: Sendable {
        var photos: [PhotoSummary]
        var days: [DayCount]
        var undatedCount: Int
        var stats: CardStats
        var collections: [CollectionRecord]
    }
}

enum DefaultsKey {
    static let sort = "sort"
    static let previewConcurrency = "previewConcurrency"
    static let useSyntheticLibrary = "useSyntheticLibrary"
    static let gridColumns = "gridColumns"
    static let autoAdvance = "autoAdvance"
    static let exportFiles = "exportFiles"
    static let exportTarget = "exportTarget"
}

/// 一条短暂的提示，如“★3（12 张）”“撤销：Pick”。
struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

/// 从 `start`（`DispatchTime` 纳秒）到现在，“12 ms”。
func msSince(_ start: UInt64) -> String {
    String(format: "%.0f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

/// `yyyy-MM-dd` → “11月21日 周六”，不是今年的带上年份。
enum DayFormat {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func title(_ day: String) -> String {
        guard let date = parser.date(from: day) else { return day }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let currentYear = calendar.component(.year, from: Date())
        let prefix = parts.year == currentYear ? "" : "\(parts.year ?? 0)年"
        return "\(prefix)\(parts.month ?? 0)月\(parts.day ?? 0)日 \(weekdays[(parts.weekday ?? 1) - 1])"
    }

    /// `yyyy-MM-dd` → “2026年11月”，侧栏按月分组用。
    static func month(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return day }
        return "\(year)年\(month)月"
    }
}
