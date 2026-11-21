import PhotoAICore
import SwiftUI

/// 网格上面的筛选条（F-22）：只有星级和选择状态，做简单。
///
/// 星级是“至少 N 星”，只能选一个（再点取消）；选择状态可以多选。同类“或者”、两类之间“并且”。
/// 打星后结果不变，有照片已经不符合时出现“刷新结果”。每个侧栏项各自记住（F-10）。
struct FilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let filter = model.currentFilter
        HStack(spacing: 0) {
            chips(filter)
            // 这两个放在滚动区外面：竖屏开着侧栏时筛选条不够宽，也不会被挤出屏幕。
            if !filter.isEmpty {
                Button {
                    model.currentFilter = PhotoFilter()
                } label: {
                    Label("清除筛选", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            }
            if model.staleCount > 0 {
                Button {
                    model.refreshResult()
                } label: {
                    Label("刷新结果（\(model.staleCount) 张已不符合）", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .padding(.trailing, 16)
            }
        }
        .background(.bar)
    }

    private func chips(_ filter: PhotoFilter) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { n in
                    Chip(title: "★\(n)+", isOn: filter.stars.contains(n)) {
                        model.currentFilter.toggleStar(n)
                    }
                }
                Divider().frame(height: 22).padding(.horizontal, 4)
                ForEach([Flag.pick, .reject, .none], id: \.self) { flag in
                    Chip(title: flag.displayName, isOn: filter.flags.contains(flag)) {
                        model.currentFilter.toggleFlag(flag)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// 筛选条上的一个开关。
struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "已选" : "")
    }
}
