import Darwin
import Foundation

/// M0 技术验证的日志：屏幕上显示，同时追加到 Documents/技术验证日志.txt（“文件”App 里能看到，Mac 上用 devicectl 拷出来）。
final class SpikeLog: @unchecked Sendable {
    static let shared = SpikeLog()

    let fileURL: URL
    private let lock = NSLock()
    private let formatter: DateFormatter
    private var onLine: (@Sendable (String) -> Void)?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("技术验证日志.txt")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func setHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { onLine = handler }
    }

    func callAsFunction(_ text: String) {
        let handler: (@Sendable (String) -> Void)?
        let line: String
        lock.lock()
        line = "\(formatter.string(from: Date()))  \(text)"
        handler = onLine
        if let data = (line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        lock.unlock()
        handler?(line)
    }
}

/// 进程的内存占用（phys_footprint，和 Xcode 内存表、系统杀进程用的是同一个数）。
enum MemoryProbe {
    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
    }

    static func describe() -> String {
        let (current, peak) = footprint()
        return "内存 \(current >> 20) MB，进程峰值 \(peak >> 20) MB，温度 \(thermal())"
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "热"
        case .critical: "过热"
        @unknown default: "未知"
        }
    }
}

/// 计时，返回毫秒。
func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }

/// 一组耗时的最小 / 平均 / 最大。
func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "无" }
    let average = values.reduce(0, +) / Double(values.count)
    return String(format: "%d 个，平均 %.1f ms，最小 %.1f，最大 %.1f", values.count, average, values.min()!, values.max()!)
}
