import Foundation
import MESCore

/// The models behind the normalizer, supplied by its caller: what the normalizer lists, routes, prepares and runs. The
/// normalizer decides what each operation asks of which capability and applies the Image profile's rules to what comes
/// back; the host decides how a model runs.
///
/// - **Pixel Agency's engines** run models in process: mlx-image-runtime's directory and runner over MLXEngine and
///   ForgeCore (pixel-agency-image-engine's `RuntimeModelHost`, Pixel Agency Desktop's built-in engine).
/// - **Gaea** runs them in plugin processes: each model is a plugin offer, and helpers (the defect detector, the namer,
///   the prompt enhancer's backbone) are offers too.
///
/// Residency (`residentPackages`, `evict`, `fit`, `footprints`) is how the normalizer keeps one heavy model in memory at
/// a time (`Residency`). A host whose own scheduler owns memory keeps the defaults: nothing resident, nothing evicted.
///
/// Errors: throw `MESError` where the MES code matters (`policy_unmet`, `no_capacity`, `out_of_limits`,
/// `model_unavailable`, `unsupported_parameter`); anything else reaches the client as `engine_error`. Cancellation must
/// reach the model: `prepare` and `run` await it directly.
public protocol ModelHost: Sendable {
    /// Every model the host registered, with its state.
    func models() async -> [ModelCard]
    /// One model by id.
    func model(_ id: String) async -> ModelCard?
    /// The model to run for `capability`: `model` when named, else the host's default (permissive and production) for it.
    func route(_ capability: ModelCapability, model: String?) async throws -> ModelRoute
    /// Downloads and loads `route` before it runs. `progress` reports phases (`downloading`, `loading`) and fractions.
    func prepare(_ route: ModelRoute, progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    /// One model invocation.
    func run(_ work: ModelWork, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ModelResult

    /// The packages loaded now (`ModelRoute.packageID`).
    func residentPackages() async -> Set<String>
    /// Releases `packageID` from memory.
    func evict(packageID: String) async
    /// Whether loading `route` now fits the machine, or nil when unknown.
    func fit(_ route: ModelRoute) async -> ModelFit?
    /// Each package's declared resident bytes.
    func footprints() async -> [String: UInt64]
    /// The model a package serves, for `ImageNormalizer.residentModels`.
    func modelID(forPackage packageID: String) async -> String?
}

extension ModelHost {
    public func model(_ id: String) async -> ModelCard? { await models().first { $0.id == id } }
    public func residentPackages() async -> Set<String> { [] }
    public func evict(packageID: String) async {}
    public func fit(_ route: ModelRoute) async -> ModelFit? { nil }
    public func footprints() async -> [String: UInt64] { [:] }
    public func modelID(forPackage packageID: String) async -> String? { nil }
}

/// What a model does, by MLXEngine's capability names (MLXToolKit `Capability` raw values), so a host maps by `rawValue`.
public struct ModelCapability: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let textToImage = Self("textToImage")
    public static let imageEdit = Self("imageEdit")
    public static let imageInpaint = Self("imageInpaint")
    public static let imageUpscale = Self("imageUpscale")
    public static let imageRestore = Self("imageRestore")
    public static let imageRelight = Self("imageRelight")
    public static let imageColorize = Self("imageColorize")
    public static let matting = Self("matting")
    public static let promptSegment = Self("promptSegment")
    public static let imageAnalysis = Self("imageAnalysis")
    public static let imageQualityScore = Self("imageQualityScore")
    public static let defectDetect = Self("defectDetect")
    /// A text model: the prompt enhancer's backbone.
    public static let llm = Self("llm")
}

/// One model the host offers, as the normalizer reads it: what it does, its terms, the sizes it serves and its state.
public struct ModelCard: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var capabilities: [ModelCapability]
    public var maturity: Maturity
    public var license: License
    /// The Hugging Face repo its weights come from (`termsURL`), or empty.
    public var sourceRepo: String
    /// The weights' revision: a pinned commit (40 hex digits) is reported in provenance.
    public var revision: String
    public var envelope: Envelope
    public var defaults: Defaults
    /// Declared resident bytes at the configured quant.
    public var footprintBytes: UInt64?
    /// Its weights are here.
    public var downloaded: Bool
    /// Why it can't run on this machine, or nil.
    public var problem: String?
    /// The package keys a request may set per run (`ModelWork.metaData`), e.g. FLUX 3 Klein's `upsample`.
    public var requestKeys: [String]
    /// The adapters (LoRA) it takes; empty when none.
    public var adapters: [Adapter]

