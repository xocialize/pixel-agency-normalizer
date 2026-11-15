# Pixel Agency Normalizer

The host half of the reference engine for the [Media Engine Specification](https://github.com/xocialize/media-engine-spec)'s
Image profile, as a Swift package with **no MLX in its dependency graph**. MES operations and vocabulary come in, model
runs go out, and the profile's rules are enforced on whatever the models return.

It holds what used to be `pixel-agency-image-engine`'s normalizer (v0.9.1): `OperationTable`, `ImageNormalizer` and the
host side of each job's plan (`RunPlan`). The caller supplies the models. Three hosts link it (decision G-20, AB-D-0182;
work order AB-T-0359):

| Host | How its models run |
|---|---|
| [pixel-agency-image-engine](https://github.com/xocialize/pixel-agency-image-engine) | In process, over mlx-image-runtime (`RuntimeModelHost`) |
| [Pixel Agency Desktop](https://github.com/xocialize/pixel-agency-desktop)'s built-in engine | In process, over ForgeCore's processing tiers |
| [Gaea](https://github.com/xocialize-code/gaea) | In plugin processes: each model is a plugin offer, and helpers are offers too |

## What it does

- **Descriptors** from the host's models: one offer for each model that serves the operation's capability, with its
  licence in MES terms, its quality tiers and the measured default for each tier. Research and work-in-progress models
  are offered only when the operator opts in, and then `named_only`.
- **Validation and the default model**: 16 bits only where a model keeps them, a restore's model chosen by `kind`, fill
  and extend with a prompt sent to an edit model, drawn content upscaled on its own ladder, erase at best by name.
- **Each job's plan**: sizes snapped to the model's envelope (`size_snapped`), black-mask pixels kept exactly, exact
  ×scale upscales, upright sRGB in and out, alpha re-applied, adapters (LoRA) with IC slots, prompt enhancement, erase by
  name, and the creative upscale (tiles, colour lock, faces and text kept).
- **Layers** (`image.decompose`, Image §3.2, MESKit 0.6.0): offered when the host has a `layerDecompose` model. The
  descriptor's `layer_count` maximum is the most any offer allows (`ModelCard.maxLayerCount`) and `composite` is listed
  only when an offer makes one (`producesComposite`). Each job gets exactly the count asked for (from `layer_count` or the
  prompt's plan) or fails, every layer at the input's size with straight alpha, and transparent input pixels kept
  transparent (`alpha_reapplied`).
- **Residency**: one heavy model in memory at a time, idle models released. A host whose own scheduler owns memory
  keeps `ModelHost`'s default hooks, which hold nothing resident.

## The API

```swift
import PixelAgencyNormalizer

let normalizer = ImageNormalizer(host: myHost, enhancer: myEnhancer, options: .init(allowResearch: false))
// It is an MESEngineCore `MediaEngine`: serve it with MESEngineKit, or in process with MESInProcess.
```

| Type | What it is |
|---|---|
| `ImageNormalizer` | The `MediaEngine`: `descriptors()`, `validate`, `defaultModel`, `run`, `prefetch`, `unload`, `residentModels()`. `Options` covers research models, the operator's enabled set (`ModelEnablement`), residency, the 16-bit and tiled models, and the enhancer's timeouts. |
| `ModelHost` | What the caller supplies: `models()`, `model(_:)`, `route(_:model:)`, `prepare`, `run`, and optional residency hooks (`residentPackages`, `evict`, `fit`, `footprints`, `modelID(forPackage:)`). |
| `ModelCard`, `ModelRoute`, `ModelWork`, `ModelResult`, `ModelImage`, `ModelMatte`, `ModelProgress`, `ModelFit`, `ModelCapability` | The values that cross the seam. Capabilities use MLXEngine's names (MLXToolKit `Capability` raw values), so a host maps them by `rawValue`. |
| `PromptEnhancing`, `PromptProfile`, `PromptRewrite`, `PromptTask`, `PromptOutcome` | The optional prompt enhancer behind `prompt_enhance`: its profiles, and its rewrite on a backbone the host routes as `.llm`. The normalizer decides when to call it and what to report. |
| `Adapters`, `PromptEnhancement`, `Creative`, `Residency` | Their public helpers: enabled-set keys, licences and notes for the console, the creative upscale's models and memory gate. |

A host serving `image.decompose` registers a card with `capabilities: [.layerDecompose]`, `maxLayerCount` and
`producesComposite`; takes `ModelWork.inputs["image"]`, `params["prompt"]` (the layer plan, when there is one),
`params["layerCount"]` (when the request or its plan states one), `params["resolution"]` (512 at draft) and `seed`; and
returns `.layers(layers, composite:)`, front-most first.

Hosts throw `MESError` when the MES code matters (`policy_unmet`, `no_capacity`, `out_of_limits`, `model_unavailable`,
`unsupported_parameter`). Any other error reaches the client as `engine_error`.

## Building

```bash
swift build
swift test
swift package show-dependencies
```

The tests serve the normalizer over a fake host with MESEngineKit and run MES's conformance suite against it, BASE and
IMAGE. The dependencies are media-engine-spec (`MESCore`, `MESEngineCore`) and, since 0.3.0, EraseKit's `EraseFill`
product. macOS 26, Swift 6.2.

**The fill route's pixel steps come from EraseFill** (0.3.0, AB-A-0180). That covers fill and extend: the marker, the
paint guard, harmonize, the composite through the mask, the padded canvas and the seam band. EraseFill's `FillRoute` is
the one implementation the Generative Fill bake-off measured, and ForgeCore (Pixel Agency Editor) calls it too. The
normalizer's `Pixels`, `Mask` and `Box` are its `FillPixels`, `FillMask` and `FillBox`. The move was token-identical:
the normalizer's copy matched ForgeCore 0.46.0's function for function. EraseFill depends on nothing (CoreGraphics only).
Resolving the package also fetches media-bridge for EraseKit's other product, but nothing links it, and MLX stays out of
the graph.

**Opaque pictures are written as RGB PNGs** (0.3.1, AB-A-0260). Every image output used to be an RGBA PNG, opaque or
not. A PNG output with no transparent pixel now has no alpha channel (colour type 2, 8- or 16-bit as before); one with
any transparency stays RGBA (colour type 6), as Image §1.5's reapplied alpha needs. The outputs the profile defines as
RGBA stay RGBA even when opaque: `image.decompose`'s layers (§3.2, IMAGE-014) and `image.matte`'s `extract` (§2,
IMAGE-004). A decompose `composite` follows the general rule. Pixels are unchanged, but the bytes (and hashes) of
opaque outputs change. That reaches every engine linking the normalizer, so pixel-agency-image-engine and Pixel Agency
Desktop's built-in engine are affected too. JPEG and TIFF outputs, masks (8-bit grey already) and the PNGs handed to
model packages are written as before.

**`image.matte` cuts out one subject** (0.4.0, AB-A-0292; Image §3.3, MES RFC 0011, media-engine-spec ≥ 0.15.0). A
request's `subject` is a box around the thing or points on and off it, in shares of the upright picture. The matting
model runs as before. Then a segmenter runs on the box (as `box: [x0, y0, x1, y1]` in source pixels, the engine
contract's box prompt) or on the points (`points` and `pointLabels`, as `image.segment` sends them), and the matte is
kept where the segmenter's mask is: their product, so soft edges survive inside the subject and everything outside it
is black. `mask` and `extract` then cover the subject alone.
- The segmenter is `image.segment`'s preferred model that the host has, offered and routable by default: SAM 2.1
  (`sam21-segment`), then EdgeTAM. It is reported in `provenance.helpers` with the role `subject`, and its licence is
  held to the request's policy (422 `policy_unmet` otherwise). `effective.subject` is the subject used, and
  `effective.model_params` names the segmenter and gives its score.
- The matte's offers list `supports.subject: ["box", "points"]`, and the descriptor has the `subject` parameter, only
  while the host has such a segmenter. Without one the operation is exactly as it was, and a `subject` is refused with
  422 `unsupported_parameter`.
- A subject that selects nothing the matte covers gives an empty mask and the warning `nothing_found`.
- Without `subject` nothing changes: one model run, the same bytes.

Measured here on the fake host only (IMAGE-020 and IMAGE-021 pass, with a box and with points). Not run in this
repository: real models. Gaea checks it with the Forge pack on mlx-3d's two hard pictures (AB-A-0292).

## Licence

Apache-2.0. See [LICENSE](LICENSE).
