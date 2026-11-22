import PhotoAICore
import UIKit

/// 单张视图的翻页（F-12）：横向分页的 `UICollectionView`，每页一个能缩放的 `ZoomPageCell`。
///
/// - 左右滑翻页；捏合缩放；双击放大到 50%（再双击回到适合屏幕）；没放大时往下滑回网格；轻点显示 / 隐藏工具条。
/// - 没放大时在照片左边三分之一上下拖动改星级（照 Lightroom iPad）：往上加、往下减，松手才打。
/// - 缩放比例按原图像素算：1 = 100%（原图一个像素对屏幕一个像素）。放大到预览不够清楚时从卡上读原图（F-13）。
/// - 在一张上停 0.3 秒，屏幕比预览清楚时按屏幕尺寸换上原图（F-16）。
/// - 对焦框（F-18）画在当前这张上，跟着缩放走。
/// - 翻页时前后几张的 1600 预览先解码好（PF-7）。
@MainActor
final class PhotoPagerController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UIGestureRecognizerDelegate {
    var onPageChanged: ((PhotoID) -> Void)?
    var onToggleChrome: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onShowedPreview: ((PhotoID) -> Void)?
    var onRate: ((Int) -> Void)?
    var loadOriginal: ((PhotoID, Int?, Bool) async -> OriginalResult)?
    /// 当前这张换上了原图（true）或回到预览（false）。
    var onImageSource: ((PhotoID, Bool) -> Void)?
    var onKey: ((KeyAction) -> Void)?
    /// 三指滑动撤销、重做走第一响应者的 `undoManager`。
    var modelUndoManager: UndoManager?

    private let previews: PreviewImageCache
    private var collectionView: UICollectionView!
    private let layout = UICollectionViewFlowLayout()
    private var photos: [PhotoSummary] = []
    private var ids: [PhotoID] = []
    private var index: [PhotoID: Int] = [:]
    private var currentID: PhotoID?
    private(set) var isCardConnected = false
    private var dismissPan: UIPanGestureRecognizer!
    private var ratingPan: UIPanGestureRecognizer!
    private let ratingHUD = RatingHUD()
    /// 拖动开始时的星级和现在拖到的星级。
    private var ratingStart = 0
    private var ratingValue = 0
    private let ratingFeedback = UISelectionFeedbackGenerator()
    /// 当前这张的对焦框；`showsFocus` 关着时不画，“放大到对焦点”照样用。
    private var focus: (id: PhotoID, area: FocusArea)?
    private var showsFocus = false
    /// 处理过的“放大到对焦点”次数。建的时候从模型拿，不然重开单张视图会按上次的次数放大一下。
    var handledZoomToFocusRequest = 0

    init(previews: PreviewImageCache) {
        self.previews = previews
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.accessibilityIdentifier = "photoPager"
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ZoomPageCell.self, forCellWithReuseIdentifier: ZoomPageCell.reuseID)
        view.addSubview(collectionView)

        dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        dismissPan.maximumNumberOfTouches = 1
        collectionView.addGestureRecognizer(dismissPan)
        // 先看是不是往下滑、是不是在左边拖星级；都不是马上失败，翻页照常。
        collectionView.panGestureRecognizer.require(toFail: dismissPan)

