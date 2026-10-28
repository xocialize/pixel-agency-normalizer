// swift-tools-version: 6.2
import PackageDescription

// Pixel Agency Normalizer: the host half of the MES Image profile's reference engine, as a library with no MLX in its
// graph. MES operations and vocabulary in, model runs out, the profile's rules enforced: the operation table (which
// capability serves each operation, each tier's default model, the vocabulary honoured), descriptors from the models
// on hand, validation, the default model, and each job's plan (sizes snapped, masks kept exact, ×scale exact, alpha
// re-applied, 16 bits, adapters, prompt enhancement, the creative upscale).
//
// Its caller supplies the models: a `ModelHost` (list, route, prepare, run) and, for prompt enhancement, a
// `PromptEnhancing`. pixel-agency-image-engine and Pixel Agency Desktop's built-in engine host models in process over
// mlx-image-runtime; Gaea hosts them in plugin processes.
let package = Package(
    name: "PixelAgencyNormalizer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PixelAgencyNormalizer", targets: ["PixelAgencyNormalizer"]),
    ],
    dependencies: [
        // MES ≥ 0.4.0: first-class adapters (Base §6.3), the prompt_enhance vocabulary and RunOutput.helpers (Image §1.9),
        // ic slots (Image §1.10), ModelEnablement. MESCore and MESEngineCore only: no server, no UI.
        .package(url: "https://github.com/xocialize/media-engine-spec.git", from: "0.4.0"),
    ],
    targets: [
        .target(name: "PixelAgencyNormalizer", dependencies: [
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESEngineCore", package: "media-engine-spec"),
        ]),
        // The tests serve the normalizer over a fake host and run MES's conformance suite against it: still no MLX.
        .testTarget(name: "PixelAgencyNormalizerTests", dependencies: [
            "PixelAgencyNormalizer",
            .product(name: "MESCore", package: "media-engine-spec"),
            .product(name: "MESEngineCore", package: "media-engine-spec"),
            .product(name: "MESEngineKit", package: "media-engine-spec"),
            .product(name: "MESConformance", package: "media-engine-spec"),
        ]),
    ]
)
