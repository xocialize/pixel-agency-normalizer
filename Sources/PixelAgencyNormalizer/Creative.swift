import Accelerate
import CoreGraphics
import Foundation
import MESCore
import MESEngineCore
import Vision

/// The creative upscale (Gigapixel gap G-5, AB-D-0126; measured in mlxengine-todo `CREATIVE-UPSCALE-EVAL.md`):
/// `image.upscale` with the declared extension `x-pixelagency.creative` (Base §6.2).
///
/// - **Creativity 0, Realistic:** VOSR2 at ×scale, behind the text guard as shipped (the best no-reference quality of
///   every arm, faces and text kept).
/// - **Creativity above 0, Creative** (§8.2):
///   1. the precision upscale at ×scale (the quality tier's model);
///   2. Mage-Flow-Edit-Turbo over tiles of at most 1024² at the target size, each starting from the tile partly
///      noised: σ = 0.85 + 0.10 × creativity;
///   3. the tiles cross-faded;
///   4. colour and tone locked to the precision base: C − G(C) + G(base);
///   5. faces and certain text lines blended back from the precision base.
/// A request without the extension is the plain upscale, unchanged.
public enum Creative {
    /// The extension's name on `image.upscale`.
    public static let name = "x-pixelagency.creative"
    /// The editor that paints the tiles.
    public static let editor = "mage-flow-edit-turbo"
    /// Realistic, at creativity 0.
    public static let realistic = "vosr2-upscale"
    /// Past this a ×4 is about 100 Mage calls (§8.3).
    static let maxOutputPixels = 32_000_000
    static let maxTile = 1024
    static let overlap = 128
    /// The editor's batch mode (mage-flow-swift ≥ 0.11.0): every tile in one call, the conditioner loaded once, the
    /// edits returned stacked top to bottom; tile k runs at seed + k, as one call per tile does.
    public static let tilesMode = "tiles"
    /// Tiles per call in that mode (the package's `MageFlowModes.maxTiles`; a 32 MP ×4 is at most ~56).
    static let maxTilesPerCall = 64

    struct Request: Equatable, Sendable {
        var prompt = ""
        var creativity = 0.5
        var protectFaces = true
        var protectText = true

        /// The extension's values, or nil when the request doesn't carry it.
        init?(_ extensions: [String: MESValue]) {
            guard let value = extensions[Creative.name] else { return nil }
            prompt = value["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            creativity = value["creativity"]?.numberValue ?? 0.5
            protectFaces = value["protect_faces"]?.boolValue ?? true
            protectText = value["protect_text"]?.boolValue ?? true
        }

        init(prompt: String = "", creativity: Double = 0.5, protectFaces: Bool = true, protectText: Bool = true) {
            self.prompt = prompt; self.creativity = creativity; self.protectFaces = protectFaces; self.protectText = protectText
        }

        /// Mage's starting noise level (§8.1): 0.85 at the bottom, 0.90 by default, 0.95 at the top.
        var initSigma: Double { 0.85 + 0.10 * min(1, max(0, creativity)) }
    }

    static let spec = ExtensionSpec(name: name, title: "Creative upscale", schema: [
        "type": "object", "additionalProperties": false,
        "properties": [
            "prompt": ["type": "string", "maxLength": 4000,
                       "x-mes-ui": ["label": "Describe the look", "widget": "textarea", "order": 1,
                                    "help": "Describe the look (film grain, crisp foliage), not what is in the picture: every tile sees it."]],
            "creativity": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.5,
                           "x-mes-ui": ["label": "Creativity", "widget": "slider", "order": 2,
                                        "help": "0 = Realistic (no new content). Higher adds more invented detail."]],
            "protect_faces": ["type": "boolean", "default": true,
                              "x-mes-ui": ["label": "Keep faces", "widget": "toggle", "order": 3]],
            "protect_text": ["type": "boolean", "default": true,
                             "x-mes-ui": ["label": "Keep text legible", "widget": "toggle", "order": 4, "advanced": true]],
        ],
    ])

    /// The fixed instruction every tile gets (§8.2 step 3). The request's prompt is style, not scene: every tile sees
    /// it, so a scene noun would be painted into every tile (§6.3).
    static func instruction(_ prompt: String) -> String {
        let base = "Upscale this image to high resolution: sharpen it and add fine, natural detail and texture. "
            + "Keep the composition, colors, faces and all text exactly the same."
        return prompt.isEmpty ? base : base + " Style: \(prompt)."
    }

