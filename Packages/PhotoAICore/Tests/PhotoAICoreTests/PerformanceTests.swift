// 改自 photoai-mac-v2 a291868 Tests/PhotoAICoreTests/PerformanceTests.swift：库按 1 万张测（开发计划 §8），
// 合成库在测试里现做；只留和 M1 有关的 PF-1（数据部分）、PF-3、PF-4、PF-8。
import Foundation
import Testing
@testable import PhotoAICore

/// 性能目标的数据层部分，在 Mac 上跑（iPad 上慢几倍，真机数字见验收记录）。
/// `PHOTOAI_PERF=1 swift test --filter PerformanceTests` 运行；没设置时跳过。结果以 `PF` 开头打印。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOAI_PERF"] != nil), .serialized)
struct PerformanceTests {
    /// 同一个查询跑 5 次，取中位数和最大值（第一次是冷的）。
    func measure(_ label: String, _ body: () throws -> Int) rethrows -> (median: Double, max: Double) {
        var times: [Double] = []
        var count = 0
        for _ in 0..<5 {
            let start = Date()
            count = try body()
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "PF %@：中位 %.1f ms，最大 %.1f ms，首次 %.1f ms，%d 条", label, sorted[2], sorted[4], times[0], count))
        return (sorted[2], sorted[4])
    }

    func syntheticLibrary(withPreviewFiles: Bool = false) throws -> TemporaryLibrary {
        var options = SyntheticLibrary.Options()
        options.withPreviewFiles = withPreviewFiles
        let start = Date()
        let temp = try TemporaryLibrary { try SyntheticLibrary.build(at: $0, options: options) }
        print(String(format: "PF 合成 1 万张：%.1f 秒", Date().timeIntervalSince(start)))
        return temp
    }

    /// PF-1 的数据部分（启动时读一次）和 PF-3（切换侧栏项），≤ 200 ms。
    @Test func sidebarQueries() throws {
        let temp = try syntheticLibrary()
        let reader = try temp.library.makeReader()
        #expect(try reader.photoCount() == 10_000)
        let days = try reader.dayCounts()
        let day = try #require(days.dropFirst(days.count / 2).first?.day)

        var results: [(Double, Double)] = []
        results.append(try measure("全部照片（新→旧）") { try reader.photos(in: .all).count })
        results.append(try measure("全部照片（旧→新）") { try reader.photos(in: .all, sort: .captureDateAscending).count })
        results.append(try measure("日 \(day)") { try reader.photos(in: .datePrefix(day)).count })
        results.append(try measure("时间树") { try reader.dayCounts().count })
        results.append(try measure("卡的概况") { try reader.cardStats().photoCount })
        for (median, _) in results { #expect(median <= 200) }
    }

    /// PF-8：对 1 万条重新筛选，≤ 100 ms。筛选在内存里做，不查数据库。
    @Test func refilterTenThousand() throws {
        let temp = try syntheticLibrary()
        let photos = try temp.library.makeReader().photos(in: .all)
        var classicFive = PhotoFilter()
        classicFive.toggleLabel(1)
        classicFive.toggleStar(5)
        var several = PhotoFilter()
        several.toggleStar(3)
        several.toggleLabel(1)
        several.toggleLabel(2)
        several.noLabel = true
        several.toggleFlag(.pick)
        several.toggleFlag(.none)
        several.toggleKind(.rawPlusJPEG)
        for (name, filter) in [("经典 + ★5", classicFive), ("四类条件都有", several)] {
            let (median, maximum) = measure("筛选 \(name)") { photos.filter(filter.matches).count }
            #expect(median <= 100)
            #expect(maximum <= 100)
        }
    }

    /// PF-4：卡插上后自动重扫 1,000 张未变化的照片，≤ 3 秒。
    /// 在 1 万张的合成库里扫一张 1,000 个文件的假卡（在本机 SSD 上），先导入，再计时重扫。
    @Test func rescanThousandUnchangedFiles() async throws {
        let temp = try syntheticLibrary()
        let card = try FakeCard()
        for index in 0..<1_000 {
            let folder = 100 + index / 250
            try card.put(String(format: "DCIM/%dMSDCF/PF4_%05d.ARW", folder, index),
                         date: String(format: "2027-01-01 10:%02d:%02d", index / 60 % 60, index % 60))
        }
        let first = try await CardScanner(library: temp.library, metadataReader: FakeMetadataReader()).scan(cardURL: card.root)
        #expect(first.newPhotos == 1_000)

        let start = Date()
        let rescan = try await CardScanner(library: temp.library).scan(cardURL: card.root)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "PF-4 重扫 1,000 张未变化（1 万张库，本机 SSD）：%.0f ms，未变 %d，完整 %@",
                     elapsed * 1000, rescan.unchanged, rescan.isComplete ? "是" : "否"))
        #expect(rescan.unchanged == 1_000)
        #expect(elapsed <= 3)
    }
}
