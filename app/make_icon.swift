// Builds Resources/AppIcon.icns from the GoldWare logo.
// Run from the app folder:  swift make_icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
// The dashboard's warm near-black squircle with a gold hairline, and the GW mark centred inside.
import AppKit

// The logo source may have a white background: flood-fill white from the edges, then crop to the mark.
let sourceURL = URL(fileURLWithPath: "Resources/goldware-logo.png")
guard let source = NSBitmapImageRep(data: try! Data(contentsOf: sourceURL)) else { fatalError("missing \(sourceURL.path)") }
let mascot: NSImage = {
    let W = source.pixelsWide, H = source.pixelsHigh
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    source.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.restoreGraphicsState()
    let px = rep.bitmapData!
    func light(_ i: Int) -> Bool { px[i * 4] > 225 && px[i * 4 + 1] > 225 && px[i * 4 + 2] > 225 }
    var seen = [Bool](repeating: false, count: W * H)
    var stack: [Int] = []
    for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
    for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
    while let i = stack.popLast() {
        if seen[i] || !light(i) { continue }
        seen[i] = true
        px[i * 4 + 3] = 0; px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0
        let x = i % W, y = i / W
        if x > 0 { stack.append(i - 1) }
        if x < W - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - W) }
        if y < H - 1 { stack.append(i + W) }
    }
    var minX = W, minY = H, maxX = 0, maxY = 0
    for y in 0..<H { for x in 0..<W where px[(y * W + x) * 4 + 3] > 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let cg = rep.cgImage!.cropping(to: crop)!
    return NSImage(cgImage: cg, size: NSSize(width: crop.width, height: crop.height))
}()
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = CGFloat(px) / 1024

    // macOS icon grid: an 824pt squircle centred on the 1024 canvas.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)
    NSGradient(colors: [color(0x221F19), color(0x0C0B09)])!.draw(in: squircle, angle: -90)

    // A soft gold glow behind the logo, like the dashboard's ambient light.
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [color(0xD2AA5F, 0.28), color(0xD2AA5F, 0)])!
        .draw(fromCenter: NSPoint(x: 512 * s, y: 470 * s), radius: 0, toCenter: NSPoint(x: 512 * s, y: 470 * s), radius: 430 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gold hairline, brighter across the top like --gold-grad.
    squircle.lineWidth = max(1, 6 * s)
    let stroke = NSGradient(colors: [color(0xD2AA5F, 0.55), color(0xF9D976, 0.9), color(0xD2AA5F, 0.55)])!
    NSGraphicsContext.current?.saveGraphicsState()
    let ring = squircle.copy() as! NSBezierPath
    ring.lineWidth = max(1, 6 * s)
    let outline = NSBezierPath()
    outline.append(ring)
    if let cg = ctx.cgContext as CGContext? {
        cg.addPath(ring.cgPath)
        cg.setLineWidth(ring.lineWidth)
        cg.replacePathWithStrokedPath()
        cg.clip()
        stroke.draw(in: tile.insetBy(dx: -10, dy: -10), angle: -90)
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // The logo, cropped to its outline, fills most of the tile.
    let artW = mascot.size.width, artH = mascot.size.height
    let fit = min(560 * s / artW, 560 * s / artH)   // fit inside the tile with a margin
    let w = artW * fit, h = artH * fit
    let rect = NSRect(x: ((CGFloat(px) - w) / 2).rounded(), y: ((CGFloat(px) - h) / 2).rounded(), width: w, height: h)
    // A soft gold glow lifts the mark off the dark tile.
    let shadow = NSShadow()
    shadow.shadowColor = color(0xF9D976, 0.25)
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    ctx.imageInterpolation = .high
    mascot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))
print("wrote \(iconset.path)")
