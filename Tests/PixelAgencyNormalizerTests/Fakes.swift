import CoreGraphics
import Foundation
import ImageIO
import MESCore
@testable import PixelAgencyNormalizer
import Synchronization
import UniformTypeIdentifiers

/// Models without MLX: the catalog a Pixel Agency engine would host, answering like real packages do (sizes a little off,
/// alpha dropped, mattes at their own resolution), so the normalizer's rules are what make the outputs right.
final class FakeHost: ModelHost {
    let cards: [ModelCard]
    let calls = Mutex<[ModelWork]>([])
    let prepared = Mutex<[String]>([])
    let resident = Mutex<Set<String>>([])
    /// A failure every run throws, when set.
    let failure: (any Error & Sendable)?

    init(_ cards: [ModelCard] = FakeHost.catalog, failure: (any Error & Sendable)? = nil) {
        self.cards = cards; self.failure = failure
    }

    func models() async -> [ModelCard] { cards }

    func route(_ capability: ModelCapability, model: String?) async throws -> ModelRoute {
        let card = model.map { id in cards.first { $0.id == id && $0.capabilities.contains(capability) } }
            ?? cards.first { $0.capabilities.contains(capability) && $0.isDefaultRoutable }
        guard let card else { throw MESError(.modelUnavailable, "No model \(model ?? "(default)") for \(capability).") }
        return ModelRoute(id: card.id, packageID: "fake." + card.id, capability: capability, displayName: card.displayName,
                          license: card.license, envelope: card.envelope, defaults: card.defaults, revision: card.revision,
                          footprintBytes: card.footprintBytes, requestKeys: card.requestKeys)
    }

    func prepare(_ route: ModelRoute, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        progress(ModelProgress(phase: "loading", fraction: 0.5))
        prepared.withLock { $0.append(route.id) }
        resident.withLock { _ = $0.insert(route.packageID) }
    }

    func run(_ work: ModelWork, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ModelResult {
        calls.withLock { $0.append(work) }
        if let failure { throw failure }
        progress(ModelProgress(phase: "denoise", fraction: 1, step: 1, totalSteps: 1))
        let first = work.inputs["image"]?.first ?? work.inputs["images"]?.first
        let (w, h) = first.flatMap(Self.size) ?? (64, 64)
        switch work.route.capability {
        case .textToImage:
            let shade = CGFloat(work.seed % 251) / 255
            return .image(Self.solid(work.width ?? 1024, work.height ?? 1024, red: shade, green: 0.5, blue: 1 - shade))
        case .imageEdit:
            return .image(Self.solid(max(16, w / 2), max(16, h / 2), red: 0.2, green: 0.8, blue: 0.2))   // its own size
        case .imageInpaint:
            return .image(Self.solid(w, h, red: 1, green: 0, blue: 1))
        case .imageUpscale:
            let scale = work.params["scale"]?.intValue ?? 4
            return .image(Self.solid(w * scale - 2, h * scale - 2, red: 0.5, green: 0.5, blue: 0.5))   // off by a little
        case .imageRestore, .imageRelight, .imageColorize:
            return .image(Self.solid(w, h, red: 0.3, green: 0.3, blue: 0.3))
        case .matting, .promptSegment, .defectDetect:
            return .matte(Self.greyMatte(max(8, w / 2), max(8, h / 2)), score: 0.9)
        case .imageAnalysis where work.params["prompt"]?.stringValue?.contains("red box") == true:
            return .text("A red mug.\nIt sits on the table.")
        case .imageAnalysis:
            return .text(#"Sure! {"caption": "A test card.", "alt_text": "A test card.", "tags": ["Test", "Card"]}"#)
        case .imageQualityScore:
            return .score(1.4, subscores: [:])
        default:
            throw MESError(.modelUnavailable, "The fake doesn't run \(work.route.capability).")
        }
    }

    func residentPackages() async -> Set<String> { resident.withLock { $0 } }
    func evict(packageID: String) async { resident.withLock { _ = $0.remove(packageID) } }
    func footprints() async -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: cards.map { ("fake." + $0.id, $0.footprintBytes ?? 0) })
    }
    func modelID(forPackage packageID: String) async -> String? {
        packageID.hasPrefix("fake.") ? String(packageID.dropFirst(5)) : nil
    }

