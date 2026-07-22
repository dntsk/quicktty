import AppKit
import CoreGraphics
import Foundation

private let masterSize = 1024

private struct IconImage {
    let filename: String
    let size: String
    let scale: String
    let pixelSize: Int
}

private let iconImages = [
    IconImage(filename: "icon_16x16.png", size: "16x16", scale: "1x", pixelSize: 16),
    IconImage(filename: "icon_16x16@2x.png", size: "16x16", scale: "2x", pixelSize: 32),
    IconImage(filename: "icon_32x32.png", size: "32x32", scale: "1x", pixelSize: 32),
    IconImage(filename: "icon_32x32@2x.png", size: "32x32", scale: "2x", pixelSize: 64),
    IconImage(filename: "icon_128x128.png", size: "128x128", scale: "1x", pixelSize: 128),
    IconImage(filename: "icon_128x128@2x.png", size: "128x128", scale: "2x", pixelSize: 256),
    IconImage(filename: "icon_256x256.png", size: "256x256", scale: "1x", pixelSize: 256),
    IconImage(filename: "icon_256x256@2x.png", size: "256x256", scale: "2x", pixelSize: 512),
    IconImage(filename: "icon_512x512.png", size: "512x512", scale: "1x", pixelSize: 512),
    IconImage(filename: "icon_512x512@2x.png", size: "512x512", scale: "2x", pixelSize: 1024),
]

private enum GeneratorError: LocalizedError {
    case invalidArguments
    case invalidOutputPath(String)
    case imageCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: swift scripts/generate-app-icon.swift <output.appiconset>"
        case .invalidOutputPath(let path):
            "Output path must end in .appiconset: \(path)"
        case .imageCreationFailed:
            "Failed to create a bitmap context or image"
        case .pngEncodingFailed:
            "Failed to encode PNG"
        }
    }
}

private func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func bitmapContext(width: Int, height: Int) throws -> CGContext {
    guard
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw GeneratorError.imageCreationFailed
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

private func superellipsePath(in rect: CGRect, exponent: CGFloat = 5, steps: Int = 256) -> CGPath {
    let path = CGMutablePath()
    let horizontalRadius = rect.width / 2
    let verticalRadius = rect.height / 2

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * .pi * 2
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = CGPoint(
            x: rect.midX + horizontalRadius * (cosine >= 0 ? 1 : -1)
                * pow(abs(cosine), 2 / exponent),
            y: rect.midY + verticalRadius * (sine >= 0 ? 1 : -1) * pow(abs(sine), 2 / exponent)
        )
        if step == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

private func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func drawLinearGradient(
    in context: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    start: CGPoint,
    end: CGPoint
) {
    guard
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        )
    else {
        return
    }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
}

private func drawRadialGradient(
    in context: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    center: CGPoint,
    radius: CGFloat
) {
    guard
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        )
    else {
        return
    }
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
}

private func drawQ(in context: CGContext) {
    let outer = CGRect(x: 266, y: 384, width: 456, height: 456)
    let counter = CGRect(x: 356, y: 474, width: 276, height: 276)
    let ring = CGMutablePath()
    ring.addEllipse(in: outer)
    ring.addEllipse(in: counter)

    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 569, y: 510))
    tail.addLine(to: CGPoint(x: 624, y: 455))
    tail.addLine(to: CGPoint(x: 756, y: 323))
    tail.addQuadCurve(to: CGPoint(x: 762, y: 286), control: CGPoint(x: 780, y: 305))
    tail.addQuadCurve(to: CGPoint(x: 725, y: 280), control: CGPoint(x: 743, y: 268))
    tail.addLine(to: CGPoint(x: 593, y: 412))
    tail.addLine(to: CGPoint(x: 538, y: 467))
    tail.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.28))
    context.addPath(ring)
    context.drawPath(using: .eoFill)
    context.addPath(tail)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(ring)
    context.clip(using: .evenOdd)
    drawLinearGradient(
        in: context,
        colors: [color(0xFFFFFF), color(0xE8EBEC), color(0xCCD2D4)],
        locations: [0, 0.58, 1],
        start: CGPoint(x: 438, y: 850),
        end: CGPoint(x: 590, y: 350)
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(tail)
    context.clip()
    drawLinearGradient(
        in: context,
        colors: [color(0xF5F7F7), color(0xD7DCDE)],
        locations: [0, 1],
        start: CGPoint(x: 615, y: 505),
        end: CGPoint(x: 740, y: 290)
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(ring)
    context.setLineWidth(2)
    context.setStrokeColor(color(0xFFFFFF, 0.38))
    context.strokePath()
    context.restoreGState()
}

private func drawTTY(in context: CGContext, for pixelSize: Int) {
    let isSmall = pixelSize <= 16
    let horizontalScale: CGFloat = isSmall ? 1.22 : 1
    let verticalScale: CGFloat = isSmall ? 1.45 : 1
    let anchor = CGPoint(x: 512, y: 260)

    context.saveGState()
    context.translateBy(x: anchor.x, y: anchor.y)
    context.scaleBy(x: horizontalScale, y: verticalScale)
    context.translateBy(x: -anchor.x, y: -anchor.y)

    let topY: CGFloat = 355
    let bottomY: CGFloat = 158
    let stroke: CGFloat = isSmall ? 44 : 38
    let accent = color(0x62CFD0)

    let tOne = CGMutablePath()
    tOne.move(to: CGPoint(x: 253, y: topY))
    tOne.addLine(to: CGPoint(x: 382, y: topY))
    tOne.move(to: CGPoint(x: 317.5, y: topY))
    tOne.addLine(to: CGPoint(x: 317.5, y: bottomY))

    let tTwo = CGMutablePath()
    tTwo.move(to: CGPoint(x: 430, y: topY))
    tTwo.addLine(to: CGPoint(x: 559, y: topY))
    tTwo.move(to: CGPoint(x: 494.5, y: topY))
    tTwo.addLine(to: CGPoint(x: 494.5, y: bottomY))

    let yGlyph = CGMutablePath()
    yGlyph.move(to: CGPoint(x: 606, y: topY))
    yGlyph.addLine(to: CGPoint(x: 670, y: 274))
    yGlyph.addLine(to: CGPoint(x: 734, y: topY))
    yGlyph.move(to: CGPoint(x: 670, y: 274))
    yGlyph.addLine(to: CGPoint(x: 670, y: bottomY))

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -7), blur: 14, color: color(0x000000, 0.30))
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(accent)
    context.addPath(tOne)
    context.addPath(tTwo)
    context.addPath(yGlyph)
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setLineWidth(max(stroke - 12, 22))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(tOne)
    context.addPath(tTwo)
    context.addPath(yGlyph)
    context.clip()
    drawLinearGradient(
        in: context,
        colors: [color(0xB7F4F2, 0.54), color(0xFFFFFF, 0)],
        locations: [0, 1],
        start: CGPoint(x: 500, y: 380),
        end: CGPoint(x: 500, y: 200)
    )
    context.restoreGState()

    context.restoreGState()
}

