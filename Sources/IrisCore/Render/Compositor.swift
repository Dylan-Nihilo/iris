import Foundation
import AppKit
import CoreImage

public struct RenderStyle {
    /// Width of the finished video in pixels.
    public var width = 1920
    /// Width over height of the finished video; nil follows the recording.
    public var aspect: Double?
    public var background = "aurora"
    /// Space around the recording, as a share of the video's width.
    public var padding = 0.055
    /// Corner radius in points, for recordings that carry no window shape.
    public var radius = 12.0
    /// Strength of the shadow under the recording, 0 to 1.
    public var shadow = 0.6
    public var cursorSize = 1.5
    public var showCursor = true
    public var showClicks = true
    /// Blur of fast camera moves, 0 to 1.
    public var motionBlur = 0.6
    /// Size of captions, shortcut keys and the pace badge; 1 suits a video watched full width.
    public var captionSize = 1.0
    public init() {}
}

public struct Ripple {
    public var point: Point
    /// 0 when the click happens, 1 when its ring has faded.
    public var progress: Double
}

/// Draws one frame of the finished video: backdrop, shadow, the recording under the camera,
/// click rings, the pointer, and what is written over it all.
public final class Compositor {
    public let width: Int
    public let height: Int
    public let context: CIContext

    private let sourceSize: CGSize
    private let base: CGRect               // the recording at full view, in canvas pixels
    private let pointScale: Double         // canvas pixels per recorded point at full view
    private let style: RenderStyle
    private let backdrop: CIImage
    private let mask: CIImage
    private let shadow: CIImage?           // drawn in source pixels, already offset and blurred
    private let ring: CIImage
    private var cursors: [String: (image: CIImage, shape: CursorShape)] = [:]
    private let fallbackCursor: (image: CIImage, shape: CursorShape)?
    private var plates: [String: (image: CIImage, plate: Lettering.Plate)?] = [:]

    /// How much wider and taller the canvas is than the recording at full view.
    public var view: (x: Double, y: Double) { (Double(width) / base.width, Double(height) / base.height) }

