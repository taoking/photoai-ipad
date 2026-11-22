import PhotoAICore
import SwiftUI

/// 设置（F-50）：存储用量、自动前进、导出、清卡、诊断。
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var usage: StorageUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("存储") {
                    LabeledContent("照片", value: "\(model.stats.photoCount) 张")
                    if let usage {
                        LabeledContent("库", value: Bytes.text(usage.database))
                        LabeledContent("预览", value: "\(Bytes.text(usage.previews))（\(usage.previewFiles) 个文件）")
                        if let available = usage.available {
                            LabeledContent("iPad 剩余空间", value: Bytes.text(available))
                        }
                    } else {
                        ProgressView()
                    }
                }
                Section("选片") {
                    Toggle("自动前进（打星、标记后跳到下一张）", isOn: Binding(get: { model.autoAdvance }, set: { model.setAutoAdvance($0) }))
                }
                Section("导出") {
                    LabeledContent("导出文件夹", value: model.exports.folderName ?? "还没选")
                    Picker("文件", selection: Binding(get: { model.exports.files }, set: { model.exports.files = $0 })) {
                        ForEach(ExportRequest.Files.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    NavigationLink("清卡…") { ClearCardView(model: model) }
                } footer: {
                    Text("选完、导出完以后清掉本机的照片记录和预览，给下一张卡腾地方。卡上的文件不受影响。")
                }
                Section("诊断") {
                    Picker("预览并发", selection: $model.previewConcurrency) {
                        ForEach([1, 2, 3, 4], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("性能测试库（1 万张合成）", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: DefaultsKey.useSyntheticLibrary) },
                        set: { model.setSyntheticLibrary($0) }
                    ))
                }
                Section("关于") {
                    let info = Bundle.main.infoDictionary ?? [:]
                    LabeledContent("版本", value: "\(info["CFBundleShortVersionString"] ?? "?")（\(info["CFBundleVersion"] ?? "?")）")
                    LabeledContent("签名到期", value: ProvisioningInfo.expiration() ?? "读不到")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { usage = await model.storageUsage() }
        }
    }
}

/// 清卡检查和清卡（F-40 – F-42）。检查只是提醒，从不阻止清卡。
struct ClearCardView: View {
    @Bindable var model: AppModel
    @State private var check: ClearCheck?
    @State private var isConfirming = false
    @State private var isClearing = false

    var body: some View {
        Form {
            if let check {
                Section("本机的库里") {
                    LabeledContent("照片", value: "\(check.photoCount) 张")
                    LabeledContent("预览没做好", value: "\(check.previewNotReadyCount) 张")
                    LabeledContent("卡上已删", value: "\(check.missingFromCardCount) 张")
                }
                Section {
                    LabeledContent("选过但没导出", value: "\(check.selectedNotExportedIDs.count) 张")
                        .foregroundStyle(check.selectedNotExportedIDs.isEmpty ? Color.primary : Color.orange)
                    if !check.selectedNotExportedIDs.isEmpty {
                        NavigationLink("去导出这 \(check.selectedNotExportedIDs.count) 张") {
                            PushedExportPanel(
                                model: model,
                                scope: ExportScope(title: "选过但没导出的 \(check.selectedNotExportedIDs.count) 张", photoIDs: check.selectedNotExportedIDs)
                            )
                            .onDisappear { Task { self.check = await model.clearCheck() } }
                        }
                    }
                } footer: {
                    Text("打过星或 Pick、一次都没导出过的照片。")
                }
                Section {
                    Button("清卡", role: .destructive) { isConfirming = true }
                        .disabled(check.photoCount == 0 || isClearing || model.importer.isRunning || model.exports.isRunning)
                        .accessibilityIdentifier("清卡")
                } footer: {
                    Text(model.importer.isRunning ? "正在读卡，读完再清。" : "删掉本机库里全部照片的记录、星级和预览，以及卡的书签。收藏夹名字、导出文件夹、设置保留。")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("清卡")
        .task { check = await model.clearCheck() }
        .alert("清掉本机的 \(check?.photoCount ?? 0) 张照片？", isPresented: $isConfirming) {
            Button("清卡", role: .destructive) {
                isClearing = true
                Task {
                    await model.clearCard()
                    isClearing = false
                    model.isShowingSettings = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    /// F-42：卡上的文件不受影响；没格式化又读这张卡，照片作为新照片重新导入。
    private var confirmText: String {
        let unexported = check?.selectedNotExportedIDs.count ?? 0
        let warning = unexported > 0 ? "其中 \(unexported) 张选过但没导出。\n\n" : ""
        return warning + "卡上的文件不受影响，请在相机里格式化这张卡。没格式化又读这张卡，照片会作为新照片重新导入，星级不回来。"
    }
}

/// 清卡页里推进去的导出：导完回到清卡检查，导出中不能退回去。
private struct PushedExportPanel: View {
    @Bindable var model: AppModel
    let scope: ExportScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ExportPanel(model: model, scope: scope) { dismiss() }
            .navigationBarBackButtonHidden(model.exports.isRunning)
            .onDisappear { model.exports.reset() }
    }
}