    public init(id: String, displayName: String, capabilities: [ModelCapability], maturity: Maturity = .prod,
                license: License, sourceRepo: String = "", revision: String = "", envelope: Envelope,
                defaults: Defaults = .init(), footprintBytes: UInt64? = nil, downloaded: Bool = false,
                problem: String? = nil, requestKeys: [String] = [], adapters: [Adapter] = []) {
        self.id = id; self.displayName = displayName; self.capabilities = capabilities; self.maturity = maturity
        self.license = license; self.sourceRepo = sourceRepo; self.revision = revision; self.envelope = envelope
        self.defaults = defaults; self.footprintBytes = footprintBytes; self.downloaded = downloaded
        self.problem = problem; self.requestKeys = requestKeys; self.adapters = adapters
    }

    /// Chosen when a request names no model: permissive and production. Others run only when named.
    public var isDefaultRoutable: Bool { license.licenseClass == .permissive && maturity == .prod }

    public enum Maturity: String, Sendable, Codable {
        /// Published and validated.
        case prod
        /// Work in progress: runs only when named.
        case wip
    }

    /// The licence facts the normalizer turns into MES terms (`ImageNormalizer.license`).
    public struct License: Sendable, Equatable, Hashable {
        public enum Class: String, Sendable, Codable {
            /// Every weight licence and the code's are permissive: commercial use allowed.
            case permissive
            /// Evaluation use only.
            case evalAcknowledged
            /// Research-only or non-commercial terms.
            case restricted
        }

        public var licenseClass: Class
        /// SPDX ids (or `LicenseRef-…`) of the weights.
        public var weightLicenses: [String]

        public init(_ licenseClass: Class, weights: [String]) {
            self.licenseClass = licenseClass; self.weightLicenses = weights
        }
    }

    /// The largest request a model is measured to serve.
    public struct Envelope: Sendable, Equatable {
        public var maxPixels: Int
        public var multipleOf: Int
        public var maxInputs: Int
        /// The model only renders square images (Mage-Flow).
        public var requiresSquare: Bool

        public init(maxPixels: Int, multipleOf: Int = 16, maxInputs: Int = 1, requiresSquare: Bool = false) {
            self.maxPixels = maxPixels; self.multipleOf = multipleOf; self.maxInputs = maxInputs
            self.requiresSquare = requiresSquare
        }

        /// Floors to the multiple, then checks the area (and squareness). nil when outside the envelope.
        public func fit(width: Int, height: Int) -> (width: Int, height: Int)? {
            let w = (width / multipleOf) * multipleOf
            let h = (height / multipleOf) * multipleOf
            guard w >= multipleOf, h >= multipleOf, w * h <= maxPixels, !requiresSquare || w == h else { return nil }
            return (w, h)
        }

        /// The largest size with this aspect ratio that fits. Square-only models get the largest square no bigger than
        /// the request's shorter side.
        public func clamp(width: Int, height: Int) -> (width: Int, height: Int) {
            if requiresSquare {
                let side = min(min(width, height), Int(Double(maxPixels).squareRoot()))
                let s = max(multipleOf, (side / multipleOf) * multipleOf)
                return (s, s)
            }
            if let fitted = fit(width: width, height: height) { return fitted }
            let scale = (Double(maxPixels) / Double(max(1, width * height))).squareRoot()
            let w = max(multipleOf, (Int(Double(width) * scale) / multipleOf) * multipleOf)
            let h = max(multipleOf, (Int(Double(height) * scale) / multipleOf) * multipleOf)
            return (w, h)
        }
    }

    /// A generative model's defaults: its size when a request names none, its steps and guidance (provenance).
    public struct Defaults: Sendable, Equatable {
        public var steps: Int?
        /// Classifier-free guidance: above 1, the model takes a negative prompt.
        public var guidance: Double?
        public var width: Int
        public var height: Int

        public init(steps: Int? = nil, guidance: Double? = nil, width: Int = 1024, height: Int = 1024) {
            self.steps = steps; self.guidance = guidance; self.width = width; self.height = height
        }
    }

    /// One adapter (LoRA) the model takes, with what an offer and a run need of it.
    public struct Adapter: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// `plain` (a weight delta) or `ic` (reference-conditioned: it takes `conditioning` images).
        public var kind: String
        public var capabilities: [ModelCapability]
        /// Text the prompt must contain for the adapter to fire.
        public var trigger: String?
        /// The adapter's canonical prompt; without a `{prompt}` placeholder, the prompt for a request that has none.
        public var promptTemplate: String?
        /// Its own licence, an SPDX id.
        public var license: String
        /// `allowed`, `conditional`, `prohibited` or `unknown`.
        public var commercialUse: String
        /// The operator accepts its terms before it's offered.
        public var licenseGated: Bool
        public var notice: String?
        public var licenseURL: String?
        public var defaultStrength: Double
        public var strengthMin: Double?
        public var strengthMax: Double?
        /// An `ic` adapter's ordered slots.
        public var conditioning: [Slot]
        /// Registry status: `verified`, `candidate`, … (`withdrawn` and `broken` are never offered).
        public var status: String
        /// The file's size, for a download preview.
        public var bytes: UInt64?

