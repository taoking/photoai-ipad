import Foundation
import PhotoAICore
import UIKit

// 选片（F-20 – F-23）。做法照 Mac 版 `AppModel+Culling.swift`：先写库，成功了才改内存；值本来就是这样时不写库、
// 不进撤销，但照样提示和自动前进（选片时按一下就是确认这一张）。

// MARK: - 筛选（F-22）

extension AppModel {
    /// 当前侧栏项的筛选条件。改条件立刻重新筛（PF-8）。
    var currentFilter: PhotoFilter {
        get { filters[selection] ?? PhotoFilter() }
        set {
            guard newValue != currentFilter else { return }
            filters[selection] = newValue
            refilter(reason: "改筛选条件")
        }
    }

    /// “刷新结果”：按当前条件重新筛，已不符合的照片离开结果。
    func refreshResult() {
        refilter(reason: "刷新结果")
    }

    private func refilter(reason: String) {
        let started = DispatchTime.now().uptimeNanoseconds
        let filter = currentFilter
        setResult(filter.isEmpty ? source : source.filter(filter.matches))
        appLog("\(reason)：\(source.count) 张里筛出 \(photos.count) 张，\(msSince(started))")
    }
}

// MARK: - 改动（可撤销）

extension AppModel {
    /// 动作作用于哪些照片：单张视图是当前这张，网格是选中的照片（按结果顺序）。
    var targetIDs: [PhotoID] {
        if isShowingSingle { return currentPhotoID.map { [$0] } ?? [] }
        return selectedIDs.sorted { (resultIndex[$0] ?? 0) < (resultIndex[$1] ?? 0) }
    }

    func photo(_ id: PhotoID) -> PhotoSummary? {
        sourceIndex[id].map { source[$0] }
    }

    func setRating(_ rating: Int) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in photo(id).map { (id, $0.rating) } })
        let after = before.mapValues { _ in rating }
        commit(.rating(before: before, after: after), title: rating == 0 ? "清除星级" : "★\(rating)")
    }

    func setFlag(_ flag: Flag) {
        let ids = targetIDs
        guard !ids.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in photo(id).map { (id, $0.flag) } })
        let after = before.mapValues { _ in flag }
        commit(.flag(before: before, after: after), title: flag == .none ? "清除标记" : flag.displayName)
    }

    /// 写库成功后才改内存里的状态；写入失败时界面不变并报错。
    func commit(_ edit: CullingEdit, title: String) {
        let started = DispatchTime.now().uptimeNanoseconds
        guard !edit.photoIDs.isEmpty else { return }
        if !edit.isEmpty {
            do {
                try library.apply(edit)
            } catch {
                message = "保存失败，改动没有生效：\(error)"
                return
            }
            history.record(edit, title: title)
            registerUndo(title: title)
            applyToMemory(edit)
            reloadIfStale()
        }
        let count = edit.photoIDs.count
        show(count > 1 ? "\(title)（\(count) 张）" : title)
        // 下一帧画出来才算界面有反应（PF-6）。
        DispatchQueue.main.async { appLog("打星 / 标记「\(title)」\(count) 张：\(msSince(started))") }
        // 自动前进只对星级、标记（加入收藏夹不算）。
        if autoAdvance, isShowingSingle, count == 1, edit.isMarkEdit {
            move(1)
        }
    }

    /// 把已经写进库的改动同步到内存。结果不重新筛（结果保持不变），只更新“已不符合”的张数。
    private func applyToMemory(_ edit: CullingEdit) {
        var source = source
        var photos = photos
        func update(_ id: PhotoID, _ change: (inout PhotoSummary) -> Void) {
            if let index = sourceIndex[id] { change(&source[index]) }
            if let index = resultIndex[id] { change(&photos[index]) }
        }
        switch edit {
        case .rating(_, let after):
            for (id, rating) in after { update(id) { $0.rating = rating } }
        case .flag(_, let after):
            for (id, flag) in after { update(id) { $0.flag = flag } }
        case .labels:
            // iPad 版没有标签（用户：“颜色标签不需要”）。
            return
        case .membership(let collection, _, _):
            membershipChanged(collection)
            return
        }
        self.source = source
        self.photos = photos
        updateStaleCount()
    }

    // MARK: 撤销（F-23）

    /// 记录在 `history` 里，系统的 `UndoManager` 只登记一个“撤销上一步”：按钮、三指滑动、⌘Z 都走它。
    func registerUndo(title: String) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoLast() }
        }
        undoManager.setActionName(title)
    }

    func undo() {
        if undoManager.canUndo {
            undoManager.undo()
        } else {
            appLog("撤销：系统的撤销记录是空的（选片记录 \(history.undoStack.count) 条）")
            show("没有可撤销的操作")
        }
    }

    func redo() {
        if undoManager.canRedo { undoManager.redo() } else { show("没有可重做的操作") }
    }

    private func undoLast() {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { DispatchQueue.main.async { appLog("撤销：\(msSince(started))") } }
        do {
            guard let entry = try history.undo({ try library.apply($0) }) else { return show("没有可撤销的操作") }
            applyToMemory(entry.edit.inverse)
            reloadIfStale()
            // 撤销时登记的就是重做。
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.redoLast() }
            }
            undoManager.setActionName(entry.title)
            show("撤销：\(entry.title)")
            followEdit(entry.edit)
        } catch {
            message = "撤销失败：\(error)"
        }
    }

    private func redoLast() {
        do {
            guard let entry = try history.redo({ try library.apply($0) }) else { return show("没有可重做的操作") }
            applyToMemory(entry.edit)
            reloadIfStale()
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.undoLast() }
            }
            undoManager.setActionName(entry.title)
            show("重做：\(entry.title)")
            followEdit(entry.edit)
        } catch {
            message = "重做失败：\(error)"
        }
    }

    /// 单张视图里撤销一张照片的改动：跳回那一张（自动前进后撤销，回到刚才打的那张）。
    private func followEdit(_ edit: CullingEdit) {
        guard isShowingSingle, edit.photoIDs.count == 1, let id = edit.photoIDs.first, resultIndex[id] != nil else { return }
        if currentPhotoID != id { showPhoto(id) }
    }

    var canUndo: Bool { !history.undoStack.isEmpty }
    var canRedo: Bool { !history.redoStack.isEmpty }

    func show(_ text: String) {
        let toast = Toast(text: text)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func setAutoAdvance(_ on: Bool) {
        guard on != autoAdvance else { return }
        autoAdvance = on
        show(on ? "自动前进：开（打完跳到下一张）" : "自动前进：关")
    }
}