private func makeIconImage(pixelSize: Int) throws -> CGImage {
    let context = try bitmapContext(width: pixelSize, height: pixelSize)
    let scale = CGFloat(pixelSize) / CGFloat(masterSize)
    context.scaleBy(x: scale, y: scale)

    let canvas = CGRect(x: 0, y: 0, width: masterSize, height: masterSize)
    context.setFillColor(NSColor.clear.cgColor)
    context.fill(canvas)

    let iconRect = CGRect(x: 96, y: 96, width: 832, height: 832)
    let icon = superellipsePath(in: iconRect)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -24), blur: 54, color: color(0x000000, 0.34))
    context.addPath(icon)
    context.setFillColor(color(0x1B2024))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(icon)
    context.clip()
    context.setFillColor(color(0x1A1F23))
    context.fill(iconRect)
    drawLinearGradient(
        in: context,
        colors: [color(0x313940), color(0x20272C), color(0x14191D)],
        locations: [0, 0.47, 1],
        start: CGPoint(x: 350, y: 950),
        end: CGPoint(x: 690, y: 70)
    )
    drawRadialGradient(
        in: context,
        colors: [color(0xAFC1C8, 0.12), color(0xAFC1C8, 0)],
        locations: [0, 1],
        center: CGPoint(x: 420, y: 864),
        radius: 590
    )
    drawRadialGradient(
        in: context,
        colors: [color(0x000000, 0), color(0x000000, 0.25)],
        locations: [0.42, 1],
        center: CGPoint(x: 512, y: 570),
        radius: 620
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(icon)
    context.setLineWidth(2)
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.strokePath()
    context.restoreGState()

    let innerEdge = superellipsePath(in: iconRect.insetBy(dx: 7, dy: 7))
    context.addPath(innerEdge)
    context.setLineWidth(2)
    context.setStrokeColor(color(0x000000, 0.20))
    context.strokePath()

    drawQ(in: context)
    drawTTY(in: context, for: pixelSize)

    guard let image = context.makeImage() else {
        throw GeneratorError.imageCreationFailed
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = CGSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw GeneratorError.pngEncodingFailed
    }
    try data.write(to: url, options: .atomic)
}

private func writeContents(to url: URL) throws {
    let images = iconImages.map { image in
        [
            "filename": image.filename,
            "idiom": "mac",
            "scale": image.scale,
            "size": image.size,
        ]
    }
    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func outputURL(from arguments: [String]) throws -> URL {
    guard arguments.count == 1 else {
        throw GeneratorError.invalidArguments
    }

    let outputURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
    guard outputURL.pathExtension == "appiconset" else {
        throw GeneratorError.invalidOutputPath(outputURL.path)
    }
    return outputURL
}

private func run() throws {
    let outputURL = try outputURL(from: Array(CommandLine.arguments.dropFirst()))
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    for iconImage in iconImages {
        let image = try makeIconImage(pixelSize: iconImage.pixelSize)
        try writePNG(image, to: outputURL.appendingPathComponent(iconImage.filename))
    }
    try writeContents(to: outputURL.appendingPathComponent("Contents.json"))

    print("Wrote \(iconImages.count) PNGs to \(outputURL.path)")
}

do {
    try run()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
