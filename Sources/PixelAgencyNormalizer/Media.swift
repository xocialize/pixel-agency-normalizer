import CoreGraphics
import EraseFill
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixels the normalizer works in: sRGB, 8 bits per channel, premultiplied RGBA, top row first. Every rule the Image
/// profile states about pixels (masks, compositing, sizes, alpha) is applied on these, whatever the model returns.
/// The type is EraseFill's `FillPixels` since 0.3.0 (AB-A-0180): the fill route's steps (`FillRoute`) are the one
/// implementation the bake-off measured, shared with ForgeCore.
typealias Pixels = FillPixels

extension FillPixels {
    /// Whether any pixel is less than fully opaque.
    var hasTransparency: Bool { stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 255 } }
}

/// Pixels at 16 bits (Gigapixel gap G-6, AB-A-0158): sRGB, 16 bits per channel, premultiplied RGBA, top row first —
/// `ModelImage.Format.rawRGBA16`'s layout. Only the upscale route works in them, when a request asks for `bit_depth: 16` and
/// the model keeps 16 bits; every other rule still runs on 8-bit `Pixels`.
struct DeepPixels: Sendable {
    let width: Int
    let height: Int
    var rgba: [UInt16]

    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue

    init(width: Int, height: Int, rgba: [UInt16]? = nil) {
        self.width = width; self.height = height
        self.rgba = rgba ?? [UInt16](repeating: 0, count: width * height * 4)
    }

    /// Draws `image` into a new 16-bit buffer of `width` × `height` (its own size by default), converting to sRGB.
    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let (w, h) = (width ?? image.width, height ?? image.height)
        self.init(width: w, height: h)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                space: Pixels.sRGB, bitmapInfo: Self.bitmapInfo)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    var cgImage: CGImage {
        var copy = rgba
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                      space: Pixels.sRGB, bitmapInfo: Self.bitmapInfo)!.makeImage()!
        }
    }

    /// Whether any pixel is less than fully opaque.
    var hasTransparency: Bool { stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < UInt16.max } }

    func resized(_ w: Int, _ h: Int) -> DeepPixels { w == width && h == height ? self : DeepPixels(cgImage, width: w, height: h) }

    /// Whether any colour value is off the 8-bit grid — i.e. the pixels really carry more than 8 bits.
    var carriesMoreThanEightBits: Bool {
        rgba.indices.contains { $0 % 4 != 3 && rgba[$0] % 257 != 0 }
    }
}

/// An 8-bit grey mask, top row first. White (255) = change. EraseFill's `FillMask` (`hole`: every non-black pixel at
/// full strength, what a model is asked to repaint; the composite still blends by the mask itself, Image §1.6–1.7).
typealias Mask = FillMask

enum Media {
    struct Loaded {
        var pixels: Pixels
        /// The file carried a profile other than sRGB and was converted (Image §1.3: warn `color_converted`).
        var colorConverted: Bool
    }

    /// Loads an input upright (EXIF orientation applied, Image §1.4) and in sRGB (§1.3).
    static func load(_ url: URL) throws -> Loaded {
        let (image, converted) = try upright(url)
        return Loaded(pixels: Pixels(image), colorConverted: converted)
    }

    /// `load` at 16 bits, for the upscale route's `bit_depth: 16`. ImageIO decodes a 16-bit TIFF or PNG at 16 bits on
    /// the upright (thumbnail-with-transform) path too (AB-D-0125's probe); an 8-bit input is widened exactly.
    static func loadDeep(_ url: URL) throws -> (pixels: DeepPixels, colorConverted: Bool) {
        let (image, converted) = try upright(url)
        return (DeepPixels(image), converted)
    }

