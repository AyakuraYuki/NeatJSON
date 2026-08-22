import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// IconComposer — NeatJSON 应用图标生成器
//
// 设计概念：「括号成序」
//   底：满幅竖向渐变（长春花紫 → 靛蓝），无自绘圆角 —— macOS 26 会把
//       app 图标统一裁成系统 squircle，自己再画一层圆角会变成双重圆角、
//       显得比同排图标小一圈。
//   主体：一对纯白大括号 { }，中间三条自上而下依次变短的圆头横杠。
//       括号 = JSON 结构，递减的横杠 = 排序（这是最通用的 sort 记号），
//       两者合起来就是「格式化 + 排序」。
//   点缀：右上一大一小两枚四角星，取「整理干净 / 焕然一新」的意思。
//
//   小尺寸策略：只有三个层次分明的白色要素、笔画粗（≥5% 画布）、不含
//       文字与细线；16px 下退化为「紫底 + 白括号剪影」，仍可辨识。
//
// 输出 AppIcon.iconset（全尺寸 PNG）→ actool 编译为 AppIcon.icns

// MARK: - 参数

/// 主图渲染尺寸，其余尺寸由它高质量缩放得到。
let canvasSize: CGFloat = 1024

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset")

/// 底色渐变：上浅下深的竖向渐变。
let gradientTop = CGColor(red: 178 / 255, green: 170 / 255, blue: 255 / 255, alpha: 1)
let gradientBottom = CGColor(red: 78 / 255, green: 94 / 255, blue: 224 / 255, alpha: 1)

// MARK: - 入口

let master = renderMaster(size: canvasSize)
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in sizes {
    savePNG(resize(master, to: entry.size), to: outputDir.appendingPathComponent(entry.name))
}

print("iconset written to \(outputDir.path)")

// MARK: - 绘制

func renderMaster(size: CGFloat) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    drawBackground(ctx: ctx, size: size)
    drawBraces(ctx: ctx, size: size)
    drawSortedBars(ctx: ctx, size: size)
    drawSparkles(ctx: ctx, size: size)

    return ctx.makeImage()!
}

// MARK: 版面

/// 主体（括号 + 横杠）的中心。略偏左下，把右上留给点缀的星星。
func glyphCenter(size: CGFloat) -> CGPoint {
    CGPoint(x: size * 0.462, y: size * 0.470)
}

/// 括号脊柱到中心的水平距离。
func braceHalfSpan(size: CGFloat) -> CGFloat {
    size * 0.232
}

/// 白色笔画的统一粗细。
func strokeWeight(size: CGFloat) -> CGFloat {
    size * 0.062
}

/// 满幅竖向渐变。不画圆角：交给系统的 squircle 蒙版。
func drawBackground(ctx: CGContext, size: CGFloat) {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: srgb,
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0, 1]
    )!
    // CG 坐标系 y 向上：起点在顶边
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

