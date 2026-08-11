#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Desk / drive bay background
    let colors = [
        CGColor(srgbRed: 0.12, green: 0.14, blue: 0.22, alpha: 1),
        CGColor(srgbRed: 0.18, green: 0.22, blue: 0.34, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.09, blue: 0.14, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.45, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    let cx = rect.midX
    let cy = rect.midY
    let floppySize = rect.width * 0.72
    let fx = cx - floppySize / 2
    let fy = cy - floppySize / 2
    let floppyRect = CGRect(x: fx, y: fy, width: floppySize, height: floppySize)

    // 3.5" shell
    let shellPath = CGPath(
        roundedRect: floppyRect,
        cornerWidth: floppySize * 0.08,
        cornerHeight: floppySize * 0.08,
        transform: nil
    )
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.18, blue: 0.26, alpha: 1))
    ctx.addPath(shellPath)
    ctx.fillPath()

    // Shell highlight
    ctx.saveGState()
    ctx.addPath(shellPath)
    ctx.clip()
    let shellColors = [
        CGColor(srgbRed: 0.28, green: 0.32, blue: 0.42, alpha: 1),
        CGColor(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 1),
    ] as CFArray
    if let sg = CGGradient(colorsSpace: colorSpace, colors: shellColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            sg,
            start: CGPoint(x: floppyRect.minX, y: floppyRect.maxY),
            end: CGPoint(x: floppyRect.maxX, y: floppyRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Metal shutter
    let shutterW = floppySize * 0.42
    let shutterH = floppySize * 0.20
    let shutterRect = CGRect(
        x: cx - shutterW / 2,
        y: floppyRect.maxY - floppySize * 0.12 - shutterH,
        width: shutterW,
        height: shutterH
    )
    let metalColors = [
        CGColor(srgbRed: 0.75, green: 0.76, blue: 0.78, alpha: 1),
        CGColor(srgbRed: 0.48, green: 0.50, blue: 0.52, alpha: 1),
        CGColor(srgbRed: 0.65, green: 0.66, blue: 0.68, alpha: 1),
    ] as CFArray
    if let mg = CGGradient(colorsSpace: colorSpace, colors: metalColors, locations: [0, 0.5, 1]) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: shutterRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(
            mg,
            start: CGPoint(x: shutterRect.minX, y: shutterRect.midY),
            end: CGPoint(x: shutterRect.maxX, y: shutterRect.midY),
            options: []
        )
        ctx.restoreGState()
    }

    // Hub
    let hubR = floppySize * 0.11
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.36, blue: 0.40, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: cx - hubR, y: cy - hubR * 0.3, width: hubR * 2, height: hubR * 2))
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    let holeR = hubR * 0.35
    ctx.fillEllipse(in: CGRect(x: cx - holeR, y: cy - hubR * 0.3 + hubR - holeR, width: holeR * 2, height: holeR * 2))

    // Label
    let labelH = floppySize * 0.26
    let labelRect = CGRect(
        x: floppyRect.minX + floppySize * 0.1,
        y: floppyRect.minY + floppySize * 0.08,
        width: floppySize * 0.8,
        height: labelH
    )
    let labelColors = [
        CGColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1),
        CGColor(srgbRed: 0.88, green: 0.85, blue: 0.76, alpha: 1),
    ] as CFArray
    if let lg = CGGradient(colorsSpace: colorSpace, colors: labelColors, locations: [0, 1]) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: labelRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(
            lg,
            start: CGPoint(x: labelRect.midX, y: labelRect.maxY),
            end: CGPoint(x: labelRect.midX, y: labelRect.minY),
            options: []
        )
        ctx.restoreGState()
    }

    // Label lines (suggest writing)
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.55, blue: 0.75, alpha: 0.55))
    ctx.setLineWidth(max(1, s * 0.008))
    for i in 0..<3 {
        let y = labelRect.maxY - labelH * 0.28 - CGFloat(i) * labelH * 0.22
        ctx.move(to: CGPoint(x: labelRect.minX + labelRect.width * 0.12, y: y))
        ctx.addLine(to: CGPoint(x: labelRect.maxX - labelRect.width * 0.12, y: y))
        ctx.strokePath()
    }

    // Accent stripe
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.52, blue: 0.88, alpha: 0.9))
    ctx.fill(CGRect(
        x: floppyRect.minX,
        y: floppyRect.midY - floppySize * 0.02,
        width: floppySize * 0.04,
        height: floppySize * 0.12
    ))

    ctx.restoreGState()

    // Outer border
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, s * 0.01))
    ctx.addPath(path)
    ctx.strokePath()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG write failed"])
    }
}

func buildIcns(pngURLs: [(Int, URL)], outURL: URL) throws {
    // iconutil expects an .iconset folder
    let iconset = outURL.deletingPathExtension().appendingPathExtension("iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    let names: [Int: String] = [
        16: "icon_16x16.png",
        32: "diana.k@example.org",
        64: "ivan.p@example.net", // also 32@2
        128: "icon_128x128.png",
        256: "wendy.h@example.net",
        512: "icon_512x512.png",
        1024: "walt.e@example.net",
    ]

    // Map our renders into iconset filenames
    let map: [(file: String, size: Int)] = [
        ("icon_16x16.png", 16),
        ("diana.k@example.org", 32),
        ("icon_32x32.png", 32),
        ("ivan.p@example.net", 64),
        ("icon_128x128.png", 128),
        ("wendy.h@example.net", 256),
        ("icon_256x256.png", 256),
        ("lisa@example.org", 512),
        ("icon_512x512.png", 512),
        ("walt.e@example.net", 1024),
    ]

    let bySize = Dictionary(uniqueKeysWithValues: pngURLs)
    for item in map {
        guard let src = bySize[item.size] else { continue }
        let dest = iconset.appendingPathComponent(item.file)
        try FileManager.default.copyItem(at: src, to: dest)
    }
    _ = names

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset.path, "-o", outURL.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw NSError(domain: "GenerateAppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
    }
    try? FileManager.default.removeItem(at: iconset)
}

// --- main ---
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
var pngs: [(Int, URL)] = []
for size in sizes {
    guard let img = renderIcon(size: size) else {
        fputs("Failed to render \(size)\n", stderr)
        exit(1)
    }
    let url = assets.appendingPathComponent("AppIcon-\(size).png")
    try writePNG(img, to: url)
    pngs.append((size, url))
    if size == 1024 {
        try writePNG(img, to: assets.appendingPathComponent("AppIcon-1024.png"))
    }
}

let icns = assets.appendingPathComponent("AppIcon.icns")
try buildIcns(pngURLs: pngs, outURL: icns)
print("Wrote \(icns.path)")