        ratingPan = UIPanGestureRecognizer(target: self, action: #selector(handleRatingPan(_:)))
        ratingPan.delegate = self
        ratingPan.maximumNumberOfTouches = 1
        collectionView.addGestureRecognizer(ratingPan)
        collectionView.panGestureRecognizer.require(toFail: ratingPan)

        ratingHUD.translatesAutoresizingMaskIntoConstraints = false
        ratingHUD.alpha = 0
        view.addSubview(ratingHUD)
        NSLayoutConstraint.activate([
            ratingHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            ratingHUD.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { modelUndoManager }

    /// 快捷键（F-26）。
    override var keyCommands: [UIKeyCommand]? {
        KeyAction.commands(for: .single, action: #selector(handleKey(_:)))
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        guard let action = KeyAction(command) else { return }
        if action == .zoom {
            currentCell?.toggleFullZoom()
        } else {
            onKey?(action)
        }
    }

    // MARK: - 数据

    /// `canTakeFocus`：没有输入框开着（收藏夹起名）。点了 SwiftUI 的按钮第一响应者有时会被拿走，快捷键就收不到；
    /// 每次界面更新时要回来。`focus`：当前这张的对焦框；`zoomToFocusRequest` 变了就放大到对焦点。
    func update(
        photos: [PhotoSummary], current: PhotoID?, cardConnected: Bool, canTakeFocus: Bool,
        focus: (id: PhotoID, area: FocusArea)?, showsFocus: Bool, zoomToFocusRequest: Int
    ) {
        guard isViewLoaded else { return }
        defer { updateFocus(focus, shows: showsFocus, zoomRequest: zoomToFocusRequest) }
        if canTakeFocus, !isFirstResponder, view.window != nil {
            DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
        }
        isCardConnected = cardConnected
        let newIDs = photos.map(\.id)
        let previous = self.photos
        self.photos = photos
        if newIDs != ids {
            ids = newIDs
            index = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
            // 第一次布局前页的大小还是默认的 50×50：先定好，不然一屏铺几百页、每页都解码预览。
            syncPageSize()
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if let current, let page = index[current] { scroll(to: page, animated: false) }
            currentID = current
            markCurrent()
            prefetchNeighbors()
            return
        }
        // 预览刚做好的那几页换上预览。
        for case let cell as ZoomPageCell in collectionView.visibleCells {
            guard let id = cell.photoID, let page = index[id], previous.indices.contains(page),
                  previous[page].thumbState != photos[page].thumbState else { continue }
            configure(cell, page: page)
        }
        for case let cell as ZoomPageCell in collectionView.visibleCells { cell.isCardConnected = cardConnected }
        guard let current, current != currentID, let page = index[current] else { return }
        let adjacent = currentID.flatMap { index[$0] }.map { abs($0 - page) == 1 } ?? false
        currentID = current
        markCurrent()
        scroll(to: page, animated: adjacent)
        prefetchNeighbors()
    }

    /// 只有当前这张换原图、画对焦框。
    private func markCurrent() {
        for case let cell as ZoomPageCell in collectionView.visibleCells {
            cell.isCurrent = cell.photoID != nil && cell.photoID == currentID
        }
    }

    private func updateFocus(_ focus: (id: PhotoID, area: FocusArea)?, shows: Bool, zoomRequest: Int) {
        self.focus = focus
        showsFocus = shows
        for case let cell as ZoomPageCell in collectionView.visibleCells { cell.zoomView.focusArea = drawnFocus(for: cell.photoID) }
        guard zoomRequest != handledZoomToFocusRequest else { return }
        handledZoomToFocusRequest = zoomRequest
        if let focus, focus.id == currentID { currentCell?.toggleZoom(toFocus: focus.area) }
    }

    private func drawnFocus(for id: PhotoID?) -> FocusArea? {
        guard showsFocus, let focus, focus.id == id else { return nil }
        return focus.area
    }

    private func scroll(to page: Int, animated: Bool) {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        collectionView.setContentOffset(CGPoint(x: CGFloat(page) * width, y: 0), animated: animated)
    }

    private func prefetchNeighbors() {
        guard let currentID, let page = index[currentID] else { return }
        let neighbors = [1, -1, 2].compactMap { offset -> PhotoID? in
            let target = page + offset
            return photos.indices.contains(target) && photos[target].thumbState == .ready ? ids[target] : nil
        }
        previews.prefetch(neighbors)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 转屏、显示 / 隐藏工具条后页的大小变了：保持在同一页。
        guard syncPageSize() else { return }
        collectionView.layoutIfNeeded()
        if let currentID, let page = index[currentID] { scroll(to: page, animated: false) }
        // 转屏后屏幕上要的像素变了，看要不要换更大的原图。
        currentCell?.scheduleScreenOriginal()
    }

    /// 页和翻页视图一样大。大小变了返回 true。
    @discardableResult
    private func syncPageSize() -> Bool {
        let size = collectionView.bounds.size
        guard layout.itemSize != size, size.width > 0, size.height > 0 else { return false }
        layout.itemSize = size
        layout.invalidateLayout()
        return true
    }

    // MARK: - 页

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ZoomPageCell.reuseID, for: indexPath) as! ZoomPageCell
        if !cell.isWired {
            cell.isWired = true
            cell.zoomView.panGestureRecognizer.require(toFail: dismissPan)
            cell.zoomView.panGestureRecognizer.require(toFail: ratingPan)
        }
        configure(cell, page: indexPath.item)
        return cell
    }

    private func configure(_ cell: ZoomPageCell, page: Int) {
        let photo = photos[page]
        cell.isCardConnected = isCardConnected
        cell.onSingleTap = { [weak self] in self?.onToggleChrome?() }
        cell.onShowedPreview = { [weak self] id in self?.onShowedPreview?(id) }
        cell.loadOriginal = loadOriginal
        cell.onImageSource = { [weak self] id, original in self?.onImageSource?(id, original) }
        cell.configure(photo, previews: previews)
        cell.zoomView.focusArea = drawnFocus(for: photo.id)
        cell.isCurrent = photo.id == currentID
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // 离开屏幕的页放掉原图（一张完整的约 130 MB）。
        (cell as? ZoomPageCell)?.resetZoom()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        reportPage()
    }

    private func reportPage() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let page = Int((collectionView.contentOffset.x / width).rounded())
        guard ids.indices.contains(page), ids[page] != currentID else { return }
        currentID = ids[page]
        markCurrent()
        onPageChanged?(ids[page])
        prefetchNeighbors()
    }

    private var currentCell: ZoomPageCell? {
        guard let currentID, let page = index[currentID] else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: page, section: 0)) as? ZoomPageCell
    }

    // MARK: - 往下滑回网格

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === dismissPan || pan === ratingPan else { return true }
        // 方向看已经拖出去的距离；按住不动再拖时速度可能还是 0，只看速度会判错。
        let translation = pan.translation(in: view)
        let direction = translation == .zero ? pan.velocity(in: view) : translation
        guard abs(direction.y) > abs(direction.x), let cell = currentCell, cell.zoomView.isAtMinimumZoom else { return false }
        // 按下的地方（不是已经拖到的地方）在左边三分之一：拖星级；别的地方往下滑：回网格。
        let start = pan.location(in: view).x - translation.x
        let inRatingZone = start < view.bounds.width / 3
        return pan === ratingPan ? inRatingZone && currentPhoto != nil : !inRatingZone && direction.y > 0
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard let cell = currentCell else { return }
        let translation = pan.translation(in: view)
        switch pan.state {
        case .changed:
            let y = max(0, translation.y)
            let scale = max(0.7, 1 - y / 1200)
            cell.zoomView.transform = CGAffineTransform(translationX: translation.x, y: y).scaledBy(x: scale, y: scale)
        case .ended where translation.y > 120 || pan.velocity(in: view).y > 900:
            onDismiss?()
        default:
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                cell.zoomView.transform = .identity
            }
        }
    }

    // MARK: - 左边上下拖动改星级（F-20）

    /// 每拖这么多点改一颗星：从 0 拖到 5 星约 200 点，一只手拇指够得着。
    private static let pointsPerStar: CGFloat = 40

    private var currentPhoto: PhotoSummary? {
        currentID.flatMap { index[$0] }.map { photos[$0] }
    }

    @objc private func handleRatingPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            ratingStart = currentPhoto?.rating ?? 0
            ratingValue = ratingStart
            ratingHUD.show(rating: ratingValue)
            ratingFeedback.prepare()
            UIView.animate(withDuration: 0.12) { self.ratingHUD.alpha = 1 }
            followRatingPan(pan)
        case .changed:
            followRatingPan(pan)
        case .ended:
            // 拖得快时可能没有 changed 就结束了：按松手时的位置再算一次。
            followRatingPan(pan)
            hideRatingHUD()
            appLog("拖动改星：\(ratingStart) → \(ratingValue)（拖了 \(Int(-pan.translation(in: view).y)) 点）")
            if ratingValue != ratingStart { onRate?(ratingValue) }
        default:
            hideRatingHUD()
        }
    }

    private func followRatingPan(_ pan: UIPanGestureRecognizer) {
        let steps = Int((-pan.translation(in: view).y / Self.pointsPerStar).rounded(.towardZero))
        let value = min(max(ratingStart + steps, 0), 5)
        guard value != ratingValue else { return }
        ratingValue = value
        ratingHUD.show(rating: value)
        ratingFeedback.selectionChanged()
    }

    private func hideRatingHUD() {
        UIView.animate(withDuration: 0.25, delay: 0.15) { self.ratingHUD.alpha = 0 }
    }
}