// MARK: - 快捷键（F-26）

extension AppModel {
    /// 网格和单张视图收到的快捷键。“网格 ↔ 单张”在网格那边由网格决定打开哪张，100% 放大由翻页视图自己做。
    func perform(_ action: KeyAction) {
        switch action {
        case .rate(let n):
            guard !targetIDs.isEmpty else { return show("先选中照片") }
            setRating(n)
        case .flag(let flag):
            guard !targetIDs.isEmpty else { return show("先选中照片") }
            setFlag(flag)
        case .addToLastCollection:
            addToLastCollection()
        case .previous:
            if isShowingSingle { move(-1) }
        case .next:
            if isShowingSingle { move(1) }
        case .toggleSingle, .back:
            if isShowingSingle { closeSingle() }
        case .zoom:
            break
        case .zoomToFocus:
            if isShowingSingle { zoomToFocus() }
        case .toggleFocusPoint:
            if isShowingSingle { setShowsFocusPoint(!showsFocusPoint) }
        case .toggleHistogram:
            if isShowingSingle { showsHistogram.toggle() }
        case .undo:
            undo()
        case .redo:
            redo()
        }
    }
}

// MARK: - 单张视图（F-12）

extension AppModel {
    func openSingle(_ id: PhotoID) {
        guard resultIndex[id] != nil else { return }
        pageStarted = DispatchTime.now().uptimeNanoseconds
        currentPhotoID = id
        lastSingleIndex = resultIndex[id] ?? 0
        isShowingSingle = true
        loadCurrentDetail()
    }

    func closeSingle() {
        gridScrollTarget = currentPhotoID
        isShowingSingle = false
        currentPhotoID = nil
        currentDetail = nil
        isShowingOriginal = false
    }

    /// 翻到某一张（胶片条、滑动翻页、自动前进）。
    func showPhoto(_ id: PhotoID) {
        guard id != currentPhotoID, let index = resultIndex[id] else { return }
        pageStarted = DispatchTime.now().uptimeNanoseconds
        currentPhotoID = id
        lastSingleIndex = index
        isShowingOriginal = false
        loadCurrentDetail()
    }

    func move(_ offset: Int) {
        guard !photos.isEmpty else { return }
        let current = currentPhotoID.flatMap { resultIndex[$0] } ?? 0
        let target = min(max(current + offset, 0), photos.count - 1)
        if target == current, offset > 0, current == photos.count - 1 { show("已经是最后一张") }
        showPhoto(photos[target].id)
    }

    var currentIndex: Int? { currentPhotoID.flatMap { resultIndex[$0] } }
    var currentPhoto: PhotoSummary? { currentIndex.map { photos[$0] } }

    func loadCurrentDetail() {
        guard let id = currentPhotoID else { return }
        if currentDetail?.summary.id != id { currentDetail = nil }
        let reader = reader
        Task {
            let detail = await Task.detached { try? reader.detail(of: id) }.value
            guard currentPhotoID == id else { return }
            currentDetail = detail
        }
    }

