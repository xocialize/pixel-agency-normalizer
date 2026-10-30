import Foundation
import MESCore
import MESEngineCore

/// `image.decompose` (Image §3.2; RFC 0004, amendments A1–A8): an image as a stack of straight-alpha RGBA layers, front-most
/// first, that composites back to it, from a `layerDecompose` model (Ming-Image Design-Layer, Gaea's `ming-image-layer`).
///
/// - **The descriptor** states the most layers any offer allows (`layer_count`'s maximum, A5) and lists `composite` only
///   when an offer makes one (`ModelCard.maxLayerCount`, `producesComposite`). Two annotations carry the same per offer for
///   machines (`x-pixelagency-max-layer-counts`, `x-pixelagency-composite-models`), so a request naming a model that allows
///   fewer layers is 422 `out_of_limits`, and one asking it for a composite it doesn't make 422 `unsupported_parameter`, at
///   submit (`validate`). Only PNG is offered: layers carry alpha.
/// - **The count** is `layer_count`, or else the one the plan (`prompt`) states (`OperationTable.statedLayerCount`), or else
///   the model's own. A plan contradicting `layer_count` is 400 `invalid_request`; one above the maximum is 422
///   `out_of_limits` (A3). A model that returns another number than was asked fails the job (`engine_error`): a stack is
///   never padded or cut. `effective.layer_count` is always the number returned (A2).
/// - **Every layer** comes back at the input's size. Pixels transparent in the input stay transparent in every layer: a
///   model that shows something there has each layer's alpha capped at the input's, with `alpha_reapplied` (§1.5).
/// - **The composite** is written only when `outputs` asks for it (default `["layers"]`; MESEngineCore refuses an `outputs`
///   without `layers`, A6), at the input's size, under the same alpha rule.
enum Decompose {
    /// The most layers `info` returns in one request: its own maximum, within the vocabulary's.
    static func maxLayers(_ info: ModelCard) -> Int {
        min(info.maxLayerCount ?? OperationTable.vocabularyMaxLayers, OperationTable.vocabularyMaxLayers)
    }

    /// Narrows `layer_count` to the most any of `offers` allows, and `outputs` to `layers` alone when none makes a
    /// composite, with each offer's limits as annotations.
    static func narrow(_ properties: inout [String: MESValue], offers: [ModelCard]) {
        let maxima = Dictionary(offers.map { ($0.id, maxLayers($0)) }, uniquingKeysWith: { a, _ in a })
        if case .object(var count)? = properties[ImageProfile.Param.layerCount] {
            count["maximum"] = .number(Double(maxima.values.max() ?? OperationTable.vocabularyMaxLayers))
            count[OperationTable.maxLayerCountsKey] = .object(maxima.mapValues { .number(Double($0)) })
            properties[ImageProfile.Param.layerCount] = .object(count)
        }
        let makers = offers.filter(\.producesComposite).map(\.id).sorted()
        if case .object(var outputs)? = properties[ImageProfile.Param.outputs] {
            if makers.isEmpty {
                outputs["items"] = ["enum": ["layers"]]
                outputs["description"] = "layers: the model makes no composite on this engine."
            }
            outputs[OperationTable.compositeModelsKey] = .array(makers.map { .string($0) })
            properties[ImageProfile.Param.outputs] = .object(outputs)
        }
    }

    /// The operation's outputs: `layers` (1 to the most any offer allows) and, when an offer makes one, `composite` (0–1).
    static func outputs(offers: [ModelCard]) -> [OutputSpec] {
        let most = offers.map(maxLayers).max() ?? OperationTable.vocabularyMaxLayers
        var outputs = [OutputSpec(name: "layers", kind: .image, mediaTypes: ["image/png"], min: 1, max: most)]
        if offers.contains(where: \.producesComposite) {
            outputs.insert(OutputSpec(name: "composite", kind: .image, mediaTypes: ["image/png"], min: 0, max: 1), at: 0)
        }
        return outputs
    }

    /// The count the request asks for: `layer_count`, or else the one its plan states; nil leaves it to the model.
    static func count(params: [String: MESValue]?, plan: String?) -> Int? {
        params?[ImageProfile.Param.layerCount]?.intValue ?? plan.flatMap(OperationTable.statedLayerCount)
    }

    static func wantsComposite(_ params: [String: MESValue]?) -> Bool {
        params?[ImageProfile.Param.outputs]?.arrayValue?.contains(.string("composite")) ?? false
    }

    /// Each offer's maximum and composite, read back from the descriptor's annotations.
    static func limits(_ descriptor: Descriptor) -> (maxima: [String: Int], composite: Set<String>) {
        let properties = descriptor.params["properties"]
        var maxima: [String: Int] = [:]
        if case .object(let values)? = properties?[ImageProfile.Param.layerCount]?[OperationTable.maxLayerCountsKey] {
            for (id, value) in values { if let n = value.intValue { maxima[id] = n } }
        }
        let composite = properties?[ImageProfile.Param.outputs]?[OperationTable.compositeModelsKey]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        return (maxima, Set(composite))
    }

