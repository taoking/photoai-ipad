import PhotoAICore
import SwiftUI

/// 导出面板（F-30 – F-32）：选文件类型和文件夹 → 进度 → 结果。导出中不能关。
struct ExportSheet: View {
    @Bindable var model: AppModel
    let scope: ExportScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExportPanel(model: model, scope: scope) { dismiss() }
                .toolbar {
                    if !model.exports.isRunning {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { dismiss() }
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.exports.isRunning)
        .onDisappear { model.exports.reset() }
    }
}

/// 面板的内容。清卡页里“去导出”也用它（推进去，不另开面板）。
struct ExportPanel: View {
    @Bindable var model: AppModel
    let scope: ExportScope
    var done: () -> Void
    @State private var plan: ExportPlan?
    @State private var isPickingFolder = false

    private var exports: ExportController { model.exports }

    var body: some View {
        Group {
            switch exports.phase {
            case .idle: options
            case .running: running
            case .finished(let report): finished(report)
            }
        }
        .navigationTitle("导出")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if let error = exports.folderPicked(result) { model.message = error }
        }
        .task(id: exports.files) {
            let ids = scope.photoIDs
            let files = exports.files
            let reader = model.reader
            let exports = exports
            plan = await Task.detached { exports.plan(ids, files: files, reader: reader) }.value
        }
    }

    // MARK: - 选项

    private var options: some View {
        Form {
            Section("范围") {
                LabeledContent("照片", value: scope.title)
                if let plan {
                    LabeledContent("要复制", value: "\(plan.fileCount) 个文件，约 \(Bytes.text(plan.byteCount))")
                    if !plan.missingPhotoIDs.isEmpty {
                        Text("其中 \(plan.missingPhotoIDs.count) 张卡上已删，导不了")
                            .foregroundStyle(.orange)
                    }
                } else {
                    ProgressView()
                }
            }
            Section {
                Picker("文件", selection: Binding(get: { exports.files }, set: { exports.files = $0 })) {
                    ForEach(ExportRequest.Files.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("文件")
            } footer: {
                Text("只要 RAW 时，没有 RAW 的照片导出 JPEG；只要 JPEG 时反过来。")
            }
            Section {
                Picker("导出到", selection: Binding(get: { exports.target }, set: { exports.target = $0 })) {
                    ForEach(ExportController.Target.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if exports.target == .folder {
                    Button {
                        isPickingFolder = true
                    } label: {
                        LabeledContent("文件夹", value: exports.folderName ?? "选一个文件夹…")
                    }
                }
            } header: {
                Text("导出到")
            } footer: {
                switch exports.target {
                case .folder:
                    Text("在“文件”里选：本机、iCloud 云盘、外接盘都行。文件直接放在这个文件夹里，名字和卡上的一样；只复制不覆盖，文件夹里已有同名的就当导出过、跳过，所以中断了再导一次就是接着导。")
                case .photos:
                    Text("JPEG 存成照片；选“RAW + JPEG”时 ARW 作为同一张照片的 RAW 一起存，只有 RAW 的存 RAW。只申请“添加照片”的权限。“照片”里认不出存过的，同一张再存会多一份。")
                }
            }
            Section {
                Button {
                    model.startExport(scope)
                } label: {
                    Text("开始导出").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
                .disabled(model.exportBlocker != nil || plan?.exportablePhotoIDs.isEmpty != false)
                .accessibilityIdentifier("开始导出")
            } footer: {
                if let blocker = model.exportBlocker {
                    Text(blocker).foregroundStyle(.orange)
                } else {
                    Text("导出时屏幕常亮，别切到别的应用；切走了回来再导一次接着导。")
                }
            }
        }
    }

    // MARK: - 进度

    private var running: some View {
        VStack(spacing: 18) {
            Spacer()
            if let progress = exports.progress {
                ProgressView(value: Double(progress.photosDone), total: Double(max(progress.photoTotal, 1)))
                    .frame(maxWidth: 420)
                Text("第 \(min(progress.photosDone + 1, progress.photoTotal)) / \(progress.photoTotal) 张")
                    .font(.title3.monospacedDigit())
                Text(progress.fileName.isEmpty ? " " : progress.fileName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(speedLine(progress))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("取消", role: .destructive) { exports.cancel() }
                .buttonStyle(.bordered)
            Text("取消后停在下一个文件之前，已导出的保留。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    private func speedLine(_ progress: ExportProgress) -> String {
        let seconds = exports.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let speed = seconds > 0 ? Double(progress.bytesCopied) / 1_000_000 / seconds : 0
        return "已复制 \(Bytes.text(progress.bytesCopied)) · \(String(format: "%.0f", speed)) MB/s"
    }

    // MARK: - 结果

    private func finished(_ report: ExportReport) -> some View {
        Form {
            Section {
                row("导出了", "\(report.exportedPhotos) 张")
                row("复制", "\(report.copiedFiles) 个文件，\(Bytes.text(report.bytesCopied))")
                if report.alreadyExportedFiles > 0 { row("已经导出过（同名），跳过", "\(report.alreadyExportedFiles) 个文件") }
                if report.usedOtherKind > 0 { row("没有选的格式，导了另一种", "\(report.usedOtherKind) 张") }
                let missing = report.skippedMissingPhotos + report.newlyMissingPhotoIDs.count
                if missing > 0 { row("卡上已删，导不了", "\(missing) 张") }
                if report.elapsed > 0 {
                    row("用时", String(format: "%.0f 秒，%.0f MB/s", report.elapsed, report.megabytesPerSecond))
                }
            } header: {
                Text(headline(report))
            }
            if report.stoppedBy != nil || report.cancelled {
                Section {
                    Text(stopText(report)).foregroundStyle(.orange)
                }
            }
            if !report.failures.isEmpty {
                Section("失败的 \(report.failures.count) 个文件") {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.name).font(.body.monospaced())
                            Text(failure.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if report.notAttempted > 0 || !report.failures.isEmpty {
                    Button("再导一次（接着导，导过的跳过）") {
                        exports.reset()
                        model.startExport(resumeScope(after: report))
                    }
                    .disabled(model.exportBlocker != nil)
                }
                Button("完成") { done() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("导出完成")
            }
        }
    }

    /// 文件夹按名字跳过导过的，整批再导就行；“照片”认不出存过的，只导这次没存成的。
    private func resumeScope(after report: ExportReport) -> ExportScope {
        guard exports.runningTarget == .photos else { return scope }
        let done = Set(report.exportedPhotoIDs)
        let rest = scope.photoIDs.filter { !done.contains($0) }
        return ExportScope(title: "没存成的 \(rest.count) 张", photoIDs: rest)
    }

    private func headline(_ report: ExportReport) -> String {
        if report.cancelled { return "取消了" }
        if report.stoppedBy != nil { return "停下了" }
        return report.failures.isEmpty ? "导出完成" : "导出完成，有失败"
    }

    private func stopText(_ report: ExportReport) -> String {
        let reason = report.stoppedBy ?? "取消了"
        return "\(reason)。还有 \(report.notAttempted) 张没导：解决之后再导一次，已经导出的会跳过。"
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).monospacedDigit()
    }
}

enum Bytes {
    static func text(_ count: Int) -> String { text(Int64(count)) }

    static func text(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
