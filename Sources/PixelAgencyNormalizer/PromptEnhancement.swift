import Foundation
import MESCore
import MESEngineCore

/// Prompt enhancement (Image §1.9; AB-D-0155, E2; pixel-agency-image-engine docs/PROMPTS-AND-ADAPTERS.md §1.5): before
/// `image.generate` runs, a short prompt is rewritten into the detailed caption the model was trained on, with that
/// model's profile, on a text backbone that's a model the host routes as `.llm`. The profiles and the rewrite are the
/// caller's `PromptEnhancing`; when to rewrite, and what's reported, is decided here.
///
/// - **The vocabulary** `prompt_enhance: auto | on | off`, declared on generate and edit wherever the engine may rewrite
///   (the backbone is on, FLUX 3 Klein is offered, or an offered adapter has a trigger or template). Without it, `auto`:
///   - **auto** follows the profile's policy: a recommended profile rewrites a prompt that isn't already detailed; an
///     optional one leaves prompts alone.
///   - **on** rewrites whenever the profile can (a prompt that's already JSON still goes as typed).
///   - **off** sends the text as typed, adapters' triggers and templates included.
/// - **Never engine-written prompts.** Only the request's own prompt passes through here: fill and extend's marker
///   instructions, erase by name and the creative upscale's instruction go to their models as written.
/// - **Reproducible.** The enhancer's seed is the job's, so a job with a fixed seed reproduces end to end.
/// - **Honest results.** A rewrite warns `prompt_rewritten`; the text the model received is `effective.prompt` (or
///   `effective.instruction`); `effective.prompt_enhance` is the mode that applied; the backbone is a helper in
///   `provenance.helpers` with the role `prompt_enhance`. `effective.model_params.prompt_enhancement` keeps the detail:
///   the profile, its version, the outcome, the backbone and the seed.
/// - **Licence policy.** Under `policy.license: commercial-use` a backbone whose terms don't allow it is skipped, with
///   `helper_skipped_by_policy` (Base §10.3).
/// - **Edits** need a rewriter that sees the input image (E4), so an edit's instruction goes as typed (`needs_vision`).
/// - **FLUX 3 Klein** keeps BFL's own upsampler, inside its package: not a helper, and its rewrite isn't handed back. The
///   mode switches it per request through the package's `upsample` key; `MLXIMG_FLUX3_UPSAMPLER` sets it for the whole
///   engine, and `off` there loads none.
/// - **The preview** `image.enhance_prompt` (Image §3.1; AB-D-0155, E5) returns the rewrite a target job would run with
///   `prompt_enhance: on`, without running it, so a client can show it and let its user edit it first. Its offers are the
///   backbones; it's declared while one is on. See `RunPlan.previewPrompt`.
public enum PromptEnhancement {
    /// The model whose enhancer lives in its own package.
    public static let flux3 = "flux-3-klein"
    /// The package key that switches a model's own upsampler for one request (FLUX 3 Klein's, AB-A-0191).
    public static let upsampleKey = "upsample"
    /// The operations whose prompts it enhances.
    public static let operations: Set<String> = ["image.generate", "image.edit"]
    /// The preview operation (Image §3.1).
    public static let preview = "image.enhance_prompt"
    /// The operations a preview can be for: those the enhancer rewrites without seeing an image (an edit's rewriter
    /// needs vision, E4). The first is the default `target_operation`.
    public static let previewTargets = ["image.generate"]

    typealias Mode = ImageProfile.PromptEnhanceMode

    /// The `prompt_enhance` param's description on this engine.
    static let paramDescription = "auto (the default): rewrite a short prompt for models whose makers recommend it. on: "
        + "rewrite whenever the model has a profile. off: send the text as typed, adapters' triggers and templates "
        + "included; use it when your prompt is already a full caption. A rewrite is reported in effective.prompt "
        + "(or effective.instruction) with a prompt_rewritten warning."

