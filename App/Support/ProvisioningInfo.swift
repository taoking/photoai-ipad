import Foundation

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
