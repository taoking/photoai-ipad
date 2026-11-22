// 画应用图标（F-52）：搬自 photoai-mac-v2 a291868 Scripts/make-icon.swift，图样不变（深色底，两张叠着的照片，
// 前面一张是日落山景，右下一颗金色的星）。iPadOS 的图标要铺满、不透明，圆角由系统裁：去掉圆角方和外面的阴影，
// 整幅放大 1024 / 824，Mac 版的底正好铺满。
// 用法：swift Scripts/make-icon.swift <输出的 PNG>；Scripts/make-icon.sh 直接写进 App/Assets.xcassets。
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func star(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<10 {
        let radius = i.isMultiple(of: 2) ? outer : inner
        let angle = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

// 坐标原点在左下。下面的坐标照 Mac 版（底是 100…924 的 824 见方），整幅放大到铺满 1024。
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
context.translateBy(x: size / 2, y: size / 2)
context.scaleBy(x: size / body.width, y: size / body.height)
context.translateBy(x: -body.midX, y: -body.midY)

context.saveGState()
context.drawLinearGradient(gradient([color(0x34467E), color(0x141B35)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// 左上一点光
context.drawRadialGradient(
    gradient([color(0x7F9CFF, 0.35), color(0x7F9CFF, 0)]),
    startCenter: CGPoint(x: 330, y: 820), startRadius: 0, endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: []
)

/// 一张照片：白边框 + 里面的画面。`angle` 是绕卡片中心转的角度（弧度）。
func card(center: CGPoint, width: CGFloat, height: CGFloat, angle: CGFloat, drawPhoto: (CGRect) -> Void) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angle)
    let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    context.addPath(CGPath(roundedRect: frame, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.setFillColor(color(0xF4F6FB))
    context.fillPath()
    context.restoreGState()
    let inset: CGFloat = 26
    let photo = frame.insetBy(dx: inset, dy: inset)
    context.saveGState()
    context.addPath(CGPath(roundedRect: photo, cornerWidth: 10, cornerHeight: 10, transform: nil))
    context.clip()
    drawPhoto(photo)
    context.restoreGState()
    context.restoreGState()
}

// 后面一张：冷色的湖景，向左歪。
card(center: CGPoint(x: 455, y: 560), width: 500, height: 380, angle: 0.16) { rect in
    context.drawLinearGradient(gradient([color(0x9FC6E8), color(0x5D8FC2)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35))
    hill.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.30),
                  control1: CGPoint(x: rect.midX - 60, y: rect.minY + rect.height * 0.62),
                  control2: CGPoint(x: rect.midX + 80, y: rect.minY + rect.height * 0.18))
    hill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    hill.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    hill.closeSubpath()
    context.addPath(hill)
    context.setFillColor(color(0x2F5A86))
    context.fillPath()
}

// 前面一张：日落和山，向右歪。
card(center: CGPoint(x: 545, y: 455), width: 540, height: 410, angle: -0.10) { rect in
    context.drawLinearGradient(gradient([color(0xFF8A5B), color(0xFFC46B), color(0xFFE3A3)]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY + rect.height * 0.3), options: [.drawsAfterEndLocation])
    let sun = CGRect(x: rect.midX + 10, y: rect.minY + rect.height * 0.42, width: 120, height: 120)
    context.setFillColor(color(0xFFF6DC))
    context.fillEllipse(in: sun)
    let far = CGMutablePath()
    far.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.30))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.62))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.52, y: rect.minY + rect.height * 0.38))
    far.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.52))
    far.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28))
    far.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    far.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    far.closeSubpath()
    context.addPath(far)
    context.setFillColor(color(0xB0546A))
    context.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.14))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.36))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.16))
    near.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.40))
    near.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.20))
    near.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    near.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    near.closeSubpath()
    context.addPath(near)
    context.setFillColor(color(0x4A2E5C))
    context.fillPath()
}

// 金色的星：选片打星。
let starCenter = CGPoint(x: 735, y: 300)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.45))
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.setFillColor(color(0xFFC83D))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.clip()
context.drawLinearGradient(gradient([color(0xFFE27A), color(0xF5A623)]), start: CGPoint(x: 0, y: starCenter.y + 150), end: CGPoint(x: 0, y: starCenter.y - 150), options: [])
context.restoreGState()
context.addPath(star(center: starCenter, outer: 150, inner: 64))
context.setStrokeColor(color(0xFFFFFF, 0.9))
context.setLineWidth(12)
context.setLineJoin(.round)
context.strokePath()
context.restoreGState()

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: output)
print(output.path)
