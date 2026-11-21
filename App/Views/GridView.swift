import PhotoAICore
import SwiftUI

/// 把 UIKit 的网格放进 SwiftUI。
struct GridView: UIViewControllerRepresentable {
    let model: AppModel
    let cache: ThumbnailCache

    func makeUIViewController(context: Context) -> PhotoGridController {
        let controller = PhotoGridController(cache: cache)
        controller.onOpen = { model.openedPhoto = $0 }
        controller.onSelectionChanged = { model.selectedIDs = $0 }
        controller.onBeginSelecting = { model.isSelecting = true }
        controller.onShowedPhotos = { model.gridDidShowPhotos() }
        return controller
    }

    func updateUIViewController(_ controller: PhotoGridController, context: Context) {
        controller.update(photos: model.photos, isSelecting: model.isSelecting, selected: model.selectedIDs)
    }
}