    static let apache = ModelCard.License(.permissive, weights: ["Apache-2.0"])
    static let research = ModelCard.License(.restricted, weights: ["LicenseRef-Qwen-Research"])

    static func model(_ id: String, _ capabilities: [ModelCapability], license: ModelCard.License = apache,
                      maturity: ModelCard.Maturity = .prod, guidance: Double? = nil, maxPixels: Int = 2_100_000,
                      maxInputs: Int = 1, gb: Double = 2) -> ModelCard {
        ModelCard(id: id, displayName: id.capitalized, capabilities: capabilities, maturity: maturity, license: license,
                  sourceRepo: "example/\(id)", revision: String(repeating: "ab", count: 20),
                  envelope: .init(maxPixels: maxPixels, multipleOf: 16, maxInputs: maxInputs),
                  defaults: .init(steps: 4, guidance: guidance), footprintBytes: UInt64(gb * 1_073_741_824), downloaded: true)
    }

    static let catalog: [ModelCard] = [
        model("z-image-turbo", [.textToImage], guidance: 1, gb: 12),
        model("klein-4b", [.textToImage, .imageEdit], guidance: 4, maxInputs: 4, gb: 8),
        model("qwen-image-2.1", [.textToImage], license: research, guidance: 1, gb: 30),
        model("mage-flow-edit-turbo", [.imageEdit], guidance: 1, maxPixels: 1024 * 1024, maxInputs: 3, gb: 14),
        model("lama-inpaint", [.imageInpaint]),
        model("realplksr-upscale", [.imageUpscale]),
        model("nerve-upscale", [.imageUpscale]),
        model("heart-upscale", [.imageUpscale]),
        model("nafnet-restore", [.imageRestore]),
        model("defect-detect", [.defectDetect]),
        model("cidnet-relight", [.imageRelight]),
        model("ddcolor-colorize", [.imageColorize]),
        model("birefnet-matte", [.matting]),
        model("sam21-segment", [.promptSegment]),
        model("mage-vl", [.imageAnalysis]),
        model("siglip2-quality", [.imageQualityScore]),
        model("tiny-llm", [.llm]),
    ]

    static func size(_ image: ModelImage) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (cg.width, cg.height)
    }

    static func solid(_ w: Int, _ h: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> ModelImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ModelImage(format: .png, data: png(ctx.makeImage()!), width: w, height: h)
    }

    static func greyMatte(_ w: Int, _ h: Int) -> ModelMatte {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return ModelMatte(data: png(ctx.makeImage()!), width: w, height: h)
    }

    static func png(_ image: CGImage) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

/// One prose profile, for Z-Image Turbo, on the fake host's `tiny-llm`: it rewrites every prompt it's given.
final class FakeEnhancer: PromptEnhancing {
    static let rewrite = "A white lighthouse stands on a rocky headland at dusk, its lamp just lit against a violet sky."
    let calls = Mutex<[String]>([])

    var backboneIDs: [String] { ["tiny-llm"] }
    var profiles: [PromptProfile] {
        [PromptProfile(id: "z-image", version: 2, title: "Z-Image", models: ["z-image-turbo"], policy: .recommended,
                       backbone: "tiny-llm")]
    }
    func profile(forModel model: String) -> PromptProfile? { profiles.first { $0.models.contains(model) } }

    func skip(_ prompt: String, profile: PromptProfile, task: PromptTask, always: Bool) -> PromptOutcome? {
        task.needsVision ? .needsVision : nil
    }

    func enhance(_ prompt: String, profile: PromptProfile, task: PromptTask, always: Bool,
                 targetSize: (width: Int, height: Int)?, seed: UInt64, timeout: Duration,
                 backbone: ModelRoute) async throws -> PromptRewrite {
        calls.withLock { $0.append(backbone.id) }
        return PromptRewrite(prompt: Self.rewrite, outcome: .enhanced)
    }
}