    /// The decoded image, upright, and whether it carried a profile other than sRGB.
    static func upright(_ url: URL) throws -> (CGImage, colorConverted: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw NormalizerError.input("\(url.lastPathComponent) isn't a readable image.")
        }
        let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h), kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let image = upright else { throw NormalizerError.input("\(url.lastPathComponent) can't be decoded.") }
        let name = image.colorSpace?.name as String?
        let converted = image.colorSpace?.model == .rgb && name != (CGColorSpace.sRGB as String)
            && !(props[kCGImagePropertyProfileName] as? String ?? "sRGB").localizedCaseInsensitiveContains("sRGB")
        return (image, converted)
    }

    /// Loads a mask as 8-bit grey at `width` × `height`; says whether it had to be resampled (warn `mask_resampled`).
    static func loadMask(_ url: URL, width: Int, height: Int) throws -> (Mask, resampled: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NormalizerError.input("The mask isn't a readable image.")
        }
        return (Mask(image, width: width, height: height), image.width != width || image.height != height)
    }

    /// A model's image output as pixels.
    static func pixels(_ image: ModelImage) throws -> Pixels {
        Pixels(try cgImage(image))
    }

    /// A model's image output at 16 bits: `.rawRGBA16` as it is, anything else widened.
    static func deepPixels(_ image: ModelImage) throws -> DeepPixels {
        if image.format == .rawRGBA16, let w = image.width, let h = image.height, image.bytesPerRow ?? w * 8 == w * 8,
           image.data.count >= w * h * 8 {
            return DeepPixels(width: w, height: h, rgba: image.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self).prefix(w * h * 4)) })
        }
        return DeepPixels(try cgImage(image))
    }

    /// A model's image output, decoded by its format.
    static func cgImage(_ image: ModelImage) throws -> CGImage {
        switch image.format {
        case .png, .jpeg:
            guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NormalizerError.engine("The model returned an unreadable image.")
            }
            return cg
        case .rawBGRA8:
            guard let w = image.width, let h = image.height else { throw NormalizerError.engine("A raw image without a size.") }
            let row = image.bytesPerRow ?? w * 4
            var copy = image.data
            return copy.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row, space: Pixels.sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
            }
        case .rawRGBA16:
            guard let w = image.width, let h = image.height else { throw NormalizerError.engine("A raw image without a size.") }
            let row = image.bytesPerRow ?? w * 8
            var copy = image.data
            return copy.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: row, space: Pixels.sRGB,
                          bitmapInfo: DeepPixels.bitmapInfo)!.makeImage()!
            }
        }
    }

    /// A model's matte output as a mask at `width` × `height`.
    static func mask(_ matte: ModelMatte, width: Int, height: Int) throws -> Mask {
        guard let source = CGImageSourceCreateWithData(matte.data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NormalizerError.engine("The model returned an unreadable matte.")
        }
        return Mask(cg, width: width, height: height)
    }

    /// Pixels as the PNG a model package takes.
    static func modelImage(_ pixels: Pixels) -> ModelImage {
        ModelImage(format: .png, data: encode(pixels.cgImage, mediaType: "image/png"), width: pixels.width, height: pixels.height)
    }

    /// 16-bit pixels as the raw `.rawRGBA16` image a 16-bit-capable model takes.
    static func modelImage(_ pixels: DeepPixels) -> ModelImage {
        .rawRGBA16(data: pixels.rgba.withUnsafeBytes { Data($0) }, width: pixels.width, height: pixels.height)
    }

    static func modelImage(_ mask: Mask) -> ModelImage {
        ModelImage(format: .png, data: encode(mask.cgImage, mediaType: "image/png"), width: mask.width, height: mask.height)
    }

    /// Encodes as PNG, JPEG or TIFF, tagged sRGB (Image §1.3), upright with no orientation flag (§1.4). PNG and TIFF keep
    /// a 16-bit image's 16 bits; TIFF is ZIP-compressed (lossless), as Desktop's Master deliverable is.
    static func encode(_ image: CGImage, mediaType: String) -> Data {
        let type: UTType = mediaType == "image/jpeg" ? .jpeg : mediaType == "image/tiff" ? .tiff : .png
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        if type == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 8] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Puts the input's alpha back on a model output that lost it (Image §1.5: warn `alpha_reapplied`).
    static func reapplyAlpha(_ output: Pixels, from input: Pixels) -> Pixels {
        let alpha = input.resized(output.width, output.height)
        var out = output
        for i in 0..<(output.width * output.height) {
            let a = Int(alpha.rgba[i * 4 + 3])
            guard a < 255 else { continue }
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt8((Int(output.rgba[i * 4 + c]) * a + 127) / 255) }
            out.rgba[i * 4 + 3] = UInt8(a)
        }
        return out
    }

    /// `reapplyAlpha` at 16 bits.
    static func reapplyAlpha(_ output: DeepPixels, from input: DeepPixels) -> DeepPixels {
        let alpha = input.resized(output.width, output.height)
        var out = output
        for i in 0..<(output.width * output.height) {
            let a = UInt32(alpha.rgba[i * 4 + 3])
            guard a < 65535 else { continue }
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt16((UInt32(output.rgba[i * 4 + c]) * a + 32767) / 65535) }
            out.rgba[i * 4 + 3] = UInt16(a)
        }
        return out
    }

    /// Whether `layer` shows anything where `input` (the same size) is fully transparent.
    static func shows(_ layer: Pixels, whereClear input: Pixels) -> Bool {
        stride(from: 3, to: input.rgba.count, by: 4).contains { input.rgba[$0] == 0 && layer.rgba[$0] > 0 }
    }

    /// `layer` with its alpha capped at `input`'s (the same size), pixel by pixel: a decomposed layer keeps its own
    /// transparency, and shows nothing where the input is transparent (Image §3.2, §1.5).
    static func capAlpha(_ layer: Pixels, at input: Pixels) -> Pixels {
        var out = layer
        for i in 0..<(layer.width * layer.height) {
            let a = Int(input.rgba[i * 4 + 3]), l = Int(layer.rgba[i * 4 + 3])
            guard l > a else { continue }
            for c in 0..<4 { out.rgba[i * 4 + c] = UInt8((Int(layer.rgba[i * 4 + c]) * a + l / 2) / l) }
        }
        return out
    }

    /// The image with the matte as its alpha (the `extract` output of `image.matte`).
    static func extract(_ image: Pixels, alpha: Mask) -> Pixels {
        var out = image
        for i in 0..<(image.width * image.height) {
            let a = Int(alpha.values[i])
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt8((Int(image.rgba[i * 4 + c]) * a + 127) / 255) }
            out.rgba[i * 4 + 3] = UInt8((Int(image.rgba[i * 4 + 3]) * a + 127) / 255)
        }
        return out
    }

    // MARK: - Erase by name

    /// The square an edit model erases in: centred on `region`, 2.5× its long side for context, at least 1024 px (or
    /// the short side) and at most the short side, inside the picture. The removal gate cropped the short side and
    /// worked at 1024², so a 1024² input gets exactly that; a large photo gets a tighter square, so the result isn't
    /// upscaled into a soft patch. nil when the region is longer than the short side: no square holds it.
    static func square(around region: Box, width: Int, height: Int) -> Box? {
        let short = min(width, height), long = max(region.width, region.height)
        guard long <= short else { return nil }
        let side = min(short, max(min(1024, short), Int((Double(long) * 2.5).rounded())))
        let (cx, cy) = (region.x + region.width / 2, region.y + region.height / 2)
        return Box(x: min(max(cx - side / 2, 0), width - side), y: min(max(cy - side / 2, 0), height - side), width: side, height: side)
    }

    /// `image` with a pure red outline `thickness` px wide, centred on `box`'s edges: how the removal gate showed Mage-VL
    /// which object to name (the fal/prithiv convention, 7 px at 1024²).
    static func outline(_ image: Pixels, box: Box, thickness: Int) -> Pixels {
        var out = image
        let half = thickness / 2
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            for y in max(0, y0)...min(image.height - 1, y1) {
                for x in max(0, x0)...min(image.width - 1, x1) {
                    let i = (y * image.width + x) * 4
                    out.rgba[i] = 255; out.rgba[i + 1] = 0; out.rgba[i + 2] = 0; out.rgba[i + 3] = 255
                }
            }
        }
        let (x1, y1) = (box.x + box.width - 1, box.y + box.height - 1)
        fill(box.x - half, box.y - half, x1 + half, box.y + half)             // top
        fill(box.x - half, y1 - half, x1 + half, y1 + half)                   // bottom
        fill(box.x - half, box.y - half, box.x + half, y1 + half)             // left
        fill(x1 - half, box.y - half, x1 + half, y1 + half)                   // right
        return out
    }

    /// The mean absolute difference between `a` and `b` (0–255, over RGB) where `mask` is non-black.
    static func meanDifference(_ a: Pixels, _ b: Pixels, within mask: Mask) -> Double {
        var total = 0, n = 0
        for i in 0..<(mask.width * mask.height) where mask.values[i] > 0 {
            for c in 0..<3 { total += abs(Int(a.rgba[i * 4 + c]) - Int(b.rgba[i * 4 + c])) }
            n += 1
        }
        return n == 0 ? 0 : Double(total) / Double(n * 3)
    }
}

/// A pixel rectangle, top row first. EraseFill's `FillBox` (`grown(by:within:_:)`).
typealias Box = FillBox

extension FillBox {
    /// Scaled by `k` about the origin (a crop resized to the model's side).
    func scaled(_ k: Double) -> FillBox {
        FillBox(x: Int((Double(x) * k).rounded()), y: Int((Double(y) * k).rounded()),
                width: max(1, Int((Double(width) * k).rounded())), height: max(1, Int((Double(height) * k).rounded())))
    }
}

/// Failures the normalizer reports (mapped to MES errors by the engine).
enum NormalizerError: Error, CustomStringConvertible {
    case input(String)
    case engine(String)
    var description: String {
        switch self {
        case .input(let m), .engine(let m): m
        }
    }
}
