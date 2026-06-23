#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

func renderIcon(pixels: Int) -> Data {
    let s = CGFloat(pixels)

    guard let ctx = CGContext(
        data: nil,
        width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
    ) else { fatalError("CGContext failed") }

    // Background — dark purple-ish
    let r = s * 0.22
    ctx.setFillColor(CGColor(red: 0.11, green: 0.09, blue: 0.18, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                       cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()

    // Five waveform bars — Claude purple, taller bars slightly brighter
    let barHeights: [CGFloat] = [0.22, 0.42, 0.62, 0.42, 0.22]
    let barW = s * 0.10
    let gap  = s * 0.045
    let totalW = CGFloat(barHeights.count) * barW + CGFloat(barHeights.count - 1) * gap
    var x = (s - totalW) / 2
    let cy = s / 2

    for frac in barHeights {
        let t = frac / 0.62          // normalise to [0..1] by max height
        let brightness = 0.70 + 0.30 * t
        ctx.setFillColor(CGColor(
            red:   0.49 * brightness,
            green: 0.24 * brightness,
            blue:  0.93 * brightness,
            alpha: 1
        ))
        let bh = frac * s * 0.85
        let br = barW / 2
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: x, y: cy - bh / 2, width: barW, height: bh),
            cornerWidth: br, cornerHeight: br, transform: nil
        ))
        ctx.fillPath()
        x += barW + gap
    }

    guard let cgImage = ctx.makeImage() else { fatalError("makeImage failed") }

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("CGImageDestination failed") }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Finalize failed") }
    return data as Data
}

let iconset = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let specs: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for spec in specs {
    let pixels = spec.size * spec.scale
    let data = renderIcon(pixels: pixels)
    let name = spec.scale == 1
        ? "icon_\(spec.size)x\(spec.size).png"
        : "icon_\(spec.size)x\(spec.size)@2x.png"
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    print("  \(name)")
}
print("Iconset ready.")
