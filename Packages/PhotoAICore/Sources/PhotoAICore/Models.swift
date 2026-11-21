// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Models.swift。改了：只有一张卡（`CardRecord` 代替卷），
// 库里的照片都可见（`isOnCard` 只用来标“卡上已删”），去掉人物、地点、搜索、导入批次的类型。
import Foundation

public typealias VolumeID = Int
public typealias PhotoID = Int
public typealias FileID = Int
public typealias CollectionID = Int
public typealias LabelID = Int

/// 唯一的那张卡（开发计划 §5）：`volumes` 表固定一行 `id = 1`。插进来的卡都当同一张，不认卡、不起名。
public struct CardRecord: Sendable, Equatable {
    /// 卡根目录的书签；清卡后为 nil，下次读卡要重新选。
    public var bookmark: Data?
    public var lastSeenAt: Date?
    /// 最后一次所有目录都完整扫完的时间。
    public var lastScannedAt: Date?
}

public enum PreviewState: String, Sendable { case pending, ready, failed }
public enum Flag: String, Sendable { case none, pick, reject }

/// 网格里一格需要的字段。1 万条一次读出，所以只放必需的。
public struct PhotoSummary: Sendable, Equatable, Identifiable {
    public let id: PhotoID
    public var baseName: String
    /// `yyyy-MM-dd HH:mm:ss`；没有拍摄时间为 nil。
    public var captureDate: String?
    public var width: Int?
    public var height: Int?
    public var rating: Int
    public var flag: Flag
    public var thumbState: PreviewState
    public var hasRaw: Bool
    public var hasJPEG: Bool
    /// 卡上还有它的文件。false 就是“卡上已删”：照常显示、照常能选，清卡时一起删（F-06）。
    public var isOnCard: Bool = true
    /// 按标签位置排好序。
    public var labelIDs: [LabelID] = []

    /// 按天分组用：`yyyy-MM-dd`；没有拍摄时间的归到“日期未知”。
    public var day: String? { captureDate.map { String($0.prefix(10)) } }

    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1.5 }
        return Double(width) / Double(height)
    }
}

/// 照片详情：信息面板用。
public struct PhotoDetail: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        /// 相对卡根目录，如 `DCIM/100MSDCF/DSC01926.ARW`。
        public var relativePath: String
        public var isPresent: Bool
    }

    public var summary: PhotoSummary
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var iso: Int?
    public var previewState: PreviewState
    public var presentLocationCount: Int
    public var extensions: [String]
    public var locations: [Location]
    /// 这张照片所在的收藏夹名字。
    public var collectionNames: [String] = []
    /// 相机记录的对焦框：`pending` 还没读（卡连接时读），`none` 没有记录。
    public var focusState: String = "pending"
    public var focus: FocusArea?
    public var lastExportedAt: Date?
}

/// 一个标签位置。一共 9 个，`sortOrder` 0–8 决定快捷键：前 4 个对应 6–9。
public struct LabelRecord: Sendable, Equatable, Identifiable, Hashable {
    public let id: LabelID
    /// 空字符串表示这个位置没用。
    public var name: String
    /// `#rrggbb`
    public var color: String
    public var sortOrder: Int

    public var isInUse: Bool { !name.isEmpty }
}

public struct CollectionRecord: Sendable, Equatable, Identifiable, Hashable {
    public let id: CollectionID
    public var name: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var photoCount: Int

    public init(id: CollectionID, name: String, createdAt: Date, lastUsedAt: Date?, photoCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.photoCount = photoCount
    }
}

/// 侧栏选的一组照片。
public enum PhotoScope: Sendable, Hashable {
    case all
    /// `yyyy`、`yyyy-MM` 或 `yyyy-MM-dd`。
    case datePrefix(String)
    /// 没有拍摄时间的照片。
    case undated
    case collection(CollectionID)
}

public enum PhotoSort: String, Sendable, Hashable, CaseIterable {
    case captureDateDescending
    case captureDateAscending
}

/// 卡和库的概况：标题栏、导入进度、清卡检查用。
public struct CardStats: Sendable, Equatable {
    public var photoCount = 0
    /// 480 和 1600 两档预览都好了的照片数。
    public var previewReadyCount = 0
    /// 卡上还有文件、预览还没做的照片数（插着卡能接着做的）。
    public var previewPendingCount = 0
    /// 预览做不出来（原片解码不了）的照片数。
    public var previewFailedCount = 0
    /// “卡上已删”的照片数。
    public var missingFromCardCount = 0
    public var incompleteDirectoryCount = 0

    public init() {}
}

/// 侧栏的时间树：每天的照片数。
public struct DayCount: Sendable, Equatable {
    public var day: String
    public var count: Int
}
