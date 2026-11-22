import UIKit

/// 导入、导出时屏幕常亮。两件事可能同时在做：都做完才恢复自动锁屏。
@MainActor
enum KeepAwake {
    private static var holders = 0

    static func begin() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func end() {
        holders = max(0, holders - 1)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
