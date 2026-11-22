import PhotoAICore
import SwiftUI
import UniformTypeIdentifiers

/// 设置（F-50）：存储卡、存储用量、自动前进、导出、清卡、诊断。
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var usage: StorageUsage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("状态", value: model.cardStatusText)
                    Button("读取存储卡") {
                        // 选卡的“文件”选择器挂在主界面上，先关掉设置再读。
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.readCardTapped() }
                    }
                    .disabled(model.importer.isRunning || model.exports.isRunning)
                } header: {
                    Text("存储卡")
                } footer: {
                    Text("插上卡就自动读，一般不用点。第一次用、或者一直读不到卡时点这里，在“文件”里选存储卡。")
                }
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
                    Picker("导出到", selection: Binding(get: { model.exports.target }, set: { model.exports.target = $0 })) {
                        ForEach(ExportController.Target.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("导出文件夹", value: model.exports.folderName ?? "还没选")
                    Picker("文件", selection: Binding(get: { model.exports.files }, set: { model.exports.files = $0 })) {
                        ForEach(ExportRequest.Files.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                RatingFilesSection(model: model)
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
                    Text("打过星、Pick 或者在收藏夹里，一次都没导出过的照片。")
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

/// 星级文件（F-34、F-51）：带回 Mac 版用它的“从文件导入星级”；也能把 Mac 上写的星级文件导进来。
private struct RatingFilesSection: View {
    @Bindable var model: AppModel
    @State private var exportDocument: TextDocument?
    @State private var isImporting = false
    @State private var pending: PendingImport?

    private struct PendingImport: Identifiable {
        let id = UUID()
        var fileName: String
        var plan: RatingImportPlan
    }

    var body: some View {
        Section {
            Button("导出星级文件…") {
                Task {
                    guard let export = await model.ratingExport() else { return }
                    guard export.photoCount > 0 else { return model.message = "还没有打过星的照片。" }
                    exportDocument = TextDocument(text: export.text)
                }
            }
            Button("从文件导入星级…") { isImporting = true }
        } header: {
            Text("星级文件")
        } footer: {
            Text("每行“文件名  星级”，如“DSC01064  4”。导出的文件在 Mac 版用“从文件导入星级”读；导入时先看对上了哪些，确认后才写，可以撤销。")
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument, contentType: .markdownText, defaultFilename: "星级 \(Self.today).md"
        ) { result in
            switch result {
            case .success(let url): appLog("导出星级文件 \(url.lastPathComponent)")
            case .failure(let error): model.message = "存不了星级文件：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.markdownText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task {
                switch await model.planRatingImport(url) {
                case .success(let plan): pending = PendingImport(fileName: url.lastPathComponent, plan: plan)
                case .failure(let failure): model.message = failure.message
                }
            }
        }
        .sheet(item: $pending) { pending in
            RatingImportConfirm(model: model, fileName: pending.fileName, plan: pending.plan)
        }
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// 导入星级前的确认：对上几张、各几星，没对上的行、忽略的行。
private struct RatingImportConfirm: View {
    let model: AppModel
    let fileName: String
    let plan: RatingImportPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(fileName) {
                    LabeledContent("对上的照片", value: "\(plan.changes.count) 张")
                    LabeledContent("星级会变的", value: "\(plan.changedCount) 张")
                    ForEach((1...5).reversed(), id: \.self) { n in
                        if let count = plan.countsByRating[n] { LabeledContent(String(repeating: "★", count: n), value: "\(count) 张") }
                    }
                }
                if !plan.conflicts.isEmpty {
                    Section("同一张写了几次，以后面的为准") {
                        ForEach(plan.conflicts, id: \.photo.id) { conflict in
                            LabeledContent(conflict.photo.baseName, value: conflict.ratings.map(String.init).joined(separator: " → "))
                        }
                    }
                }
                if !plan.unmatched.isEmpty {
                    Section("没对上照片的 \(plan.unmatched.count) 行") {
                        ForEach(plan.unmatched, id: \.line) { entry in
                            LabeledContent("第 \(entry.line) 行", value: "\(entry.key)  \(entry.rating)")
                        }
                    }
                }
                if !plan.ignored.isEmpty {
                    Section("格式不对、忽略的 \(plan.ignored.count) 行") {
                        ForEach(plan.ignored, id: \.line) { line in
                            LabeledContent("第 \(line.line) 行", value: line.text)
                        }
                    }
                }
            }
            .navigationTitle("从文件导入星级")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入 \(plan.changedCount) 张") {
                        model.applyRatingImport(plan, fileName: fileName)
                        dismiss()
                    }
                    .disabled(plan.changedCount == 0)
                }
            }
        }
    }
}

/// 导出星级文件用的文本文档。
struct TextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// `.md`。系统不一定认识，认不出就当普通文本。
    static let markdownText = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}
