import Foundation
import MESCore
import MESEngineCore

/// One job's plan: the operation's mapping onto model runs, and the profile's rules applied to what comes back.
struct RunPlan {
    let context: RunContext
    let spec: OperationSpec
    let normalizer: ImageNormalizer
    var warnings: [Warning] = []
    var effective: [String: MESValue] = [:]
    var modelParams: [String: MESValue] = [:]
    /// The seed a generative step used, reported as the job's (Image §2).
    var seedUsed: UInt64?
    /// Models that shaped the result without producing it (the prompt enhancer's backbone), for `provenance.helpers`.
    var helpers: [HelperRef] = []
    /// The pinned commits of the weights that ran, by model or adapter id, for provenance's `revision` fields.
    var revisions: [String: String] = [:]
    /// Models this job admitted to memory (ENG-3), released when it ends.
    var admitted: [ModelRoute] = []
    /// The size a structured rewrite suggested (SenseNova's canvas), used when the request names none.
    var suggestedSize: SuggestedSize?
    /// The canvas a layout was laid out for (MOSS-Image): its boxes are in these pixels, so the job runs at exactly it.
    var layoutCanvas: CanvasSize?

    init(context: RunContext, spec: OperationSpec, normalizer: ImageNormalizer) {
        self.context = context; self.spec = spec; self.normalizer = normalizer
    }

    var host: any ModelHost { normalizer.host }

    mutating func run() async throws -> MESEngineCore.RunOutput {
        let outputs: [ProducedOutput]
        switch spec.operation {
        case "image.generate": outputs = try await generate()
        case "image.edit": outputs = try await edit()
        case "image.fill", "image.erase": outputs = try await inpaint()
        case "image.extend": outputs = try await extend()
        case "image.upscale": outputs = try await upscale()
        case "image.restore": outputs = try await restore()
        case "image.relight", "image.colorize": outputs = try await sameSize()
        case "image.matte": outputs = try await matte()
        case "image.segment": outputs = try await segment()
        case "image.describe": outputs = try await describe()
        case "image.score": outputs = try await score()
        case PromptEnhancement.preview: outputs = try await previewPrompt()
        default: throw MESError(.unknownOperation, "No plan for \(spec.operation).")
        }
        if !modelParams.isEmpty { effective["model_params"] = .object(modelParams) }
        return MESEngineCore.RunOutput(outputs: outputs, effective: effective, seed: seedUsed.map { Int($0) }, warnings: warnings,
                                       helpers: helpers, revisions: revisions)
    }

