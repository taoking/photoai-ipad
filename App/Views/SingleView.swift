import PhotoAICore
import SwiftUI

/// 单张视图（F-12、F-13、F-15、F-20 – F-23）：上面一行文件名、拍摄参数、撤销；中间翻页；下面星级、标记、自动前进和胶片条。
/// 轻点照片隐藏 / 显示上下两条。
struct SingleView: View {
    @Bindable var model: AppModel
    let thumbnails: ThumbnailCache
    let previews: PreviewImageCache
    @State private var chromeVisible = true
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            if chromeVisible { topBar }
            PagerView(model: model, previews: previews) { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                .ignoresSafeArea(edges: chromeVisible ? [] : .all)
            if chromeVisible { bottomBar }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .center) { ToastView(toast: model.toast) }
        .modifier(CollectionPrompts(model: model, isActive: true))
        .statusBarHidden(!chromeVisible)
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
    }

    // MARK: - 上面

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                model.closeSingle()
            } label: {
                Label("返回网格", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .accessibilityIdentifier("返回网格")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.currentPhoto?.baseName ?? "")
                        .font(.headline)
                    if let index = model.currentIndex {
                        Text("\(index + 1) / \(model.photos.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("pageIndex")
                    }
                    if model.currentPhoto?.isOnCard == false {
                        Text("卡上已删")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.3), in: .capsule)
                    }
                }
                Text(infoLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            UndoButtons(model: model, identifierPrefix: "single-")
            Button {
                showInfo = true
            } label: {
                Label("信息", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .popover(isPresented: $showInfo) { InfoPanel(detail: model.currentDetail) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    /// F-15：“35 mm · f/1.8 · 1/250 s · ISO 100 · 2026-11-21 14:03:22”。
    private var infoLine: String {
        guard let detail = model.currentDetail, detail.summary.id == model.currentPhotoID else {
            return model.currentPhoto?.captureDate ?? " "
        }
        return (PhotoFormat.exposure(detail) + [detail.summary.captureDate ?? "日期未知"]).joined(separator: " · ")
    }

    // MARK: - 下面

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                RatingButtons(rating: model.currentPhoto?.rating ?? 0) { model.setRating($0) }
                Divider().frame(height: 28)
                FlagButtons(flag: model.currentPhoto?.flag ?? .none) { model.setFlag($0) }
                Divider().frame(height: 28)
                CollectionButton(model: model)
                Spacer(minLength: 8)
                Toggle(isOn: Binding(get: { model.autoAdvance }, set: { model.setAutoAdvance($0) })) {
                    Label("自动前进", systemImage: "forward.end")
                }
                .toggleStyle(.button)
            }
            .padding(.horizontal, 16)
            FilmstripView(model: model, cache: thumbnails)
                .frame(height: 56)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// 星级 0–5：五颗星点哪颗就是几星；“清除”是 0 星。
struct RatingButtons: View {
    let rating: Int
    let action: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                action(0)
            } label: {
                Label("清除星级", systemImage: "star.slash")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .padding(.trailing, 6)
            ForEach(1...5, id: \.self) { n in
                Button {
                    action(n)
                } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .foregroundStyle(n <= rating ? .yellow : .secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(n) 星")
                .accessibilityValue(n == rating ? "当前" : "")
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
    }
}

/// Pick / Reject / 未标记。
struct FlagButtons: View {
    let flag: Flag
    let action: (Flag) -> Void

    var body: some View {
        HStack(spacing: 8) {
            button(.pick, "flag.fill", .green)
            button(.reject, "xmark", .red)
            button(.none, "flag.slash", .secondary)
        }
    }

    private func button(_ value: Flag, _ symbol: String, _ color: Color) -> some View {
        Button {
            action(value)
        } label: {
            Label(value.displayName, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(flag == value && value != .none ? .white : color)
                .background(flag == value && value != .none ? color : Color.secondary.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(flag == value ? "当前" : "")
        .accessibilityIdentifier("single-\(value.rawValue)")
    }
}

struct UndoButtons: View {
    let model: AppModel
    /// 单张视图盖在网格上，两边都有撤销按钮：界面测试靠前缀分开。
    var identifierPrefix = ""

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.undo()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .accessibilityIdentifier(identifierPrefix + "撤销")
            Button {
                model.redo()
            } label: {
                Label("重做", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .accessibilityIdentifier(identifierPrefix + "重做")
        }
        .labelStyle(.iconOnly)
    }
}

/// 点“i”看的完整信息（F-15）。
struct InfoPanel: View {
    let detail: PhotoDetail?

    var body: some View {
        if let detail {
            Form {
                Section("拍摄") {
                    row("时间", detail.summary.captureDate ?? "日期未知")
                    row("相机", [detail.cameraMake, detail.cameraModel].compactMap { $0 }.joined(separator: " "))
                    row("镜头", detail.lens ?? "—")
                    row("参数", PhotoFormat.exposure(detail).joined(separator: " · "))
                    if let width = detail.summary.width, let height = detail.summary.height {
                        row("尺寸", "\(width) × \(height)")
                    }
                }
                Section("选片") {
                    row("星级", detail.summary.rating == 0 ? "未评分" : String(repeating: "★", count: detail.summary.rating))
                    row("标记", detail.summary.flag.displayName)
                    row("收藏夹", detail.collectionNames.joined(separator: "、"))
                    row("导出过", detail.lastExportedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "没有")
                }
                Section("文件") {
                    row("格式", detail.extensions.joined(separator: " + "))
                    ForEach(detail.locations, id: \.relativePath) { location in
                        HStack {
                            Text(location.relativePath).font(.caption.monospaced())
                            Spacer()
                            if !location.isPresent { Text("卡上已删").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .frame(minWidth: 380, minHeight: 460)
        } else {
            ProgressView().padding(40)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value.isEmpty ? "—" : value)
    }
}

enum PhotoFormat {
    /// 焦距、光圈、快门、ISO，没有的跳过。
    static func exposure(_ detail: PhotoDetail) -> [String] {
        var parts: [String] = []
        if let focal = detail.focalLength { parts.append("\(number(focal)) mm") }
        if let aperture = detail.aperture { parts.append("f/\(number(aperture))") }
        if let shutter = detail.shutter, shutter > 0 {
            parts.append(shutter < 1 ? "1/\(Int((1 / shutter).rounded())) s" : "\(number(shutter)) s")
        }
        if let iso = detail.iso { parts.append("ISO \(iso)") }
        return parts
    }

    /// 35 → “35”，1.8 → “1.8”。
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// 屏幕中间一闪而过的提示。
struct ToastView: View {
    let toast: Toast?

    var body: some View {
        if let toast {
            Text(toast.text)
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: .capsule)
                .id(toast.id)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityIdentifier("toast")
        }
    }
}

// MARK: - UIKit 的两块

struct PagerView: UIViewControllerRepresentable {
    let model: AppModel
    let previews: PreviewImageCache
    let toggleChrome: () -> Void

    func makeUIViewController(context: Context) -> PhotoPagerController {
        let controller = PhotoPagerController(previews: previews)
        controller.onPageChanged = { model.showPhoto($0) }
        controller.onDismiss = { model.closeSingle() }
        controller.onToggleChrome = toggleChrome
        controller.onShowedPreview = { model.pageDidShowPreview($0) }
        controller.onRate = { model.setRating($0) }
        controller.loadOriginal = { id, size in await model.loadOriginal(id, maximumPixelSize: size) }
        controller.onKey = { model.perform($0) }
        controller.modelUndoManager = model.undoManager
        return controller
    }

    func updateUIViewController(_ controller: PhotoPagerController, context: Context) {
        controller.update(
            photos: model.photos, current: model.currentPhotoID, cardConnected: model.cardState == .connected,
            canTakeFocus: model.collectionPrompt == nil
        )
    }
}

struct FilmstripView: UIViewControllerRepresentable {
    let model: AppModel
    let cache: ThumbnailCache

    func makeUIViewController(context: Context) -> FilmstripController {
        let controller = FilmstripController(cache: cache)
        controller.onSelect = { model.showPhoto($0) }
        return controller
    }

    func updateUIViewController(_ controller: FilmstripController, context: Context) {
        controller.update(photos: model.photos, current: model.currentPhotoID)
    }
}