/// 拖星级时屏幕中间显示的五颗星和“N 星”。
final class RatingHUD: UIView {
    private let stars = (1...5).map { _ in UIImageView() }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 18
        clipsToBounds = true
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)

        let row = UIStackView(arrangedSubviews: stars)
        row.spacing = 10
        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        for star in stars { star.preferredSymbolConfiguration = config }
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [row, label])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
        accessibilityIdentifier = "ratingHUD"
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    func show(rating: Int) {
        for (offset, star) in stars.enumerated() {
            let on = offset < rating
            star.image = UIImage(systemName: on ? "star.fill" : "star")
            star.tintColor = on ? .systemYellow : UIColor(white: 1, alpha: 0.45)
        }
        label.text = rating == 0 ? "无星级" : "\(rating) 星"
    }
}

/// 一页：能缩放的图。缩放比例 1 = 原图 100%。
@MainActor
final class ZoomPageCell: UICollectionViewCell {
    static let reuseID = "ZoomPage"

    let zoomView = ZoomView()
    private let placeholder = UILabel()
    private let status = PaddedLabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var previewTask: Task<Void, Never>?
    private var originalTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private(set) var photoID: PhotoID?
    private var photo: PhotoSummary?
    private var previewImage: UIImage?
    /// 已经换上的原图是多大一档：0 还是预览，0.5 是 50%，1 是 100%。
    private var originalLevel: CGFloat = 0
    /// 这张没有可读的原图（只有 RAW、卡上没了），不再去卡上找。
    private var noOriginal = false
    /// 停在这张上 0.3 秒后按屏幕尺寸换上的原图（F-16），约 15 MB；离开屏幕时放掉。
    private var screenImage: UIImage?
    private var screenTask: Task<Void, Never>?

