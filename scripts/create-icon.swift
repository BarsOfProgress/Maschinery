import AppKit
import Foundation
// Original pad-grid identity. No NI logos or artwork.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(white: 0.035, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 180, yRadius: 180).fill()
        for row in 0..<4 { for column in 0..<4 {
            let x = 164 + column * 180, y = 164 + row * 180
            let active = row == 2 && column == 1
            (active ? NSColor(red: 0.86, green: 0.94, blue: 0.18, alpha: 1) : NSColor(white: 0.17 + Double(row) * 0.014, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 154, height: 154), xRadius: 12, yRadius: 12).fill()
        } }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