    /// Tiles along one axis: the fewest tiles of at most `maxTile` covering `length` with `overlap`-px overlaps, each
    /// shrunk to a multiple of 16 so neighbours overlap by about `overlap` only (wider overlaps average independent
    /// generations and blur them). Returns the starts and the tile length.
    static func layout(_ length: Int, maxTile: Int, overlap: Int) -> (starts: [Int], tile: Int) {
        if length <= maxTile { return ([0], length) }
        let n = Int((Double(length - overlap) / Double(maxTile - overlap)).rounded(.up))
        let tile = min(maxTile, ((length + (n - 1) * overlap) + n - 1) / n + 15) / 16 * 16
        return ((0..<n).map { Int((Double($0) * Double(length - tile) / Double(n - 1)).rounded()) }, tile)
    }

    /// A raised-cosine ramp over the overlap on interior edges only, so neighbouring weights sum to one.
    static func ramp(_ p: Int, length: Int, low: Bool, high: Bool, overlap: Int) -> Float {
        var w: Float = 1
        if low && p < overlap { w = min(w, 0.5 - 0.5 * cos(Float.pi * (Float(p) + 0.5) / Float(overlap))) }
        if high && length - 1 - p < overlap { w = min(w, 0.5 - 0.5 * cos(Float.pi * (Float(length - 1 - p) + 0.5) / Float(overlap))) }
        return w
    }

    /// A tile of `image` at (x, y), `width` × `height`, edge-padded to `side` × `side` (Mage's envelope is square).
    static func tile(_ image: Pixels, x: Int, y: Int, width: Int, height: Int, side: Int) -> Pixels {
        var out = Pixels(width: side, height: side)
        for yy in 0..<side {
            let sy = y + min(yy, height - 1)
            for xx in 0..<side {
                let sx = x + min(xx, width - 1)
                let s = (sy * image.width + sx) * 4, d = (yy * side + xx) * 4
                out.rgba[d] = image.rgba[s]; out.rgba[d + 1] = image.rgba[s + 1]; out.rgba[d + 2] = image.rgba[s + 2]
                out.rgba[d + 3] = 255
            }
        }
        return out
    }

    /// The three colour planes of `image` as floats.
    static func planes(_ image: Pixels) -> [[Float]] {
        let n = image.width * image.height
        var p = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for i in 0..<n { for c in 0..<3 { p[c][i] = Float(image.rgba[i * 4 + c]) } }
        return p
    }