    public init(info: SessionInfo, store: SessionStore, style: RenderStyle) throws {
        self.style = style
        let source = CGSize(width: info.pixelWidth, height: info.pixelHeight)
        sourceSize = source
        let even = { (value: Double) -> Int in max(2, Int((value / 2).rounded()) * 2) }
        width = even(Double(style.width))
        let pad = (Double(width) * style.padding).rounded()
        if let aspect = style.aspect {
            height = even(Double(width) / aspect)
        } else {
            height = even((Double(width) - 2 * pad) * source.height / source.width + 2 * pad)
        }
        let fit = min((Double(width) - 2 * pad) / source.width, (Double(height) - 2 * pad) / source.height)
        let size = CGSize(width: source.width * fit, height: source.height * fit)
        base = CGRect(x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2, width: size.width, height: size.height)
        pointScale = fit * info.scale

        context = CIContext(options: [.cacheIntermediates: false])
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        // A whisper of noise keeps the encoder from banding the gradients.
        let plain = CIImage(cgImage: try Backdrop.image(spec: style.background, width: width, height: height))
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.012, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.012, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.012, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.006, y: -0.006, z: -0.006, w: 0),
            ]).cropped(to: canvas)
        let dithered = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: plain])
        backdrop = Self.bake(dithered, in: canvas, context: context) ?? plain

        mask = Self.loadMask(store: store, size: source) ?? Self.roundedMask(size: source, radius: style.radius * info.scale)
        shadow = style.shadow > 0
            ? Self.makeShadow(mask: mask, size: source, strength: style.shadow, scale: info.scale, context: context) : nil
        ring = Self.makeRing()

        if let files = try? FileManager.default.contentsOfDirectory(at: store.cursorsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let shape = try? SessionStore.decoder.decode(CursorShape.self, from: data),
                      let image = CIImage(contentsOf: file.deletingPathExtension().appendingPathExtension("png")) else { continue }
                cursors[shape.id] = (image, shape)
            }
        }
        fallbackCursor = Self.arrowCursor()
    }

    // MARK: Geometry

    /// Scale and offset that place source pixels on the canvas under `camera`.
    private func placement(_ camera: Camera) -> (k: Double, tx: Double, ty: Double) {
        let z = camera.zoom
        let k = base.width / sourceSize.width * z
        let tx = Double(width) / 2 - camera.center.x * base.width * z
        let ty = Double(height) / 2 + (camera.center.y - 1) * base.height * z
        return (k, tx, ty)
    }

    /// Canvas position of a point of the recording (0...1, y from the top).
    private func project(_ p: Point, _ camera: Camera) -> CGPoint {
        let z = camera.zoom
        return CGPoint(x: Double(width) / 2 + (p.x - camera.center.x) * base.width * z,
                       y: Double(height) / 2 + (camera.center.y - p.y) * base.height * z)
    }

    // MARK: Frame

    public func frame(source: CIImage, camera: Camera, previous: Camera?, cursor: CursorState?, ripples: [Ripple],
                      notes: [Note] = []) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let place = placement(camera)

        // The recording, cut to its window shape, resampled once to its size on the canvas.
        let shaped = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        var layer = shaped
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: place.k, kCIInputAspectRatioKey: 1.0])
            .transformed(by: CGAffineTransform(translationX: place.tx, y: place.ty))
        if let shadow {
            let under = shadow.transformed(by: CGAffineTransform(scaleX: place.k, y: place.k)
                .concatenating(CGAffineTransform(translationX: place.tx, y: place.ty)))
            layer = layer.composited(over: under)
        }
        layer = layer.cropped(to: canvas.insetBy(dx: -64, dy: -64))
        if let previous, style.motionBlur > 0 {
            layer = blurred(layer, from: placement(previous), to: place)
        }

        var image = layer.composited(over: backdrop)
        let grow = pow(camera.zoom, 0.8)

        if style.showClicks {
            for ripple in ripples {
                let u = min(max(ripple.progress, 0), 1)
                let eased = 1 - pow(1 - u, 3)
                let radius = (7 + 19 * eased) * pointScale * grow
                let alpha = pow(1 - u, 1.6) * 0.9
                let at = project(ripple.point, camera)
                let scale = radius * 2 / ring.extent.width
                let sprite = ring
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: at.x - radius, y: at.y - radius))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                image = sprite.composited(over: image)
            }
        }

        if style.showCursor, let cursor, let art = cursor.shape.flatMap({ cursors[$0] }) ?? fallbackCursor {
            // The pointer fades out as it leaves the recorded area.
            let p = cursor.position
            let outside = max(max(-p.x, p.x - 1), max(-p.y, p.y - 1), 0)
            let alpha = 1 - min(outside / 0.012, 1)
            if alpha > 0 {
                let at = project(p, camera)
                let scale = art.shape.height * pointScale * style.cursorSize * grow * cursor.press / art.image.extent.height
                let hotX = art.shape.hotX / art.shape.width * art.image.extent.width * scale
                let hotY = (1 - art.shape.hotY / art.shape.height) * art.image.extent.height * scale
                var sprite = art.image
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                    .transformed(by: CGAffineTransform(translationX: at.x - hotX, y: at.y - hotY))
                if alpha < 1 {
                    sprite = sprite.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                }
                image = sprite.composited(over: image)
            }
        }
        return lettered(image, notes: notes).cropped(to: canvas)
    }

    // MARK: Lettering

    private func plate(_ note: Note, unit: Double) -> (image: CIImage, plate: Lettering.Plate)? {
        let name = "\(note.kind)/\(note.text)"
        if let known = plates[name] { return known }
        let made: Lettering.Plate?
        switch note.kind {
        case .caption: made = Lettering.caption(note.text, unit: unit, maxWidth: Double(width) * 0.84)
        case .keys: made = Lettering.keys(Overlays.keycaps(note.text), unit: unit)
        case .pace: made = Lettering.pace(note.text, unit: unit)
        }
        let entry = made.map { (image: CIImage(cgImage: $0.image), plate: $0) }
        plates[name] = entry
        return entry
    }

    /// Captions sit at the bottom in the middle, inside the band of backdrop when there is
    /// one; a shortcut sits in the same place, or on top of the caption that is there; the
    /// pace badge keeps to the top right corner.
    private func lettered(_ image: CIImage, notes: [Note]) -> CIImage {
        guard !notes.isEmpty else { return image }
        var image = image
        // A small video is looked at small: its lettering shrinks less than the picture does.
        let unit = pow(Double(width) / 1920, 0.7) * style.captionSize
        let band = (Double(height) - base.height) / 2
        func draw(_ note: Note, _ origin: (Lettering.Plate) -> CGPoint, rise: Double) {
            guard note.presence > 0, let (art, plate) = plate(note, unit: unit) else { return }
            let u = min(note.presence, 1)
            let eased = u * u * (3 - 2 * u)
            let at = origin(plate)
            var sprite = art.transformed(by: CGAffineTransform(translationX: (at.x - plate.margin).rounded(),
                                                               y: (at.y - plate.margin - rise * (1 - eased)).rounded()))
            if eased < 1 {
                sprite = sprite.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: eased)])
            }
            image = sprite.composited(over: image)
        }
        func bottom(_ plate: Lettering.Plate) -> Double { min(max((band - plate.height) / 2, 20 * unit), 60 * unit) }

        // A shortcut moves up to clear the caption under it, as far as the caption is there.
        var caption: (top: Double, share: Double)?
        for note in notes where note.kind == .caption {
            draw(note, { CGPoint(x: (Double(self.width) - $0.width) / 2, y: bottom($0)) }, rise: 12 * unit)
            if let (_, plate) = plate(note, unit: unit), note.presence > (caption?.share ?? 0) {
                caption = (bottom(plate) + plate.height + 10 * unit, min(note.presence, 1))
            }
        }
        for note in notes where note.kind == .keys {
            draw(note, { plate in
                var y = bottom(plate)
                if let caption { y += max(caption.top - y, 0) * caption.share * caption.share * (3 - 2 * caption.share) }
                return CGPoint(x: (Double(self.width) - plate.width) / 2, y: y)
            }, rise: 12 * unit)
        }
        for note in notes where note.kind == .pace {
            draw(note, { CGPoint(x: Double(self.width) - $0.width - 30 * unit, y: Double(self.height) - $0.height - 30 * unit) }, rise: 0)
        }
        return image
    }

    /// Blurs the layer along its own motion since the previous frame by averaging copies
    /// placed along the way; a camera at rest costs nothing.
    private func blurred(_ layer: CIImage, from a: (k: Double, tx: Double, ty: Double),
                         to b: (k: Double, tx: Double, ty: Double)) -> CIImage {
        // Where each canvas point of this frame sat one frame earlier: q' = s * q + d.
        let s = a.k / b.k
        let dx = a.tx - s * b.tx, dy = a.ty - s * b.ty
        let reach = abs(s - 1) * hypot(Double(width), Double(height)) / 2 + hypot(dx, dy)
        let length = reach * style.motionBlur * 0.6
        guard length > 1.2 else { return layer }
        let samples = min(max(Int(length / 1.5), 3), 12)
        var result = layer
        for index in 1..<samples {
            let u = Double(index) / Double(samples - 1) * style.motionBlur * 0.6
            let si = 1 + (s - 1) * u
            let copy = layer.transformed(by: CGAffineTransform(a: si, b: 0, c: 0, d: si, tx: dx * u, ty: dy * u))
            result = copy.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: result, kCIInputAmountKey: 1.0 / Double(index + 1),
            ])
        }
        return result
    }

    // MARK: Prepared images

    static func bake(_ image: CIImage, in rect: CGRect, context: CIContext) -> CIImage? {
        context.createCGImage(image, from: rect).map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)) }
    }

    static func loadMask(store: SessionStore, size: CGSize) -> CIImage? {
        guard let image = CIImage(contentsOf: store.maskURL), image.extent.width > 0 else { return nil }
        let sx = size.width / image.extent.width, sy = size.height / image.extent.height
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    static func roundedMask(size: CGSize, radius: Double) -> CIImage {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(gray: 1, alpha: 1)
        let r = min(radius, min(size.width, size.height) / 2)
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else {
            return CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        }
        return CIImage(cgImage: image)
    }

    /// A soft shadow in the shape of the recording, computed small because it is all blur:
    /// a wide one that lifts the window off the backdrop, and a tight one that grounds its edge.
    static func makeShadow(mask: CIImage, size: CGSize, strength: Double, scale: Double, context: CIContext) -> CIImage? {
        let shrink = min(1, 420 / max(size.width, size.height))
        let unit = scale * shrink
        let small = mask.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        func layer(sigma: Double, drop: Double, alpha: Double) -> CIImage {
            small.applyingFilter("CIMaskToAlpha")
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(alpha * strength, 1)),
                ])
                .applyingGaussianBlur(sigma: sigma * unit)
                .transformed(by: CGAffineTransform(translationX: 0, y: -drop * unit))
        }
        let soft = layer(sigma: 7, drop: 4, alpha: 0.34).composited(over: layer(sigma: 34, drop: 22, alpha: 0.72))
        let reach = (34 * 3 + 22) * unit
        let bounds = small.extent.insetBy(dx: -reach, dy: -reach).integral
        guard let baked = bake(soft, in: bounds, context: context) else { return nil }
        return baked.transformed(by: CGAffineTransform(scaleX: 1 / shrink, y: 1 / shrink))
    }

    /// The ring that marks a click.
    static func makeRing() -> CIImage {
        let side = 256
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.empty() }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.3))
        context.fillEllipse(in: rect.insetBy(dx: 10, dy: 10))
        context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
        context.setLineWidth(14)
        context.strokeEllipse(in: rect.insetBy(dx: 10, dy: 10))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        context.setLineWidth(9)
        context.strokeEllipse(in: rect.insetBy(dx: 10, dy: 10))
        return context.makeImage().map { CIImage(cgImage: $0) } ?? CIImage.empty()
    }

    /// An arrow drawn here, for a pointer that was never the system's: the one that follows
    /// declared clicks. Drawn large, so it stays sharp however far the camera moves in.
    static func arrowCursor() -> (image: CIImage, shape: CursorShape)? {
        let size = CGSize(width: 28, height: 40), hot = CGPoint(x: 4.5, y: 4), scale = 10.0
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Outline of the arrow in points from its tip, y downwards.
        let outline: [(Double, Double)] = [(0, 0), (0, 15.2), (3.5, 12), (6.2, 18.2), (8.7, 17.1), (6, 11.1), (10.7, 11.1)]
        let path = CGMutablePath()
        for (index, point) in outline.enumerated() {
            let at = CGPoint(x: (hot.x + point.0) * scale, y: (size.height - hot.y - point.1) * scale)
            if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
        }
        path.closeSubpath()

        context.setLineJoin(.round)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2.6 * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(2.6 * scale)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        context.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.setLineWidth(0.5 * scale)
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        guard let image = context.makeImage() else { return nil }
        let shape = CursorShape(id: "arrow", width: size.width, height: size.height, hotX: hot.x, hotY: hot.y)
        return (CIImage(cgImage: image), shape)
    }
}
