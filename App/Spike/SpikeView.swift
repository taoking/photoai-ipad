import SwiftUI

/// M0 最小读卡页：选卡、测量、看日志。
struct SpikeView: View {
    @State private var model = SpikeModel()
    @State private var isPicking = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("选择存储卡") { isPicking = true }
                    Button("检查书签") { model.checkCard(reason: "手动") }
                    Button("全部测一遍") { model.runAll() }
                    Button("测轮询开销") { model.measurePolling() }
                    Toggle("前台轮询", isOn: $model.isPolling).fixedSize()
                    Spacer()
                    if model.isBusy { ProgressView() }
                    Button("清空日志", role: .destructive) { model.clearLog() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.lines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .padding()
            .navigationTitle("M0 技术验证")
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { model.cardPicked($0) }
        .task { model.recordLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkCard(reason: "回到前台") }
        }
    }
}