    var isWired = false
    var isCardConnected = false {
        didSet { if isCardConnected, !oldValue { scheduleScreenOriginal() } }
    }
    /// 是翻页视图正在看的这张：只有它换原图。
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            if isCurrent { scheduleScreenOriginal() } else { screenTask?.cancel() }
        }
    }
    var onSingleTap: (() -> Void)?
    var onShowedPreview: ((PhotoID) -> Void)?
    /// 照片 id、长边上限（nil 读完整的）、卡上没了要不要标“卡上已删”。
    var loadOriginal: ((PhotoID, Int?, Bool) async -> OriginalResult)?
    var onImageSource: ((PhotoID, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        zoomView.frame = contentView.bounds
        zoomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(zoomView)
        zoomView.onZoomEnded = { [weak self] in self?.zoomEnded() }

        placeholder.textColor = .lightGray
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.numberOfLines = 0
        placeholder.textAlignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholder)

        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .white
        status.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        status.layer.cornerRadius = 8
        status.clipsToBounds = true
        status.numberOfLines = 0
        status.insets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.isHidden = true
        contentView.addSubview(status)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),
            status.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            status.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            status.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8),
            spinner.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        zoomView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        zoomView.addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewTask?.cancel()
        originalTask?.cancel()
        statusTask?.cancel()
        isCurrent = false
        photoID = nil
        previewImage = nil
        screenImage = nil
        zoomView.focusArea = nil
        originalLevel = 0
        noOriginal = false
        noOriginalText = nil
        zoomView.transform = .identity
        hideStatus()
    }

    func configure(_ photo: PhotoSummary, previews: PreviewImageCache) {
        let samePhoto = photoID == photo.id
        self.photo = photo
        photoID = photo.id
        accessibilityIdentifier = "page-\(photo.baseName)"
        if samePhoto, previewImage != nil { return }

        let pixelSize = CGSize(width: photo.width ?? 1600, height: photo.height ?? 1067)
        if let image = previews.cached(photo.id) {
            show(preview: image, pixelSize: pixelSize)
            return
        }
        zoomView.setImage(nil, pixelSize: pixelSize)
        guard photo.thumbState == .ready else {
            placeholder.text = switch photo.thumbState {
            case .failed: "预览做不出来（原片解码不了）"
            default: photo.isOnCard ? "预览还没做好\n插着卡会自动做" : "卡上已删，做不了预览了"
            }
            placeholder.isHidden = false
            return
        }
        placeholder.isHidden = true
        let id = photo.id
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let image = await previews.load(id)
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            if let image {
                self.show(preview: image, pixelSize: pixelSize)
            } else {
                self.placeholder.text = "预览文件读不了"
                self.placeholder.isHidden = false
            }
        }
    }

    private func show(preview image: UIImage, pixelSize: CGSize) {
        previewImage = image
        placeholder.isHidden = true
        zoomView.setImage(image, pixelSize: pixelSize)
        if let photoID {
            // 下一帧画出来才算翻页完成。
            DispatchQueue.main.async { [weak self] in self?.onShowedPreview?(photoID) }
        }
        scheduleScreenOriginal()
    }

    /// 回到适合屏幕，放掉原图（包括按屏幕尺寸换上的）。
    func resetZoom() {
        originalTask?.cancel()
        screenTask?.cancel()
        zoomView.transform = .identity
        if zoomView.zoomScale != zoomView.minimumZoomScale { zoomView.setZoomScale(zoomView.minimumZoomScale, animated: false) }
        dropOriginal()
        if screenImage != nil {
            screenImage = nil
            zoomView.replaceImage(previewImage)
            if let photoID { onImageSource?(photoID, false) }
        }
    }

    /// 放掉放大时读的原图（一张完整的约 130 MB），回到按屏幕尺寸的原图或预览。
    private func dropOriginal() {
        guard originalLevel > 0 else { return }
        originalLevel = 0
        zoomView.replaceImage(screenImage ?? previewImage)
        if let photoID { onImageSource?(photoID, screenImage != nil) }
    }

    /// 屏幕上正在画的图的长边像素。
    private var displayedPixels: CGFloat {
        zoomView.imageView.image.map { max($0.size.width, $0.size.height) * $0.scale } ?? 1
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    /// 双击：适合屏幕 ↔ 50%（照片比屏幕小、50% 还不到适合屏幕时放到 100%）。
    @objc private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        if !zoomView.isAtMinimumZoom {
            zoomView.setZoomScale(zoomView.minimumZoomScale, animated: true)
            return
        }
        let target: CGFloat = zoomView.minimumZoomScale < 0.5 ? 0.5 : zoomView.maximumZoomScale
        zoomView.zoom(to: target, around: tap.location(in: zoomView.imageView))
    }

    /// 放大到对焦点（⇧Z）：以对焦框中心放大到 100%；已经放大了就回到适合屏幕。
    func toggleZoom(toFocus area: FocusArea) {
        if !zoomView.isAtMinimumZoom {
            zoomView.setZoomScale(zoomView.minimumZoomScale, animated: true)
            return
        }
        let bounds = zoomView.imageView.bounds
        zoomView.zoom(to: 1, around: CGPoint(x: area.centerX * bounds.width, y: area.centerY * bounds.height))
    }

    /// 快捷键 Z：适合屏幕 ↔ 100%，以画面中间为中心。
    func toggleFullZoom() {
        if !zoomView.isAtMinimumZoom {
            zoomView.setZoomScale(zoomView.minimumZoomScale, animated: true)
        } else {
            let center = zoomView.convert(CGPoint(x: zoomView.bounds.midX, y: zoomView.bounds.midY), to: zoomView.imageView)
            zoomView.zoom(to: 1, around: center)
        }
    }

    // MARK: - 按屏幕尺寸换原图（F-16）

    /// 当前这张、预览已经画出来、卡连着：停 0.3 秒再读，快速翻页时不读中间的。
    /// 转屏、隐藏工具条后屏幕上的照片变大了也再看一次（手里的图不够大才读）。
    func scheduleScreenOriginal() {
        screenTask?.cancel()
        guard isCurrent, isCardConnected, !noOriginal, previewImage != nil, let id = photoID else { return }
        screenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            await self.loadScreenOriginal(id)
        }
    }

    /// 适合屏幕时屏幕上要的像素比预览多一成以上才读（竖着拿 iPad 看横图、工具条占掉一块时可能不读）。
    /// 读不到就留在预览，不提示：这是自动的，放大时会说为什么。
    private func loadScreenOriginal(_ id: PhotoID) async {
        guard originalLevel == 0, let loadOriginal else { return }
        let longEdge = max(zoomView.pixelSize.width, zoomView.pixelSize.height)
        let needed = (longEdge * zoomView.minimumZoomScale).rounded(.up)
        guard needed > displayedPixels * 1.1 else { return }
        let result = await loadOriginal(id, Int(needed), false)
        guard !Task.isCancelled, photoID == id else { return }
        switch result {
        case .image(let image, _):
            screenImage = UIImage(cgImage: image)
            // 已经放大、换上了更大的原图：先不换，缩回适合屏幕时换上这张。
            guard originalLevel == 0 else { return }
            zoomView.replaceImage(screenImage)
            onImageSource?(id, true)
        case .rawOnly:
            noOriginal = true
        case .offline, .missing, .failed:
            break
        }
    }

    // MARK: - 原图（F-13）

    /// 缩放结束：屏幕上要的像素比手里的图多时从卡上读原图；回到适合屏幕时放掉。
    private func zoomEnded() {
        let scale = zoomView.zoomScale
        if zoomView.isAtMinimumZoom {
            originalTask?.cancel()
            dropOriginal()
            hideStatus()
            return
        }
        guard let photo, !noOriginal else {
            if noOriginal { showStatus(noOriginalReason, autoHide: true) }
            return
        }
        let longEdge = max(zoomView.pixelSize.width, zoomView.pixelSize.height)
        guard longEdge * scale > displayedPixels * 1.15 else { return }
        let level: CGFloat = scale <= 0.5 ? 0.5 : 1
        guard level > originalLevel else { return }
        guard isCardConnected else {
            showStatus("卡没连接：放大看的是预览，插上卡能看原图", autoHide: true)
            return
        }
        let id = photo.id
        originalTask?.cancel()
        showStatus("正在读原图…", autoHide: false, spinning: true)
        originalTask = Task { [weak self, loadOriginal] in
            guard let loadOriginal else { return }
            let result = await loadOriginal(id, level < 1 ? Int((longEdge * level).rounded(.up)) : nil, true)
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            switch result {
            case .image(let image, _):
                // 已经缩回适合屏幕了就不换。
                guard !self.zoomView.isAtMinimumZoom else { return self.hideStatus() }
                self.originalLevel = level
                self.zoomView.replaceImage(UIImage(cgImage: image))
                self.onImageSource?(id, true)
                self.showStatus(level < 1 ? "原图 50%" : "原图 100%", autoHide: true)
            case .rawOnly:
                self.noOriginal = true
                self.showStatus(self.noOriginalReason, autoHide: true)
            case .missing:
                self.noOriginal = true
                self.noOriginalText = "卡上已经没有这张的文件了，放大看的是预览"
                self.showStatus(self.noOriginalReason, autoHide: true)
            case .offline:
                self.showStatus("卡没连接：放大看的是预览，插上卡能看原图", autoHide: true)
            case .failed(let reason):
                self.showStatus("读不了原图：\(reason)", autoHide: true)
            }
        }
    }

    private var noOriginalText: String?
    private var noOriginalReason: String {
        noOriginalText ?? "只有 RAW：iPad 读不了 RAW 的完整画面，最大看 1616 像素"
    }

    private func showStatus(_ text: String, autoHide: Bool, spinning: Bool = false) {
        statusTask?.cancel()
        status.text = text
        status.isHidden = false
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        guard autoHide else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.hideStatus()
        }
    }

    private func hideStatus() {
        status.isHidden = true
        spinner.stopAnimating()
    }
}

