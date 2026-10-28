import Foundation
import MESCore
import MESEngineCore

/// Adapters (LoRA) through MES 0.4's first-class adapters (Base §6.3, Image §1.10; AB-D-0155, L4–L5;
/// pixel-agency-image-engine docs/PROMPTS-AND-ADAPTERS.md §2.2): the adapters each model takes (`ModelCard.adapters`),
/// offered on `image.generate` and `image.edit`.
///
/// - **Offers.** Each model offer lists the adapters it takes (`ModelOffer.adapters`) and how many one request stacks
///   (`max_adapters`, its surface's `AdapterSupport.maxCount`). An adapter's strength range is where the surface's and the
///   adapter's own overlap; its notes say how to use it (slots, template, trigger).
/// - **Requests** name them in `adapters: [{id, strength?}]`. MESEngineCore checks them at submit (an id listed twice,
///   one no offer lists or the named model doesn't, more than `max_adapters`, a strength out of range, the licence policy),
///   chooses the model (an adapter implies its model, Base §6.3 rule 2) and counts an `ic` adapter's slots (Image §1.10);
///   the engine gets them in `RunContext.adapters`.
/// - **Reference-conditioned (IC) adapters** take their slots, in order, from the edit's `images` or the generate's
///   `references`; images left over stay the edit's own.
/// - **Prompts.** An adapter's prompt template wraps the prompt (or is the prompt when there's none), and its trigger is
///   added when the prompt lacks it, after prompt enhancement, with a `prompt_rewritten` warning. `prompt_enhance: off`
///   sends the text as typed, adapters or not (Image §1.9).
/// - **Honest results.** Each adapter's pinned commit goes back in `RunOutput.revisions`, so `provenance.adapters` lists
///   what ran: id, title, the revision, its licence and the strength.
/// - **The enabled set.** Each adapter is an `adapter:<id>` entry in the operator's enabled set. Adapters whose terms the
///   operator should read first are opt-in (`isOptIn`): gated ones, ones whose licence doesn't allow commercial use or
///   doesn't say, and `candidate` ones not yet judged on this stack. The headless engine offers those only with
///   `--allow-research`.
public enum Adapters {
    /// The operations that take adapters, with the capability their adapters must serve.
    public static let operations: [String: ModelCapability] = ["image.generate": .textToImage, "image.edit": .imageEdit]
    /// Registry statuses never offered. Format 3 keeps withdrawn entries out of the catalog altogether; these are the
    /// statuses older registries used for the same thing.
    static let refusedStatuses: Set<String> = ["withdrawn", "broken"]

    /// The adapter's key in the operator's enabled set (`ModelEnablement`).
    public static func key(_ id: String) -> String { "adapter:" + id }

    /// The adapter id behind an enabled-set key, or nil for a model's key.
    public static func adapterID(fromKey key: String) -> String? {
        key.hasPrefix("adapter:") ? String(key.dropFirst("adapter:".count)) : nil
    }

    /// Whether the operator must switch `adapter` on and accept its terms first: its terms are gated, they don't allow
    /// commercial use or don't say, or it's a `candidate` not yet judged on this stack.
    public static func isOptIn(_ adapter: ModelCard.Adapter) -> Bool {
        adapter.licenseGated || !["allowed", "conditional"].contains(adapter.commercialUse) || adapter.status == "candidate"
    }

    /// Never offered, whatever the enabled set says.
    public static func isRefused(_ adapter: ModelCard.Adapter) -> Bool { refusedStatuses.contains(adapter.status) }

    /// The adapter's own licence in MES terms (Base §10.2), which applies on top of its model's. `conditional` (e.g.
    /// OpenRAIL's use restrictions) allows commercial use, with a notice to read the conditions.
    public static func license(_ adapter: ModelCard.Adapter) -> MESCore.License {
        let use: CommercialUse
        switch adapter.commercialUse {
        case "allowed", "conditional": use = .yes
        case "prohibited": use = .no
        default: use = .unknown
        }
        var notes: [String] = []
        if adapter.commercialUse == "conditional" {
            notes.append("Commercial use is allowed on the conditions of its licence (\(adapter.license)): read them first.")
        } else if use == .unknown {
            notes.append("Its licence doesn't say whether commercial use is allowed.")
        }
        if let notice = adapter.notice { notes.append(notice) }
        return MESCore.License(spdx: adapter.license, commercialUse: use, termsURL: adapter.licenseURL,
                               notice: notes.isEmpty ? nil : notes.joined(separator: " "),
                               acceptedRequired: isOptIn(adapter) ? true : nil)
    }

    // MARK: - The offer

    /// The adapter as `support`'s model offers it (Base §6.3), or nil when the surface can't run its kind or the two
    /// strength ranges don't overlap. `input` is the operation's input an IC adapter's slots fill (Image §1.10).
    static func offer(_ info: ModelCard.Adapter, support: ModelRoute.AdapterSupport, input: String) -> AdapterOffer? {
        guard support.kinds.contains(info.kind) else { return nil }
        let low = max(support.strengthMin, info.strengthMin ?? -.infinity)
        let high = min(support.strengthMax, info.strengthMax ?? .infinity)
        guard low <= high else { return nil }
        let slots = info.conditioning.map { slot in
            AdapterOffer.Slot(role: slot.role, kind: MESCore.Kind(rawValue: slot.media) ?? .image,
                              required: slot.required ? nil : false, notes: slot.note)
        }
        return AdapterOffer(id: info.id, title: info.title, kind: info.kind == "ic" ? .ic : .plain,
                            slots: slots.isEmpty ? nil : slots,
                            strength: .init(min: low, max: high, defaultValue: min(max(info.defaultStrength, low), high)),
                            license: license(info), notes: notes(info, input: input))
    }