        public struct Slot: Sendable, Equatable {
            public var role: String
            /// The MES kind it takes (`image`, `mask`).
            public var media: String
            public var required: Bool
            public var note: String?

            public init(role: String, media: String = "image", required: Bool = true, note: String? = nil) {
                self.role = role; self.media = media; self.required = required; self.note = note
            }
        }

        public init(id: String, title: String, kind: String = "plain", capabilities: [ModelCapability],
                    trigger: String? = nil, promptTemplate: String? = nil, license: String, commercialUse: String,
                    licenseGated: Bool = false, notice: String? = nil, licenseURL: String? = nil, defaultStrength: Double = 1,
                    strengthMin: Double? = nil, strengthMax: Double? = nil, conditioning: [Slot] = [],
                    status: String = "verified", bytes: UInt64? = nil) {
            self.id = id; self.title = title; self.kind = kind; self.capabilities = capabilities; self.trigger = trigger
            self.promptTemplate = promptTemplate; self.license = license; self.commercialUse = commercialUse
            self.licenseGated = licenseGated; self.notice = notice; self.licenseURL = licenseURL
            self.defaultStrength = defaultStrength; self.strengthMin = strengthMin; self.strengthMax = strengthMax
            self.conditioning = conditioning; self.status = status; self.bytes = bytes
        }
    }
}

/// The model the host chose to run for one capability.
public struct ModelRoute: Sendable, Equatable {
    public var id: String
    /// What residency loads and evicts: one package may serve several models.
    public var packageID: String
    public var capability: ModelCapability
    public var displayName: String
    public var license: ModelCard.License
    public var envelope: ModelCard.Envelope
    public var defaults: ModelCard.Defaults
    public var revision: String
    public var footprintBytes: UInt64?
    /// The package keys this capability takes per request.
    public var requestKeys: [String]
    /// What its surface accepts of adapters, or nil when it takes none.
    public var adapterSupport: AdapterSupport?
    /// The pinned commit of each adapter file it would load, by adapter id (provenance.adapters).
    public var adapterRevisions: [String: String]

    public init(id: String, packageID: String, capability: ModelCapability, displayName: String,
                license: ModelCard.License, envelope: ModelCard.Envelope, defaults: ModelCard.Defaults = .init(),
                revision: String = "", footprintBytes: UInt64? = nil, requestKeys: [String] = [],
                adapterSupport: AdapterSupport? = nil, adapterRevisions: [String: String] = [:]) {
        self.id = id; self.packageID = packageID; self.capability = capability; self.displayName = displayName
        self.license = license; self.envelope = envelope; self.defaults = defaults; self.revision = revision
        self.footprintBytes = footprintBytes; self.requestKeys = requestKeys; self.adapterSupport = adapterSupport
        self.adapterRevisions = adapterRevisions
    }

    /// Whether this model takes the package key `name` per request.
    public func takes(_ name: String) -> Bool { requestKeys.contains(name) }

    /// How many adapters a surface stacks, of which kinds, at which strengths.
    public struct AdapterSupport: Sendable, Equatable {
        /// `plain`, `ic`.
        public var kinds: [String]
        public var maxCount: Int
        public var strengthMin: Double
        public var strengthMax: Double

        public init(kinds: [String], maxCount: Int, strengthMin: Double, strengthMax: Double) {
            self.kinds = kinds; self.maxCount = maxCount; self.strengthMin = strengthMin; self.strengthMax = strengthMax
        }
    }
}

/// One model invocation.
public struct ModelWork: Sendable {
    public var route: ModelRoute
    /// The package's mode, e.g. `fast` (MI-GAN on the inpainting package) or `tiles` (Mage's batch).
    public var mode: String?
    /// The capability's params: `prompt`, `negativePrompt`, `strength`, `scale`, `kind`, `points`, … as the package names them.
    public var params: [String: JSONValue]
    /// Images by input name: `image`, `images`, `mask`, and an IC adapter's `adapter<n>.<role>`.
    public var inputs: [String: [ModelImage]]
    /// Package keys the route declares (`ModelRoute.requestKeys`).
    public var metaData: [String: JSONValue]?
    public var adapters: [Adapter]?
    public var seed: UInt64
    public var width: Int?
    public var height: Int?
    /// Which of a job's outputs this is.
    public var outputIndex: Int