    /// What `effective.model_params.prompt_enhancement` reports.
    struct Record {
        var applied = false
        /// The enhancer's outcome (`PromptOutcome`), or the engine's own: `off` (the request asked), `no_profile`,
        /// `unavailable` (the backbone is off or failed to load, or FLUX 3 Klein's upsampler is off on this engine),
        /// `built_in` (FLUX 3 Klein's upsampler rewrote it), `policy`.
        var outcome: String
        var profile: String?
        var version: Int?
        var backbone: String?
        var seed: UInt64?
        /// The size the rewrite suggested (a structured profile's canvas), as `W:H` and `WxH` where it named them.
        var suggestedSize: SuggestedSize?
        /// The canvas a layout was laid out for (MOSS-Image), which the job runs at.
        var canvas: CanvasSize?
        /// How many times the backbone was asked: 2 when the profile's compiler rejected its first draft.
        var attempts: Int?

        var value: MESValue {
            var object: [String: MESValue] = ["applied": .bool(applied), "outcome": .string(outcome)]
            if let profile { object["profile"] = .string(profile) }
            if let version { object["version"] = .number(Double(version)) }
            if let backbone { object["backbone"] = .string(backbone) }
            if let seed { object["seed"] = .number(Double(seed)) }
            if let size = suggestedSize {
                var suggested: [String: MESValue] = [:]
                if let w = size.width, let h = size.height { suggested["width"] = .number(Double(w)); suggested["height"] = .number(Double(h)) }
                if let aspect = size.aspectRatio { suggested["aspect"] = .string(aspect) }
                object["suggested_size"] = .object(suggested)
            }
            if let canvas { object["canvas"] = RunPlan.sizeValue(canvas.width, canvas.height) }
            if let attempts { object["attempts"] = .number(Double(attempts)) }
            return .object(object)
        }
    }
}

extension PromptEnhancing {
    /// The backbone that rewrites prompts for `model`, or nil when it has no profile (or keeps its own upsampler).
    public func backbone(forModel model: String) -> String? { profile(forModel: model)?.backbone }

    /// The models whose prompts backbone `id` rewrites, sorted.
    public func models(rewrittenOn id: String) -> [String] {
        profiles.filter { $0.backbone == id }.flatMap(\.models).sorted()
    }

    /// How a model wants its prompts, for its offer's notes and its console card: `required`, `recommended` or `optional`,
    /// and who rewrites them. nil for a model with no enhancer.
    public func prompting(forModel id: String) -> (policy: String, by: String)? {
        if id == PromptEnhancement.flux3 { return ("required", "its own upsampler") }
        guard let profile = profile(forModel: id) else { return nil }
        return (profile.policy.rawValue, "the \(profile.title) profile")
    }

    /// A backbone's card: which models it rewrites prompts for, and what turning it off does.
    public func backboneNote(_ id: String) -> String {
        let models = models(rewrittenOn: id).joined(separator: ", ")
        if profiles.contains(where: { $0.backbone == id && $0.structured }) {
            return "The prompt enhancer for structured prompts: it rewrites prompts for " + models + " into the JSON each "
                + "model reads (SenseNova U1.5's Render JSON, MOSS-Image's layouts), with each model's own profile, and "
                + "reports the rewrite in effective.prompt. Turned off, prompts go to those models as typed."
        }
        return "The prompt enhancer: it rewrites short prompts for " + models + " before they run, with each model's own "
            + "profile, and reports the rewrite in effective.prompt. Turned off, prompts go to the image models as typed. "
            + "FLUX 3 Klein uses its own upsampler instead."
    }

    /// A backbone's offer on `image.enhance_prompt`: which target models it previews, and how to use the result.
    public func previewNote(_ id: String) -> String {
        "Returns the prompt image.generate would run with prompt_enhance on, rewritten with target_model's own "
            + "profile and the job's seed, without generating; this backbone rewrites them for "
            + models(rewrittenOn: id).joined(separator: ", ") + ", and the "
            + "engine picks it when target_model is one of them. Run the target with that text (and the size, when one "
            + "comes back: a layout is only right at its size), the same model named, and prompt_enhance off. FLUX 3 "
            + "Klein's own upsampler can't be previewed."
    }

