import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(size)
    NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84), xRadius: s * 0.20,
        yRadius: s * 0.20
    ).fill()
    NSColor(calibratedRed: 0.47, green: 0.84, blue: 0.68, alpha: 1).setFill()
    for (x, height) in [(0.27, 0.22), (0.44, 0.36), (0.61, 0.5)] {
        NSBezierPath(
            roundedRect: NSRect(x: s * x, y: s * 0.25, width: s * 0.12, height: s * height),
            xRadius: s * 0.04, yRadius: s * 0.04
        ).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(
        to: folder.appendingPathComponent(name + ".png"))
}