    public init(route: ModelRoute, mode: String? = nil, params: [String: JSONValue] = [:], inputs: [String: [ModelImage]] = [:],
                metaData: [String: JSONValue]? = nil, adapters: [Adapter]? = nil, seed: UInt64 = 0, width: Int? = nil,
                height: Int? = nil, outputIndex: Int = 0) {
        self.route = route; self.mode = mode; self.params = params; self.inputs = inputs; self.metaData = metaData
        self.adapters = adapters; self.seed = seed; self.width = width; self.height = height; self.outputIndex = outputIndex
    }

    /// An adapter for this run.
    public struct Adapter: Sendable, Equatable {
        public var id: String
        /// nil: the adapter's default.
        public var strength: Double?
        /// An `ic` adapter's slots: role → the `inputs` entry holding its image.
        public var conditioning: [String: String]

        public init(id: String, strength: Double? = nil, conditioning: [String: String] = [:]) {
            self.id = id; self.strength = strength; self.conditioning = conditioning
        }
    }
}

/// What one invocation produced.
public enum ModelResult: Sendable {
    case image(ModelImage)
    /// An upscale through an enhancer (a generative tier behind a text guard, a chain), with what ran.
    case upscaled(ModelImage, model: String)
    case matte(ModelMatte, score: Float?)
    case score(Float, subscores: [String: Float])
    /// A vision-language model's reply.
    case text(String)
}

/// An image crossing the seam: PNG or JPEG bytes, or raw pixels.
public struct ModelImage: Sendable, Equatable {
    public enum Format: String, Sendable, Codable {
        case png, jpeg
        /// Raw interleaved BGRA8, premultiplied: `width` and `height` required, `bytesPerRow` defaults to `width * 4`.
        case rawBGRA8
        /// Raw interleaved RGBA, 16 bits per component, little-endian, sRGB, premultiplied: `width` and `height`
        /// required, `bytesPerRow` defaults to `width * 8`.
        case rawRGBA16
    }

    public var format: Format
    public var data: Data
    public var width: Int?
    public var height: Int?
    public var bytesPerRow: Int?

    public init(format: Format, data: Data, width: Int? = nil, height: Int? = nil, bytesPerRow: Int? = nil) {
        self.format = format; self.data = data; self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
    }

    /// Raw 16-bit RGBA pixels, tightly packed unless `bytesPerRow` says otherwise.
    public static func rawRGBA16(data: Data, width: Int, height: Int, bytesPerRow: Int? = nil) -> ModelImage {
        ModelImage(format: .rawRGBA16, data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }
}

/// A single-channel coverage map as a grayscale PNG (0 background … 1 foreground).
public struct ModelMatte: Sendable, Equatable {
    public var data: Data
    public var width: Int?
    public var height: Int?

    public init(data: Data, width: Int? = nil, height: Int? = nil) {
        self.data = data; self.width = width; self.height = height
    }
}

/// A host's progress report.
public struct ModelProgress: Sendable, Equatable {
    /// `downloading`, `loading`, `waiting_for_memory`, or a model's own phase while it runs.
    public var phase: String
    public var fraction: Double?
    public var step: Int?
    public var totalSteps: Int?
    /// A staged report (tile k of n in one call).
    public var stage: Int?
    public var totalStages: Int?

    public init(phase: String, fraction: Double? = nil, step: Int? = nil, totalSteps: Int? = nil, stage: Int? = nil,
                totalStages: Int? = nil) {
        self.phase = phase; self.fraction = fraction; self.step = step; self.totalSteps = totalSteps; self.stage = stage
        self.totalStages = totalStages
    }
}

/// Whether a model fits the machine's memory now.
public struct ModelFit: Sendable, Equatable {
    /// It fits what's available now.
    public var fits: Bool
    public var message: String
    /// Its projected peak: weights at the residency the host chose, plus activation.
    public var projectedPeakBytes: UInt64?
    /// The engine's memory budget.
    public var budgetBytes: UInt64?

    public init(fits: Bool, message: String, projectedPeakBytes: UInt64? = nil, budgetBytes: UInt64? = nil) {
        self.fits = fits; self.message = message; self.projectedPeakBytes = projectedPeakBytes; self.budgetBytes = budgetBytes
    }

    /// Whether the projected peak fits the budget at all, once idle models are released; nil when unknown.
    public var fitsBudget: Bool? {
        guard let projectedPeakBytes, let budgetBytes else { return nil }
        return projectedPeakBytes <= budgetBytes
    }
}
