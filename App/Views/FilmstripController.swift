import PhotoAICore
import UIKit

/// 单张视图底部的胶片条（F-12）：当前结果的缩略图，当前这张加白框、居中；轻点跳过去。
@MainActor
final class FilmstripController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var onSelect: ((PhotoID) -> Void)?

    private let cache: ThumbnailCache
    private var collectionView: UICollectionView!
    private var photos: [PhotoSummary] = []
    private var ids: [PhotoID] = []
    private var index: [PhotoID: Int] = [:]
    private var currentID: PhotoID?

    init(cache: ThumbnailCache) {
        self.cache = cache
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    // 默认的视图是整屏大，第一次布局前就加载数据会一下建几百格；先给胶片条的高度。
    override func loadView() {
        view = UIView(frame: CGRect(x: 0, y: 0, width: 1000, height: 56))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 52, height: 52)
        layout.minimumLineSpacing = 3
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.accessibilityIdentifier = "filmstrip"
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.reuseID)
        view.addSubview(collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 两头留半屏，第一张和最后一张也能居中。
        let side = max(0, collectionView.bounds.width / 2 - 26)
        if collectionView.contentInset.left != side {
            collectionView.contentInset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
            centerCurrent(animated: false)
        }
    }

    func update(photos: [PhotoSummary], current: PhotoID?) {
        guard isViewLoaded else { return }
        let newIDs = photos.map(\.id)
        let previous = self.photos
        self.photos = photos
        if newIDs != ids {
            ids = newIDs
            index = Dictionary(uniqueKeysWithValues: newIDs.enumerated().map { ($0.element, $0.offset) })
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            currentID = current
            centerCurrent(animated: false)
            return
        }
        for case let cell as FilmstripCell in collectionView.visibleCells {
            guard let id = cell.photoID, let item = index[id], previous.indices.contains(item), previous[item] != photos[item] else { continue }
            cell.configure(photos[item], cache: cache, isCurrent: id == currentID)
        }
        guard current != currentID else { return }
        let old = currentID
        currentID = current
        for id in [old, current].compactMap({ $0 }) {
            guard let item = index[id], let cell = collectionView.cellForItem(at: IndexPath(item: item, section: 0)) as? FilmstripCell else { continue }
            cell.configure(photos[item], cache: cache, isCurrent: id == current)
        }
        let near = old.flatMap { index[$0] }.flatMap { a in current.flatMap { index[$0] }.map { abs(a - $0) < 20 } } ?? false
        centerCurrent(animated: near)
    }

    private func centerCurrent(animated: Bool) {
        guard let currentID, let item = index[currentID], !collectionView.isDragging else { return }
        collectionView.scrollToItem(at: IndexPath(item: item, section: 0), at: .centeredHorizontally, animated: animated)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.reuseID, for: indexPath) as! FilmstripCell
        let photo = photos[indexPath.item]
        cell.configure(photo, cache: cache, isCurrent: photo.id == currentID)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        onSelect?(ids[indexPath.item])
    }
}

/// 胶片条的一格：填满裁切，Reject 调暗，当前这张白框。
final class FilmstripCell: UICollectionViewCell {
    static let reuseID = "FilmstripCell"

    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private(set) var photoID: PhotoID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        contentView.layer.cornerRadius = 3
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        imageView.image = nil
        photoID = nil
    }

    func configure(_ photo: PhotoSummary, cache: ThumbnailCache, isCurrent: Bool) {
        let samePhoto = photoID == photo.id
        photoID = photo.id
        contentView.layer.borderWidth = isCurrent ? 2 : 0
        contentView.layer.borderColor = UIColor.white.cgColor
        imageView.alpha = photo.flag == .reject ? 0.4 : 1
        if samePhoto, imageView.image != nil { return }
        if let image = cache.cached(photo.id, size: .small) {
            imageView.image = image
            return
        }
        guard photo.thumbState == .ready else { return }
        let id = photo.id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await cache.load(id, size: .small)
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            self.imageView.image = image
        }
    }
}
