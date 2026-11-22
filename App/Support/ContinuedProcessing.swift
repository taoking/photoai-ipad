import BackgroundTasks
import Foundation

/// iPadOS 26 的“继续处理任务”（F-07）：切到后台后系统让应用接着跑，屏幕上显示进度，用户在那里能停下。
///
/// 只能在前台申请，系统没批（设备忙、关了后台刷新）就返回 nil，照旧切到后台停下、回来续做。
/// 每次申请用新的标识符，先注册再提交（只注册通配符系统不认）。进度要一直在走，停住 20 秒左右系统会收回。
/// 系统可能在调 `start` 的处理块之前就结束了，所以进度、结束都先记着，任务开始时补上。
final class ContinuedProcessing: @unchecked Sendable {
    private let lock = NSLock()
    private var task: BGContinuedProcessingTask?
    private var progress: (completed: Int64, total: Int64, subtitle: String)?
    private var result: Bool?
    private var subtitleShownAt = Date.distantPast
    private let title: String

    private init(title: String) {
        self.title = title
    }

    /// 申请。`onExpire` 在系统收回时调（不在主线程）：时间到了、或用户在系统的进度上点了停。调了之后照常停下，再调 `finish`。
    static func start(name: String, title: String, subtitle: String, onExpire: @escaping @Sendable () -> Void) -> ContinuedProcessing? {
        let identifier = "\(Bundle.main.bundleIdentifier ?? "").continued.\(name).\(UUID().uuidString)"
        let handle = ContinuedProcessing(title: title)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = {
                appLog("继续处理任务被系统收回：\(title)")
                onExpire()
            }
            handle.began(task)
        }
        guard registered else {
            appLog("继续处理任务注册不上（Info.plist 的 BGTaskSchedulerPermittedIdentifiers）：\(title)")
            return nil
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            appLog("继续处理任务没批：\(title)，\(error)")
            return nil
        }
        appLog("申请了继续处理任务：\(title)")
        return handle
    }

    /// 张数随时改；副标题最多一秒改一次（导出时进度来得很勤）。
    func update(completed: Int, total: Int, subtitle: String) {
        lock.withLock {
            progress = (Int64(completed), Int64(max(total, completed, 1)), subtitle)
            if let task { apply(to: task) }
        }
    }

    func finish(success: Bool) {
        lock.withLock {
            guard result == nil else { return }
            result = success
            task?.setTaskCompleted(success: success)
        }
    }

    private func began(_ task: BGContinuedProcessingTask) {
        lock.withLock {
            self.task = task
            if let result {
                task.setTaskCompleted(success: result)
            } else {
                apply(to: task)
            }
        }
    }

    private func apply(to task: BGContinuedProcessingTask) {
        guard let progress else { return }
        task.progress.totalUnitCount = progress.total
        task.progress.completedUnitCount = progress.completed
        guard Date().timeIntervalSince(subtitleShownAt) >= 1 else { return }
        subtitleShownAt = Date()
        task.updateTitle(title, subtitle: progress.subtitle)
    }
}
