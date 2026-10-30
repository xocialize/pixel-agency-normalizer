import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixels the normalizer works in: sRGB, 8 bits per channel, premultiplied RGBA, top row first. Every rule the Image
/// profile states about pixels (masks, compositing, sizes, alpha) is applied on these, whatever the model returns.
struct Pixels: Sendable {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, rgba: [UInt8]? = nil) {
        self.width = width; self.height = height
        self.rgba = rgba ?? [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Draws `image` into a new buffer of `width` × `height` (its own size by default), converting to sRGB.
    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let (w, h) = (width ?? image.width, height ?? image.height)
        self.init(width: w, height: h)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    var cgImage: CGImage {
        var copy = rgba
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    /// Whether any pixel is less than fully opaque.
    var hasTransparency: Bool { stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 255 } }

    func resized(_ w: Int, _ h: Int) -> Pixels { w == width && h == height ? self : Pixels(cgImage, width: w, height: h) }
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

/// An 8-bit grey mask, top row first. White (255) = change.
struct Mask: Sendable {
    let width: Int
    let height: Int
    var values: [UInt8]

    init(width: Int, height: Int, values: [UInt8]? = nil) {
        self.width = width; self.height = height
        self.values = values ?? [UInt8](repeating: 0, count: width * height)
    }

    /// A mask from any image (its luminance), resampled to `width` × `height`.
    init(_ image: CGImage, width: Int, height: Int) {
        self.init(width: width, height: height)
        values.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Every pixel the mask lets change, at full strength: what a model is asked to repaint. The composite still
    /// blends by the mask itself, so black pixels stay untouched (Image §1.7) and grey ones blend (§1.6); but a
    /// model shown only the mask's solid core paints the soft fringe back in from what it can still see.
    var hole: Mask { Mask(width: width, height: height, values: values.map { $0 > 0 ? 255 : 0 }) }

    var cgImage: CGImage {
        var copy = values
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        }
    }
}

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

    /// The model's result over the original where the mask is white, blended where grey, and the original's exact
    /// pixels where black (Image §1.7: untouched pixels stay untouched).
    static func composite(result: Pixels, over original: Pixels, mask: Mask) -> Pixels {
        let r = result.resized(original.width, original.height)
        var out = original
        for i in 0..<(original.width * original.height) {
            let m = Int(mask.values[i])
            guard m > 0 else { continue }
            for c in 0..<4 {
                let o = Int(original.rgba[i * 4 + c]), n = Int(r.rgba[i * 4 + c])
                out.rgba[i * 4 + c] = UInt8((n * m + o * (255 - m) + 127) / 255)
            }
        }
        return out
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

    /// The image on a larger canvas for `image.extend` (IMG-5): the original at (`left`, `top`), the new area filled
    /// with the nearest edge pixels as a starting point, and a mask that is white exactly over the new area.
    static func pad(_ image: Pixels, left: Int, top: Int, right: Int, bottom: Int) -> (Pixels, Mask) {
        let w = image.width + left + right, h = image.height + top + bottom
        var canvas = Pixels(width: w, height: h)
        var mask = Mask(width: w, height: h)
        for y in 0..<h {
            let sy = min(max(y - top, 0), image.height - 1)
            for x in 0..<w {
                let sx = min(max(x - left, 0), image.width - 1)
                let inside = x >= left && x < left + image.width && y >= top && y < top + image.height
                let s = (sy * image.width + sx) * 4, d = (y * w + x) * 4
                for c in 0..<4 { canvas.rgba[d + c] = image.rgba[s + c] }
                if !inside { mask.values[y * w + x] = 255 }
            }
        }
        return (canvas, mask)
    }

    /// `image` with the mask's non-black area painted flat magenta: how an edit model is shown where to paint. Its
    /// instruction then says "replace the bright magenta area with …", the phrasing edit models follow reliably.
    static let marker: [UInt8] = [255, 0, 255, 255]
    static func mark(_ image: Pixels, region: Mask) -> Pixels {
        var out = image
        for i in 0..<(image.width * image.height) where region.values[i] > 0 {
            for c in 0..<4 { out.rgba[i * 4 + c] = marker[c] }
        }
        return out
    }

    /// Why an edit model's painting can't be used, or nil, checking each of `parts` (extend: one per new side; fill:
    /// the mask) on its own, so a good side can't hide a bad one. Edit models fail at it in two ways (R1b): they keep
    /// the magenta marker, as is or as a shaded purple surface, or they leave the area dark.
    /// - `marker`: over a quarter of a part is purple-dominant (red and blue both well above green).
    /// - `dark` (`checkDark`, for extend): a part is under half as bright as the picture along its edge.
    static func paintingProblem(_ result: Pixels, canvas: Pixels, parts: [Mask], checkDark: Bool) -> String? {
        let (w, h) = (canvas.width, canvas.height)
        func luma(_ p: Pixels, _ i: Int) -> Double {
            0.299 * Double(p.rgba[i * 4]) + 0.587 * Double(p.rgba[i * 4 + 1]) + 0.114 * Double(p.rgba[i * 4 + 2])
        }
        for part in parts {
            var inside = 0, purple = 0, brightness = 0.0
            for i in 0..<(w * h) where part.values[i] > 0 {
                inside += 1
                let (r, g, b) = (Int(result.rgba[i * 4]), Int(result.rgba[i * 4 + 1]), Int(result.rgba[i * 4 + 2]))
                if r - g > 40 && b - g > 40 { purple += 1 }
                brightness += luma(result, i)
            }
            guard inside > 0 else { continue }
            if Double(purple) / Double(inside) > 0.25 { return "marker" }
            guard checkDark else { continue }
            // The picture's own pixels along this part: the band just outside it.
            let outside = Mask(width: w, height: h, values: part.values.map { $0 > 0 ? 0 : 255 })
            let band = seamBand(of: outside, width: max(8, max(w, h) / 48))
            var edge = 0.0, n = 0
            for i in 0..<(w * h) where band.values[i] > 0 && canvas.rgba[i * 4 + 3] > 0 { edge += luma(canvas, i); n += 1 }
            if n > 0, brightness / Double(inside) < 0.5 * (edge / Double(n)) { return "dark" }
        }
        return nil
    }

    /// The new sides of a padded canvas, one mask each (left, right, top, bottom; corners go with left and right).
    static func sides(width w: Int, height h: Int, left: Int, top: Int, right: Int, bottom: Int) -> [Mask] {
        var masks: [Mask] = []
        func side(_ inside: (Int, Int) -> Bool) {
            var m = Mask(width: w, height: h)
            for y in 0..<h { for x in 0..<w where inside(x, y) { m.values[y * w + x] = 255 } }
            masks.append(m)
        }
        if left > 0 { side { x, _ in x < left } }
        if right > 0 { side { x, _ in x >= w - right } }
        if top > 0 { side { x, y in y < top && x >= left && x < w - right } }
        if bottom > 0 { side { x, y in y >= h - bottom && x >= left && x < w - right } }
        return masks
    }

    /// Makes a generative result meet the original without a seam, leaving the original untouched.
    ///
    /// An edit model re-renders the whole picture, so its painted region continues *its* version of the rest, not the
    /// original, which differs a little in tone. Compositing the original back then leaves a visible seam. This
    /// measures `original − result` outside the region, spreads it smoothly into the region (normalized
    /// convolution on a coarse grid: an average of the nearby differences that fades with distance), and adds it to
    /// the result. Where the model already matches the original (LaMa composites itself), it changes nothing.
    static func harmonize(_ result: Pixels, toward original: Pixels, region: Mask) -> Pixels {
        let (w, h) = (original.width, original.height)
        let cell = max(1, max(w, h) / 256)
        let (gw, gh) = ((w + cell - 1) / cell, (h + cell - 1) / cell)
        var diff = [Float](repeating: 0, count: gw * gh * 3), weight = [Float](repeating: 0, count: gw * gh)
        for y in 0..<h {
            for x in 0..<w where region.values[y * w + x] == 0 {
                let g = (y / cell) * gw + x / cell, i = (y * w + x) * 4
                weight[g] += 1
                for c in 0..<3 { diff[g * 3 + c] += Float(original.rgba[i + c]) - Float(result.rgba[i + c]) }
            }
        }
        let sigma = max(2, Float(max(gw, gh)) / 40)                     // ~2.5% of the long side
        blur(&weight, gw, gh, channels: 1, sigma: sigma)
        blur(&diff, gw, gh, channels: 3, sigma: sigma)
        let floor = Float(cell * cell) / 2                              // half a cell's support: fades beyond the seam
        var out = result
        for y in 0..<h {
            for x in 0..<w where region.values[y * w + x] > 0 {
                // Bilinear in the grid, at the pixel's centre.
                let gx = min(Float(gw - 1), max(0, (Float(x) + 0.5) / Float(cell) - 0.5))
                let gy = min(Float(gh - 1), max(0, (Float(y) + 0.5) / Float(cell) - 0.5))
                let (x0, y0) = (Int(gx), Int(gy)), (x1, y1) = (min(gw - 1, Int(gx) + 1), min(gh - 1, Int(gy) + 1))
                let (fx, fy) = (gx - Float(x0), gy - Float(y0))
                func at(_ a: [Float], _ gx: Int, _ gy: Int, _ c: Int, _ n: Int) -> Float { a[(gy * gw + gx) * n + c] }
                func lerp(_ a: [Float], _ c: Int, _ n: Int) -> Float {
                    let top = at(a, x0, y0, c, n) * (1 - fx) + at(a, x1, y0, c, n) * fx
                    let bottom = at(a, x0, y1, c, n) * (1 - fx) + at(a, x1, y1, c, n) * fx
                    return top * (1 - fy) + bottom * fy
                }
                let support = max(lerp(weight, 0, 1), floor)
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let v = Float(result.rgba[i + c]) + lerp(diff, c, 3) / support
                    out.rgba[i + c] = UInt8(min(Float(result.rgba[i + 3]), max(0, v.rounded())))   // premultiplied
                }
            }
        }
        return out
    }

    /// A separable Gaussian blur in place, over `channels` interleaved planes.
    static func blur(_ a: inout [Float], _ w: Int, _ h: Int, channels n: Int, sigma: Float) {
        let r = Int((sigma * 3).rounded(.up))
        let raw = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +)
        let kernel = raw.map { $0 / total }
        var tmp = a
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<n {
                    var s: Float = 0
                    for k in -r...r { let xx = min(w - 1, max(0, x + k)); s += a[(y * w + xx) * n + c] * kernel[k + r] }
                    tmp[(y * w + x) * n + c] = s
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<n {
                    var s: Float = 0
                    for k in -r...r { let yy = min(h - 1, max(0, y + k)); s += tmp[(yy * w + x) * n + c] * kernel[k + r] }
                    a[(y * w + x) * n + c] = s
                }
            }
        }
    }

    /// The part of `region` within `width` pixels of the rest of the picture: the strip on the new side of a seam.
    static func seamBand(of region: Mask, width band: Int) -> Mask {
        let (w, h) = (region.width, region.height)
        // Dilate the kept area (region == 0) by `band`, separably, with running counts; keep what lands in the region.
        var rows = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            var prefix = [Int](repeating: 0, count: w + 1)
            for x in 0..<w { prefix[x + 1] = prefix[x] + (region.values[y * w + x] == 0 ? 1 : 0) }
            for x in 0..<w where prefix[min(w, x + band + 1)] - prefix[max(0, x - band)] > 0 { rows[y * w + x] = 1 }
        }
        var out = Mask(width: w, height: h)
        for x in 0..<w {
            var prefix = [Int](repeating: 0, count: h + 1)
            for y in 0..<h { prefix[y + 1] = prefix[y] + Int(rows[y * w + x]) }
            for y in 0..<h where region.values[y * w + x] > 0 && prefix[min(h, y + band + 1)] - prefix[max(0, y - band)] > 0 {
                out.values[y * w + x] = 255
            }
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

    /// The mask's non-black pixels' bounding box, or nil when it is all black.
    static func bounds(of mask: Mask) -> Box? {
        var (x0, y0, x1, y1) = (mask.width, mask.height, -1, -1)
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.values[y * mask.width + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : Box(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

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

    static func crop(_ image: Pixels, _ box: Box) -> Pixels {
        var out = Pixels(width: box.width, height: box.height)
        for row in 0..<box.height {
            let src = ((box.y + row) * image.width + box.x) * 4
            out.rgba.replaceSubrange(row * box.width * 4..<(row + 1) * box.width * 4, with: image.rgba[src..<src + box.width * 4])
        }
        return out
    }

    static func crop(_ mask: Mask, _ box: Box) -> Mask {
        var out = Mask(width: box.width, height: box.height)
        for row in 0..<box.height {
            let src = (box.y + row) * mask.width + box.x
            out.values.replaceSubrange(row * box.width..<(row + 1) * box.width, with: mask.values[src..<src + box.width])
        }
        return out
    }

    /// `image` with `patch` written over it at `box`'s origin.
    static func paste(_ patch: Pixels, into image: Pixels, at box: Box) -> Pixels {
        var out = image
        for row in 0..<patch.height {
            let dst = ((box.y + row) * image.width + box.x) * 4
            out.rgba.replaceSubrange(dst..<dst + patch.width * 4, with: patch.rgba[row * patch.width * 4..<(row + 1) * patch.width * 4])
        }
        return out
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

/// A pixel rectangle, top row first.
struct Box: Equatable, Sendable {
    var x: Int, y: Int, width: Int, height: Int

    /// Grown by `margin` on every side, kept inside a `width` × `height` picture.
    func grown(by margin: Int, within w: Int, _ h: Int) -> Box {
        let (x0, y0) = (max(0, x - margin), max(0, y - margin))
        let (x1, y1) = (min(w, x + width + margin), min(h, y + height + margin))
        return Box(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Scaled by `k` about the origin (a crop resized to the model's side).
    func scaled(_ k: Double) -> Box {
        Box(x: Int((Double(x) * k).rounded()), y: Int((Double(y) * k).rounded()),
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
