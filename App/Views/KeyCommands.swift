import PhotoAICore
import UIKit

/// 外接键盘快捷键（F-26），网格和单张视图共用这一张表。沿用 Mac 版的单键；没有标签，不要 `6`–`9`；
/// Smart Keyboard Folio 没有 `Esc`，另配 `⌘.`。按住 ⌘ 时系统会列出这些快捷键。
enum KeyAction: Hashable {
    case rate(Int)
    case flag(Flag)
    case previous, next
    /// 网格 ↔ 单张。
    case toggleSingle
    /// 单张视图回网格（`Esc`、`⌘.`）。
    case back
    /// 单张视图：100% ↔ 适合屏幕。
    case zoom
    case addToLastCollection
    case undo, redo

    enum Place { case grid, single }

    /// 按顺序：⌘ 列表里也是这个顺序。带 ⌘ 的放前面：同一个键（`Z` 和 `⌘Z`）系统取先登记的那个。
    static func all(for place: Place) -> [KeyAction] {
        var actions: [KeyAction] = [.undo, .redo]
        actions += (1...5).map { .rate($0) } + [.rate(0), .flag(.pick), .flag(.reject), .flag(.none), .addToLastCollection]
        switch place {
        case .grid: actions += [.toggleSingle]
        case .single: actions += [.previous, .next, .zoom, .toggleSingle, .back]
        }
        return actions
    }

    private var keys: [(input: String, modifiers: UIKeyModifierFlags)] {
        switch self {
        case .rate(let n): [("\(n)", [])]
        case .flag(.pick): [("p", [])]
        case .flag(.reject): [("x", [])]
        case .flag(.none): [("u", [])]
        case .previous: [(UIKeyCommand.inputLeftArrow, [])]
        case .next: [(UIKeyCommand.inputRightArrow, [])]
        case .toggleSingle: [(" ", [])]
        case .back: [(UIKeyCommand.inputEscape, []), (".", .command)]
        case .zoom: [("z", [])]
        case .addToLastCollection: [("b", [])]
        case .undo: [("z", .command)]
        case .redo: [("z", [.command, .shift])]
        }
    }

    var title: String {
        switch self {
        case .rate(0): "清除星级"
        case .rate(let n): String(repeating: "★", count: n)
        case .flag(let flag): flag == .none ? "清除标记" : flag.displayName
        case .previous: "上一张"
        case .next: "下一张"
        case .toggleSingle: "网格 ↔ 单张"
        case .back: "回到网格"
        case .zoom: "100% ↔ 适合屏幕"
        case .addToLastCollection: "加入上一次的收藏夹"
        case .undo: "撤销"
        case .redo: "重做"
        }
    }

    /// 这个动作的全部 `UIKeyCommand`，动作的名字放在 `propertyList` 里，`action` 收到后用 `KeyAction(command)` 认回来。
    @MainActor
    func commands(action: Selector) -> [UIKeyCommand] {
        keys.map { key in
            let command = UIKeyCommand(title: title, action: action, input: key.input, modifierFlags: key.modifiers, propertyList: id)
            // 方向键、空格默认被翻页和焦点系统拿走。
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @MainActor
    static func commands(for place: Place, action: Selector) -> [UIKeyCommand] {
        all(for: place).flatMap { $0.commands(action: action) }
    }

    @MainActor
    init?(_ command: UIKeyCommand) {
        guard let id = command.propertyList as? String,
              let action = Self.all(for: .single).first(where: { $0.id == id }) ?? Self.all(for: .grid).first(where: { $0.id == id })
        else { return nil }
        self = action
    }

    private var id: String {
        switch self {
        case .rate(let n): "rate\(n)"
        case .flag(let flag): "flag-\(flag.rawValue)"
        case .previous: "previous"
        case .next: "next"
        case .toggleSingle: "toggleSingle"
        case .back: "back"
        case .zoom: "zoom"
        case .addToLastCollection: "addToLastCollection"
        case .undo: "undo"
        case .redo: "redo"
        }
    }
}

