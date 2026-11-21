import PhotoAICore
import UIKit

/// 网格里的一格：缩略图按原比例完整显示（不裁切，F-11），角上标“卡上已删”和选中。
final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"

    private let imageView = UIImageView()
    private let placeholder = UIImageView()
    private let missingBadge = PaddedLabel()
    private let checkmark = UIImageView()
    private var loadTask: Task<Void, Never>?
    private(set) var photoID: PhotoID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.secondarySystemBackground
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        placeholder.contentMode = .center
        placeholder.tintColor = .tertiaryLabel
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)
        placeholder.frame = contentView.bounds
        placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(placeholder)

        missingBadge.text = "卡上已删"
        missingBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        missingBadge.textColor = .white
        missingBadge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        missingBadge.layer.cornerRadius = 4
        missingBadge.clipsToBounds = true
        missingBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(missingBadge)

        checkmark.image = UIImage(systemName: "checkmark.circle.fill")
        checkmark.tintColor = .systemBlue
        checkmark.backgroundColor = .white
        checkmark.layer.cornerRadius = 11
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            missingBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            missingBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            checkmark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            checkmark.widthAnchor.constraint(equalToConstant: 22),
            checkmark.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        photoID = nil
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    var isSelecting = false {
        didSet { updateSelection() }
    }

    func configure(_ photo: PhotoSummary, cache: ThumbnailCache) {
        let sameItem = photoID == photo.id
        photoID = photo.id
        missingBadge.isHidden = photo.isOnCard
        updateSelection()

        if let image = cache.cached(photo.id) {
            show(image)
            return
        }
        switch photo.thumbState {
        case .pending:
            if !sameItem { imageView.image = nil }
            placeholder.image = UIImage(systemName: "photo")
            placeholder.isHidden = imageView.image != nil
        case .failed:
            imageView.image = nil
            placeholder.image = UIImage(systemName: "exclamationmark.triangle")
            placeholder.isHidden = false
        case .ready:
            if !sameItem { imageView.image = nil }
            placeholder.isHidden = imageView.image != nil
            placeholder.image = UIImage(systemName: "photo")
            loadTask?.cancel()
            let id = photo.id
            loadTask = Task { [weak self] in
                let image = await cache.load(id)
                guard !Task.isCancelled, let self, self.photoID == id, let image else { return }
                self.show(image)
            }
        }
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        placeholder.isHidden = true
    }

    private func updateSelection() {
        checkmark.isHidden = !(isSelecting && isSelected)
        imageView.alpha = isSelecting && isSelected ? 0.75 : 1
    }
}

/// 带内边距的小标签。
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// 按天分组的标题：“11月21日 周六 · 123 张”。
final class DayHeaderView: UICollectionReusableView {
    static let reuseID = "DayHeader"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        backgroundColor = .systemBackground.withAlphaComponent(0.92)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不从 storyboard 建") }
}
