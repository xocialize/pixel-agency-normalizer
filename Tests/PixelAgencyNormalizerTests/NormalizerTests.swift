import Foundation
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
                                implementationName: "pixel-agency-normalizer", implementationVersion: "0.1.0", spoolDirectory: spool)
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

        let trigger = ModelCard.Adapter(id: "x:y", title: "Y", capabilities: [.textToImage], trigger: "mrth",
                                        license: "Apache-2.0", commercialUse: "allowed")
        #expect(Adapters.prompt("a fox", for: [trigger]) == ("mrth a fox", ["x:y"]))
        #expect(!Adapters.isOptIn(trigger) && Adapters.license(trigger).commercialUse == .yes)
    }
}
