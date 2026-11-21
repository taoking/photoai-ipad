import PhotoAICore
import SwiftUI

/// M1 的临时单张视图：只看 1600 预览，核对预览做得对不对。M2 换成正式的单张视图（F-12）。
struct PreviewViewer: View {
    let photo: PhotoSummary
    let store: PreviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            } else {
                ContentUnavailableView("预览还没做好", systemImage: "photo", description: Text(photo.isOnCard ? "插着卡会自动做" : "卡上已删，做不了预览了"))
                    .foregroundStyle(.white)
            }
            HStack {
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderedProminent)
                Text("\(photo.baseName) · \(photo.captureDate ?? "日期未知")\(photo.isOnCard ? "" : " · 卡上已删")")
                    .foregroundStyle(.white)
                    .font(.callout)
            }
            .padding()
        }
        .onTapGesture { dismiss() }
        .task {
            let url = store.url(for: photo.id, size: .preview)
            image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
        }
    }
}

