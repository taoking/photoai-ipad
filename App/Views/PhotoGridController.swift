import PhotoAICore
import QuartzCore
import UIKit

/// 网格（F-11）：`UICollectionView`，按天分组，缩略图按原比例完整显示。
///
/// - 捏合改每行几张（2–12），记在 UserDefaults；
/// - 轻点打开；“选择”进入多选：轻点切换，横着拖过去连选（也支持系统的两指拖选），拖到上下边缘自动滚；
/// - 数据变了只重新配置内容变了的格子，导入时网格不闪；只是星级、标记变了（照片和顺序没变）时不重做快照，
///   直接改看得见的格子（PF-6）。
@MainActor
final class PhotoGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching,
    UIGestureRecognizerDelegate {
    var onOpen: ((PhotoID) -> Void)?
    var onSelectionChanged: ((Set<PhotoID>) -> Void)?
    var onBeginSelecting: (() -> Void)?
    var onShowedPhotos: (() -> Void)?
    var onKey: ((KeyAction) -> Void)?
    /// 三指滑动撤销、重做走第一响应者的 `undoManager`（F-23）。
    var modelUndoManager: UndoManager?

    let cache: ThumbnailCache
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, PhotoID>!
    private var photosByID: [PhotoID: PhotoSummary] = [:]
    /// 上次换上的数据：只是选择变了（每点一下都会来）时不重做 1 万条的快照。
    private var appliedPhotos: [PhotoSummary] = []
    private var appliedIDs: [PhotoID] = []
    private var sectionTitles: [String: String] = [:]
    private var hasAppliedOnce = false
    private var isSelecting = false

    private var columns: Int
    private var pinchStartColumns = 0

    private var dragSelection: DragSelection?
    private var autoScroll: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0
    private var lastPanLocation: CGPoint = .zero

    private let frameMonitor = FrameMonitor()
    private var prefetchTasks: [PhotoID: Task<Void, Never>] = [:]

    init(cache: ThumbnailCache) {
        self.cache = cache
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.gridColumns)
        columns = saved > 0 ? saved : 6
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.accessibilityIdentifier = "photoGrid"
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.allowsSelectionDuringEditing = true
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: PhotoCell.reuseID)
        collectionView.register(
            DayHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: DayHeaderView.reuseID
        )
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoCell.reuseID, for: indexPath) as! PhotoCell
            if let self, let photo = self.photosByID[id] {
                cell.isSelecting = self.isSelecting
                cell.thumbSize = self.thumbSize
                cell.configure(photo, cache: self.cache)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: DayHeaderView.reuseID, for: indexPath
            ) as! DayHeaderView
            if let self, let key = self.dataSource.sectionIdentifier(for: indexPath.section) {
                header.label.text = self.sectionTitles[key]
            }
            return header
        }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        collectionView.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDragSelect(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        collectionView.addGestureRecognizer(pan)
        // 先看是不是横着拖选；不是（或者不在选择状态）马上失败，滚动照常。
        collectionView.panGestureRecognizer.require(toFail: pan)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { modelUndoManager }

    private var isCovered = false

    /// 单张视图盖上 / 关掉。关掉后重新做第一响应者，三指撤销才回到网格（全屏盖住再拿开不会再调 `viewDidAppear`）。
    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        if !covered { reclaimFirstResponder(attempt: 0) }
    }

    /// 刚关掉时就能要到第一响应者，但关掉的动画做完系统又把它给了别的视图：2 秒里每 0.1 秒看一次，丢了就再要。
    private func reclaimFirstResponder(attempt: Int) {
        guard !isCovered, attempt < 20 else { return }
        if !isFirstResponder, view.window != nil { becomeFirstResponder() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reclaimFirstResponder(attempt: attempt + 1) }
    }

    /// 快捷键（F-26）：打星、标记、加入收藏夹作用于选中的照片；空格打开第一张选中的（没选就是屏幕上第一张）。
    override var keyCommands: [UIKeyCommand]? {
        KeyAction.commands(for: .grid, action: #selector(handleKey(_:)))
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        guard let action = KeyAction(command) else { return }
        if action == .toggleSingle {
            openFirstPhoto()
        } else {
            onKey?(action)
        }
    }

    /// 打开第一张选中的，没选就是屏幕上第一张。
    private func openFirstPhoto() {
        let selected = (collectionView.indexPathsForSelectedItems ?? []).sorted()
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        if let indexPath = selected.first ?? visible.first, let id = dataSource.itemIdentifier(for: indexPath) { onOpen?(id) }
    }

    // MARK: - 数据

    func update(photos: [PhotoSummary], isSelecting: Bool, selected: Set<PhotoID>, scrollTarget: PhotoID?) {
        guard isViewLoaded else { return }
        if !hasAppliedOnce || photos != appliedPhotos {
            let ids = photos.map(\.id)
            if hasAppliedOnce, ids == appliedIDs {
                updateMarks(photos)
            } else {
                applyData(photos, ids: ids)
            }
        }
        setSelecting(isSelecting)
        syncSelection(selected)
        if let scrollTarget { scrollToPhoto(scrollTarget) }
    }

    /// 照片和顺序都没变（打星、标记、预览做好了）：只改内容变了的格子。
    private func updateMarks(_ photos: [PhotoSummary]) {
        var changed: Set<PhotoID> = []
        for photo in photos where photosByID[photo.id] != photo {
            photosByID[photo.id] = photo
            changed.insert(photo.id)
        }
        appliedPhotos = photos
        guard !changed.isEmpty else { return }
        for case let cell as PhotoCell in collectionView.visibleCells {
            guard let id = cell.photoID, changed.contains(id), let photo = photosByID[id] else { continue }
            cell.configure(photo, cache: cache)
        }
    }

    /// 从单张视图回来：那一张不在屏幕上就滚过去。
    private func scrollToPhoto(_ id: PhotoID) {
        guard let indexPath = dataSource.indexPath(for: id) else { return }
        if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
    }

    private func applyData(_ photos: [PhotoSummary], ids: [PhotoID]) {
        appliedPhotos = photos
        appliedIDs = ids
        var order: [String] = []
        var items: [String: [PhotoID]] = [:]
        var byID: [PhotoID: PhotoSummary] = [:]
        byID.reserveCapacity(photos.count)
        for photo in photos {
            let key = photo.day ?? "undated"
            if items[key] == nil { order.append(key) }
            items[key, default: []].append(photo.id)
            byID[photo.id] = photo
        }
        var titles: [String: String] = [:]
        for key in order {
            let name = key == "undated" ? "日期未知" : DayFormat.title(key)
            titles[key] = "\(name) · \(items[key]?.count ?? 0) 张"
        }

        var snapshot = NSDiffableDataSourceSnapshot<String, PhotoID>()
        snapshot.appendSections(order)
        for key in order { snapshot.appendItems(items[key] ?? [], toSection: key) }
        let changed = photos.compactMap { photo in
            photosByID[photo.id].map { $0 == photo ? nil : photo.id } ?? nil
        }
        photosByID = byID
        sectionTitles = titles
        if hasAppliedOnce {
            if !changed.isEmpty { snapshot.reconfigureItems(changed) }
            dataSource.apply(snapshot, animatingDifferences: false)
        } else {
            dataSource.applySnapshotUsingReloadData(snapshot)
            hasAppliedOnce = !photos.isEmpty
            if !photos.isEmpty {
                // 下一帧画出来以后才算“网格可见”。
                DispatchQueue.main.async { [weak self] in self?.onShowedPhotos?() }
            }
        }
        refreshVisibleHeaders()
    }

    private func refreshVisibleHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = collectionView.supplementaryView(
                forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath
            ) as? DayHeaderView, let key = dataSource.sectionIdentifier(for: indexPath.section) else { continue }
            header.label.text = sectionTitles[key]
        }
    }

    private func setSelecting(_ selecting: Bool) {
        guard selecting != isSelecting else { return }
        isSelecting = selecting
        collectionView.isEditing = selecting
        if !selecting {
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        for case let cell as PhotoCell in collectionView.visibleCells { cell.isSelecting = selecting }
    }

    private func syncSelection(_ selected: Set<PhotoID>) {
        guard isSelecting else { return }
        let current = Set((collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
        guard current != selected else { return }
        for id in current.subtracting(selected) {
            if let indexPath = dataSource.indexPath(for: id) { collectionView.deselectItem(at: indexPath, animated: false) }
        }
        for id in selected.subtracting(current) {
            if let indexPath = dataSource.indexPath(for: id) { collectionView.selectItem(at: indexPath, animated: false, scrollPosition: []) }
        }
    }

    private func reportSelection() {
        let ids = (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        onSelectionChanged?(Set(ids))
    }

    // MARK: - 布局

    /// 格子的边长（像素）决定缩略图解码到哪一档（PF-2）。
    private var thumbSize: ThumbnailCache.Size {
        let width = (collectionView?.bounds.width ?? view.bounds.width) - 16
        return .fitting(pixels: width / CGFloat(columns) * (view.window?.screen.scale ?? 2))
    }

    private func refreshVisibleCells() {
        let size = thumbSize
        for case let cell as PhotoCell in collectionView.visibleCells {
            guard let id = cell.photoID, let photo = photosByID[id], cell.thumbSize != size else { continue }
            cell.thumbSize = size
            cell.configure(photo, cache: cache)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        let columns = columns
        return UICollectionViewCompositionalLayout { _, _ in
            let fraction = 1 / CGFloat(columns)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction), heightDimension: .fractionalHeight(1)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(fraction)),
                repeatingSubitem: item, count: columns
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(36)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchStartColumns = columns
        case .changed:
            // 张开变大（每行少几张），捏拢变小；每 25% 换一档。
            let steps = Int((log2(pinch.scale) / log2(1.25)).rounded(.towardZero))
            let target = min(12, max(2, pinchStartColumns - steps))
            guard target != columns else { return }
            let anchor = collectionView.indexPathForItem(at: pinch.location(in: collectionView))
            columns = target
            UserDefaults.standard.set(columns, forKey: DefaultsKey.gridColumns)
            collectionView.setCollectionViewLayout(makeLayout(), animated: false)
            if let anchor { collectionView.scrollToItem(at: anchor, at: .centeredVertically, animated: false) }
            refreshVisibleCells()
        default:
            break
        }
    }

    // MARK: - 轻点、选择

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isSelecting {
            reportSelection()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        if let id = dataSource.itemIdentifier(for: indexPath) { onOpen?(id) }
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if isSelecting { reportSelection() }
    }

    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        if !isSelecting {
            setSelecting(true)
            onBeginSelecting?()
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let size = thumbSize
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath), photosByID[id]?.thumbState == .ready,
                  cache.cached(id, size: size) == nil, prefetchTasks[id] == nil else { continue }
            prefetchTasks[id] = Task { [cache, weak self] in
                _ = await cache.load(id, size: size)
                self?.prefetchTasks[id] = nil
            }
        }
    }

    /// 快速滚过去、不会显示了：没开始的解码不做了。
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { continue }
            prefetchTasks.removeValue(forKey: id)?.cancel()
        }
    }

    // MARK: - 拖过去连选

    /// 一次拖选：从哪一格开始、是选上还是取消、拖之前的选择（拖回来时还原）。
    private struct DragSelection {
        var start: Int
        var selecting: Bool
        var before: Set<Int>
        var current: Int
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, gestureRecognizer.view == collectionView else { return true }
        guard isSelecting else { return false }
        // 横着拖才是连选，竖着拖照常滚动。
        let velocity = pan.velocity(in: collectionView)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func handleDragSelect(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: collectionView)
        lastPanLocation = location
        switch pan.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location) else { return }
            let flat = flatIndex(indexPath)
            let selected = Set((collectionView.indexPathsForSelectedItems ?? []).map(flatIndex))
            dragSelection = DragSelection(start: flat, selecting: !selected.contains(flat), before: selected, current: flat)
            applyDrag(to: flat)
        case .changed:
            updateDrag(at: location)
            updateAutoScroll(location: pan.location(in: view))
        default:
            dragSelection = nil
            stopAutoScroll()
            reportSelection()
        }
    }

    private func updateDrag(at location: CGPoint) {
        guard dragSelection != nil, let indexPath = collectionView.indexPathForItem(at: location) else { return }
        applyDrag(to: flatIndex(indexPath))
    }

    private func applyDrag(to target: Int) {
        guard var drag = dragSelection else { return }
        let oldRange = min(drag.start, drag.current)...max(drag.start, drag.current)
        let newRange = min(drag.start, target)...max(drag.start, target)
        for flat in oldRange where !newRange.contains(flat) {
            setItem(flat, selected: drag.before.contains(flat))
        }
        for flat in newRange { setItem(flat, selected: drag.selecting) }
        drag.current = target
        dragSelection = drag
    }

    private func setItem(_ flat: Int, selected: Bool) {
        guard let indexPath = indexPath(flat: flat) else { return }
        if selected {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        } else {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
    }

    private func flatIndex(_ indexPath: IndexPath) -> Int {
        var index = indexPath.item
        for section in 0..<indexPath.section { index += collectionView.numberOfItems(inSection: section) }
        return index
    }

    private func indexPath(flat: Int) -> IndexPath? {
        var remaining = flat
        for section in 0..<collectionView.numberOfSections {
            let count = collectionView.numberOfItems(inSection: section)
            if remaining < count { return IndexPath(item: remaining, section: section) }
            remaining -= count
        }
        return nil
    }

    private func updateAutoScroll(location: CGPoint) {
        let edge: CGFloat = 80
        let height = view.bounds.height
        if location.y < edge {
            autoScrollSpeed = -(edge - location.y) * 0.4
        } else if location.y > height - edge {
            autoScrollSpeed = (location.y - (height - edge)) * 0.4
        } else {
            autoScrollSpeed = 0
        }
        if autoScrollSpeed != 0, autoScroll == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
            link.add(to: .main, forMode: .common)
            autoScroll = link
        } else if autoScrollSpeed == 0 {
            stopAutoScroll()
        }
    }

    @objc private func autoScrollTick() {
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let minY = -collectionView.adjustedContentInset.top
        let y = min(maxY, max(minY, collectionView.contentOffset.y + autoScrollSpeed))
        let delta = y - collectionView.contentOffset.y
        collectionView.contentOffset.y = y
        lastPanLocation.y += delta
        updateDrag(at: lastPanLocation)
    }

    private func stopAutoScroll() {
        autoScroll?.invalidate()
        autoScroll = nil
        autoScrollSpeed = 0
    }

    // MARK: - 滚动帧率（PF-2）

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        frameMonitor.start()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { frameMonitor.stop(columns: columns) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        frameMonitor.stop(columns: columns)
    }
}

/// 滚动时数帧：平均帧率、超过两帧时长的卡顿次数。滚动超过 1 秒才记日志。
@MainActor
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var first: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var worst: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        frames = 0
        hitches = 0
        worst = 0
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last == 0 {
            first = link.timestamp
        } else {
            let interval = link.timestamp - last
            worst = max(worst, interval)
            if interval > (link.targetTimestamp - link.timestamp) * 2.5 { hitches += 1 }
            frames += 1
        }
        last = link.timestamp
    }

    func stop(columns: Int) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        let duration = last - first
        guard duration > 1, frames > 0 else { return }
        appLog(String(
            format: "网格滚动 %.1f 秒（每行 %d 张）：平均 %.0f 帧/秒，卡顿 %d 次，最长一帧 %.1f ms；%@",
            duration, columns, Double(frames) / duration, hitches, worst * 1000, MemoryProbe.describe()
        ))
    }
}

