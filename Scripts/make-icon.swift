import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"), (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 190, yRadius: 190)
    NSGradient(colors: [NSColor(red: 0.23, green: 0.61, blue: 1, alpha: 1), NSColor(red: 0.13, green: 0.28, blue: 0.86, alpha: 1)])!.draw(in: background, angle: -45)
    NSColor.white.withAlphaComponent(0.13).setFill()
    NSBezierPath(roundedRect: NSRect(x: 204, y: 288, width: 616, height: 446), xRadius: 28, yRadius: 28).fill()
    let tablet = NSBezierPath(roundedRect: NSRect(x: 172, y: 246, width: 680, height: 530), xRadius: 54, yRadius: 54)
    tablet.lineWidth = 24; NSColor.white.setStroke(); tablet.stroke()
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: 791, y: 494, width: 21, height: 21)).fill()
    let cursor = NSBezierPath()
    cursor.move(to: NSPoint(x: 408, y: 646)); cursor.line(to: NSPoint(x: 408, y: 390))
    cursor.line(to: NSPoint(x: 470, y: 441)); cursor.line(to: NSPoint(x: 531, y: 345))
    cursor.line(to: NSPoint(x: 585, y: 379)); cursor.line(to: NSPoint(x: 528, y: 475))
    cursor.line(to: NSPoint(x: 614, y: 486)); cursor.close()
    NSColor.white.setFill(); cursor.fill()
    let badge = NSBezierPath(ovalIn: NSRect(x: 710, y: 153, width: 140, height: 140))
    NSColor(red: 0.2, green: 0.82, blue: 0.58, alpha: 1).setFill(); badge.fill()
    let check = NSBezierPath(); check.move(to: NSPoint(x: 746, y: 224)); check.line(to: NSPoint(x: 772, y: 198)); check.line(to: NSPoint(x: 820, y: 248))
    check.lineWidth = 13; check.lineCapStyle = .round; check.lineJoinStyle = .round; NSColor.white.setStroke(); check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
