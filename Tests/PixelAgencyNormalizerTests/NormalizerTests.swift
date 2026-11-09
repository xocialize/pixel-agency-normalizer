import CoreGraphics
import Foundation
import ImageIO
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import PixelAgencyNormalizer
import Testing

// The normalizer over a host with no MLX in it: the MES conformance suite passes, and the Image profile's rules hold
// whatever the host's models return. pixel-agency-image-engine's tests run the same normalizer over mlx-image-runtime.

func config() -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("pa-normalizer-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_normalizer_test", name: "Pixel Agency Normalizer (test)",
                                implementationName: "pixel-agency-normalizer", implementationVersion: "0.2.0", spoolDirectory: spool)
    c.advertise = false
    c.sweepInterval = .milliseconds(200)
    return c
}

/// Serves a normalizer over `host` on a free loopback port, connected with the conformance suite's probe.
func withEngine(host: FakeHost = FakeHost(), enhancer: FakeEnhancer? = nil, options: ImageNormalizer.Options = .init(),
                _ body: (Probe) async throws -> Void) async throws {
    let engine = ImageNormalizer(host: host, enhancer: enhancer, options: options)
    let server = MESEngineServer(engine: engine, configuration: config())
    let (ports, continuation) = AsyncStream<Int>.makeStream()
    let app = try await server.makeApplication { port in continuation.yield(port) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService() }
        var it = ports.makeAsyncIterator()
        guard let port = await it.next() else { return }
        let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
        try await body(probe)
        group.cancelAll()
    }
}

func image(_ data: Data = Fixtures.png()) -> RequestInput { .one(.inline(mediaType: "image/png", data: data)) }

/// A picture whose left half is fully transparent.
func halfClearPNG(width: Int = 64, height: Int = 48) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return FakeHost.png(ctx.makeImage()!)
}

/// The IMAGE-014 to IMAGE-016 results of a conformance run.
func decomposeResults(_ report: ConformanceReport) -> [String: TestResult.Status] {
    Dictionary(uniqueKeysWithValues: report.results.filter { ["IMAGE-014", "IMAGE-015", "IMAGE-016"].contains($0.id) }
        .map { ($0.id, $0.status) })
}

