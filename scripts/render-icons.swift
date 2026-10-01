import AppKit

@main
@MainActor
enum RenderIcons {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let iconset = destination.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let image = BrandArtwork.renderIcon(size: size * scale)
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                if size == 512 && scale == 2 { try data.write(to: destination.appendingPathComponent("AppIcon.png")) }
            }
        }
        var bounds = CGRect(x: 0, y: 0, width: 24, height: 28)
        let url = destination.appendingPathComponent("MenuBar.pdf") as CFURL
        let context = CGContext(url, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        BrandArtwork.drawGlyph(context, color: .black)
        context.endPDFPage(); context.closePDF()
    }
}