    /// How to use an adapter, in a sentence or two (its offer's `notes`). `input` is where an IC adapter's images come from.
    public static func notes(_ info: ModelCard.Adapter, input: String = "images") -> String? {
        var parts: [String] = []
        if info.kind == "ic", !info.conditioning.isEmpty {
            parts.append("Takes its reference images from \(input), in this order: "
                + info.conditioning.map { $0.role + ($0.required ? "" : " (optional)") }.joined(separator: ", ") + ".")
        }
        if let template = info.promptTemplate {
            parts.append(template.contains("{prompt}")
                ? "Your prompt is placed in its template: \(template)"
                : "Without a prompt it runs \"\(template)\".")
        }
        if let trigger = info.trigger, trigger != info.promptTemplate {
            parts.append("The engine adds its trigger, \"\(trigger)\", when the prompt lacks it.")
        }
        if info.status == "candidate" { parts.append("A candidate: checked, but not yet judged on this engine.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The models of `descriptor`'s operation that take adapter `id`, or nil when none does.
    public static func models(taking id: String, in descriptor: Descriptor) -> [String]? {
        let ids = descriptor.models.filter { $0.adapter(id) != nil }.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    // MARK: - Prompts

    /// Whether the adapter may change a prompt: it has a template or a trigger.
    static func rewrites(_ info: ModelCard.Adapter) -> Bool {
        info.promptTemplate != nil || info.trigger?.trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// `prompt` as the adapters want it: each one's template wrapped round it (or standing in for an empty one), then its
    /// trigger added when the prompt lacks it. Returns the ids that changed it.
    static func prompt(_ prompt: String, for adapters: [ModelCard.Adapter]) -> (prompt: String, changedBy: [String]) {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var changedBy: [String] = []
        for adapter in adapters {
            let before = text
            if let template = adapter.promptTemplate {
                if template.contains("{prompt}") {
                    text = template.replacingOccurrences(of: "{prompt}", with: text)
                } else if text.isEmpty {
                    text = template
                }
            }
            if let trigger = adapter.trigger?.trimmingCharacters(in: .whitespaces), !trigger.isEmpty,
               text.range(of: trigger, options: .caseInsensitive) == nil {
                // A trigger word goes before the prompt; a trigger sentence is its own sentence.
                let sentence = trigger.contains(" ")
                let joint = !sentence || trigger.last.map { ".!?".contains($0) } == true ? " " : ". "
                text = text.isEmpty ? trigger : trigger + joint + text
            }
            if text != before { changedBy.append(adapter.id) }
        }
        return (text, changedBy)
    }
}

extension RunPlan {
    /// The request's adapters (`RunContext.adapters`, checked by MESEngineCore) for `route`, as the runtime takes them
    /// (`ModelWork.adapters`), with an IC adapter's images taken in order from `images` (the edit's `images`, the generate's
    /// `references`) into inputs of their own. Returns the images left over. Records each adapter's pinned commit in
    /// `revisions` (provenance.adapters) and adapts `prompt` (`Adapters.prompt`), warning when it changed, unless
    /// `prompt_enhance` is off.
    mutating func applyAdapters(_ route: ModelRoute, prompt: inout String, param: String, images: [ModelImage] = [])
        async -> (adapters: [ModelWork.Adapter]?, inputs: [String: [ModelImage]], images: [ModelImage]) {
        guard !context.adapters.isEmpty else { return (nil, [:], images) }
        let infos = await normalizer.host.model(route.id)?.adapters ?? []
        var remaining = images[...]
        var inputs: [String: [ModelImage]] = [:]
        var jobAdapters: [ModelWork.Adapter] = []
        var applied: [ModelCard.Adapter] = []
        for (n, choice) in context.adapters.enumerated() {
            let info = infos.first { $0.id == choice.id }
            var conditioning: [String: String] = [:]
            for slot in info?.conditioning ?? [] where slot.required || !remaining.isEmpty {
                guard let image = remaining.popFirst() else { break }
                let input = "adapter\(n).\(slot.role)"
                inputs[input] = [image]
                conditioning[slot.role] = input
            }
            jobAdapters.append(ModelWork.Adapter(id: choice.id, strength: choice.strength, conditioning: conditioning))
            if let info { applied.append(info) }
            // What ran (provenance.adapters): the adapter file's pinned commit.
            if let revision = route.adapterRevisions[choice.id], !revision.isEmpty {
                revisions[choice.id] = revision
            }
        }

        guard promptEnhanceMode != .off else { return (jobAdapters, inputs, Array(remaining)) }
        let adapted = Adapters.prompt(prompt, for: applied)
        if !adapted.changedBy.isEmpty {
            warn(ImageProfile.WarningCode.promptRewritten, "The \(param) was changed for \(adapted.changedBy.joined(separator: ", ")) "
                 + "(its trigger or prompt template); what ran is in effective.\(param). prompt_enhance off sends it as typed.",
                 param: param)
            prompt = adapted.prompt
        }
        return (jobAdapters, inputs, Array(remaining))
    }
}
