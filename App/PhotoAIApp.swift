import PhotoAICore
import SwiftUI

@main
struct PhotoAIApp: App {
    @State private var state = Self.makeState()

    var body: some Scene {
        WindowGroup {
            switch state {
            case .ready(let model, let cache):
                RootView(model: model, cache: cache)
            case .failed(let message):
                ContentUnavailableView("库打不开", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
    }

    enum LaunchState {
        case ready(AppModel, ThumbnailCache)
        case failed(String)
    }

    @MainActor
    private static func makeState() -> LaunchState {
        do {
            let model = try AppModel()
            return .ready(model, ThumbnailCache(store: model.previewStore))
        } catch {
            appLog("库打不开：\(error)")
            return .failed("\(error)")
        }
    }
}
