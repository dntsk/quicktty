import AppKit
import CoreGraphics
import Foundation

private let canvasSize = CGSize(width: 1024, height: 1024)

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
            "Failed to create icon image"
        case .pngEncodingFailed:
            "Failed to encode PNG"
        }
    }
}

private func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255.0
    let green = CGFloat((hex >> 8) & 0xFF) / 255.0
    let blue = CGFloat(hex & 0xFF) / 255.0
    return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private func superellipsePath(in rect: CGRect, exponent: CGFloat = 5.0, steps: Int = 240) -> CGPath
{
    let path = CGMutablePath()
    let horizontalRadius = rect.width / 2.0
    let verticalRadius = rect.height / 2.0
    let centerX = rect.midX
    let centerY = rect.midY

    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * .pi * 2.0
        let cosine = cos(angle)
        let sine = sin(angle)
        let x =
            centerX + horizontalRadius * (cosine >= 0 ? 1 : -1)
            * pow(abs(cosine), 2.0 / exponent)
        let y = centerY + verticalRadius * (sine >= 0 ? 1 : -1) * pow(abs(sine), 2.0 / exponent)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }

    path.closeSubpath()
    return path
}

private func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

private func drawGradient(
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

private func makeMasterImage() throws -> CGImage {
    guard
        let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
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
    context.setFillColor(NSColor.clear.cgColor)
    context.fill(CGRect(origin: .zero, size: canvasSize))

    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let iconPath = superellipsePath(in: iconRect, exponent: 5.0)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -26), blur: 64, color: color(0x000000, 0.34))
    context.addPath(iconPath)
    context.setFillColor(color(0x1E2127))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(iconPath)
    context.clip()

    context.setFillColor(color(0x1D2026))
    context.fill(iconRect)

    drawGradient(
        in: context,
        colors: [color(0x2A2E35, 0.92), color(0x16181D, 0.96)],
        locations: [0.0, 1.0],
        start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.midX, y: iconRect.minY)
    )

    drawGradient(
        in: context,
        colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0.02), color(0xFFFFFF, 0.0)],
        locations: [0.0, 0.45, 1.0],
        start: CGPoint(x: iconRect.midX, y: iconRect.maxY - 20),
        end: CGPoint(x: iconRect.midX, y: iconRect.midY + 80)
    )

    drawGradient(
        in: context,
        colors: [color(0x000000, 0.0), color(0x000000, 0.18)],
        locations: [0.0, 1.0],
        start: CGPoint(x: iconRect.midX, y: iconRect.minY + iconRect.height * 0.38),
        end: CGPoint(x: iconRect.midX, y: iconRect.minY)
    )

    let dividerX = iconRect.midX + 36
    context.setStrokeColor(color(0xFFFFFF, 0.07))
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: dividerX, y: iconRect.minY + 154))
    context.addLine(to: CGPoint(x: dividerX, y: iconRect.maxY - 154))
    context.strokePath()

    let topEdge = CGRect(x: iconRect.minX + 76, y: iconRect.maxY - 120, width: 220, height: 6)
    context.setFillColor(color(0xFFFFFF, 0.08))
    context.addPath(roundedRectPath(topEdge, radius: 3))
    context.fillPath()

    context.restoreGState()

    context.saveGState()
    context.addPath(iconPath)
    context.setLineWidth(2.0)
    context.setStrokeColor(color(0xFFFFFF, 0.07))
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    let innerEdgePath = superellipsePath(in: iconRect.insetBy(dx: 6, dy: 6), exponent: 5.0)
    context.addPath(innerEdgePath)
    context.setLineWidth(3.0)
    context.setStrokeColor(color(0x000000, 0.18))
    context.strokePath()
    context.restoreGState()

    let gColor = color(0xF3F1EA)
    let tColor = color(0x79DDD3)
    let gCenter = CGPoint(x: iconRect.midX - 82, y: iconRect.midY + 6)
    let gRadius: CGFloat = 147
    let gLine: CGFloat = 84

    let gArc = CGMutablePath()
    gArc.addArc(
        center: gCenter,
        radius: gRadius,
        startAngle: CGFloat(38.0 * .pi / 180.0),
        endAngle: CGFloat(322.0 * .pi / 180.0),
        clockwise: false
    )

    let gBar = CGMutablePath()
    gBar.move(to: CGPoint(x: gCenter.x + 6, y: gCenter.y - 26))
    gBar.addLine(to: CGPoint(x: gCenter.x + 118, y: gCenter.y - 26))

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    context.addPath(gArc)
    context.setStrokeColor(gColor)
    context.setLineWidth(gLine)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.addPath(gBar)
    context.setStrokeColor(gColor)
    context.setLineWidth(gLine * 0.68)
    context.setLineCap(.round)
    context.strokePath()
    context.restoreGState()

    let topBar = CGRect(x: iconRect.midX + 8, y: iconRect.midY + 113, width: 226, height: 78)
    let stem = CGRect(x: iconRect.midX + 81, y: iconRect.midY - 168, width: 78, height: 360)
    let topBarPath = roundedRectPath(topBar, radius: 28)
    let stemPath = roundedRectPath(stem, radius: 28)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.26))
    context.addPath(topBarPath)
    context.setFillColor(tColor)
    context.fillPath()
    context.addPath(stemPath)
    context.setFillColor(tColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    let tClip = CGMutablePath()
    tClip.addPath(topBarPath)
    tClip.addPath(stemPath)
    context.addPath(tClip)
    context.clip()
    drawGradient(
        in: context,
        colors: [color(0xB6FFF8, 0.18), color(0xFFFFFF, 0.0)],
        locations: [0.0, 1.0],
        start: CGPoint(x: topBar.midX, y: topBar.maxY),
        end: CGPoint(x: stem.midX, y: stem.minY)
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(topBarPath)
    context.addPath(stemPath)
    context.setLineWidth(2.0)
    context.setStrokeColor(color(0xDFFFFB, 0.24))
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else {
        throw GeneratorError.imageCreationFailed
    }
    return image
}

private func writePNG(_ image: CGImage, pixelSize: Int, to outputURL: URL) throws {
    let renderedImage: CGImage
    if pixelSize == image.width, pixelSize == image.height {
        renderedImage = image
    } else {
        guard
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw GeneratorError.imageCreationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let scaledImage = context.makeImage() else {
            throw GeneratorError.imageCreationFailed
        }
        renderedImage = scaledImage
    }

    let representation = NSBitmapImageRep(cgImage: renderedImage)
    representation.size = CGSize(width: pixelSize, height: pixelSize)
    guard let pngData = representation.representation(using: .png, properties: [:]) else {
        throw GeneratorError.pngEncodingFailed
    }
    try pngData.write(to: outputURL, options: .atomic)
}

private func writeContents(to outputURL: URL) throws {
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
        "info": [
            "author": "xcode",
            "version": 1,
        ],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputURL, options: .atomic)
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

do {
    let outputURL = try outputURL(from: Array(CommandLine.arguments.dropFirst()))
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let masterImage = try makeMasterImage()
    for image in iconImages {
        try writePNG(
            masterImage, pixelSize: image.pixelSize, to: outputURL.appending(path: image.filename))
    }
    try writeContents(to: outputURL.appending(path: "Contents.json"))
    print("Wrote \(iconImages.count) PNGs to \(outputURL.path)")
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