    /// A Gaussian blur of one plane (Accelerate's separable convolution, edges extended).
    static func gaussian(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.up)))
        let raw = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +)
        let kernel = raw.map { $0 / total }
        var src = plane, dst = [Float](repeating: 0, count: plane.count)
        src.withUnsafeMutableBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                      rowBytes: width * MemoryLayout<Float>.size)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                      rowBytes: width * MemoryLayout<Float>.size)
                _ = vImageSepConvolve_PlanarF(&a, &b, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count), 0, 0,
                                              vImage_Flags(kvImageEdgeExtend))
            }
        }
        return dst
    }

    /// Colour and tone from `base`, detail from `creative` (§8.2 step 5): C − G(C) + G(base), G a Gaussian of `sigma`
    /// output px. Removes per-tile tone drift by construction.
    static func colourLock(_ creative: Pixels, base: Pixels, sigma: Float) -> Pixels {
        let (w, h) = (creative.width, creative.height)
        let c = planes(creative), b = planes(base)
        var out = creative
        for ch in 0..<3 {
            let gc = gaussian(c[ch], width: w, height: h, sigma: sigma), gb = gaussian(b[ch], width: w, height: h, sigma: sigma)
            for i in 0..<(w * h) { out.rgba[i * 4 + ch] = UInt8(max(0, min(255, (c[ch][i] - gc[i] + gb[i]).rounded()))) }
        }
        return out
    }

    /// `top` over `bottom` through `mask` (0…1 per pixel).
    static func blend(_ top: Pixels, over bottom: Pixels, mask: [Float]) -> Pixels {
        var out = bottom
        for i in 0..<mask.count where mask[i] > 0 {
            let m = mask[i]
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt8((Float(bottom.rgba[i * 4 + c]) * (1 - m) + Float(top.rgba[i * 4 + c]) * m).rounded()) }
        }
        return out
    }

    /// Faces Vision finds, in pixels with a top-left origin, at least 16 px wide (smaller ones nothing recovers).
    static func faces(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        return (request.results ?? []).map { f in
            CGRect(x: f.boundingBox.minX * w, y: (1 - f.boundingBox.maxY) * h, width: f.boundingBox.width * w,
                   height: f.boundingBox.height * h)
        }.filter { $0.width >= 16 }
    }

    /// Each face's feathered ellipse (§8.2 step 6): 1.7× the face box, a cosine falloff over its outer 35 %.
    static func faceMask(_ faces: [CGRect], width: Int, height: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)
        for f in faces {
            let (cx, cy, rx, ry) = (Float(f.midX), Float(f.midY), Float(0.85 * f.width), Float(0.85 * f.height))
            for y in max(0, Int(cy - ry))..<min(height, Int(cy + ry) + 1) {
                for x in max(0, Int(cx - rx))..<min(width, Int(cx + rx) + 1) {
                    let dx = (Float(x) - cx) / rx, dy = (Float(y) - cy) / ry
                    let r = (dx * dx + dy * dy).squareRoot()
                    let m: Float = r < 0.65 ? 1 : r < 1 ? 0.5 + 0.5 * cos(Float.pi * (r - 0.65) / 0.35) : 0
                    mask[y * width + x] = max(mask[y * width + x], m)
                }
            }
        }
        return mask
    }

    struct Line: Equatable { var text: String; var box: CGRect; var certain: Bool }

    /// Text lines Vision reads (accurate, no language correction: how the N7 guard reads), boxes in pixels, top-left
    /// origin. A line is certain when Vision reads it at confidence 1.0.
    static func lines(in image: CGImage) -> [Line] {
        lines(in: image, offset: .zero)
    }

    static func lines(in image: CGImage, offset: CGPoint) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        return (request.results ?? []).compactMap { o in
            guard let best = o.topCandidates(1).first else { return nil }
            let b = o.boundingBox
            return Line(text: best.string, box: CGRect(x: offset.x + b.minX * w, y: offset.y + (1 - b.maxY) * h, width: b.width * w,
                                                       height: b.height * h),
                        certain: best.confidence >= 1)
        }
    }

    /// Certain lines' feathered boxes (§8.2 step 7): padded by 0.35 × the line's height, a Gaussian edge of about half
    /// that, scaled by 1.5 and clipped, as the measured prototype.
    static func lineMask(_ lines: [Line], width: Int, height: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)
        for line in lines where line.certain {
            let lh = max(4, Float(line.box.height)), pad = 0.35 * lh, sigma = max(1.5, pad / 2)
            let (x0, x1) = (Float(line.box.minX) - pad, Float(line.box.maxX) + pad)
            let (y0, y1) = (Float(line.box.minY) - pad, Float(line.box.maxY) + pad)
            let s = sigma * Float(2).squareRoot()
            func inside(_ p: Float, _ a: Float, _ b: Float) -> Float { 0.5 * (erf((p - a) / s) - erf((p - b) / s)) }
            for y in max(0, Int(y0 - 3 * sigma))..<min(height, Int(y1 + 3 * sigma) + 1) {
                let wy = inside(Float(y) + 0.5, y0, y1)
                for x in max(0, Int(x0 - 3 * sigma))..<min(width, Int(x1 + 3 * sigma) + 1) {
                    let m = min(1, 1.5 * wy * inside(Float(x) + 0.5, x0, x1))
                    mask[y * width + x] = max(mask[y * width + x], m)
                }
            }
        }
        return mask
    }

    /// Why the creative upscale isn't offered on this Mac, or nil when it is: each of its models' projected peak (its
    /// weights at the residency the runtime chose for this Mac, plus its activation) against the engine's memory
    /// budget (`ModelFit.fitsBudget`, asked with nothing loaded). An unknown fit is offered: Residency still makes room.
    public static func unavailableReason(editor: ModelFit?, realistic: ModelFit?) -> String? {
        let gb = { (b: UInt64) in String(format: "%.1f GB", Double(b) / 1e9) }
        for (name, fit) in [("Mage-Flow-Edit-Turbo", editor), ("VOSR2", realistic)] {
            guard let fit, fit.fitsBudget == false, let peak = fit.projectedPeakBytes, let budget = fit.budgetBytes else { continue }
            return "The creative upscale isn't offered on this Mac: \(name) peaks at about \(gb(peak)) and this Mac's GPU budget is \(gb(budget))."
        }
        return nil
    }

    /// The certain lines whose text reads differently after the creative pass: each line's padded box read the same
    /// way in the base and in the result (a whole-frame reading re-segments around invented text, so comparing two
    /// whole-frame readings flags lines that didn't change). At most 40 lines are checked.
    static func altered(_ lines: [Line], base: CGImage, result: CGImage) -> [String] {
        let frame = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        var changed: [String] = []
        for line in lines.filter(\.certain).prefix(40) {
            let pad = 0.35 * max(4, line.box.height)
            let box = line.box.insetBy(dx: -pad, dy: -pad).intersection(frame).integral
            guard let b = base.cropping(to: box), let r = result.cropping(to: box) else { continue }
            let before = Self.lines(in: b, offset: .zero).map(\.text).joined(separator: " ")
            guard !normalized(before).isEmpty else { continue }
            let after = Self.lines(in: r, offset: .zero).map(\.text).joined(separator: " ")
            if normalized(before) != normalized(after) { changed.append(line.text) }
        }
        return changed
    }

    /// Text for comparison: case and spacing ignored.
    static func normalized(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
}

