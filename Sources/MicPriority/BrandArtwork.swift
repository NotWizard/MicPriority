import AppKit

@MainActor
enum BrandArtwork {
    static let repositoryURL = URL(string: "https://github.com/NotWizard/MicPriority")!
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1" }
    static var menuIcon: NSImage {
        let image = Bundle.main.url(forResource: "MenuBar", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(size: NSSize(width: 24, height: 28), flipped: false) { _ in
                if let context = NSGraphicsContext.current?.cgContext { drawGlyph(context, color: .black) }
                return true
            }
        image.size = NSSize(width: 15.5, height: 18)
        image.isTemplate = true
        return image
    }
    static var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(cgImage: renderIcon(size: 256), size: NSSize(width: 256, height: 256))
    }
    static func drawGlyph(_ context: CGContext, color: NSColor) {
        // The P is the microphone head; its counter is the open voice channel.
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 8, y: 25)); head.addLine(to: CGPoint(x: 13, y: 25))
        head.addCurve(to: CGPoint(x: 19, y: 19), control1: CGPoint(x: 17, y: 25), control2: CGPoint(x: 19, y: 23))
        head.addCurve(to: CGPoint(x: 13, y: 13), control1: CGPoint(x: 19, y: 15), control2: CGPoint(x: 17, y: 13))
        head.addLine(to: CGPoint(x: 11, y: 13)); head.addLine(to: CGPoint(x: 11, y: 10))
        head.addLine(to: CGPoint(x: 8, y: 10)); head.closeSubpath()
        head.move(to: CGPoint(x: 11, y: 22)); head.addLine(to: CGPoint(x: 11, y: 16))
        head.addLine(to: CGPoint(x: 13, y: 16))
        head.addCurve(to: CGPoint(x: 16, y: 19), control1: CGPoint(x: 15, y: 16), control2: CGPoint(x: 16, y: 17))
        head.addCurve(to: CGPoint(x: 13, y: 22), control1: CGPoint(x: 16, y: 21), control2: CGPoint(x: 15, y: 22))
        head.closeSubpath()
        context.setFillColor(color.cgColor); context.addPath(head); context.fillPath(using: .evenOdd)
        let stand = CGMutablePath()
        stand.move(to: CGPoint(x: 4, y: 15)); stand.addLine(to: CGPoint(x: 4, y: 13))
        stand.addCurve(to: CGPoint(x: 12, y: 6), control1: CGPoint(x: 4, y: 8), control2: CGPoint(x: 7, y: 6))
        stand.addCurve(to: CGPoint(x: 20, y: 13), control1: CGPoint(x: 17, y: 6), control2: CGPoint(x: 20, y: 8))
        stand.addLine(to: CGPoint(x: 20, y: 15))
        stand.move(to: CGPoint(x: 12, y: 6)); stand.addLine(to: CGPoint(x: 12, y: 3))
        stand.move(to: CGPoint(x: 8, y: 3)); stand.addLine(to: CGPoint(x: 16, y: 3))
        context.setStrokeColor(color.cgColor); context.setLineWidth(2.1); context.setLineCap(.round)
        context.addPath(stand); context.strokePath()
    }
    static func renderIcon(size: Int) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864), cornerWidth: 190, cornerHeight: 190, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.setFillColor(NSColor(srgbRed: 0.13, green: 0.17, blue: 0.15, alpha: 1).cgColor)
        context.addPath(tile); context.fillPath()
        context.restoreGState()
        context.saveGState(); context.addPath(tile); context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            NSColor(srgbRed: 0.20, green: 0.25, blue: 0.22, alpha: 1).cgColor,
            NSColor(srgbRed: 0.10, green: 0.13, blue: 0.12, alpha: 1).cgColor
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 944), end: CGPoint(x: 512, y: 80), options: [])
        context.restoreGState()
        context.saveGState(); context.translateBy(x: 236, y: 190); context.scaleBy(x: 23, y: 23)
        context.setShadow(offset: CGSize(width: 0, height: -0.18), blur: 0.35, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        drawGlyph(context, color: NSColor(srgbRed: 0.73, green: 0.89, blue: 0.79, alpha: 1))
        context.restoreGState()
        return context.makeImage()!
    }
    static var credits: NSAttributedString {
        NSAttributedString(string: "GitHub · 开放源码", attributes: [.link: repositoryURL, .font: NSFont.systemFont(ofSize: 12)])
    }
    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "MicPriority", .applicationVersion: version,
            .applicationIcon: appIcon, .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
