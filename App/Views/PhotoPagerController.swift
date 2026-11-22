import PhotoAICore
import UIKit

/// 单张视图的翻页（F-12）：横向分页的 `UICollectionView`，每页一个能缩放的 `ZoomPageCell`。
///
/// - 左右滑翻页；捏合缩放；双击放大到 50%（再双击回到适合屏幕）；没放大时往下滑回网格；轻点显示 / 隐藏工具条。
/// - 缩放比例按原图像素算：1 = 100%（原图一个像素对屏幕一个像素）。放大到预览不够清楚时从卡上读原图（F-13）。
/// - 翻页时前后几张的 1600 预览先解码好（PF-7）。
@MainActor
final class PhotoPagerController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UIGestureRecognizerDelegate {
    var onPageChanged: ((PhotoID) -> Void)?
    var onToggleChrome: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onShowedPreview: ((PhotoID) -> Void)?
    var loadOriginal: ((PhotoID, Int?) async -> OriginalResult)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
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
        // 先看是不是往下滑；不是马上失败，翻页照常。
        collectionView.panGestureRecognizer.require(toFail: dismissPan)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { modelUndoManager }

    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(title: "撤销", action: #selector(undoKey), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "重做", action: #selector(redoKey), input: "z", modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return [undo, redo]
    }

    @objc private func undoKey() { undo?() }
    @objc private func redoKey() { redo?() }

    // MARK: - 数据

    func update(photos: [PhotoSummary], current: PhotoID?, cardConnected: Bool) {
        guard isViewLoaded else { return }
        isCardConnected = cardConnected
        let newIDs = photos.map(\.id)
        let previous = self.photos
        self.photos = photos
        if newIDs != ids {
            ids = newIDs
            index = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if let current, let page = index[current] { scroll(to: page, animated: false) }
            currentID = current
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
        scroll(to: page, animated: adjacent)
        prefetchNeighbors()
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
        guard layout.itemSize != collectionView.bounds.size, collectionView.bounds.width > 0 else { return }
        layout.itemSize = collectionView.bounds.size
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if let currentID, let page = index[currentID] { scroll(to: page, animated: false) }
    }

    // MARK: - 页

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ZoomPageCell.reuseID, for: indexPath) as! ZoomPageCell
        if !cell.isWired {
            cell.isWired = true
            cell.zoomView.panGestureRecognizer.require(toFail: dismissPan)
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
        cell.configure(photo, previews: previews)
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
        onPageChanged?(ids[page])
        prefetchNeighbors()
    }

    private var currentCell: ZoomPageCell? {
        guard let currentID, let page = index[currentID] else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: page, section: 0)) as? ZoomPageCell
    }

    // MARK: - 往下滑回网格

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        let velocity = dismissPan.velocity(in: view)
        guard velocity.y > abs(velocity.x), let cell = currentCell else { return false }
        return cell.zoomView.isAtMinimumZoom
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

    var isWired = false
    var isCardConnected = false
    var onSingleTap: (() -> Void)?
    var onShowedPreview: ((PhotoID) -> Void)?
    var loadOriginal: ((PhotoID, Int?) async -> OriginalResult)?

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
        photoID = nil
        previewImage = nil
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
    }

    /// 回到适合屏幕，放掉原图。
    func resetZoom() {
        originalTask?.cancel()
        zoomView.transform = .identity
        if zoomView.zoomScale != zoomView.minimumZoomScale { zoomView.setZoomScale(zoomView.minimumZoomScale, animated: false) }
        dropOriginal()
    }

    private func dropOriginal() {
        guard originalLevel > 0 else { return }
        originalLevel = 0
        zoomView.replaceImage(previewImage)
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
        let have = originalLevel > 0 ? longEdge * originalLevel : max(previewImage.map { max($0.size.width, $0.size.height) * $0.scale } ?? 0, 1)
        guard longEdge * scale > have * 1.15 else { return }
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
            let result = await loadOriginal(id, level < 1 ? Int((longEdge * level).rounded(.up)) : nil)
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            switch result {
            case .image(let image, _):
                // 已经缩回适合屏幕了就不换。
                guard !self.zoomView.isAtMinimumZoom else { return self.hideStatus() }
                self.originalLevel = level
                self.zoomView.replaceImage(UIImage(cgImage: image))
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
@MainActor
final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    private(set) var pixelSize = CGSize(width: 1600, height: 1067)
    var onZoomEnded: (() -> Void)?
    private var lastBounds: CGSize = .zero

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

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomEnded?()
    }
}
