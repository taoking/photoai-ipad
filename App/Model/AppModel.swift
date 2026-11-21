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

    var scope: PhotoScope {
        switch self {
        case .all: .all
        case .day(let day): .datePrefix(day)
        case .undated: .undated
        }
    }

    var title: String {
        switch self {
        case .all: "全部照片"
        case .day(let day): DayFormat.title(day)
        case .undated: "日期未知"
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
    /// 用的是 1 万张的合成库（性能测试，PF-1、PF-2），不读卡。
    let isSynthetic: Bool

    private(set) var cardState: CardState = .unknown
    var selection: SidebarItem = .all {
        didSet { if selection != oldValue { exitSelection(); reloadPhotos() } }
    }
    var sort: PhotoSort {
        didSet {
            UserDefaults.standard.set(sort.rawValue, forKey: DefaultsKey.sort)
            reloadPhotos()
        }
    }
    /// 每个侧栏项的筛选条件（F-10；筛选条在 M2 做）。
    var filters: [SidebarItem: PhotoFilter] = [:]

    /// 当前侧栏项里、筛选后的照片，按排序排好。
    private(set) var photos: [PhotoSummary] = []
    private(set) var days: [DayCount] = []
    private(set) var undatedCount = 0
    private(set) var stats = CardStats()

    var isSelecting = false
    var selectedIDs: Set<PhotoID> = []
    var openedPhoto: PhotoSummary?
    var isPickingCard = false
    var message: String?

    var previewConcurrency: Int {
        didSet { UserDefaults.standard.set(previewConcurrency, forKey: DefaultsKey.previewConcurrency) }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    /// 导入因为切后台、拔卡停下了，下次连上要续做。
    @ObservationIgnored private var needsResume = false
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var didLogFirstGrid = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() throws {
        let defaults = UserDefaults.standard
        isSynthetic = defaults.bool(forKey: DefaultsKey.useSyntheticLibrary)
        sort = PhotoSort(rawValue: defaults.string(forKey: DefaultsKey.sort) ?? "") ?? .captureDateDescending
        previewConcurrency = defaults.object(forKey: DefaultsKey.previewConcurrency) as? Int ?? 3

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
        importer.onProgress = { [weak self] in self?.reloadAll() }
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
    func reloadAll() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let reader = reader
        let scope = selection.scope
        let sort = sort
        Task {
            let result = await Task.detached { () -> Snapshot? in
                try? Snapshot(
                    photos: reader.photos(in: scope, sort: sort),
                    days: reader.dayCounts(),
                    undatedCount: reader.undatedCount(),
                    stats: reader.cardStats()
                )
            }.value
            guard let result, generation == reloadGeneration else { return }
            days = result.days
            undatedCount = result.undatedCount
            stats = result.stats
            setPhotos(result.photos)
            // 启动时库是空的（第一次读卡）：之后网格出照片是导入的结果，不算冷启动（PF-1）。
            if photos.isEmpty { didLogFirstGrid = true }
        }
    }

    func reloadPhotos() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let reader = reader
        let scope = selection.scope
        let sort = sort
        Task {
            let photos = await Task.detached { try? reader.photos(in: scope, sort: sort) }.value
            guard let photos, generation == reloadGeneration else { return }
            setPhotos(photos)
        }
    }

    private func setPhotos(_ all: [PhotoSummary]) {
        let filter = filters[selection] ?? PhotoFilter()
        photos = filter.isEmpty ? all : all.filter(filter.matches)
        selectedIDs.formIntersection(photos.map(\.id))
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

    private struct Snapshot: Sendable {
        var photos: [PhotoSummary]
        var days: [DayCount]
        var undatedCount: Int
        var stats: CardStats
    }
}

enum DefaultsKey {
    static let sort = "sort"
    static let previewConcurrency = "previewConcurrency"
    static let useSyntheticLibrary = "useSyntheticLibrary"
    static let gridColumns = "gridColumns"
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