    /// `revision` when it pins a commit (40 hex digits), not a branch.
    static func pinned(_ revision: String) -> String? {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit) ? revision : nil
    }

    // MARK: - Shared steps

    mutating func warn(_ code: String, _ message: String, param: String? = nil) {
        warnings.append(Warning(code: code, message: message, param: param))
    }

    /// The model the engine kit chose, as the runtime's route, prepared (downloaded, loaded) before it runs. A helper
    /// step (`helper: true`, e.g. restore's defect detector) takes the runtime's default: permissive and production.
    /// `named` routes that model instead (the creative upscale's editor, its Realistic VOSR2).
    mutating func route(_ capability: ModelCapability, helper: Bool = false, named: String? = nil) async throws -> ModelRoute {
        let model = named ?? (helper ? nil : context.model.id)
        let route = try await normalizer.host.route(capability, model: model)
        await normalizer.residency.admit(route)                  // room first: one heavy model, and what fits
        admitted.append(route)
        let relay = ProgressRelay(context.reporter)
        do {
            try await host.prepare(route) { p in relay.send(.preparing, fraction: p.fraction, message: p.phase) }
            await relay.finish()
        } catch {
            await relay.finish()
            throw error
        }
        return route
    }

    func releaseModels() async {
        for route in admitted { await normalizer.residency.release(route) }
    }

    /// Runs one model invocation, reporting its progress as output `index` of `count`. `metaData` carries package keys the
    /// routed model declares (`ModelRoute.requestKeys`), such as FLUX 3 Klein's `upsample`; `adapters` the request's
    /// adapters (`applyAdapters`), an IC adapter's images among `inputs`.
    func invoke(_ route: ModelRoute, params: Params, mode: String? = nil, inputs: [String: [ModelImage]] = [:],
                metaData: Params? = nil, adapters: [ModelWork.Adapter]? = nil, seed: UInt64 = 0, width: Int? = nil,
                height: Int? = nil, index: Int = 0, count: Int = 1) async throws -> ModelResult {
        let work = ModelWork(route: route, mode: mode, params: params, inputs: inputs, metaData: metaData, adapters: adapters,
                             seed: seed, width: width, height: height, outputIndex: index)
        let relay = ProgressRelay(context.reporter)
        do {
            let output = try await host.run(work) { p in
                // The runtime reports `downloading`/`loading` when the governor had to reload mid-job.
                let stage: Stage = ["downloading", "loading", "waiting_for_memory"].contains(p.phase) ? .preparing : .running
                // A staged report (an editor's tiles mode: tile k of n) places its step within the whole call.
                let within = p.fraction.map { f in
                    guard let s = p.stage, let n = p.totalStages, n > 0 else { return f }
                    return (Double(max(0, s - 1)) + f) / Double(n)
                }
                relay.send(stage, step: p.step, steps: p.totalSteps,
                           fraction: within.map { (Double(index) + $0) / Double(count) }, message: p.phase)
            }
            await relay.finish()
            return output
        } catch {
            await relay.finish()
            throw error
        }
    }

    /// Loads an image input (upright, sRGB), warning when its colours were converted.
    mutating func load(_ name: String) throws -> Pixels {
        guard let url = context.input(name)?.fileURL else { throw NormalizerError.input("Input '\(name)' is missing.") }
        let loaded = try Media.load(url)
        if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "'\(name)' was converted to sRGB.", param: name) }
        return loaded.pixels
    }

    /// `load` at 16 bits (the upscale route's `bit_depth: 16`).
    mutating func loadDeep(_ name: String) throws -> DeepPixels {
        guard let url = context.input(name)?.fileURL else { throw NormalizerError.input("Input '\(name)' is missing.") }
        let loaded = try Media.loadDeep(url)
        if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "'\(name)' was converted to sRGB.", param: name) }
        return loaded.pixels
    }

    mutating func loadMask(_ name: String, for image: Pixels) throws -> Mask {
        guard let url = context.input(name)?.fileURL else { throw NormalizerError.input("Input '\(name)' is missing.") }
        let (mask, resampled) = try Media.loadMask(url, width: image.width, height: image.height)
        if resampled { warn(ImageProfile.WarningCode.maskResampled, "The mask was resized to the image.", param: name) }
        return mask
    }

    /// The requested output format (PNG unless `output.media_type` asks for JPEG, or TIFF where offered).
    var outputType: String { context.param("output")?["media_type"]?.stringValue ?? "image/png" }
    /// The requested bit depth (Image §1.2): 8 unless `output.bit_depth` asks for 16, which upscale and restore offer.
    var bitDepth: Int { context.param("output")?["bit_depth"]?.intValue ?? 8 }

    static func fileExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/tiff": "tiff"
        default: "png"
        }
    }

    func write(_ pixels: Pixels, name: String, kind: MESCore.Kind = .image, index: Int = 0) throws -> ProducedOutput {
        let type = kind == .mask ? "image/png" : outputType
        let url = context.outputDirectory.appendingPathComponent("\(name)-\(index).\(Self.fileExtension(type))")
        try Media.encode(pixels.cgImage, mediaType: type).write(to: url)
        return .file(url, name: name, kind: kind, mediaType: type, width: pixels.width, height: pixels.height)
    }

    /// `write` at 16 bits: a 16-bit PNG or TIFF.
    func write(_ pixels: DeepPixels, name: String, index: Int = 0) throws -> ProducedOutput {
        let url = context.outputDirectory.appendingPathComponent("\(name)-\(index).\(Self.fileExtension(outputType))")
        try Media.encode(pixels.cgImage, mediaType: outputType).write(to: url)
        return .file(url, name: name, kind: .image, mediaType: outputType, width: pixels.width, height: pixels.height)
    }

    func write(_ mask: Mask, name: String, index: Int = 0) throws -> ProducedOutput {
        let url = context.outputDirectory.appendingPathComponent("\(name)-\(index).png")
        try Media.encode(mask.cgImage, mediaType: "image/png").write(to: url)
        return .file(url, name: name, kind: .mask, mediaType: "image/png", width: mask.width, height: mask.height)
    }

    func image(_ value: ModelResult) throws -> Pixels {
        switch value {
        // `.upscaled`: ForgeCore's still enhancer ran it (a generative tier behind the text guard).
        case .image(let image), .upscaled(let image, _): return try Media.pixels(image)
        default: throw NormalizerError.engine("The model returned no image.")
        }
    }

    /// The seed: the request's, or a random one that survives JSON (≤ 2^53 − 1).
    func seed(count: Int) -> UInt64 {
        if let s = context.param("seed")?.intValue, s >= 0 { return UInt64(s) }
        return UInt64.random(in: 0...(9_007_199_254_740_991 - UInt64(count)))
    }

    /// Re-applies the input's alpha when the model dropped it (Image §1.5).
    mutating func keepAlpha(_ output: Pixels, input: Pixels) -> Pixels {
        guard input.hasTransparency, !output.hasTransparency else { return output }
        warn(ImageProfile.WarningCode.alphaReapplied, "The model can't carry alpha; the input's was re-applied.")
        return Media.reapplyAlpha(output, from: input)
    }

    // MARK: - Generate and edit

    /// The size the request asks for: `size`, or `aspect` + `megapixels`, or `megapixels` alone (a square); nil when it
    /// names none.
    func askedSize() -> (width: Int, height: Int)? {
        if let size = context.param("size"), let sw = size["width"]?.intValue, let sh = size["height"]?.intValue {
            return (sw, sh)
        }
        if let aspect = context.param("aspect")?.stringValue {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            let mp = context.param("megapixels")?.numberValue ?? 1
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            let w = Int((mp * 1_000_000 * parts[0] / parts[1]).squareRoot())
            return (w, Int(Double(w) * parts[1] / parts[0]))
        }
        if let mp = context.param("megapixels")?.numberValue {
            let side = Int((mp * 1_000_000).squareRoot())
            return (side, side)
        }
        return nil
    }

    /// A structured rewrite's suggested size in pixels: its aspect ratio over the model's default area. SenseNova's canvas
    /// rows are 2K (1664×2496 for 2:3); generating there took 40–118 s on the 8-step tier against 14–16 s at the same
    /// aspect near 1 MP, and SigLIP2 scored the 1 MP renders level or higher (AB-D-0155 E3 live run), so the row's
    /// pixels are left to requests that ask for them with `size`.
    static func pixels(_ suggested: SuggestedSize, defaultWidth: Int, defaultHeight: Int) -> (width: Int, height: Int)? {
        guard let ratio = suggested.ratio, ratio > 0 else { return nil }
        let w = Int((Double(defaultWidth * defaultHeight) * ratio).squareRoot())
        return (w, Int(Double(w) / ratio))
    }

    /// `size`, or `aspect` + `megapixels`, or else the size a structured rewrite suggested (`suggestedSize`), or the
    /// model's default; then snapped to its envelope (`size_snapped` when the request asked for it). A layout's canvas
    /// (`layoutCanvas`) is the size: it's what the profile was told (`targetSize`), and the kit holds the layout to it.
    mutating func size(for route: ModelRoute, required: Bool) -> (Int, Int)? {
        var w = route.defaults.width, h = route.defaults.height
        let asked = askedSize()
        let suggested = asked == nil ? suggestedSize.flatMap { Self.pixels($0, defaultWidth: w, defaultHeight: h) } : nil
        if let chosen = asked ?? suggested { (w, h) = chosen }
        guard asked != nil || suggested != nil || layoutCanvas != nil || required else { return nil }
        var fitted = route.envelope.fit(width: w, height: h) ?? route.envelope.clamp(width: w, height: h)
        if asked != nil, fitted.width != w || fitted.height != h {
            warn(ImageProfile.WarningCode.sizeSnapped, "\(w)×\(h) became \(fitted.width)×\(fitted.height) for \(route.displayName).", param: "size")
        }
        if let canvas = layoutCanvas { fitted = (canvas.width, canvas.height) }
        effective["size"] = Self.sizeValue(fitted.width, fitted.height)
        return (fitted.width, fitted.height)
    }

    /// A size on the wire: `{width, height}`.
    static func sizeValue(_ width: Int, _ height: Int) -> MESValue {
        ["width": .number(Double(width)), "height": .number(Double(height))]
    }

    /// The size the request asks for, snapped to `model`'s envelope as `size(for:)` will: what a structured profile is
    /// told to lay out for. nil when the request names none, unless `laysOut` (MOSS-Image), which is always told one, the
    /// model's default when the request names none: its boxes are in that canvas's pixels.
    func targetSize(for model: String, laysOut: Bool) async -> (width: Int, height: Int)? {
        let asked = askedSize()
        guard asked != nil || laysOut, let info = await normalizer.host.model(model) else { return nil }
        guard let asked = asked ?? (laysOut ? (info.defaults.width, info.defaults.height) : nil) else { return nil }
        let fitted = info.envelope.fit(width: asked.width, height: asked.height)
            ?? info.envelope.clamp(width: asked.width, height: asked.height)
        return (fitted.width, fitted.height)
    }

    /// A negative prompt reaches only models that use classifier-free guidance.
    mutating func negativePrompt(for route: ModelRoute) -> String? {
        guard let negative = context.param("negative_prompt")?.stringValue, !negative.isEmpty else { return nil }
        guard (route.defaults.guidance ?? 0) > 1 else {
            warn(ImageProfile.WarningCode.negativePromptIgnored, "\(route.displayName) doesn't use a negative prompt.", param: "negative_prompt")
            return nil
        }
        return negative
    }

    mutating func generate() async throws -> [ProducedOutput] {
        let count = context.param("count")?.intValue ?? 1
        let base = seed(count: count)
        // The request's prompt, enhanced for this model (`PromptEnhance`), before the model loads: one heavy model at a time.
        let typed = context.input("prompt")?.text ?? ""
        var prompt = try await enhancedPrompt(typed, param: "prompt", task: .textToImage, seed: base)
        let route = try await route(.textToImage)
        // The request's adapters (`Adapters`): their trigger or template goes into the prompt after enhancement; an IC
        // adapter's slots take the `references`, in order (Image §1.10).
        var references: [ModelImage] = []
        for (i, input) in (context.inputs["references"] ?? []).enumerated() {
            guard let url = input.fileURL else { continue }
            let loaded = try Media.load(url)
            if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "Reference \(i + 1) was converted to sRGB.", param: "references") }
            references.append(Media.modelImage(loaded.pixels))
        }
        let adapters = await applyAdapters(route, prompt: &prompt, param: "prompt", images: references)
        if !adapters.images.isEmpty {
            warn("references_ignored", "\(adapters.images.count) reference image(s) filled no adapter's slot and weren't used.",
                 param: "references")
        }
        reportPrompt(prompt, typed: typed, param: "prompt")
        let (w, h) = size(for: route, required: true)!
        var params: Params = ["prompt": .string(prompt)]
        if let negative = negativePrompt(for: route) { params["negativePrompt"] = .string(negative) }
        record(route)
        var outputs: [ProducedOutput] = []
        for i in 0..<count {
            let result = try image(try await invoke(route, params: params, inputs: adapters.inputs, metaData: requestPromptKeys(route),
                                                    adapters: adapters.adapters, seed: base + UInt64(i),
                                                    width: w, height: h, index: i, count: count))
            outputs.append(try write(result, name: "images", index: i))
        }
        effective["count"] = .number(Double(count))
        seedUsed = base
        return outputs
    }

    mutating func edit() async throws -> [ProducedOutput] {
        let route = try await route(.imageEdit)
        var images: [ModelImage] = []
        var first: Pixels?
        for (i, input) in (context.inputs["images"] ?? []).enumerated() {
            guard let url = input.fileURL else { continue }
            let loaded = try Media.load(url)
            if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "Image \(i + 1) was converted to sRGB.", param: "images") }
            if first == nil { first = loaded.pixels }
            images.append(Media.modelImage(loaded.pixels))
        }
        guard let first else { throw NormalizerError.input("image.edit needs at least one image.") }
        let size = size(for: route, required: false)
        let base = seed(count: 1)
        // An edit's rewriter would need to see the image (E4): for now this reports `needs_vision` and keeps the instruction.
        let typed = context.input("instruction")?.text ?? ""
        var instruction = try await enhancedPrompt(typed, param: "instruction", task: .imageEdit, seed: base)
        // The request's adapters: an IC adapter takes its slots' images, in order, from the edit's images.
        let adapters = await applyAdapters(route, prompt: &instruction, param: "instruction", images: images)
        reportPrompt(instruction, typed: typed, param: "instruction")
        var params: Params = ["prompt": .string(instruction)]
        if let strength = context.param("strength")?.numberValue { params["strength"] = .number(strength) }
        record(route)
        var result = try image(try await invoke(route, params: params, inputs: adapters.inputs.merging(["images": adapters.images]) { a, _ in a },
                                                 metaData: requestPromptKeys(route), adapters: adapters.adapters, seed: base,
                                                 width: size?.0, height: size?.1))
        if size == nil, result.width != first.width || result.height != first.height {
            result = result.resized(first.width, first.height)                     // the first image sets the size
        }
        seedUsed = base
        return [try write(result, name: "image")]
    }

    // MARK: - Masks: fill, erase, extend

    /// The inpainting package's variant for a large hole: MI-GAN at draft (LaMa's fast sibling), LaMa at standard and
    /// best. LaMa's pink cast on colour fills was the published bf16 weights, not the port; mlx-lama-swift 0.3.1 loads
    /// fp32 weights and matches PyTorch within one 8-bit level in every hole pixel (AB-R-0451). What remains is
    /// Big-LaMa's own limit: very large box holes (~65% of the frame and up) fade to a grey, blurry centre in PyTorch
    /// too; mug-sized holes (~25–40% of a 768² frame) fill cleanly.
    mutating func inpaintMode() -> String? {
        let lama = context.quality != .draft
        modelParams["variant"] = .string(lama ? "lama" : "mi-gan")
        return lama ? nil : "fast"
    }

    /// Whether the chosen model is an edit model, which runs fill and extend generatively.
    func generative() async -> Bool {
        await normalizer.host.model(context.model.id)?.capabilities.contains(.imageEdit) ?? false
    }

    mutating func inpaint() async throws -> [ProducedOutput] {
        let original = try load("image")
        let mask = try loadMask("mask", for: original)
        let prompt = context.input("prompt")?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if spec.operation == "image.erase", await generative() {
            return [try write(Media.composite(result: try await eraseByName(original, mask: mask), over: original, mask: mask), name: "image")]
        }
        if spec.operation == "image.fill", await generative() {
            let instruction = prompt.isEmpty
                ? "Fill the bright magenta area so it blends seamlessly into the rest of the picture, as if nothing had been there. Keep everything else unchanged."
                : "Replace the bright magenta area with \(prompt). Match the picture's lighting, perspective and style, and keep everything else unchanged."
            if let result = try await paint(original, region: mask, instruction: instruction, prompt: prompt) {
                return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
            }
            let result = try await fallBack(original, hole: mask.hole)
            return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
        }
        if !prompt.isEmpty {
            warn("prompt_ignored", "\(context.model.title) fills from the surrounding picture; the prompt isn't used.", param: "prompt")
        }
        let route = try await route(.imageInpaint)
        record(route)
        let mode = inpaintMode()
        let result = try image(try await invoke(route, params: [:], mode: mode,
                                                inputs: ["image": [Media.modelImage(original)], "mask": [Media.modelImage(mask.hole)]]))
        return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
    }

    /// The edit model left its region unpainted (the marker colour is still there, twice): LaMa fills it instead,
    /// so the marker never reaches an output.
    mutating func fallBack(_ canvas: Pixels, hole: Mask, because: String? = nil) async throws -> Pixels {
        warn("model_fallback", "\(context.model.title) \(because ?? "didn't paint the area usably twice"); LaMa filled it instead.")
        let lama = try await route(.imageInpaint, helper: true)
        modelParams["fallback"] = .string(lama.id)
        return try image(try await invoke(lama, params: [:], inputs: ["image": [Media.modelImage(canvas)], "mask": [Media.modelImage(hole)]]))
    }

    /// Erase with an edit model, by name (AB-T-0220; the removal gate's named route, AB-R-0464). Edit models ignore
    /// marks (Mage erases a red box and keeps magenta) but remove an object they are told the name of. So:
    /// - a square around the region (`Media.square`), at the model's side;
    /// - Mage-VL names what's inside a red box drawn round the region;
    /// - the edit model removes "the <name> and its shadow and reflection" from the unmarked square;
    /// - the square goes back into the picture, its tone matched at the seam.
    /// The caller composites through the client's mask (Image §1.7), so a shadow outside the mask stays. An object
    /// handed back (`Erase.handedBack`) is retried once with the next seed; after that LaMa erases it.
    mutating func eraseByName(_ original: Pixels, mask: Mask) async throws -> Pixels {
        let hole = mask.hole
        guard let region = Media.bounds(of: hole) else { return original }
        guard let square = Media.square(around: region, width: original.width, height: original.height) else {
            return try await fallBack(original, hole: hole, because: "needs the area to fit in a square inside the picture")
        }
        // The namer first: it's small and stays warm, and the editor then takes the heavy slot (ENG-3).
        let namer = try await route(.imageAnalysis, helper: true)
        let editor = try await route(.imageEdit)
        record(editor)
        let maxSide = Int(Double(editor.envelope.maxPixels).squareRoot()) / 16 * 16
        let side = max(512, min(maxSide, square.width / 16 * 16))
        let k = Double(side) / Double(square.width)
        let input = Media.crop(original, square).resized(side, side)
        let local = Box(x: region.x - square.x, y: region.y - square.y, width: region.width, height: region.height).scaled(k)
            .grown(by: Int((0.045 * Double(side)).rounded()), within: side, side)
        let boxed = Media.outline(input, box: local, thickness: max(3, side * 7 / 1024))
        guard case .text(let reply) = try await invoke(namer, params: ["prompt": .string(Erase.namePrompt)],
                                                       inputs: ["image": [Media.modelImage(boxed)]]) else {
            throw NormalizerError.engine("The namer returned no text.")
        }
        let name = Erase.objectName(reply)
        modelParams["namer"] = .string(namer.id)
        modelParams["named"] = .string(name)
        let before = Media.crop(original, square), squareHole = Media.crop(hole, square)
        let base = seed(count: 2)
        for attempt in 0..<2 {
            let result = try image(try await invoke(editor, params: ["prompt": .string(Erase.instruction(name))],
                                                    inputs: ["images": [Media.modelImage(input)]], metaData: writtenPromptKeys(editor),
                                                    seed: base + UInt64(attempt), width: side, height: side))
                .resized(square.width, square.height)
            guard Media.meanDifference(result, before, within: squareHole) < Erase.handedBack else {
                seedUsed = base + UInt64(attempt)
                if attempt > 0 { modelParams["retries"] = .number(Double(attempt)) }
                return Media.paste(Media.harmonize(result, toward: before, region: squareHole), into: original, at: square)
            }
            modelParams["rejected"] = "object left"
        }
        return try await fallBack(original, hole: hole, because: "handed the object back twice")
    }

    mutating func extend() async throws -> [ProducedOutput] {
        let original = try load("image")
        let prompt = context.input("prompt")?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (l, t, r, b) = try padding(for: original)
        let (canvas, mask) = Media.pad(original, left: l, top: t, right: r, bottom: b)
        effective["canvas"] = ["left": .number(Double(l)), "top": .number(Double(t)), "right": .number(Double(r)), "bottom": .number(Double(b))]
        let result: Pixels
        if await generative() {
            // Naming the edges matters: told only "around it", edit models often leave a side blank.
            let edges = [("left", l), ("right", r), ("top", t), ("bottom", b)].filter { $0.1 > 0 }.map(\.0)
            let named = edges.count > 1 ? edges.dropLast().joined(separator: ", ") + " and " + edges.last! : edges.first ?? "outer"
            let instruction = "Replace the bright magenta \(edges.count > 1 ? "areas" : "area") at the \(named) "
                + "\(edges.count > 1 ? "edges" : "edge") with a seamless continuation of the scene"
                + (prompt.isEmpty ? "" : " showing \(prompt)") + ". Keep everything else unchanged."
            let sides = Media.sides(width: canvas.width, height: canvas.height, left: l, top: t, right: r, bottom: b)
            guard let paintedRegion = try await paint(canvas, region: mask, instruction: instruction, prompt: prompt,
                                                      parts: sides, checkDark: true) else {
                let filled = try await fallBack(canvas, hole: mask)
                return [try write(Media.composite(result: filled, over: canvas, mask: mask), name: "image")]
            }
            let painted = Media.composite(result: paintedRegion, over: canvas, mask: mask)
            // The edit model continued its own re-rendering of the picture, so its border can meet the original out of
            // step (a trunk a little to one side). LaMa bridges a thin band on the new side of the seam from both
            // sides' context; the original's pixels stay as they are.
            let band = Media.seamBand(of: mask, width: max(8, max(canvas.width, canvas.height) / 48))
            let lama = try await route(.imageInpaint, helper: true)
            modelParams["seam"] = .string(lama.id)
            let bridged = try image(try await invoke(lama, params: [:], inputs: ["image": [Media.modelImage(painted)],
                                                                                 "mask": [Media.modelImage(band)]]))
            result = Media.composite(result: bridged, over: painted, mask: band)
        } else {
            if !prompt.isEmpty {
                warn("prompt_ignored", "\(context.model.title) extends from the picture itself; the prompt isn't used.", param: "prompt")
            }
            let route = try await route(.imageInpaint)
            record(route)
            result = try image(try await invoke(route, params: [:], mode: inpaintMode(), inputs: ["image": [Media.modelImage(canvas)],
                                                                                                "mask": [Media.modelImage(mask)]]))
        }
        return [try write(Media.composite(result: result, over: canvas, mask: mask), name: "image")]
    }

    /// An edit model paints `region` (shown to it in magenta) as `instruction` says. The result is at the canvas's
    /// size; the caller composites it with the mask, so only the region changes. Edit models sometimes keep the marker
    /// (as is, or as a shaded purple surface) or leave the region dark (`Media.paintingProblem`), so such a result is
    /// retried once with the next seed, and nil after that: the caller falls back.
    mutating func paint(_ canvas: Pixels, region: Mask, instruction: String, prompt: String, parts: [Mask]? = nil,
                        checkDark: Bool = false) async throws -> Pixels? {
        let route = try await route(.imageEdit)
        record(route)
        let fitted = route.envelope.fit(width: canvas.width, height: canvas.height)
            ?? route.envelope.clamp(width: canvas.width, height: canvas.height)
        let base = seed(count: 2)
        let marked = Media.mark(canvas, region: region)
        // A prompt that asks for the marker's colour can't be checked for it.
        let checkable = !["magenta", "pink", "fuchsia", "purple"].contains { prompt.lowercased().contains($0) }
        for attempt in 0..<2 {
            let result = try image(try await invoke(route, params: ["prompt": .string(instruction)], inputs: ["images": [Media.modelImage(marked)]],
                                                    metaData: writtenPromptKeys(route), seed: base + UInt64(attempt),
                                                    width: fitted.width, height: fitted.height))
                .resized(canvas.width, canvas.height)
            let problem = checkable ? Media.paintingProblem(result, canvas: canvas, parts: parts ?? [region], checkDark: checkDark) : nil
            guard let problem else {
                seedUsed = base + UInt64(attempt)
                if attempt > 0 { modelParams["retries"] = .number(Double(attempt)) }
                return Media.harmonize(result, toward: canvas, region: region)
            }
            modelParams["rejected"] = .string(problem)
        }
        return nil
    }

    /// `canvas` as {left, top, right, bottom}, or {size, anchor}, in pixels.
    func padding(for image: Pixels) throws -> (Int, Int, Int, Int) {
        guard let canvas = context.param("canvas") else { return (0, 0, 0, 0) }
        if let l = canvas["left"]?.intValue, let t = canvas["top"]?.intValue, let r = canvas["right"]?.intValue, let b = canvas["bottom"]?.intValue {
            return (l, t, r, b)
        }
        guard let w = canvas["size"]?["width"]?.intValue, let h = canvas["size"]?["height"]?.intValue,
              w >= image.width, h >= image.height else {
            throw MESError(.outOfLimits, "canvas.size must be at least the image's size.", param: "canvas")
        }
        let (dx, dy) = (w - image.width, h - image.height)
        let anchor = canvas["anchor"]?.stringValue ?? "center"
        let left = anchor.contains("left") ? 0 : anchor.contains("right") ? dx : dx / 2
        let top = anchor.hasPrefix("top") ? 0 : anchor.hasPrefix("bottom") ? dy : dy / 2
        return (left, top, dx - left, dy - top)
    }

    // MARK: - Processing

    mutating func upscale() async throws -> [ProducedOutput] {
        // The creative upscale (G-5, AB-D-0126): Realistic at creativity 0, Creative above.
        if let creative = Creative.Request(context.extensions) {
            let input = try load("image")
            let scale = context.param("scale")?.intValue ?? 2
            guard creative.creativity > 0 else {
                if !creative.prompt.isEmpty { warn("prompt_ignored", "Realistic (creativity 0) takes no prompt.", param: Creative.name) }
                let result = try await upscaled(input, scale: scale, named: Creative.realistic)
                effective["scale"] = .number(Double(scale))
                return [try write(keepAlpha(result, input: input), name: "image")]
            }
            return try await creativeUpscale(creative, input: input, scale: scale)
        }
        if bitDepth == 16 { return try await upscaleDeep() }
        let input = try load("image")
        let scale = context.param("scale")?.intValue ?? 2
        let result = try await upscaled(input, scale: scale)
        effective["scale"] = .number(Double(scale))
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    /// `input` upscaled by the routed model (or `named`), exactly ×scale (Image §3).
    mutating func upscaled(_ input: Pixels, scale: Int, named: String? = nil) async throws -> Pixels {
        let route = try await route(.imageUpscale, named: named)
        record(route)
        let ran = try await invoke(route, params: ["scale": .number(Double(scale))], inputs: ["image": [Media.modelImage(input)]])
        // What the enhancer reports it ran, e.g. VOSR2 behind the text guard, with the words it kept.
        if case .upscaled(_, let model) = ran { modelParams["ran"] = .string(model) }
        var result = try image(ran)
        let (w, h) = (input.width * scale, input.height * scale)
        if result.width != w || result.height != h { result = result.resized(w, h) }
        return result
    }

    /// `upscale` at 16 bits (G-6, AB-A-0158): the input loaded at 16 bits goes to the model as `.rawRGBA16` and the
    /// model's 16-bit result is written as a 16-bit PNG or TIFF. `validateBitDepth` admitted the job only for a model
    /// that keeps 16 bits; should one still answer in 8, the output says so (`bit_depth_reduced`) rather than passing
    /// an 8-bit staircase off as 16-bit detail.
    mutating func upscaleDeep() async throws -> [ProducedOutput] {
        let input = try loadDeep("image")
        let scale = context.param("scale")?.intValue ?? 2
        let route = try await route(.imageUpscale)
        guard normalizer.options.sixteenBitUpscalers.contains(route.id) else {
            throw MESError(.unsupportedParameter, "\(route.id) runs at 8 bits.", param: "output")
        }
        record(route)
        let ran = try await invoke(route, params: ["scale": .number(Double(scale))], inputs: ["image": [Media.modelImage(input)]])
        if case .upscaled(_, let model) = ran { modelParams["ran"] = .string(model) }
        let result = try deepResult(ran, route: route, input: input, width: input.width * scale, height: input.height * scale)
        effective["scale"] = .number(Double(scale))
        return [try write(result, name: "image")]
    }

    /// A 16-bit route's answer as 16-bit pixels at exactly `width`×`height` (Image §3), with the input's alpha. Should the
    /// model still answer in 8 bits, the output says so (`bit_depth_reduced`) rather than passing an 8-bit staircase off as
    /// 16-bit detail.
    mutating func deepResult(_ ran: ModelResult, route: ModelRoute, input: DeepPixels, width w: Int, height h: Int) throws -> DeepPixels {
        let answered: ModelImage
        switch ran {
        case .image(let image), .upscaled(let image, _): answered = image
        default: throw NormalizerError.engine("The model returned no image.")
        }
        var result = try Media.deepPixels(answered)
        if answered.format != .rawRGBA16 && !result.carriesMoreThanEightBits {
            warn("bit_depth_reduced", "\(route.id) answered at 8 bits; the 16-bit file carries 8-bit precision.", param: "output")
        }
        if result.width != w || result.height != h { result = result.resized(w, h) }
        if input.hasTransparency, !result.hasTransparency {
            warn(ImageProfile.WarningCode.alphaReapplied, "The model can't carry alpha; the input's was re-applied.")
            result = Media.reapplyAlpha(result, from: input)
        }
        return result
    }

    mutating func restore() async throws -> [ProducedOutput] {
        let kind = context.param("kind")?.stringValue ?? "general"
        effective["kind"] = .string(kind)
        if bitDepth == 16 { return try await restoreDeep() }
        let input = try load("image")
        if kind == "scratches" {
            // Old-photo scratches (IMG-4): find the defects, then inpaint just those.
            let detector = try await route(.defectDetect, helper: true)
            guard case .matte(let matte, _) = try await invoke(detector, params: ["kind": "binary"], inputs: ["image": [Media.modelImage(input)]]) else {
                throw NormalizerError.engine("The defect detector returned no mask.")
            }
            let mask = try Media.mask(matte, width: input.width, height: input.height)
            let painter = try await route(.imageInpaint, helper: true)
            modelParams["detector"] = .string(detector.id)
            record(painter)
            let result = try image(try await invoke(painter, params: [:], inputs: ["image": [Media.modelImage(input)], "mask": [Media.modelImage(mask)]]))
            return [try write(keepAlpha(Media.composite(result: result, over: input, mask: mask), input: input), name: "image")]
        }
        let route = try await route(.imageRestore)
        record(route)
        var result = try image(try await invoke(route, params: [:], inputs: ["image": [Media.modelImage(input)]]))
        if result.width != input.width || result.height != input.height { result = result.resized(input.width, input.height) }
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    /// `restore` at 16 bits (G-6, AB-T-0230): the input loaded at 16 bits goes to the kind's own route as `.rawRGBA16`, and
    /// the model's 16-bit result is written as a 16-bit PNG or TIFF. `validateBitDepth` admitted the job only where that
    /// route keeps 16 bits (never scratches).
    mutating func restoreDeep() async throws -> [ProducedOutput] {
        let input = try loadDeep("image")
        let route = try await route(.imageRestore)
        guard normalizer.options.sixteenBitRestorers.contains(route.id) else {
            throw MESError(.unsupportedParameter, "\(route.id) runs at 8 bits.", param: "output")
        }
        record(route)
        let ran = try await invoke(route, params: [:], inputs: ["image": [Media.modelImage(input)]])
        return [try write(try deepResult(ran, route: route, input: input, width: input.width, height: input.height), name: "image")]
    }

    /// relight and colorize: same size and composition (Image §3).
    mutating func sameSize() async throws -> [ProducedOutput] {
        let input = try load("image")
        if let prompt = context.input("prompt")?.text, !prompt.isEmpty {
            warn("prompt_ignored", "\(context.model.title) corrects exposure; the prompt isn't used.", param: "prompt")
        }
        let route = try await route(spec.capability)
        record(route)
        var params: Params = [:]
        if let strength = context.param("strength")?.numberValue { params["strength"] = .number(strength) }
        var result = try image(try await invoke(route, params: params, inputs: ["image": [Media.modelImage(input)]]))
        if result.width != input.width || result.height != input.height { result = result.resized(input.width, input.height) }
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    mutating func matte() async throws -> [ProducedOutput] {
        let input = try load("image")
        let route = try await route(.matting)
        record(route)
        guard case .matte(let matte, _) = try await invoke(route, params: ["kind": "softAlpha"], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no matte.")
        }
        let mask = try Media.mask(matte, width: input.width, height: input.height)
        let wanted = Set(context.param("outputs")?.arrayValue?.compactMap(\.stringValue) ?? ["mask", "extract"])
        var outputs: [ProducedOutput] = []
        if wanted.contains("mask") { outputs.append(try write(mask, name: "mask")) }
        if wanted.contains("extract") {
            let url = context.outputDirectory.appendingPathComponent("extract-0.png")
            let cut = Media.extract(input, alpha: mask)
            try Media.encode(cut.cgImage, mediaType: "image/png").write(to: url)          // alpha needs PNG
            outputs.append(.file(url, name: "extract", kind: .image, mediaType: "image/png", width: cut.width, height: cut.height))
        }
        return outputs
    }

    mutating func segment() async throws -> [ProducedOutput] {
        let input = try load("image")
        guard let points = context.input("points")?.data?.arrayValue, !points.isEmpty else {
            throw NormalizerError.input("image.segment needs points: [{x, y, label}] with x and y in 0…1.")
        }
        let pixels: [MESValue] = points.map { p in
            [.number((p["x"]?.numberValue ?? 0) * Double(input.width)), .number((p["y"]?.numberValue ?? 0) * Double(input.height))]
        }
        let labels: [MESValue] = points.map { .number($0["label"]?.stringValue == "exclude" ? 0 : 1) }
        let route = try await route(.promptSegment)
        record(route)
        guard case .matte(let matte, let score) = try await invoke(route, params: ["points": .array(pixels), "pointLabels": .array(labels)],
                                                                   inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no mask.")
        }
        if let score { modelParams["score"] = .number(Double(score)) }
        return [try write(try Media.mask(matte, width: input.width, height: input.height), name: "masks")]
    }

    mutating func describe() async throws -> [ProducedOutput] {
        let input = try load("image")
        let language = context.param("language")?.stringValue ?? "en"
        let route = try await route(.imageAnalysis)
        record(route)
        let question = Describe.prompt + (language == "en" ? "" : " Write the caption and alt text in the language with code \(language).")
        guard case .text(let reply) = try await invoke(route, params: ["prompt": .string(question)], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no text.")
        }
        var value = Describe.parse(reply)
        value["language"] = .string(language)
        return [.data(.object(value), name: "description")]
    }

    mutating func score() async throws -> [ProducedOutput] {
        let input = try load("image")
        let route = try await route(.imageQualityScore)
        record(route)
        guard case .score(let raw, _) = try await invoke(route, params: [:], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no score.")
        }
        let r = Double(raw.description) ?? Double(raw)          // the Float's own digits, not its binary widening
        let value: MESValue = ["score": .number(min(1, max(0, r))), "scale": .string("\(route.id): 0 (worst) to 1 (best)"),
                               "raw": .number(r)]
        return [.data(value, name: "score")]
    }

    /// The model-specific detail of a run (Base §10.1: `effective.model_params`).
    mutating func record(_ route: ModelRoute) {
        modelParams["model"] = .string(route.id)
        // provenance.model.revision: the weights' pinned commit, when the model's manifest pins one.
        if route.id == context.model.id, let revision = Self.pinned(route.revision) { revisions[context.model.id] = revision }
        if let steps = route.defaults.steps { modelParams["steps"] = .number(Double(steps)) }
        if let guidance = route.defaults.guidance { modelParams["guidance"] = .number(guidance) }
    }
}

/// Hands the runtime's synchronous progress callbacks to the job's async reporter, in order.
final class ProgressRelay: Sendable {
    typealias Update = (stage: Stage, step: Int?, steps: Int?, fraction: Double?, message: String?)
    private let continuation: AsyncStream<Update>.Continuation
    private let task: Task<Void, Never>

    init(_ reporter: RunReporter) {
        let (stream, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        task = Task {
            for await u in stream { await reporter.progress(u.stage, step: u.step, steps: u.steps, fraction: u.fraction, message: u.message) }
        }
    }

    func send(_ stage: Stage, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil, message: String? = nil) {
        continuation.yield((stage, step, steps, fraction, message))
    }

    func finish() async {
        continuation.finish()
        await task.value
    }
}

/// Erasing by name (AB-T-0220): the removal gate's question to Mage-VL, its instruction to the editor, and how a
/// handed-back object is recognised.
enum Erase {
    static let namePrompt = "What is the object inside the red box? Reply with only a short noun phrase of one to four words "
        + "that names it, with no other text."

    static func instruction(_ name: String) -> String {
        "Remove the \(name) and its shadow and reflection. Keep everything else unchanged."
    }

    /// Below this mean change inside the mask (0–255 over RGB), the editor handed the object back. Calibrated on the
    /// removal gate's 287 Edit-Turbo outputs: it catches 19 of the 21 objects left in place and flags 8 of the 266
    /// removals, each of which costs one retry.
    static let handedBack = 18.0

    /// The namer's reply as a noun phrase: its first line, without quotes, a full stop or a leading article. A reply
    /// that isn't one (empty, or over six words) names nothing in particular.
    static func objectName(_ reply: String) -> String {
        var name = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .!\"'`*"))
        for article in ["a ", "an ", "the "] where name.lowercased().hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        let words = name.split(separator: " ").count
        return words == 0 || words > 6 ? "object" : name
    }
}

/// Asking a vision-language model for a library description, and reading its answer.
enum Describe {
    static let prompt = """
        Describe this image. Reply with JSON only, no other text:
        {"caption": "one sentence: the subject, the setting and the style", \
        "alt_text": "a short description for a screen reader, under 125 characters", \
        "tags": ["5 to 12 lowercase keywords: subjects, objects, setting, style, mood, main colours"]}
        """

    /// The reply → the profile's `description` (caption, alt text, lowercase tags). A reply that isn't JSON still
    /// yields a caption, so a chatty model isn't a failed job.
    static func parse(_ reply: String) -> [String: MESValue] {
        struct Reply: Decodable { var caption: String?; var alt_text: String?; var tags: [String]? }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: Reply?
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            parsed = try? JSONDecoder().decode(Reply.self, from: Data(text[open...close].utf8))
        }
        let caption = parsed?.caption ?? String(text.prefix { $0 != "\n" }.prefix(400))
        let tags = (parsed?.tags ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        return ["caption": .string(caption), "alt_text": .string(String((parsed?.alt_text ?? caption).prefix(250))),
                "tags": .array(tags.map { .string($0) })]
    }
}
