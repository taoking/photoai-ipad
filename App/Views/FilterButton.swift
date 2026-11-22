import PhotoAICore
import SwiftUI

/// 工具栏的“筛选”（F-22）：只有星级和选择状态，做简单。
///
/// 原来是网格上面一直占着一条，选片时大多不用筛选，改成按钮 + 弹出框；有条件生效时图标是实心的、带个数，
/// 副标题写“筛选出 N / M 张”。弹出框里点一下就生效，可以连着点几个，点外面关掉。
/// 星级是“至少 N 星”，只能选一个（再点取消）；选择状态可以多选。同类“或者”、两类之间“并且”。
/// 打星后结果不变，有照片已经不符合时网格底部出现“刷新结果”。每个侧栏项各自记住（F-10）。
struct FilterButton: View {
    @Bindable var model: AppModel
    @State private var isOpen = false

    var body: some View {
        let count = model.currentFilter.activeGroupCount
        Button {
            isOpen = true
        } label: {
            Label("筛选", systemImage: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .badge(count)
        .accessibilityValue(count > 0 ? "\(count) 类条件" : "")
        .popover(isPresented: $isOpen) {
            FilterPanel(model: model)
        }
    }
}

/// 弹出框里的内容：两行开关和“清除筛选”。
struct FilterPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let filter = model.currentFilter
        VStack(alignment: .leading, spacing: 14) {
            Text("星级（至少）").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { n in
                    Chip(title: "★\(n)+", isOn: filter.stars.contains(n)) {
                        model.currentFilter.toggleStar(n)
                    }
                }
            }
            Text("标记").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([Flag.pick, .reject, .none], id: \.self) { flag in
                    Chip(title: flag.displayName, isOn: filter.flags.contains(flag)) {
                        model.currentFilter.toggleFlag(flag)
                    }
                }
            }
            Divider()
            HStack {
                Text(filter.isEmpty ? "\(model.photos.count) 张" : "筛选出 \(model.photos.count) / \(model.source.count) 张")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 16)
                Button("清除筛选", role: .destructive) { model.currentFilter = PhotoFilter() }
                    .disabled(filter.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .presentationCompactAdaptation(.popover)
    }
}

/// 筛选里的一个开关。
struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "已选" : "")
    }
}
