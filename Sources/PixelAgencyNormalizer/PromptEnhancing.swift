import Foundation

/// The prompt enhancer behind `prompt_enhance` (Image §1.9), supplied by the normalizer's caller: model profiles that
/// rewrite a short prompt into the caption a model was trained on, on a text backbone the host routes as `.llm`.
///
/// The normalizer decides when to call it (the mode, the licence policy, the backbone being offered), routes, prepares and
/// releases the backbone, and reports the outcome. The enhancer owns the profiles and the rewrite. Pixel Agency's engines
/// supply prompt-enhance-kit's image profiles; Gaea, its LLM plugin's.
public protocol PromptEnhancing: Sendable {
    /// The backbones, small first: model ids the host routes as `.llm`. The first is the default.
    var backboneIDs: [String] { get }
    /// Every profile.
    var profiles: [PromptProfile] { get }
    /// The profile for `model`, or nil when it has none.
    func profile(forModel model: String) -> PromptProfile?
    /// What becomes of `prompt` without calling a backbone, or nil when the rewrite would call one (`always`: the
    /// request's `prompt_enhance: on`). It reads only the prompt and the profile, so the backbone loads only when needed.
    func skip(_ prompt: String, profile: PromptProfile, task: PromptTask, always: Bool) -> PromptOutcome?
    /// Rewrites `prompt` with `profile` on `backbone`, which the normalizer routed and prepared. `targetSize` is the size a
    /// structured profile lays out for (nil for prose). Rethrows cancellation; any other failure is an outcome.
    func enhance(_ prompt: String, profile: PromptProfile, task: PromptTask, always: Bool,
                 targetSize: (width: Int, height: Int)?, seed: UInt64, timeout: Duration,
                 backbone: ModelRoute) async throws -> PromptRewrite
}

/// One model profile, as the normalizer reads it.
public struct PromptProfile: Sendable, Equatable {
    public enum Policy: String, Sendable {
        /// Its makers require a rewrite.
        case required
        /// Its makers recommend one: `auto` rewrites a prompt that isn't already detailed.
        case recommended
        /// Prompts go as typed unless the request says `on`.
        case optional
    }

    public var id: String
    public var version: Int
    public var title: String
    /// The models it rewrites for.
    public var models: [String]
    public var policy: Policy
    /// It answers JSON (SenseNova U1.5's Render JSON, MOSS-Image's layouts), not prose.
    public var structured: Bool
    /// Its answer suggests a size (SenseNova's canvas): it's told the size the request asked for.
    public var suggestsSize: Bool
    /// It lays out a canvas (MOSS-Image): it's always told a size, and the job runs at exactly it.
    public var laysOutCanvas: Bool
    /// The backbone it runs on (one of `PromptEnhancing.backboneIDs`).
    public var backbone: String
    /// It runs on a large backbone (structured answers of 1,000–2,000 tokens): `structuredPromptEnhanceTimeout` applies.
    public var large: Bool

    public init(id: String, version: Int, title: String, models: [String], policy: Policy, structured: Bool = false,
                suggestsSize: Bool = false, laysOutCanvas: Bool = false, backbone: String, large: Bool = false) {
        self.id = id; self.version = version; self.title = title; self.models = models; self.policy = policy
        self.structured = structured; self.suggestsSize = suggestsSize; self.laysOutCanvas = laysOutCanvas
        self.backbone = backbone; self.large = large
    }
}

/// What a rewrite is for.
public enum PromptTask: String, Sendable {
    case textToImage
    /// An edit's instruction: its rewriter would need to see the image.
    case imageEdit

    public var needsVision: Bool { self == .imageEdit }
}

/// An enhancer's outcome, as `effective.model_params.prompt_enhancement.outcome` reports it.
public enum PromptOutcome: String, Sendable {
    case enhanced
    case passedThrough = "passed_through"
    case notRecommended = "not_recommended"
    case noInstruction = "no_instruction"
    case needsVision = "needs_vision"
    case failed
    case timedOut = "timed_out"
    case empty
}

/// The size a structured rewrite suggested.
public struct SuggestedSize: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    /// `W:H`.
    public var aspectRatio: String?

    public init(width: Int? = nil, height: Int? = nil, aspectRatio: String? = nil) {
        self.width = width; self.height = height; self.aspectRatio = aspectRatio
    }

    /// Width over height, from the aspect or the size.
    public var ratio: Double? {
        if let aspect = aspectRatio {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        }
        if let width, let height, height > 0 { return Double(width) / Double(height) }
        return nil
    }
}

/// The canvas a layout was laid out for, in pixels.
public struct CanvasSize: Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// What a rewrite made of a prompt.
public struct PromptRewrite: Sendable, Equatable {
    /// The text to run: the rewrite, or the prompt as typed.
    public var prompt: String
    public var outcome: PromptOutcome
    /// How many times the backbone was asked: 2 when a profile's compiler rejected its first draft.
    public var attempts: Int
    /// Why it failed, for the log.
    public var failure: String?
    public var suggestedSize: SuggestedSize?
    public var canvas: CanvasSize?

    public init(prompt: String, outcome: PromptOutcome, attempts: Int = 1, failure: String? = nil,
                suggestedSize: SuggestedSize? = nil, canvas: CanvasSize? = nil) {
        self.prompt = prompt; self.outcome = outcome; self.attempts = attempts; self.failure = failure
        self.suggestedSize = suggestedSize; self.canvas = canvas
    }

    public var applied: Bool { outcome == .enhanced }
}