    /// The backbone a preview for `target` runs on: its profile's, or, with no target named, the one image.generate's
    /// preferred default rewrites on. nil for a target with no profile (any backbone answers; nothing is rewritten).
    func previewBackbone(target: String?) -> String? {
        let model = target ?? OperationTable.specs.first { $0.operation == PromptEnhancement.previewTargets[0] }?.defaults.first
        return model.flatMap(backbone(forModel:))
    }

    /// The offer's line about prompts (image.generate), while its backbone is on.
    func note(forModel id: String) -> String? {
        guard id != PromptEnhancement.flux3, let profile = profile(forModel: id) else { return nil }
        switch (profile.policy, profile.structured) {
        case (.required, true), (.recommended, true):
            return "The engine rewrites a prompt that isn't already JSON into the \(profile.title) profile's JSON on "
                + "\(profile.backbone) before it runs, as the model's makers recommend, and uses the aspect ratio it "
                + "suggests when the request names no size; the rewrite is reported in effective.prompt, and prompt_enhance "
                + "off sends a prompt as typed."
        case (.required, false), (.recommended, false):
            return "The engine rewrites a short prompt with the \(profile.title) profile before it runs, as the model's makers "
                + "recommend; the rewrite is reported in effective.prompt, and prompt_enhance off sends a prompt as typed."
        case (.optional, true) where profile.laysOutCanvas:
            return "Prompts go as typed; prompt_enhance on lays them out as the \(profile.title) profile's layout JSON on "
                + "\(profile.backbone) first, for the job's size (the model's default when the request names none), "
                + "and the job runs at exactly that size."
        case (.optional, true):
            return "Prompts go as typed; prompt_enhance on rewrites them into the \(profile.title) profile's JSON on "
                + "\(profile.backbone) first."
        case (.optional, false):
            return "Prompts go as typed; prompt_enhance on rewrites them with the \(profile.title) profile first."
        }
    }
}

extension RunPlan {
    /// The request's `prompt_enhance` (Image §1.9), `auto` when it doesn't say.
    var promptEnhanceMode: PromptEnhancement.Mode {
        context.param(ImageProfile.Param.promptEnhance)?.stringValue.flatMap(PromptEnhancement.Mode.init(rawValue:)) ?? .auto
    }

    /// The prompt `image.generate` or `image.edit` runs: the request's own, rewritten by the model's profile when the
    /// mode and the profile's policy say so. Call it before the image model loads: the backbone loads, runs, and is
    /// released or kept warm (`Residency.releaseHelper`) first. `param` is the input it came from (`prompt` or
    /// `instruction`). Reports the mode in `effective.prompt_enhance`, the backbone in `helpers`, and the detail in
    /// `model_params.prompt_enhancement`; `reportPrompt` reports the text once adapters have had their say.
    ///
    /// A structured profile (one whose answer suggests a size: SenseNova's canvas) is told the size the
    /// request asked for, if it asked (`targetSize`), and what it suggests is kept in `suggestedSize` for `size(for:)`;
    /// a layout's canvas is kept in `layoutCanvas`.
    mutating func enhancedPrompt(_ prompt: String, param: String, task: PromptTask, seed: UInt64) async throws -> String {
        let mode = promptEnhanceMode
        if context.descriptor.params["properties"]?[ImageProfile.Param.promptEnhance] != nil {
            effective[ImageProfile.Param.promptEnhance] = .string(mode.rawValue)
        }
        if context.model.id == PromptEnhancement.flux3 {
            modelParams["prompt_enhancement"] = flux3Upsampler(mode, param: param).value
            return prompt
        }
        let (text, record) = try await rewrite(prompt, param: param, task: task, seed: seed, mode: mode, for: context.model)
        suggestedSize = record.suggestedSize
        layoutCanvas = record.canvas
        modelParams["prompt_enhancement"] = record.value
        return text
    }