/// 能缩放的图。`imageView` 的大小按原图像素 ÷ 屏幕倍数定，所以缩放比例 1 就是 100%；
/// 换成更清楚的图（原图）时大小不变，缩放位置不跳。
/// 对焦框不放进 `imageView`（不然线跟着放大变粗），每次滚动、缩放按照片上的位置重新摆。
@MainActor
final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private(set) var pixelSize = CGSize(width: 1600, height: 1067)
    var onZoomEnded: (() -> Void)?
    private var lastBounds: CGSize = .zero
    private let focusFrame = FocusFrameView()
    /// 要画的对焦框（转正后的照片上 0–1），nil 不画。
    var focusArea: FocusArea? {
        didSet { if focusArea != oldValue { layoutFocusFrame() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        focusFrame.isHidden = true
        addSubview(focusFrame)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    var isAtMinimumZoom: Bool { zoomScale <= minimumZoomScale * 1.01 }

    func setImage(_ image: UIImage?, pixelSize: CGSize) {
        self.pixelSize = pixelSize
        imageView.image = image
        zoomScale = 1
        let scale = max(screenScale, 1)
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale))
        contentSize = imageView.frame.size
        updateZoomScales(resetToFit: true)
        layoutFocusFrame()
    }

    /// 换图，大小和缩放不变。
    func replaceImage(_ image: UIImage?) {
        imageView.image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            updateZoomScales(resetToFit: isAtMinimumZoom)
        }
        centerContent()
        layoutFocusFrame()
    }

    private func layoutFocusFrame() {
        guard let area = focusArea, imageView.image != nil, imageView.bounds.width > 0 else {
            focusFrame.isHidden = true
            return
        }
        let size = imageView.bounds.size
        var rect = imageView.convert(
            CGRect(x: area.x * size.width, y: area.y * size.height, width: area.width * size.width, height: area.height * size.height),
            to: self
        )
        // 广域、自由点的框只有图宽 3%，适合屏幕时也就二三十点；再小的至少画 18 点见方，看得见。
        let minimumSide: CGFloat = 18
        rect = rect.insetBy(dx: min(0, (rect.width - minimumSide) / 2), dy: min(0, (rect.height - minimumSide) / 2))
        focusFrame.frame = rect
        focusFrame.isHidden = false
        bringSubviewToFront(focusFrame)
    }

    private func updateZoomScales(resetToFit: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: imageView.bounds.width, height: imageView.bounds.height)
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        // 最大 100%；照片比屏幕还小时，适合屏幕就是最大。
        maximumZoomScale = max(1, fit)
        if resetToFit || zoomScale < fit {
            zoomScale = fit
        } else if zoomScale > maximumZoomScale {
            zoomScale = maximumZoomScale
        }
        centerContent()
    }

    private func centerContent() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    /// 以 `point`（`imageView` 里的坐标）为中心放大到 `scale`。
    func zoom(to scale: CGFloat, around point: CGPoint) {
        let scale = min(max(scale, minimumZoomScale), maximumZoomScale)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        layoutFocusFrame()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomEnded?()
    }
}

/// 对焦框：绿色细框，外面一圈淡淡的黑影，亮的地方也看得清。
final class FocusFrameView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.borderColor = UIColor.systemGreen.cgColor
        layer.borderWidth = 1.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 1.5
        layer.shadowOffset = .zero
        accessibilityIdentifier = "focusFrame"
        isAccessibilityElement = true
        accessibilityLabel = "对焦框"
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }
}
