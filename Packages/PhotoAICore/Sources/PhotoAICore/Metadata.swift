// 搬自 photoai-mac-v2 a291868 Sources/PhotoAICore/Metadata.swift。改了：EXIF 的 PixelX/YDimension 比文件头的宽高大时用它（iPadOS 的 ImageIO 把 ARW 报成内嵌图的 1616×1080）。
import Foundation
import ImageIO

/// 扫描时从一个文件读出的元数据。
public struct PhotoMetadata: Sendable, Equatable {
    /// `yyyy-MM-dd HH:mm:ss`，相机写的本地时间；读不到为 nil。
    public var captureDate: String?
    public var captureSubsec: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var shutter: Double?
    public var iso: Int?
    /// 按方向转正后的宽高。
    public var width: Int?
    public var height: Int?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        captureDate: String? = nil,
        captureSubsec: String? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lens: String? = nil,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        shutter: Double? = nil,
        iso: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.captureDate = captureDate
        self.captureSubsec = captureSubsec
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 读元数据。扫描测试里换成假的实现，不需要真实图片。
///
/// 三种结果要分清：读出来了；文件能打开但不是图片（返回 nil，跳过这个文件）；
/// 文件打不开（抛错，比如中途拔卡）。打不开时绝不能当作“没有拍摄时间”去算身份，
/// 否则会把原来的照片误判成同一路径换了照片。
public protocol MetadataReading: Sendable {
    func metadata(at url: URL) throws -> PhotoMetadata?
}

public struct MetadataReadError: Error, CustomStringConvertible {
    public var path: String
    public var description: String { "读不到文件：\(path)" }
}

/// 用 ImageIO 读 EXIF。只读属性，不解码像素。
public struct ImageIOMetadataReader: MetadataReading {
    public init() {}

    public func metadata(at url: URL) throws -> PhotoMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw MetadataReadError(path: url.path)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            // 读属性失败时再确认一次文件还在：拔卡后 ImageIO 也会走到这里。
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw MetadataReadError(path: url.path)
            }
            return nil
        }
        return Self.metadata(from: properties)
    }

    static func metadata(from properties: [CFString: Any]) -> PhotoMetadata {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var metadata = PhotoMetadata()
        // 只认 DateTimeOriginal。TIFF 的 DateTime 是“文件改过的时间”，修图软件会改写它，不能用来认身份。
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            metadata.captureDate = CaptureDate.normalize(exif: text)
        }
        metadata.captureSubsec = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)?
            .trimmingCharacters(in: .whitespaces)
        metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        metadata.lens = (exif[kCGImagePropertyExifLensModel] as? String)
            ?? (exifAux[kCGImagePropertyExifAuxLensModel] as? String)
        metadata.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
        metadata.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        metadata.shutter = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoValues.first {
            metadata.iso = first.intValue
        }

        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        // iPadOS 不解 RAW，ARW 的文件头宽高是内嵌 JPEG 的 1616×1080；EXIF 里记的更大就用 EXIF 的（技术验证 §2）。
        if let exifWidth = (exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue,
           let exifHeight = (exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue,
           max(exifWidth, exifHeight) > max(width ?? 0, height ?? 0) {
            width = exifWidth
            height = exifHeight
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            metadata.width = height
            metadata.height = width
        } else {
            metadata.width = width
            metadata.height = height
        }

        if let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
            metadata.latitude = latitudeRef == "S" ? -latitude : latitude
            metadata.longitude = longitudeRef == "W" ? -longitude : longitude
        }
        return metadata
    }

    /// 和身份、尺寸有关的 EXIF 原始字段，诊断日志记录真实样片用。
    public static func identityFields(at url: URL) -> [String: String] {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return [:]
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var fields: [String: String] = [:]
        fields["Exif.DateTimeOriginal"] = exif[kCGImagePropertyExifDateTimeOriginal].map { "\($0)" }
        fields["Exif.SubsecTimeOriginal"] = exif[kCGImagePropertyExifSubsecTimeOriginal].map { "\($0)" }
        fields["Exif.OffsetTimeOriginal"] = exif[kCGImagePropertyExifOffsetTimeOriginal].map { "\($0)" }
        fields["Exif.DateTimeDigitized"] = exif[kCGImagePropertyExifDateTimeDigitized].map { "\($0)" }
        fields["TIFF.DateTime"] = tiff[kCGImagePropertyTIFFDateTime].map { "\($0)" }
        fields["TIFF.Make"] = tiff[kCGImagePropertyTIFFMake].map { "\($0)" }
        fields["TIFF.Model"] = tiff[kCGImagePropertyTIFFModel].map { "\($0)" }
        fields["PixelWidth"] = properties[kCGImagePropertyPixelWidth].map { "\($0)" }
        fields["PixelHeight"] = properties[kCGImagePropertyPixelHeight].map { "\($0)" }
        fields["Exif.PixelXDimension"] = exif[kCGImagePropertyExifPixelXDimension].map { "\($0)" }
        fields["Exif.PixelYDimension"] = exif[kCGImagePropertyExifPixelYDimension].map { "\($0)" }
        fields["Orientation"] = properties[kCGImagePropertyOrientation].map { "\($0)" }
        return fields
    }
}