    /// Whether this job is the preview (`image.enhance_prompt`), whose own model is the backbone.
    var previewing: Bool { context.operation == PromptEnhancement.preview }
    /// The param enhancement's warnings name: the job's `prompt_enhance`, or the preview's `target_model`.
    var enhanceParam: String { previewing ? ImageProfile.Param.targetModel : ImageProfile.Param.promptEnhance }
    /// What became of a text the enhancer left alone.
    func asTyped(_ param: String) -> String { previewing ? "the \(param) is returned as typed" : "the \(param) was used as typed" }

    /// The rewrite `model`'s profile makes of `prompt` under `mode`, and what to report of it: the job's own prompt
    /// (`enhancedPrompt`) and the preview (`previewPrompt`, always `on`) both come through here, so a preview is what its
    /// target would run. The backbone loads only when the kit would call it; it runs with the job's `seed`, under the
    /// request's licence policy, and is listed in `helpers` when it rewrote. The backbone is the one the profile's class
    /// needs (`PromptProfile.backbone`): a structured profile runs on the large backbone, and isn't moved to the small one
    /// when the large one is off. Only a profile whose answer suggests a size (`suggestsSize`) or lays out a canvas (`laysOutCanvas`,
    /// MOSS-Image) is told one (`targetSize(for:laysOut:)`), so prose rewrites don't change with the request's size.
    mutating func rewrite(_ prompt: String, param: String, task: PromptTask, seed: UInt64, mode: PromptEnhancement.Mode,
                          for model: ModelOffer) async throws
        -> (prompt: String, record: PromptEnhancement.Record) {
        guard let enhancer = normalizer.enhancer, let profile = enhancer.profile(forModel: model.id) else {
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "\(model.title) has no prompt enhancement profile; "
                     + "\(asTyped(param)).", param: enhanceParam)
            }
            return (prompt, .init(outcome: "no_profile"))
        }
        var record = PromptEnhancement.Record(outcome: "off", profile: profile.id, version: profile.version)
        guard mode != .off else { return (prompt, record) }
        if task.needsVision {
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "Edit instructions aren't enhanced yet: the rewriter would "
                     + "need to see the image. The instruction was used as typed.", param: enhanceParam)
            }
            record.outcome = PromptOutcome.needsVision.rawValue
            return (prompt, record)
        }

        // Would the enhancer call the backbone at all? Its decision reads only the prompt and the profile, so a prompt that
        // goes as typed (an optional profile under auto, a detailed or structured prompt) never loads the backbone.
        let always = mode == .on
        if let skip = enhancer.skip(prompt, profile: profile, task: task, always: always) {
            record.outcome = skip.rawValue
            return (prompt, record)
        }

        let backboneID = profile.backbone
        record.backbone = backboneID
        record.seed = seed
        guard await normalizer.backboneOffered(backboneID), let info = await normalizer.host.model(backboneID) else {
            record.outcome = "unavailable"
            if mode == .on {
                warn(ImageProfile.WarningCode.promptEnhanceIgnored, "The prompt enhancer (\(backboneID)) is off "
                     + "on this engine; \(asTyped(param)).", param: enhanceParam)
            }
            return (prompt, record)
        }
        // A helper's licence is held to the request's policy like the model's (Base §10.3).
        let license = ImageNormalizer.license(info)
        guard context.policy.allows(license) else {
            record.outcome = "policy"
            warn(BaseWarningCode.helperSkippedByPolicy, "The prompt enhancer (\(info.displayName), \(license.spdx)) doesn't "
                 + "satisfy the request's licence policy; \(asTyped(param)).", param: enhanceParam)
            return (prompt, record)
        }
        let backbone: ModelRoute
        do {
            backbone = try await route(.llm, named: backboneID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Enhancement never blocks generation: a backbone that can't load leaves the prompt as typed.
            print("job \(context.jobID): the prompt enhancer didn't load: \(error)")
            record.outcome = "unavailable"
            let why = (ImageNormalizer.mesError(error) as? MESError)?.message ?? "\(error)"
            warn(ImageProfile.WarningCode.promptEnhanceFailed, "The prompt enhancer couldn't load (\(why)); \(asTyped(param)).",
                 param: enhanceParam)
            return (prompt, record)
        }
        // The preview's own model is the backbone: its pinned commit is provenance.model.revision.
        if backbone.id == context.model.id, let revision = Self.pinned(backbone.revision) {
            revisions[context.model.id] = revision
        }
        await context.reporter.progress(previewing ? .running : .preparing, message: "enhancing the prompt")
        // The enhancer rethrows cancellation, so a cancelled job stops here instead of generating from the prompt as typed.
        let target = !profile.suggestsSize && !profile.laysOutCanvas ? nil
            : await targetSize(for: model.id, laysOut: profile.laysOutCanvas)
        let timeout = profile.large ? normalizer.options.structuredPromptEnhanceTimeout
            : normalizer.options.promptEnhanceTimeout
        let result = try await enhancer.enhance(prompt, profile: profile, task: task, always: always, targetSize: target,
                                                seed: seed, timeout: timeout, backbone: backbone)
        if let i = admitted.lastIndex(where: { $0.packageID == backbone.packageID }) { admitted.remove(at: i) }
        await normalizer.residency.releaseHelper(backbone)

        record.outcome = result.outcome.rawValue
        record.applied = result.applied
        record.attempts = result.attempts
        if result.applied { record.suggestedSize = result.suggestedSize; record.canvas = result.canvas }
        if result.applied, result.attempts > 1 {
            print("job \(context.jobID): the prompt enhancer's first draft was rejected (\(result.failure ?? "-")); it fixed it")
        }
        switch result.outcome {
        case .enhanced:
            helpers.append(HelperRef(id: backboneID, title: backbone.displayName,
                                     revision: Self.pinned(backbone.revision), license: license,
                                     role: ImageProfile.HelperRole.promptEnhance))
            // No model receives a preview's rewrite, so only a job warns that one did.
            if !previewing {
                warn(ImageProfile.WarningCode.promptRewritten, "The \(param) was rewritten for \(model.title) with the "
                     + "\(profile.title) profile (v\(profile.version)) on \(backbone.displayName); what ran is in "
                     + "effective.\(param). prompt_enhance off sends it as typed.", param: param)
            }
        case .failed, .timedOut, .empty:
            print("job \(context.jobID): prompt enhancement \(record.outcome): \(result.failure ?? "-")")
            warn(ImageProfile.WarningCode.promptEnhanceFailed, "Prompt enhancement "
                 + "\(record.outcome.replacingOccurrences(of: "_", with: " ")); \(asTyped(param)).", param: enhanceParam)
        default:
            break
        }
        return (result.prompt, record)
    }

    /// `image.enhance_prompt` (Image §3.1; AB-D-0155, E5): the text the target job would run with `prompt_enhance: on`,
    /// without running it. The target is `target_operation` (image.generate) and `target_model`, or else the model that
    /// operation runs for a request naming none (`previewTarget`); the rewrite is `rewrite`'s, with that model's profile
    /// and the job's seed, so the same seed gives the same text. `enhanced` is `{prompt, applied}`: `applied` says whether
    /// the text changed, and when it didn't a `prompt_enhance_ignored` warning says why. A structured profile's suggested
    /// aspect comes back as `size` at the target's default area, snapped to its envelope: what the job would run at when
    /// it names no size, so a client sends it with the text. (The preview takes no size, so it rewrites as a job that names none; a job that
    /// names one tells a structured profile its size.) A layout (MOSS-Image) is laid out for the target's default size, as
    /// a job naming none is, and `size` is exactly that canvas. FLUX 3 Klein's upsampler runs inside its model and doesn't
    /// hand its rewrite back, so it can't be previewed.
    mutating func previewPrompt() async throws -> [ProducedOutput] {
        let operation = context.param(ImageProfile.Param.targetOperation)?.stringValue ?? PromptEnhancement.previewTargets[0]
        let target = try await previewTarget(operation)
        effective[ImageProfile.Param.targetOperation] = .string(operation)
        effective[ImageProfile.Param.targetModel] = .string(target.id)
        let typed = context.input("prompt")?.text ?? ""
        let base = seed(count: 1)
        seedUsed = base
        var text = typed
        var record = PromptEnhancement.Record(outcome: "built_in", profile: "flux3-upsampler")
        if target.id == PromptEnhancement.flux3 {
            warn(ImageProfile.WarningCode.promptEnhanceIgnored, "FLUX 3 Klein rewrites prompts with its own upsampler, inside "
                 + "the model, and doesn't hand the rewrite back, so it can't be previewed; the prompt is returned as typed. "
                 + "Run it with prompt_enhance auto or on to have it upsampled, or off to send exactly this text.",
                 param: ImageProfile.Param.targetModel)
        } else {
            (text, record) = try await rewrite(typed, param: "prompt", task: .textToImage, seed: base, mode: .on, for: target)
        }
        record.applied = text != typed
        if !record.applied, !warnings.contains(where: { $0.code == ImageProfile.WarningCode.promptEnhanceIgnored }) {
            let why = switch record.outcome {
            case PromptOutcome.passedThrough.rawValue: "it's already detailed or structured enough for the \(record.profile ?? "") profile"
            case PromptOutcome.noInstruction.rawValue: "the \(record.profile ?? "") profile has no rewrite for text to image"
            case "policy": "the prompt enhancer doesn't satisfy the request's licence policy"
            case PromptOutcome.enhanced.rawValue: "the enhancer kept it as it was"
            default: "prompt enhancement \(record.outcome.replacingOccurrences(of: "_", with: " "))"
            }
            warn(ImageProfile.WarningCode.promptEnhanceIgnored, "No rewrite for \(target.title): \(why). The prompt is "
                 + "returned as typed; \(operation) would run it so.", param: ImageProfile.Param.targetModel)
        }
        modelParams["prompt_enhancement"] = record.value
        var enhanced: [String: MESValue] = ["prompt": .string(text), "applied": .bool(record.applied)]
        if record.applied, let canvas = record.canvas {
            enhanced["size"] = Self.sizeValue(canvas.width, canvas.height)
        } else if record.applied, let suggested = record.suggestedSize, let info = await normalizer.host.model(target.id),
           let pixels = Self.pixels(suggested, defaultWidth: info.defaults.width, defaultHeight: info.defaults.height) {
            let fitted = info.envelope.fit(width: pixels.width, height: pixels.height)
                ?? info.envelope.clamp(width: pixels.width, height: pixels.height)
            enhanced["size"] = Self.sizeValue(fitted.width, fitted.height)
        }
        return [.data(.object(enhanced), name: "enhanced")]
    }

    /// The preview's target model: `target_model`, one of `operation`'s offers; or, when it names none, the model that
    /// operation runs for a request naming none under the same policy (Image §3.1), as MESEngineCore and `defaultModel`
    /// would choose it at standard quality.
    func previewTarget(_ operation: String) async throws -> ModelOffer {
        guard let spec = normalizer.spec(operation),
              let descriptor = normalizer.descriptor(spec, models: await normalizer.host.models()) else {
            throw MESError(.unsupportedParameter, "No \(operation) on this engine to enhance a prompt for.",
                           param: ImageProfile.Param.targetOperation)
        }
        if let named = context.param(ImageProfile.Param.targetModel)?.stringValue {
            guard let offer = descriptor.models.first(where: { $0.id == named }) else {
                throw MESError(.modelUnavailable, "\(operation) offers no model \(named).", param: ImageProfile.Param.targetModel)
            }
            return offer
        }
        let candidates = descriptor.models.filter { $0.qualityTiers.contains(.standard) && $0.namedOnly != true && context.policy.allows($0) }
        guard let kitChoice = candidates.first(where: { $0.isDefault == true }) ?? candidates.first else {
            throw MESError(.policyUnmet, "No model for \(operation) satisfies the request's policy.", param: ImageProfile.Param.targetModel)
        }
        let request = JobRequest(operation: operation, inputs: ["prompt": .text(context.input("prompt")?.text ?? "")],
                                 policy: context.policy)
        return normalizer.defaultModel(for: request, descriptor: descriptor, kitChoice: kitChoice, candidates: candidates)
            ?? kitChoice
    }

    /// The text the model receives, in `effective.prompt` or `effective.instruction`, when it isn't the request's own
    /// (Image §1.9): rewritten by the enhancer, or by an adapter's trigger or template.
    mutating func reportPrompt(_ prompt: String, typed: String, param: String) {
        if prompt != typed { effective[param] = .string(prompt) }
    }

    /// FLUX 3 Klein's enhancer is BFL's upsampler, inside flux3-klein-swift. The mode reaches it as the package's
    /// `upsample` key (`requestPromptKeys`): off skips it, with a warning, since BFL requires it; on asks for it; auto
    /// leaves the engine's setting. `MLXIMG_FLUX3_UPSAMPLER=off` (the runtime reads the same variable) loads no
    /// upsampler, so on can't be honoured. It's part of the model, not a helper, and the package doesn't hand the
    /// rewrite back, so it warns `prompt_rewritten` without the text (Image §1.9 allows that).
    mutating func flux3Upsampler(_ mode: PromptEnhancement.Mode, param: String) -> PromptEnhancement.Record {
        let tier = ProcessInfo.processInfo.environment["MLXIMG_FLUX3_UPSAMPLER"]?.lowercased() ?? "int8"
        let configured = tier != "off"
        var record = PromptEnhancement.Record(outcome: "built_in", profile: "flux3-upsampler")
        switch mode {
        case .off:
            record.outcome = "off"
            if configured {
                warn("prompt_upsampler_off", "FLUX 3 Klein's own prompt upsampler was skipped, as asked; its makers require "
                     + "it, so expect weaker results unless the prompt is already a full scene caption.",
                     param: ImageProfile.Param.promptEnhance)
            }
            return record
        case .on where !configured:
            warn(ImageProfile.WarningCode.promptEnhanceIgnored, "FLUX 3 Klein's prompt upsampler is switched off on this "
                 + "engine; the \(param) was used as typed.", param: ImageProfile.Param.promptEnhance)
            record.outcome = "unavailable"
            return record
        case .auto where !configured:
            record.outcome = "unavailable"
            return record
        case .on, .auto:
            warn(ImageProfile.WarningCode.promptRewritten, "FLUX 3 Klein's own upsampler rewrote the \(param) inside the "
                 + "model, as its makers require; the rewrite isn't handed back. prompt_enhance off sends it as typed.",
                 param: param)
            record.applied = true
            record.backbone = "flux-3-image-klein-pup (\(tier))"
            return record
        }
    }

    /// The package keys for the request's own prompt, on a model that rewrites prompts itself (FLUX 3 Klein's
    /// `upsample`, AB-T-0336): off sends it as typed, on asks for the upsampler, auto leaves the engine's setting.
    func requestPromptKeys(_ route: ModelRoute) -> Params? {
        guard route.takes(PromptEnhancement.upsampleKey) else { return nil }
        switch promptEnhanceMode {
        case .off: return [PromptEnhancement.upsampleKey: .bool(false)]
        case .on: return [PromptEnhancement.upsampleKey: .bool(true)]
        case .auto: return nil
        }
    }

    /// The package keys for a prompt the engine wrote (fill and extend's marker instructions, erase by name, the creative
    /// upscale's instruction): it goes to the model as written, so a model's own upsampler is skipped (§1.1).
    func writtenPromptKeys(_ route: ModelRoute) -> Params? {
        route.takes(PromptEnhancement.upsampleKey) ? [PromptEnhancement.upsampleKey: .bool(false)] : nil
    }
}
