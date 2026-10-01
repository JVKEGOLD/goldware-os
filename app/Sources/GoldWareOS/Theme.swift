import AppKit
import CoreText

/// The GoldWare dashboard's design tokens (outputs/system-status-template.html :root),
/// so the indicator reads as part of the same product.
enum Theme {
    static let bg = hex(0x0C0B09)
    static let surface = hex(0x14120F)
    static let surface2 = hex(0x1B1914)
    static let border = hex(0x29251E)
    static let borderLight = hex(0x3D372C)
    static let text = hex(0xF2EEE4)
    static let textDim = hex(0xB5AD9D)
    static let textMuted = hex(0x857D6F)
    static let gold = hex(0xD2AA5F)
    static let goldHi = hex(0xF9D976)
    static let goldLine = NSColor(red: 210 / 255, green: 170 / 255, blue: 95 / 255, alpha: 0.34)
    static let goldSoft = NSColor(red: 210 / 255, green: 170 / 255, blue: 95 / 255, alpha: 0.09)
    static let green = hex(0x9FD07F)
    static let red = hex(0xF0806B)

    static func hex(_ v: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    /// The same gold gradient as the dashboard's --gold-grad.
    static let goldGradient = NSGradient(colors: [gold, goldHi, gold], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!

    // MARK: Fonts (bundled, SIL Open Font License; see Resources/Fonts/*-OFL.txt)

    private static var registered = false

    static func registerFonts() {
        guard !registered else { return }
        registered = true
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Fonts")) }
        if let root = VaultContext.resolveRoot() { dirs.append(root.appendingPathComponent("app/Resources/Fonts")) }
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let fonts = files.filter { $0.pathExtension == "ttf" }
            if fonts.isEmpty { continue }
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
            return
        }
    }

    private static func font(family: String, face: String, size: CGFloat, fallback: NSFont) -> NSFont {
        registerFonts()
        let d = NSFontDescriptor(fontAttributes: [.family: family, .face: face])
        if let f = NSFont(descriptor: d, size: size), f.familyName == family { return f }
        return fallback
    }

    /// Instrument Serif, the dashboard's display face.
    static func display(_ size: CGFloat, italic: Bool = false) -> NSFont {
        let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
        return font(family: "Instrument Serif", face: italic ? "Italic" : "Regular", size: size, fallback: serif ?? .systemFont(ofSize: size))
    }

    /// DM Sans, the dashboard's UI face. Faces: Regular, Medium, SemiBold, Bold.
    static func sans(_ size: CGFloat, _ face: String = "Regular") -> NSFont {
        let weight: NSFont.Weight = ["Medium": .medium, "SemiBold": .semibold, "Bold": .bold][face] ?? .regular
        return font(family: "DM Sans", face: face, size: size, fallback: .systemFont(ofSize: size, weight: weight))
    }

    /// JetBrains Mono for keys and model names.
    static func mono(_ size: CGFloat, _ face: String = "Medium") -> NSFont {
        font(family: "JetBrains Mono", face: face, size: size, fallback: .monospacedSystemFont(ofSize: size, weight: .medium))
    }

    // MARK: Drawing helpers

    @discardableResult
    static func draw(_ string: String, at p: NSPoint, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
        (string as NSString).draw(at: p, withAttributes: attrs)
        return (string as NSString).size(withAttributes: attrs)
    }

    static func size(_ string: String, font: NSFont, kern: CGFloat = 0) -> NSSize {
        (string as NSString).size(withAttributes: [.font: font, .kern: kern])
    }

    /// A key cap like the dashboard's <kbd>: mono text, hairline border, thicker bottom edge.
    @discardableResult
    static func drawKey(_ label: String, at p: NSPoint, height: CGFloat = 22, gold: Bool = false) -> CGFloat {
        // Modifier glyphs read better in the system face than in the mono.
        let f = label.count == 1 && "⌥⌘⇧⌃".contains(label) ? NSFont.systemFont(ofSize: 12.5, weight: .medium) : mono(11)
        let w = max(height, size(label, font: f).width + 14)
        let r = NSRect(x: p.x, y: p.y, width: w, height: height)
        let body = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (gold ? goldSoft : surface2).setFill()
        body.fill()
        (gold ? goldLine : borderLight).setStroke()
        body.lineWidth = 1
        body.stroke()
        // the key's lower lip
        let lip = NSBezierPath()
        lip.move(to: NSPoint(x: r.minX + 5, y: r.maxY - 1))
        lip.line(to: NSPoint(x: r.maxX - 5, y: r.maxY - 1))
        lip.lineWidth = 1.5
        (gold ? goldLine : borderLight).setStroke()
        lip.stroke()
        let ts = size(label, font: f)
        draw(label, at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2 - 0.5), font: f, color: gold ? goldHi : text)
        return w
    }

    /// Section label: a small gold diamond and letterspaced caps, as in the dashboard's .card-title.
    static func drawSectionTitle(_ title: String, at p: NSPoint) {
        let d = NSBezierPath()
        let c = NSPoint(x: p.x + 3, y: p.y + 7)
        d.move(to: NSPoint(x: c.x, y: c.y - 3))
        d.line(to: NSPoint(x: c.x + 3, y: c.y))
        d.line(to: NSPoint(x: c.x, y: c.y + 3))
        d.line(to: NSPoint(x: c.x - 3, y: c.y))
        d.close()
        gold.setFill()
        d.fill()
        draw(title.uppercased(), at: NSPoint(x: p.x + 14, y: p.y), font: sans(10, "Medium"), color: textDim, kern: 2)
    }
}