/// 一对大括号 { }。纯白粗描边，中部带标准凸尖。
func drawBraces(ctx: CGContext, size: CGFloat) {
    let center = glyphCenter(size: size)
    let thickness = strokeWeight(size: size)
    let halfSpan = braceHalfSpan(size: size)
    let height = size * 0.418
    let armLength = size * 0.056

    let paths = [-1, 1].map { side in
        bracePath(
            side: CGFloat(side),
            center: CGPoint(x: center.x + CGFloat(side) * halfSpan, y: center.y),
            height: height,
            armLength: armLength,
            thickness: thickness
        )
    }

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for path in paths {
        ctx.addPath(path)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// 一侧大括号的骨架路径（供粗描边）。
///
/// side = -1 画左括号 `{`，+1 画右括号 `}`（水平镜像）。
/// 局部坐标：脊柱在 x=0，横臂朝 x+（也就是朝中心）伸出，
/// 中部凸尖朝 x- 突出；y 向上、中心为 0。
func bracePath(
    side: CGFloat,
    center: CGPoint,
    height: CGFloat,
    armLength: CGFloat,
    thickness: CGFloat
) -> CGPath {
    let halfH = height / 2
    let corner = thickness * 0.55 // 横臂转入脊柱的圆角
    let notchDepth = thickness * 1.05 // 中部凸尖突出深度
    let notchSpan = thickness * 0.90 // 凸尖在脊柱上占的高度

    let path = CGMutablePath()
    path.move(to: CGPoint(x: armLength, y: halfH))
    path.addLine(to: CGPoint(x: corner, y: halfH))
    path.addQuadCurve(
        to: CGPoint(x: 0, y: halfH - corner),
        control: CGPoint(x: 0, y: halfH)
    )
    path.addLine(to: CGPoint(x: 0, y: notchSpan))
    path.addQuadCurve(
        to: CGPoint(x: -notchDepth, y: 0),
        control: CGPoint(x: 0, y: 0)
    )
    path.addQuadCurve(
        to: CGPoint(x: 0, y: -notchSpan),
        control: CGPoint(x: 0, y: 0)
    )
    path.addLine(to: CGPoint(x: 0, y: -halfH + corner))
    path.addQuadCurve(
        to: CGPoint(x: corner, y: -halfH),
        control: CGPoint(x: 0, y: -halfH)
    )
    path.addLine(to: CGPoint(x: armLength, y: -halfH))

    var transform = CGAffineTransform(translationX: center.x, y: center.y)
    if side > 0 {
        transform = transform.scaledBy(x: -1, y: 1)
    }
    return path.copy(using: &transform)!
}

/// 括号之间自上而下依次变短的三条圆头横杠 —— 通用的「已排序」记号。
func drawSortedBars(ctx: CGContext, size: CGFloat) {
    let center = glyphCenter(size: size)
    let thickness = strokeWeight(size: size) * 0.95
    let spacing = size * 0.134
    // 相对最长杠的比例：递减读作「已排序」
    let ratios: [CGFloat] = [1.0, 0.68, 0.40]
    let longest = size * 0.252

    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    for (index, ratio) in ratios.enumerated() {
        let width = longest * ratio
        let y = center.y + spacing - CGFloat(index) * spacing
        // 左端对齐，让长度差一眼可见（居中会两头同时收缩，不像排序）
        let rect = CGRect(
            x: center.x - longest / 2,
            y: y - thickness / 2,
            width: width,
            height: thickness
        )
        ctx.addPath(
            CGPath(
                roundedRect: rect,
                cornerWidth: thickness / 2,
                cornerHeight: thickness / 2,
                transform: nil
            )
        )
    }
    ctx.fillPath()
    ctx.restoreGState()
}

/// 右上角一大一小两枚四角星。
func drawSparkles(ctx: CGContext, size: CGFloat) {
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(
        sparklePath(center: CGPoint(x: size * 0.779, y: size * 0.735), radius: size * 0.066)
    )
    ctx.addPath(
        sparklePath(center: CGPoint(x: size * 0.855, y: size * 0.818), radius: size * 0.028)
    )
    ctx.fillPath()
    ctx.restoreGState()
}

/// 四角星：四个尖角之间用二次曲线内凹，控制点靠近中心。
func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let waist = radius * 0.17
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: radius))
    path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: waist, y: waist))
    path.addQuadCurve(to: CGPoint(x: 0, y: -radius), control: CGPoint(x: waist, y: -waist))
    path.addQuadCurve(to: CGPoint(x: -radius, y: 0), control: CGPoint(x: -waist, y: -waist))
    path.addQuadCurve(to: CGPoint(x: 0, y: radius), control: CGPoint(x: -waist, y: waist))
    path.closeSubpath()

    var transform = CGAffineTransform(translationX: center.x, y: center.y)
    return path.copy(using: &transform)!
}

// MARK: - 导出

func resize(_ image: CGImage, to pixels: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("cannot create destination \(url)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("cannot write \(url)")
    }
}