@Suite("Pixel Agency Normalizer", .serialized)
struct NormalizerTests {
    @Test("Conformance: every applicable BASE and IMAGE test passes against the normalizer over an MLX-free host")
    func conformance() async throws {
        try await withEngine(enhancer: FakeEnhancer()) { probe in
            let report = await ConformanceRunner.run(probe)
            let failed = report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" }
            #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
            #expect(report.conformsToBase && report.conformsToImage == true)
            #expect(report.results.first { $0.id == "IMAGE-011" }?.status == .pass, "the prompt enhancer's preview runs")
            #expect(decomposeResults(report) == ["IMAGE-014": .pass, "IMAGE-015": .pass, "IMAGE-016": .pass],
                    "decompose runs on the decomposer, with its composite")
        }
    }

    @Test("Conformance: decompose on a decomposer that makes no composite refuses one (IMAGE-015's 422 branch)")
    func conformanceWithoutComposite() async throws {
        let cards = FakeHost.catalogWithoutDecomposer + [FakeHost.decomposer(maxLayers: 6, composite: false)]
        try await withEngine(host: FakeHost(cards)) { probe in
            let report = await ConformanceRunner.run(probe, only: ["IMAGE-014", "IMAGE-015", "IMAGE-016"])
            #expect(decomposeResults(report) == ["IMAGE-014": .pass, "IMAGE-015": .pass, "IMAGE-016": .pass],
                    "\(report.results.map { "\($0.id): \($0.detail ?? "")" })")
            let d = try #require(probe.descriptor("image.decompose"))
            #expect(d.outputs.map(\.name) == ["layers"])
            #expect(d.params["properties"]?["outputs"]?["items"]?["enum"] == ["layers"])
        }
    }

    @Test("decompose: hosts without a layerDecompose model (Pixel Agency's own engines) don't offer it")
    func decomposeNotOffered() async throws {
        let ops = await ImageNormalizer(host: FakeHost(FakeHost.catalogWithoutDecomposer)).descriptors()
        #expect(!ops.contains { $0.operation == "image.decompose" })
        #expect(ops.contains { $0.operation == "image.matte" })
    }

    @Test("decompose: the count from layer_count or the plan, the working bucket, layers at the input's size, the composite on request")
    func decompose() async throws {
        let host = FakeHost()
        try await withEngine(host: host) { probe in
            let d = try #require(probe.descriptor("image.decompose"))
            #expect(d.params["properties"]?["layer_count"]?["maximum"] == 12)
            #expect(d.params["properties"]?["layer_count"]?[OperationTable.maxLayerCountsKey] == ["ming-image-layer": 12])
            #expect(d.params["properties"]?["output"]?["properties"]?["media_type"]?["enum"] == ["image/png"])
            #expect(d.params["properties"]?["prompt_enhance"] == nil, "no enhancer plans layers yet")
            #expect(d.outputs.map(\.name) == ["composite", "layers"] && d.outputs.last?.max == 12)
            let plan = "Layer 1: the headline.\nLayer 2: the badge.\nLayer 3: the background."
            let job = try await probe.succeed(JobRequest(
                operation: "image.decompose", inputs: ["image": image(Fixtures.png(width: 72, height: 40)), "prompt": .text(plan)],
                params: ["quality": "draft", "outputs": ["layers", "composite"], "seed": 5]))
            let outputs = job.result?.outputs ?? []
            #expect(outputs.map(\.name) == ["layers", "layers", "layers", "composite"])
            #expect(outputs.allSatisfy { $0.width == 72 && $0.height == 40 && $0.mediaType == "image/png" })
            #expect(job.result?.effective["layer_count"] == 3)
            #expect(job.result?.effective["seed"] == 5)
            let work = try #require(host.calls.withLock { $0.last })
            #expect(work.route.capability == .layerDecompose && work.route.id == "ming-image-layer")
            #expect(work.params["prompt"]?.stringValue == plan && work.params["layerCount"] == 3 && work.params["resolution"] == 512)
            #expect(work.seed == 5)
            #expect(job.warnings.isEmpty)

            // No count and no plan: the model's own; standard is the model's own bucket; layers only by default.
            let plain = try await probe.succeed(JobRequest(operation: "image.decompose", inputs: ["image": image()],
                                                           params: ["layer_count": 5]))
            #expect(plain.result?.outputs.map(\.name) == Array(repeating: "layers", count: 5))
            #expect(plain.result?.effective["layer_count"] == 5)
            let last = try #require(host.calls.withLock { $0.last })
            #expect(last.params["resolution"] == nil && last.params["prompt"] == nil && last.params["layerCount"] == 5)
        }
    }

    @Test("decompose: transparent input pixels stay transparent in every layer, with alpha_reapplied")
    func decomposeAlpha() async throws {
        try await withEngine { probe in
            let job = try await probe.succeed(JobRequest(operation: "image.decompose", inputs: ["image": image(halfClearPNG())],
                                                         params: ["layer_count": 2]))
            #expect(job.warnings.map(\.code) == ["alpha_reapplied"])
            for output in job.result?.outputs ?? [] {
                let layer = try DecodedImage(try await probe.output(job, output.index).1)
                #expect(layer.hasAlpha && layer.width == 64)
                // The background layer covered everything; its left half is clear now, its right half not.
                let alpha = { (x: Int, y: Int) in layer.rgba[(y * layer.width + x) * 4 + 3] }
                #expect(alpha(5, 20) == 0)
                if output.index == 1 { #expect(alpha(50, 20) == 255) }
            }
        }
    }

    @Test("decompose refuses: a plan contradicting layer_count (400), above the maximum (422), a named model's limits (422); a missed count fails")
    func decomposeRefusals() async throws {
        let cards = FakeHost.catalog + [FakeHost.decomposer("small-layer", maxLayers: 4, composite: false)]
        try await withEngine(host: FakeHost(cards)) { probe in
            let schemas = probe.schemas
            func post(_ params: [String: JSONValue], prompt: String? = nil, model: String? = nil) async throws -> Wire.Reply {
                var inputs: [String: RequestInput] = ["image": image()]
                if let prompt { inputs["prompt"] = .text(prompt) }
                return try await probe.wire.json("POST", "jobs", JobRequest(operation: "image.decompose", inputs: inputs,
                                                                            params: params, model: model))
            }
            try expect(try await post(["layer_count": 2], prompt: "Decompose this image into 3 layers."), 400,
                       code: "invalid_request", "a plan of 3 against layer_count 2", schemas: schemas)
            try expect(try await post([:], prompt: "Number of layers: 13"), 422, code: "out_of_limits", "a plan of 13", schemas: schemas)
            try expect(try await post(["layer_count": 13]), 422, code: "out_of_limits", "layer_count 13", schemas: schemas)
            try expect(try await post(["layer_count": 6], model: "small-layer"), 422, code: "out_of_limits",
                       "6 layers from a model allowing 4", schemas: schemas)
            try expect(try await post(["outputs": ["layers", "composite"]], model: "small-layer"), 422,
                       code: "unsupported_parameter", "a composite from a model making none", schemas: schemas)
            try expect(try await post(["outputs": ["composite"]]), 400, code: "invalid_request", "outputs without layers",
                       schemas: schemas)
            // Unnamed, 6 layers runs on the model that allows them.
            let six = try await probe.succeed(JobRequest(operation: "image.decompose", inputs: ["image": image()], params: ["layer_count": 6]))
            #expect(six.result?.provenance.model.id == "ming-image-layer")
        }
        try await withEngine(host: FakeHost(extraLayers: 1)) { probe in
            let job = try await probe.run(JobRequest(operation: "image.decompose", inputs: ["image": image()], params: ["layer_count": 3]))
            #expect(job.error?.code == MESErrorCode.engineError.rawValue)
        }
    }

    @Test("Descriptors come from the host: research models are left out, each operation's measured default is the default")
    func descriptors() async throws {
        let ops = await ImageNormalizer(host: FakeHost()).descriptors()
        let generate = try #require(ops.first { $0.operation == "image.generate" })
        #expect(generate.models.first { $0.isDefault == true }?.id == "z-image-turbo")
        #expect(!generate.models.contains { $0.id == "qwen-image-2.1" })
        #expect(ops.first { $0.operation == "image.upscale" }?.models.first { $0.isDefault == true }?.id == "realplksr-upscale")
        // No enhancer: no prompt_enhance, and no preview operation.
        #expect(generate.params["properties"]?[ImageProfile.Param.promptEnhance] == nil)
        #expect(!ops.contains { $0.operation == PromptEnhancement.preview })

        let research = await ImageNormalizer(host: FakeHost(), options: .init(allowResearch: true)).descriptors()
        let named = research.first { $0.operation == "image.generate" }?.models.first { $0.id == "qwen-image-2.1" }
        #expect(named?.namedOnly == true && named?.license.commercialUse == .no)
    }

    @Test("generate: the size snaps to the envelope with size_snapped; the seed is the job's; the weights' revision is provenance")
    func generate() async throws {
        let host = FakeHost()
        try await withEngine(host: host) { probe in
            let job = try await probe.succeed(JobRequest(
                operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                params: ["size": ["width": 500, "height": 300], "count": 2, "seed": 7]))
            #expect(job.warnings.map(\.code) == ["size_snapped"])
            #expect(job.result?.effective["size"] == ["width": 496, "height": 288])
            #expect(job.result?.outputs.count == 2 && job.result?.outputs.allSatisfy { $0.width == 496 && $0.height == 288 } == true)
            #expect(host.calls.withLock { $0.suffix(2).map(\.seed) } == [7, 8])
            #expect(job.result?.provenance.model.revision == String(repeating: "ab", count: 20))
        }
    }

    @Test("edit takes the first image's size; upscale is exactly ×scale; scratches detect, then inpaint")
    func plans() async throws {
        let host = FakeHost()
        try await withEngine(host: host) { probe in
            let edit = try await probe.succeed(JobRequest(operation: "image.edit",
                                                          inputs: ["images": image(Fixtures.png(width: 80, height: 48)),
                                                                   "instruction": .text("make it green")]))
            #expect(edit.result?.outputs.first?.width == 80 && edit.result?.outputs.first?.height == 48)
            let up = try await probe.succeed(JobRequest(operation: "image.upscale", inputs: ["image": image(Fixtures.png(width: 30, height: 20))],
                                                        params: ["scale": 4]))
            #expect(up.result?.outputs.first?.width == 120 && up.result?.outputs.first?.height == 80)
            _ = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()], params: ["kind": "scratches"]))
            #expect(host.calls.withLock { $0.suffix(2).map(\.route.capability) } == [.defectDetect, .imageInpaint])
        }
    }

    @Test("Prompt enhancement through the caller's enhancer: the backbone is routed, prepared and reported as a helper")
    func enhancement() async throws {
        let host = FakeHost(), enhancer = FakeEnhancer()
        try await withEngine(host: host, enhancer: enhancer) { probe in
            let job = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                                                         params: ["size": ["width": 256, "height": 256], "prompt_enhance": "on"]))
            #expect(enhancer.calls.withLock { $0 } == ["tiny-llm"])
            #expect(host.prepared.withLock { $0.first } == "tiny-llm", "the backbone loads before the image model")
            #expect(job.result?.effective["prompt"]?.stringValue == FakeEnhancer.rewrite)
            #expect(job.warnings.map(\.code).contains("prompt_rewritten"))
            #expect(host.calls.withLock { $0.last?.params["prompt"]?.stringValue } == FakeEnhancer.rewrite)
            let off = try await probe.succeed(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                                                         params: ["size": ["width": 256, "height": 256], "prompt_enhance": "off"]))
            #expect(off.result?.effective["prompt"] == nil && host.calls.withLock { $0.last?.params["prompt"] } == "a lighthouse")
        }
    }

    @Test("A host's MES error reaches the client with its code; anything else is engine_error")
    func hostErrors() async throws {
        try await withEngine(host: FakeHost(failure: MESError(.noCapacity, "busy"))) { probe in
            let job = try await probe.run(JobRequest(operation: "image.restore", inputs: ["image": image()]))
            #expect(job.error?.code == MESErrorCode.noCapacity.rawValue)
        }
        struct Odd: Error {}
        #expect((ImageNormalizer.mesError(Odd()) as? MESError)?.code == MESErrorCode.engineError.rawValue)
        #expect((ImageNormalizer.mesError(NormalizerError.input("bad")) as? MESError)?.code == MESErrorCode.inputInvalid.rawValue)
    }

    @Test("PNG outputs: an opaque picture is RGB (colour type 2) with the same pixels, at 8 and 16 bits; one transparent pixel keeps RGBA; JPEG is unchanged")
    func opaquePNGs() async throws {
        /// The PNG's bit depth and colour type, from its IHDR (signature 8, length 4, "IHDR" 4, width 4, height 4).
        func ihdr(_ png: Data) -> (bitDepth: Int, colourType: Int) {
            #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) && png[12..<16] == Data("IHDR".utf8))
            return (Int(png[24]), Int(png[25]))
        }
        func decoded(_ png: Data) throws -> (image: CGImage, hasAlpha: Bool?) {
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return (try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)), props?[kCGImagePropertyHasAlpha] as? Bool)
        }

        // 8 bits: every colour value somewhere, all opaque.
        var opaque = Pixels(width: 37, height: 23)
        for i in opaque.rgba.indices { opaque.rgba[i] = i % 4 == 3 ? 255 : UInt8((i * 37 + i / 97) % 256) }
        let rgb = Media.encode(opaque, mediaType: "image/png")
        #expect(ihdr(rgb) == (8, 2))
        let (rgbImage, rgbHasAlpha) = try decoded(rgb)
        #expect(rgbHasAlpha != true && [.none, .noneSkipLast].contains(rgbImage.alphaInfo))   // ImageIO leaves HasAlpha out
        #expect(Pixels(rgbImage) == opaque)
        #expect(rgb.count < Media.encode(opaque.cgImage, mediaType: "image/png").count)

        // One transparent pixel: still RGBA, its alpha kept, every other pixel exact.
        var holed = opaque
        holed.rgba.replaceSubrange(4 * 40..<4 * 41, with: [0, 0, 0, 0])
        let rgba = Media.encode(holed, mediaType: "image/png")
        #expect(ihdr(rgba) == (8, 6))
        let (rgbaImage, rgbaHasAlpha) = try decoded(rgba)
        #expect(rgbaHasAlpha == true)
        #expect(Pixels(rgbaImage) == holed)

        // A half-transparent pixel keeps its alpha too (its colour is re-premultiplied, so only the alpha is compared).
        var soft = opaque
        soft.rgba[4 * 7 + 3] = 128
        for c in 0..<3 { soft.rgba[4 * 7 + c] = min(soft.rgba[4 * 7 + c], 128) }
        let softPNG = Media.encode(soft, mediaType: "image/png")
        #expect(ihdr(softPNG) == (8, 6))
        #expect(Pixels(try decoded(softPNG).image).rgba[4 * 7 + 3] == 128)

        // 16 bits: an opaque picture is 16-bit RGB with the same values; a transparent one 16-bit RGBA.
        var deep = DeepPixels(width: 19, height: 11)
        for i in deep.rgba.indices { deep.rgba[i] = i % 4 == 3 ? .max : UInt16((i * 4099 + 17) % 65536) }
        #expect(deep.carriesMoreThanEightBits)
        let deepRGB = Media.encode(deep, mediaType: "image/png")
        #expect(ihdr(deepRGB) == (16, 2))
        #expect(DeepPixels(try decoded(deepRGB).image).rgba == deep.rgba)
        var deepHoled = deep
        deepHoled.rgba.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        let deepRGBA = Media.encode(deepHoled, mediaType: "image/png")
        #expect(ihdr(deepRGBA) == (16, 6))
        #expect(DeepPixels(try decoded(deepRGBA).image).rgba == deepHoled.rgba)

        // The outputs the profile defines as RGBA keep alpha even when opaque: decompose's layers, matte's extract.
        #expect(ihdr(Media.encode(opaque, mediaType: "image/png", alwaysRGBA: true)) == (8, 6))
        #expect(Pixels(try decoded(Media.encode(opaque, mediaType: "image/png", alwaysRGBA: true)).image) == opaque)

        // JPEG and TIFF are written exactly as before.
        #expect(Media.encode(opaque, mediaType: "image/jpeg") == Media.encode(opaque.cgImage, mediaType: "image/jpeg"))
        #expect(Media.encode(deep, mediaType: "image/tiff") == Media.encode(deep.cgImage, mediaType: "image/tiff"))

        // Through the engine: an opaque input's restore comes back as an RGB PNG; a half-clear one's as RGBA.
        try await withEngine { probe in
            let plain = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image()]))
            #expect(ihdr(try await probe.output(plain, 0).1) == (8, 2))
            let clear = try await probe.succeed(JobRequest(operation: "image.restore", inputs: ["image": image(halfClearPNG())]))
            let png = try await probe.output(clear, 0).1
            #expect(ihdr(png) == (8, 6))
            #expect(try DecodedImage(png).rgba[(20 * 64 + 5) * 4 + 3] == 0)
            // decompose of an opaque input: the layers stay RGBA (Image §3.2), the composite is RGB.
            let layered = try await probe.succeed(JobRequest(operation: "image.decompose", inputs: ["image": image()],
                                                             params: ["layer_count": 2, "outputs": ["layers", "composite"]]))
            #expect(Set(layered.result?.outputs.map(\.name) ?? []) == ["layers", "composite"])
            for output in layered.result?.outputs ?? [] {
                #expect(ihdr(try await probe.output(layered, output.index).1) == (8, output.name == "layers" ? 6 : 2), "\(output.name)")
            }
        }
    }

    @Test("The pieces: envelopes fit and clamp, tiles cover each axis, the namer's reply is a noun phrase, adapters' prompts")
    func pieces() {
        let envelope = ModelCard.Envelope(maxPixels: 1024 * 1024, multipleOf: 16)
        #expect(envelope.fit(width: 500, height: 300)! == (496, 288))
        #expect(envelope.fit(width: 2048, height: 2048) == nil)
        #expect(envelope.clamp(width: 2048, height: 1024) == (1440, 720))
        let square = ModelCard.Envelope(maxPixels: 1024 * 1024, requiresSquare: true)
        #expect(square.clamp(width: 900, height: 600) == (592, 592))

        let (starts, tile) = Creative.layout(3000, maxTile: 1024, overlap: 128)
        #expect(starts.first == 0 && starts.last! + tile == 3000 && tile <= 1024 && tile % 16 == 0)
        #expect(Erase.objectName("A red mug.\nIt sits on the table.") == "red mug")
        #expect(Erase.objectName("") == "object")
        #expect(Describe.parse("not json")["caption"] == "not json")
        #expect(OperationTable.statedLayerCount("Decompose this image into 4 layers. Layer 1: text.") == 4)
        #expect(OperationTable.statedLayerCount("Number of layers: 6\nLayer 1: the logo") == 6)
        #expect(OperationTable.statedLayerCount("Layer 1: the headline. Layer 2: the badge.") == 2)
        #expect(OperationTable.statedLayerCount("Split the layer 2 of the design") == nil)

        let trigger = ModelCard.Adapter(id: "x:y", title: "Y", capabilities: [.textToImage], trigger: "mrth",
                                        license: "Apache-2.0", commercialUse: "allowed")
        #expect(Adapters.prompt("a fox", for: [trigger]) == ("mrth a fox", ["x:y"]))
        #expect(!Adapters.isOptIn(trigger) && Adapters.license(trigger).commercialUse == .yes)
    }
}
