import Foundation
import AppKit
import CoreText

/// What is written over the picture while a frame is drawn.
public struct Note {
    public enum Kind { case caption, keys, pace }
    public var kind: Kind
    public var text: String
    /// 0 to 1: how far it has come in, or how far it has yet to go out.
    public var presence: Double
    public init(kind: Kind, text: String, presence: Double) { self.kind = kind; self.text = text; self.presence = presence }
}

/// Draws the plates that carry words: captions, the keys of a shortcut, the pace badge.
/// Every size is in units the compositor chooses for the size of the video.
enum Lettering {
    struct Plate {
        var image: CGImage
        /// Room left around the plate for its shadow, in pixels.
        var margin: Double
        var width: Double { Double(image.width) - 2 * margin }
        var height: Double { Double(image.height) - 2 * margin }
    }

    private static let ink = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97)
    // Nearly opaque: frames are blended in linear light, where a dark veil over a white
    // page comes out far lighter than its alpha suggests.
    private static let slate = CGColor(srgbRed: 0.035, green: 0.035, blue: 0.05, alpha: 0.92)
    private static let edge = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22)

    private static func line(_ text: String, size: Double, weight: NSFont.Weight) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: NSFont.systemFont(ofSize: size, weight: weight) as CTFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: ink,
        ]))
    }

    /// A canvas with a dark rounded plate on it, and the rectangle of that plate.
    private static func plate(width: Double, height: Double, radius: Double, unit: Double) -> (CGContext, CGRect, Double)? {
        let margin = (26 * unit).rounded(.up)
        guard let context = CGContext(data: nil, width: Int((width + 2 * margin).rounded(.up)), height: Int((height + 2 * margin).rounded(.up)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: margin, y: margin, width: width, height: height)
        let r = min(radius, height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -5 * unit), blur: 18 * unit, color: CGColor(gray: 0, alpha: 0.32))
        context.setFillColor(slate)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(edge)
        context.setLineWidth(max(1, 1.2 * unit))
        let inner = rect.insetBy(dx: 0.6 * unit, dy: 0.6 * unit)
        context.addPath(CGPath(roundedRect: inner, cornerWidth: min(r, inner.height / 2), cornerHeight: min(r, inner.height / 2), transform: nil))
        context.strokePath()
        return (context, rect, margin)
    }

    /// A caption: centred words on a plate, wrapped when they are wider than `maxWidth`.
    static func caption(_ text: String, unit: Double, maxWidth: Double) -> Plate? {
        let padX = 28 * unit, padY = 14 * unit
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)], 1)
        }
        let string = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: NSFont.systemFont(ofSize: 34 * unit, weight: .medium) as CTFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: ink,
            kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(), nil, CGSize(width: maxWidth - 2 * padX, height: .greatestFiniteMagnitude), nil)
        let words = CGSize(width: fit.width.rounded(.up) + 2, height: fit.height.rounded(.up))
        guard words.width > 2, let (context, rect, margin) = plate(width: words.width + 2 * padX, height: words.height + 2 * padY,
                                                                   radius: 26 * unit, unit: unit) else { return nil }
        let box = CGRect(x: rect.minX + padX, y: rect.minY + padY, width: words.width, height: words.height)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil), context)
        return context.makeImage().map { Plate(image: $0, margin: margin) }
    }

    /// The keys of a shortcut, side by side.
    static func keys(_ caps: [String], unit: Double) -> Plate? {
        guard !caps.isEmpty else { return nil }
        let side = 62 * unit, gap = 9 * unit, pad = 10 * unit
        let lines = caps.map { line($0, size: ($0.count > 1 ? 27 : 37) * unit, weight: .semibold) }
        let bounds = lines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }
        let widths = bounds.map { max(side, ($0.width + 34 * unit).rounded(.up)) }
        let width = widths.reduce(0, +) + gap * Double(caps.count - 1) + 2 * pad
        guard let (context, rect, margin) = plate(width: width, height: side + 2 * pad, radius: 22 * unit, unit: unit) else { return nil }
        var x = rect.minX + pad
        for index in caps.indices {
            let cap = CGRect(x: x, y: rect.minY + pad, width: widths[index], height: side)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2))
            context.addPath(CGPath(roundedRect: cap, cornerWidth: 13 * unit, cornerHeight: 13 * unit, transform: nil))
            context.fillPath()
            // Each legend sits by its own outline in the middle of its key.
            context.textPosition = CGPoint(x: cap.midX - bounds[index].midX, y: cap.midY - bounds[index].midY)
            CTLineDraw(lines[index], context)
            x += widths[index] + gap
        }
        return context.makeImage().map { Plate(image: $0, margin: margin) }
    }

    /// The badge that says the video is running faster than it was recorded.
    static func pace(_ label: String, unit: Double) -> Plate? {
        let height = 44 * unit, padX = 17 * unit, arrow = 12 * unit, gap = 10 * unit
        let words = line(label, size: 23 * unit, weight: .semibold)
        let bounds = CTLineGetBoundsWithOptions(words, .useGlyphPathBounds)
        let width = 2 * padX + 2 * arrow + gap + bounds.width
        guard let (context, rect, margin) = plate(width: width.rounded(.up), height: height, radius: height / 2, unit: unit) else { return nil }
        context.setFillColor(ink)
        for index in 0..<2 {
            let x = rect.minX + padX + Double(index) * arrow
            context.move(to: CGPoint(x: x, y: rect.midY + arrow * 0.62))
            context.addLine(to: CGPoint(x: x + arrow, y: rect.midY))
            context.addLine(to: CGPoint(x: x, y: rect.midY - arrow * 0.62))
            context.closePath()
        }
        context.fillPath()
        context.textPosition = CGPoint(x: rect.minX + padX + 2 * arrow + gap - bounds.minX, y: rect.midY - bounds.midY)
        CTLineDraw(words, context)
        return context.makeImage().map { Plate(image: $0, margin: margin) }
    }
}
