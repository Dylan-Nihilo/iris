import Foundation
import AppKit
import CoreImage

/// The picture behind the recording. It is drawn once per render and reused for every frame.
public enum Backdrop {
    struct Blob {
        var color: String
        var x: Double, y: Double     // centre, 0...1, y from the top
        var radius: Double           // share of the canvas diagonal
        var alpha: Double
    }

    struct Preset {
        var from: String, to: String
        var angle: Double            // degrees, direction the gradient runs in
        var blobs: [Blob]
    }

    static let presets: [String: Preset] = [
        "aurora": Preset(from: "#231A6B", to: "#7A2A9B", angle: 20, blobs: [
            Blob(color: "#FF6FA5", x: 0.92, y: 0.12, radius: 0.55, alpha: 0.85),
            Blob(color: "#FFB36B", x: 1.0, y: 0.95, radius: 0.45, alpha: 0.75),
            Blob(color: "#3FC8FF", x: 0.05, y: 0.95, radius: 0.5, alpha: 0.7),
            Blob(color: "#5B3FE0", x: 0.1, y: 0.05, radius: 0.5, alpha: 0.8),
        ]),
        "ocean": Preset(from: "#0A1F52", to: "#0D6E94", angle: 35, blobs: [
            Blob(color: "#3BE0D0", x: 0.95, y: 0.9, radius: 0.5, alpha: 0.7),
            Blob(color: "#3A1C8C", x: 0.05, y: 0.1, radius: 0.5, alpha: 0.75),
            Blob(color: "#2E9BFF", x: 0.85, y: 0.05, radius: 0.45, alpha: 0.6),
        ]),
        "sunset": Preset(from: "#FF8A5B", to: "#A82C7C", angle: 60, blobs: [
            Blob(color: "#FFD27A", x: 0.08, y: 0.08, radius: 0.5, alpha: 0.8),
            Blob(color: "#5A1E96", x: 0.95, y: 0.95, radius: 0.55, alpha: 0.75),
            Blob(color: "#FF5F7E", x: 0.9, y: 0.1, radius: 0.4, alpha: 0.6),
        ]),
        "meadow": Preset(from: "#0E5C4C", to: "#6FBF9C", angle: 30, blobs: [
            Blob(color: "#F4E48A", x: 0.95, y: 0.08, radius: 0.45, alpha: 0.65),
            Blob(color: "#12A5A0", x: 0.05, y: 0.9, radius: 0.5, alpha: 0.7),
        ]),
        "graphite": Preset(from: "#17181C", to: "#3B3E48", angle: 40, blobs: [
            Blob(color: "#5C6270", x: 0.92, y: 0.08, radius: 0.5, alpha: 0.55),
            Blob(color: "#0C0D10", x: 0.05, y: 0.95, radius: 0.5, alpha: 0.7),
        ]),
        "paper": Preset(from: "#EFECE7", to: "#D8D3CB", angle: 50, blobs: [
            Blob(color: "#FFFFFF", x: 0.1, y: 0.05, radius: 0.5, alpha: 0.8),
            Blob(color: "#C6BFB4", x: 0.95, y: 0.95, radius: 0.5, alpha: 0.6),
        ]),
        "midnight": Preset(from: "#06070F", to: "#1B1C40", angle: 30, blobs: [
            Blob(color: "#43309A", x: 0.92, y: 0.1, radius: 0.5, alpha: 0.7),
            Blob(color: "#0F5687", x: 0.05, y: 0.95, radius: 0.5, alpha: 0.6),
        ]),
        "peach": Preset(from: "#FFD8BE", to: "#F9A9B8", angle: 45, blobs: [
            Blob(color: "#FFF2DC", x: 0.08, y: 0.08, radius: 0.5, alpha: 0.85),
            Blob(color: "#C4A2EE", x: 0.95, y: 0.92, radius: 0.5, alpha: 0.7),
        ]),
    ]

    public static var names: [String] { presets.keys.sorted() }

    /// `spec` is a preset name, `#hex`, `#hex,#hex` for a gradient, `wallpaper`, or an image file.
    public static func image(spec: String, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IrisError("cannot create a \(width)x\(height) canvas")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let preset = presets[spec.lowercased()] {
            draw(preset, in: context, bounds: bounds)
        } else if spec.hasPrefix("#") {
            let parts = spec.split(separator: ",").map(String.init)
            let colors = try parts.map { text -> CGColor in
                guard let color = color(text) else { throw IrisError("\"\(text)\" is not a colour like #1a2b3c") }
                return color
            }
            if colors.count == 1 {
                context.setFillColor(colors[0])
                context.fill(bounds)
            } else {
                linear(colors, angle: 45, in: context, bounds: bounds)
            }
        } else {
            let url: URL
            var blur = 0.0
            if spec.lowercased() == "wallpaper" {
                guard let screen = NSScreen.main, let found = NSWorkspace.shared.desktopImageURL(for: screen) else {
                    throw IrisError("cannot find the desktop wallpaper")
                }
                url = found
                blur = Double(width) * 0.012
            } else {
                url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw IrisError("\"\(spec)\" is not a backdrop: use one of \(names.joined(separator: ", ")), a #hex colour, wallpaper, or an image file")
            }
            let scale = max(bounds.width / CGFloat(picture.width), bounds.height / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                             width: size.width, height: size.height))
            if blur > 0, let drawn = context.makeImage() {
                let soft = CIImage(cgImage: drawn).clampedToExtent()
                    .applyingGaussianBlur(sigma: blur).cropped(to: bounds)
                if let result = CIContext().createCGImage(soft, from: bounds) { return result }
            }
        }
        guard let image = context.makeImage() else { throw IrisError("cannot draw the backdrop") }
        return image
    }

    static func draw(_ preset: Preset, in context: CGContext, bounds: CGRect) {
        linear([color(preset.from)!, color(preset.to)!], angle: preset.angle, in: context, bounds: bounds)
        let diagonal = hypot(bounds.width, bounds.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for blob in preset.blobs {
            guard let base = color(blob.color) else { continue }
            // Several stops approximate a smooth falloff; two would leave a visible disc edge.
            let stops: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
            let colors = stops.map { stop -> CGColor in
                let falloff = pow(1 - Double(stop), 2.2)
                return base.copy(alpha: CGFloat(blob.alpha * falloff))!
            }
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { continue }
            let center = CGPoint(x: bounds.width * blob.x, y: bounds.height * (1 - blob.y))
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: diagonal * blob.radius, options: [])
        }
    }

    static func linear(_ colors: [CGColor], angle: Double, in context: CGContext, bounds: CGRect) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        let radians = angle * .pi / 180
        let reach = (abs(cos(radians)) * bounds.width + abs(sin(radians)) * bounds.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Runs from the top left towards the bottom right for angles between 0 and 90.
        let direction = CGPoint(x: cos(radians), y: -sin(radians))
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: center.x - direction.x * reach, y: center.y - direction.y * reach),
                                   end: CGPoint(x: center.x + direction.x * reach, y: center.y + direction.y * reach),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func color(_ hex: String) -> CGColor? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
