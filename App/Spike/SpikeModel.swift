import Foundation
import Observation

/// M0 读卡页的状态。测量都丢到后台线程，日志回主线程显示。
@MainActor @Observable
final class SpikeModel {
    var lines: [String] = []
    var isBusy = false
    var isPolling = false {
        didSet { isPolling ? startPolling() : pollTask?.cancel() }
    }

    private let log = SpikeLog.shared
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastPollState: String?

    init() {
        log.setHandler { [weak self] line in
            Task { @MainActor in self?.lines.append(line) }
        }
    }

    /// 启动时记一次：第几次启动、这次的构建号、签名到期日、书签能不能用。重装后看这里就知道数据留没留住。
    func recordLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let launches = LaunchRecord.append(build: build)
        log("启动：第 \(launches.count) 次，构建 \(build)；之前的构建：\(Set(launches.map(\.build)).count) 种；签名到期 \(ProvisioningInfo.expiration() ?? "读不到")")
        log("首次启动记录：\(launches.first.map { "\($0.date) 构建 \($0.build)" } ?? "无")")
        log("书签文件\(CardBookmark.exists ? "在" : "不在")；\(MemoryProbe.describe())")
        retryAfterLaunch()
    }

    /// 冷启动时第一次解析书签会报 -2001（找不到文件提供者），过一会儿又好了。每秒试一次，最多 30 秒，看要等多久。
    private func retryAfterLaunch() {
        let log = log
        Task.detached {
            let start = DispatchTime.now().uptimeNanoseconds
            for attempt in 1...30 {
                let (resolution, time) = measure { CardBookmark.resolve() }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                if case .connected = resolution {
                    log(String(format: "[启动重试] 第 %d 次（启动后 %.1f 秒）连上了，这次 %@", attempt, elapsed, ms(time)))
                    return
                }
                let reason = if case let .failed(text) = resolution { String(text.prefix(80)) } else { CardBookmark.describe(resolution) }
                log(String(format: "[启动重试] 第 %d 次（启动后 %.1f 秒）没连上：%@", attempt, elapsed, reason))
                if case .none = resolution { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cardPicked(_ result: Result<URL, any Error>) {
        switch result {
        case let .failure(error):
            log("选择器返回错误：\(error)")
        case let .success(url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let (_, time) = try measure { try CardBookmark.save(url) }
                log("选了 \(url.path)，startAccessing=\(accessing)，存书签 \(ms(time))")
            } catch {
                log("存书签失败：\(error)")
            }
            checkCard(reason: "选卡后")
        }
    }

    func checkCard(reason: String) {
        let log = log
        Task.detached {
            let (resolution, time) = measure { CardBookmark.resolve() }
            log("[\(reason)] 解析书签 \(ms(time))：\(CardBookmark.describe(resolution))")
        }
    }

    func runAll() { run { CardProbe.runAll(log: $0) } }

    func measurePolling() { run { CardProbe.measurePolling(log: $0) } }

    func clearLog() {
        lines.removeAll()
        try? FileManager.default.removeItem(at: log.fileURL)
        log("清空了日志")
    }

    private func run(_ work: @escaping @Sendable (SpikeLog) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        let log = log
        Task {
            await Task.detached(priority: .userInitiated) { work(log) }.value
            isBusy = false
        }
    }

    /// 前台每 3 秒解析一次书签，状态变了才记日志（问题 4：值不值得做“插上就自动读”）。
    private func startPolling() {
        lastPollState = nil
        log("开始前台轮询，每 3 秒一次")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let (resolution, time) = await Task.detached { measure { CardBookmark.resolve() } }.value
                let state: String = switch resolution {
                case .connected: "已连接"
                case .unreachable: "未连接"
                case .failed: "解析失败"
                case .none: "没有书签"
                }
                if let self, state != self.lastPollState {
                    self.lastPollState = state
                    self.log("[轮询] 状态变为“\(state)”（这次 \(ms(time))）：\(CardBookmark.describe(resolution))")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// 每次启动追加一行，放在 Application Support（覆盖安装应该还在）。
enum LaunchRecord {
    struct Entry { var date: String; var build: String }

    static var fileURL: URL { CardBookmark.directory.appendingPathComponent("launches.txt") }

    static func append(build: String) -> [Entry] {
        try? FileManager.default.createDirectory(at: CardBookmark.directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let updated = existing + "\(formatter.string(from: Date()))\t\(build)\n"
        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
        return updated.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Entry(date: parts[0], build: parts[1]) : nil
        }
    }
}

/// 应用里带的描述文件的到期日（免费账号 7 天）。
enum ProvisioningInfo {
    static func expiration() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let date = plist["ExpirationDate"] as? Date else { return nil }
        return date.formatted(date: .numeric, time: .shortened)
    }
}
