import AppKit
import Foundation

// Render the original pad-grid identity once, then derive every icon size from
// the same pixels. Explicit bitmap contexts avoid screen-dependent lockFocus
// representations corrupting the smallest ICNS entries.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func context(size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let master = context(size: 1024)
master.setFillColor(CGColor(srgbRed: 0.035, green: 0.035, blue: 0.035, alpha: 1))
master.addPath(CGPath(roundedRect: CGRect(x: 32, y: 32, width: 960, height: 960),
                      cornerWidth: 180, cornerHeight: 180, transform: nil))
master.fillPath()
for row in 0..<4 {
    for column in 0..<4 {
        let shade = 0.17 + Double(row) * 0.014
        let active = row == 2 && column == 1
        master.setFillColor(active
            ? CGColor(srgbRed: 0.86, green: 0.94, blue: 0.18, alpha: 1)
            : CGColor(srgbRed: shade, green: shade, blue: shade, alpha: 1))
        master.addPath(CGPath(roundedRect: CGRect(x: 164 + column * 180,
                                                 y: 164 + row * 180,
                                                 width: 154, height: 154),
                              cornerWidth: 12, cornerHeight: 12, transform: nil))
        master.fillPath()
    }
}
let artwork = master.makeImage()!
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let resized = context(size: pixels)
        resized.interpolationQuality = .high
        resized.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let bitmap = NSBitmapImageRep(cgImage: resized.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