    /// 单张视图上的预览第一次画出来（PF-7：翻页 ≤ 100 ms）。
    func pageDidShowPreview(_ id: PhotoID) {
        guard id == currentPhotoID, let started = pageStarted else { return }
        pageStarted = nil
        appLog("翻页到 \(photo(id)?.baseName ?? "?")：\(msSince(started))；\(MemoryProbe.describe())")
    }
}

// MARK: - 100% 放大读原图（F-13）

enum OriginalResult: Sendable {
    case image(CGImage, fileName: String)
    /// 只有 RAW：iPadOS 读不了 RAW 的完整画面，最大只能看内嵌的 1616 px（和预览差不多）。
    case rawOnly
    case offline
    /// 卡上已经没有它的文件了。
    case missing
    case failed(String)
}

extension AppModel {
    /// 从卡上读原图（JPG / HEIF），长边不超过 `maximumPixelSize`（nil 读完整尺寸）。
    /// 卡连着、文件却不在了：标“卡上已删”。`marksMissing` 为 false（停在一张上自动换原图，F-16）时不标：
    /// 那是看照片时自动发生的，不悄悄改照片的状态（同 Mac 版设计稿 §4.1）；放大时还会再读、再标。
    func loadOriginal(_ id: PhotoID, maximumPixelSize: Int?, marksMissing: Bool = true) async -> OriginalResult {
        if isSynthetic { return .failed("性能测试库没有原图") }
        guard let bookmark = (try? reader.card())?.bookmark, cardState == .connected else { return .offline }
        let reader = reader
        let started = DispatchTime.now().uptimeNanoseconds
        let (result, missing) = await Task.detached(priority: .userInitiated) { () -> (OriginalResult, [Int]) in
            guard case .success(let (access, _)) = CardConnection.open(bookmark) else { return (.offline, []) }
            defer { access.stop() }
            let sources = (try? reader.presentSources(of: [id]))?[id] ?? []
            if sources.isEmpty { return (.missing, []) }
            if sources.allSatisfy({ $0.kind == .raw }) { return (.rawOnly, []) }
            let lookup = OriginalFinder(root: access.root).lookupForViewing(sources)
            guard let found = lookup.found else {
                if let problem = lookup.problems.first { return (.failed(problem), lookup.missingLocationIDs) }
                if lookup.wasOffline { return (.offline, lookup.missingLocationIDs) }
                return (.missing, lookup.missingLocationIDs)
            }
            if Task.isCancelled { return (.failed("取消了"), []) }
            let image = maximumPixelSize.map { OriginalDecoder.decode(found.url, maximumPixelSize: $0) } ?? OriginalDecoder.decode(found.url)
            guard let image else { return (.failed("\(found.source.fileName) 解码不了"), lookup.missingLocationIDs) }
            return (.image(image, fileName: found.source.fileName), lookup.missingLocationIDs)
        }.value
        if marksMissing, !missing.isEmpty {
            let gone = (try? library.markLocationsMissing(missing)) ?? []
            appLog("读原图时发现卡上没有了：\(missing.count) 个文件，\(gone.count) 张变成卡上已删")
            reloadAll()
        }
        if case .image(let image, let name) = result {
            appLog("\(marksMissing ? "读原图" : "换原图") \(name) \(image.width)×\(image.height)：\(msSince(started))；\(MemoryProbe.describe())")
        }
        return result
    }
}

// MARK: - 对焦框（F-18）

extension AppModel {
    /// 当前这张的对焦框；详细信息还没读到、相机没记都是 nil。
    var currentFocus: FocusArea? {
        guard let detail = currentDetail, detail.summary.id == currentPhotoID else { return nil }
        return detail.focus
    }

    /// 没有对焦框时为什么没有。
    var currentFocusMissingReason: String? {
        guard let detail = currentDetail, detail.summary.id == currentPhotoID, detail.focus == nil else { return nil }
        if detail.focusState == "none" { return "这张相机没记对焦位置" }
        return detail.summary.isOnCard ? "还没读这张的对焦框，插着卡读完会出来" : "卡上已删，读不了对焦框"
    }

    func setShowsFocusPoint(_ on: Bool) {
        showsFocusPoint = on
        show(on ? (currentFocusMissingReason ?? "显示对焦框") : "隐藏对焦框")
    }

    /// 以对焦框为中心放大到 100%（已经放大了就回到适合屏幕）。
    func zoomToFocus() {
        guard currentFocus != nil else { return show(currentFocusMissingReason ?? "还没读到对焦框") }
        zoomToFocusRequest += 1
    }
}