extension RunPlan {
    /// §8.2: the precision base, Mage over tiles, cross-fade, colour lock, faces and certain text lines from the base.
    mutating func creativeUpscale(_ creative: Creative.Request, input: Pixels, scale: Int) async throws -> [ProducedOutput] {
        let (w, h) = (input.width * scale, input.height * scale)
        guard w * h <= Creative.maxOutputPixels else {
            throw MESError(.outOfLimits, "The creative upscale makes at most 32 MP; \(w)×\(h) is more. Use a smaller scale or image.",
                           param: "scale")
        }
        // 1. The precision base: the quality tier's model, exactly ×scale. Also the fallback output.
        let base = try await upscaled(input, scale: scale)
        let baseModel = modelParams["model"]
        // 2–3. Mage over tiles, cross-faded.
        let editor = try await route(.imageEdit, named: Creative.editor)
        // Residency made room; if the Mac still can't hold the editor's peak right now, the run pages. Say so.
        if let fit = await host.fit(editor), !fit.fits {
            warn("memory_tight", "This Mac is short of free memory for the creative pass (\(fit.message)); it may run slowly.",
                 param: Creative.name)
        }
        let envelopeSide = Int(Double(editor.envelope.maxPixels).squareRoot()) / 16 * 16
        let maxTile = max(256, min(Creative.maxTile, envelopeSide))
        let (xs, tw) = Creative.layout(w, maxTile: maxTile, overlap: Creative.overlap)
        let (ys, th) = Creative.layout(h, maxTile: maxTile, overlap: Creative.overlap)
        let side = (max(tw, th) + 15) / 16 * 16
        let ovx = xs.count > 1 ? tw - (xs[1] - xs[0]) : 1, ovy = ys.count > 1 ? th - (ys[1] - ys[0]) : 1
        let origins = ys.flatMap { y0 in xs.map { x0 in (x: x0, y: y0) } }
        let count = origins.count
        let seedBase = seed(count: count)
        let params: Params = ["prompt": .string(Creative.instruction(creative.prompt)), "initSigma": .number(creative.initSigma)]
        var acc = [Float](repeating: 0, count: w * h * 3), weights = [Float](repeating: 0, count: w * h)
        /// Cross-fades tile `k`, found at rows `row`… of `edited`, into the accumulator.
        func accumulate(_ edited: Pixels, row: Int, tile k: Int) {
            let (x0, y0) = origins[k]
            for yy in 0..<th {
                let wy = Creative.ramp(yy, length: th, low: y0 > 0, high: y0 + th < h, overlap: ovy)
                for xx in 0..<tw {
                    let wt = wy * Creative.ramp(xx, length: tw, low: x0 > 0, high: x0 + tw < w, overlap: ovx)
                    let d = (y0 + yy) * w + x0 + xx, s = ((row + yy) * side + xx) * 4
                    for c in 0..<3 { acc[d * 3 + c] += wt * Float(edited.rgba[s + c]) }
                    weights[d] += wt
                }
            }
        }
        let tiles = origins.map { Creative.tile(base, x: $0.x, y: $0.y, width: tw, height: th, side: side) }
        let batched = normalizer.options.tiledEditors.contains(editor.id)
        if batched {
            // One call per batch: the editor loads its conditioner once for all of them (the small-Mac path).
            let batches = stride(from: 0, to: count, by: Creative.maxTilesPerCall).map { $0..<min(count, $0 + Creative.maxTilesPerCall) }
            for (b, batch) in batches.enumerated() {
                let strip = try image(try await invoke(editor, params: params, mode: Creative.tilesMode,
                                                       inputs: ["images": batch.map { Media.modelImage(tiles[$0]) }],
                                                       metaData: writtenPromptKeys(editor), seed: seedBase + UInt64(batch.lowerBound), width: side, height: side,
                                                       index: b, count: batches.count))
                guard strip.width == side, strip.height == side * batch.count else {
                    throw NormalizerError.engine("The editor returned \(strip.width)×\(strip.height) for \(batch.count) tiles of \(side)².")
                }
                for (i, k) in batch.enumerated() { accumulate(strip, row: i * side, tile: k) }
            }
        } else {
            for k in 0..<count {
                let edited = try image(try await invoke(editor, params: params, inputs: ["images": [Media.modelImage(tiles[k])]],
                                                        metaData: writtenPromptKeys(editor), seed: seedBase + UInt64(k), width: side, height: side,
                                                        index: k, count: count)).resized(side, side)
                accumulate(edited, row: 0, tile: k)
            }
        }
        var result = Pixels(width: w, height: h)
        for i in 0..<(w * h) {
            let wt = max(weights[i], 1e-6)
            for c in 0..<3 { result.rgba[i * 4 + c] = UInt8(max(0, min(255, (acc[i * 3 + c] / wt).rounded()))) }
            result.rgba[i * 4 + 3] = 255
        }
        acc.removeAll(); weights.removeAll()
        // 4. Colour and tone from the base.
        result = Creative.colourLock(result, base: base, sigma: Float(1.5 * Double(scale)))
        // 5. Faces from the base.
        var facesKept = 0
        let baseImage = base.cgImage
        if creative.protectFaces {
            let faces = Creative.faces(in: baseImage)
            facesKept = faces.count
            if !faces.isEmpty { result = Creative.blend(base, over: result, mask: Creative.faceMask(faces, width: w, height: h)) }
        }
        // 6. Certain text lines from the base; what still changed is reported.
        var text: [String: MESValue] = [:]
        if creative.protectText {
            let lines = Creative.lines(in: baseImage)
            let certain = lines.filter(\.certain)
            if !certain.isEmpty { result = Creative.blend(base, over: result, mask: Creative.lineMask(lines, width: w, height: h)) }
            let altered = certain.isEmpty ? [] : Creative.altered(lines, base: baseImage, result: result.cgImage)
            text = ["certain_lines": .number(Double(certain.count)),
                    "certain_words": .number(Double(certain.flatMap { $0.text.split(separator: " ") }.count)),
                    "altered": .array(altered.prefix(20).map { .string($0) })]
            if !altered.isEmpty {
                warn("text_altered", "Some lines the precision upscale read clearly read differently after the creative pass: "
                     + altered.prefix(10).joined(separator: "; ") + ".", param: Creative.name)
            }
        }
        modelParams["base"] = baseModel ?? .null
        modelParams["editor"] = .string(Creative.editor)
        modelParams["model"] = .string(Creative.editor)
        modelParams["initSigma"] = .number((creative.initSigma * 1000).rounded() / 1000)
        modelParams["creativity"] = .number(creative.creativity)
        modelParams["tiles"] = .number(Double(count))
        modelParams["editor_calls"] = .number(Double(batched ? (count + Creative.maxTilesPerCall - 1) / Creative.maxTilesPerCall : count))
        modelParams["faces_protected"] = .number(Double(facesKept))
        if !text.isEmpty { modelParams["text"] = .object(text) }
        seedUsed = seedBase
        effective["scale"] = .number(Double(scale))
        return [try write(keepAlpha(result, input: input), name: "image")]
    }
}