    /// §3.2 at submit: a plan's count meets `layer_count`'s rules (A3), and a named model allows the count and makes the
    /// composite asked for (A5).
    static func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        let params = request.params
        var plan: String?
        if case .text(let text)? = request.inputs?["prompt"] { plan = text }
        let stated = plan.flatMap(OperationTable.statedLayerCount)
        if let asked = params?[ImageProfile.Param.layerCount]?.intValue, let stated, asked != stated {
            throw MESError(.invalidRequest, "layer_count \(asked) contradicts the prompt, which plans \(stated) layers.",
                           param: ImageProfile.Param.layerCount)
        }
        let maximum = descriptor.params["properties"]?[ImageProfile.Param.layerCount]?["maximum"]?.intValue
            ?? OperationTable.vocabularyMaxLayers
        if let stated, stated < 1 || stated > maximum {
            throw MESError(.outOfLimits, "The prompt plans \(stated) layers; image.decompose returns 1 to \(maximum).",
                           param: ImageProfile.Param.layerCount)
        }
        guard let named = request.model else { return }
        let (maxima, composite) = limits(descriptor)
        if let count = count(params: params, plan: plan), let most = maxima[named], count > most {
            throw MESError(.outOfLimits, "\(named) returns at most \(most) layers, not \(count).",
                           param: ImageProfile.Param.layerCount)
        }
        if wantsComposite(params), !composite.contains(named) {
            throw MESError(.unsupportedParameter, "\(named) makes no composite; ask for layers alone.",
                           param: ImageProfile.Param.outputs)
        }
    }

    /// The offers among `candidates` that serve the request's count and composite (the default's pool); all of them when
    /// none does, so the run refuses with the reason.
    static func fitting(_ candidates: [ModelOffer], request: JobRequest, descriptor: Descriptor) -> [ModelOffer] {
        let (maxima, composite) = limits(descriptor)
        var plan: String?
        if case .text(let text)? = request.inputs?["prompt"] { plan = text }
        let count = count(params: request.params, plan: plan)
        let wants = wantsComposite(request.params)
        let fit = candidates.filter { offer in
            (count.map { $0 <= maxima[offer.id] ?? OperationTable.vocabularyMaxLayers } ?? true)
                && (!wants || composite.contains(offer.id))
        }
        return fit.isEmpty ? candidates : fit
    }
}

extension RunPlan {
    /// `image.decompose` (Image §3.2): one `layerDecompose` call, then the profile's rules on the stack it returns.
    mutating func decompose() async throws -> [ProducedOutput] {
        let input = try load("image")
        let typed = context.input("prompt")?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plan = typed.isEmpty ? nil : typed
        let asked = Decompose.count(params: context.params, plan: plan)
        let wantsComposite = Decompose.wantsComposite(context.params)
        // The model's limits before it loads (A5), for a host whose model isn't the one the descriptor promised.
        if let info = await host.model(context.model.id) {
            if let asked, asked > Decompose.maxLayers(info) {
                throw MESError(.outOfLimits, "\(info.displayName) returns at most \(Decompose.maxLayers(info)) layers, not \(asked).",
                               param: ImageProfile.Param.layerCount)
            }
            if wantsComposite, !info.producesComposite {
                throw MESError(.unsupportedParameter, "\(info.displayName) makes no composite.", param: ImageProfile.Param.outputs)
            }
        }
        let route = try await route(.layerDecompose)
        record(route)
        var params: Params = [:]
        if let plan { params["prompt"] = .string(plan) }
        if let asked { params["layerCount"] = .number(Double(asked)) }
        if let resolution = OperationTable.decomposeResolution[context.quality] {
            params["resolution"] = .number(Double(resolution))
            modelParams["resolution"] = .number(Double(resolution))
        }
        let base = seed(count: 1)
        let ran = try await invoke(route, params: params, inputs: ["image": [Media.modelImage(input)]], seed: base)
        guard case .layers(let stack, let frame) = ran, !stack.isEmpty else {
            throw NormalizerError.engine("\(route.displayName) returned no layers.")
        }
        // The count is exact both ways (A3): padding or cutting the stack would break layers[i] ↔ the plan's entry i.
        if let asked, stack.count != asked {
            throw MESError(.engineError, "\(route.displayName) returned \(stack.count) layers, not the \(asked) asked for.")
        }
        if wantsComposite, frame == nil {
            throw MESError(.engineError, "\(route.displayName) returned no composite.")
        }
        var layers = try stack.map { try Media.pixels($0).resized(input.width, input.height) }
        var composite = wantsComposite ? try frame.map { try Media.pixels($0).resized(input.width, input.height) } : nil
        // Transparent input pixels stay transparent in every layer (§3.2, §1.5).
        if input.hasTransparency, (layers + (composite.map { [$0] } ?? [])).contains(where: { Media.shows($0, whereClear: input) }) {
            warn(ImageProfile.WarningCode.alphaReapplied, "\(route.displayName) showed pixels where the input is transparent; "
                 + "each layer's alpha was capped at the input's.")
            layers = layers.map { Media.capAlpha($0, at: input) }
            composite = composite.map { Media.capAlpha($0, at: input) }
        }
        effective[ImageProfile.Param.layerCount] = .number(Double(layers.count))
        seedUsed = base
        var outputs = try layers.enumerated().map { try write($1, name: "layers", index: $0) }
        if let composite { outputs.append(try write(composite, name: "composite")) }
        return outputs
    }
}
