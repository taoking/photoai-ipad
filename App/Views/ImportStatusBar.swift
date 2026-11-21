import PhotoAICore
import SwiftUI

/// 导入进度（F-05）：扫描、预览各自的张数。导入结束后留着最后的结果，直到下次导入。
struct ImportStatusBar: View {
    let model: AppModel
    let importer: ImportController

    var body: some View {
        if importer.phase != .idle {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if importer.isRunning, total > 0 {
                    ProgressView(value: Double(importer.previewsMade), total: Double(total))
                        .frame(width: 160)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var total: Int { importer.previewsMade + importer.previewsFailed + importer.previewsPending }

    @ViewBuilder
    private var icon: some View {
        switch importer.phase {
        case .running: ProgressView()
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }

    private var headline: String {
        switch importer.phase {
        case .running: importer.isScanFinished ? "正在生成预览…（屏幕不会自动锁）" : "正在读卡…（屏幕不会自动锁）"
        case .finished: importer.scan.isComplete ? "读卡完成" : "读卡完成，有目录没扫完，下次插卡续扫"
        case .stopped(let reason): "已停下：\(reason)。回到前台、插上卡会接着做"
        case .idle: ""
        }
    }

    private var detail: String {
        let scan = importer.scan
        var parts = ["扫描 \(scan.filesSeen) 个文件\(importer.isScanFinished ? "" : "…")", "新照片 \(scan.newPhotos) 张"]
        if scan.vanished > 0 { parts.append("卡上已删 \(scan.vanished) 个文件") }
        if scan.otherCamera > 0 { parts.append("跳过别的相机 \(scan.otherCamera) 个") }
        var previews = "预览 \(importer.previewsMade) / \(total)"
        if importer.previewsFailed > 0 { previews += "，失败 \(importer.previewsFailed)" }
        parts.append(previews)
        if let started = importer.startedAt {
            let end = importer.finishedAt ?? Date()
            parts.append(Self.duration(end.timeIntervalSince(started)))
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }
}
