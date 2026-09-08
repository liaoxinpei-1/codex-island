import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let d = CGFloat(pixels)
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: d * 0.05, y: d * 0.05, width: d * 0.9, height: d * 0.9), xRadius: d * 0.22, yRadius: d * 0.22).fill()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: d * 0.12, y: d * 0.31, width: d * 0.76, height: d * 0.38), xRadius: d * 0.19, yRadius: d * 0.19).fill()
        NSColor(calibratedRed: 0.63, green: 0.91, blue: 0.76, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: d * 0.25, y: d * 0.435, width: d * 0.13, height: d * 0.13)).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: d * 0.48, y: d * 0.46, width: d * 0.25, height: d * 0.08), xRadius: d * 0.04, yRadius: d * 0.04).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
