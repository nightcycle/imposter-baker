# imposter-render

Strictly typed Luau runtime for `imposter-baker` layout version 1. One batch owns a single EditableMesh, a single MeshPart, and one shared EditableImage per enabled material layer. Every imposter has its own quad in that mesh, so independent instances can select different shots and still share geometry and textures.

All Luau methods and record fields use PascalCase, including constructors (`ImposterRender.New`), options (`Limits.MaxInstances`), sources (`Color`, `Normal`), and generated layout fields (`PanShotCount`). This is a breaking change from the earlier camelCase API: update callers and regenerate old `.imposter.luau` files. Lowercase layer IDs in `Layers` and `Images["color"]`, shot keys, PNG paths, and the JSON manifest format are unchanged.

## Install

This directory is a standalone Wally project:

```sh
wally package --project-path imposter-render --output imposter-render.zip
rojo build imposter-render/default.project.json --output imposter-render.rbxm
```

To publish the registry package, authenticate with Wally and run `wally publish` inside this directory. GitHub Actions also supports manual or automatic stable-version registry publication using `WALLY_AUTH_TOKEN`; see the [release guide](../.github/RELEASING.md). Once published, consumers add:

```toml
[dependencies]
ImposterRender = "nightcycle/imposter-render@0.1.0"
```

Enable editable assets in the experience's security settings. Asset ownership/access requirements still apply. Roblox can deny allocations before a configured limit is reached; creation and registration return errors with cleanup. Editable assets are local to each client. Create/update the renderer from a LocalScript.

## Spritesheet example

Upload the baker's PNGs without resizing them. Keep the generated `.imposter.luau` layout alongside your asset IDs; the default layout can be omitted. Use bounds from the same model and coordinate basis used during baking.

```lua
--!strict
local RunService = game:GetService("RunService")
local ImposterRender = require(game.ReplicatedStorage.Packages.ImposterRender)

local options: ImposterRender.Options = {
    Origin = CFrame.new(100, 0, 100),
    Limits = {
        MaxTextureSize = 1024,
        MaxInstances = 256,
        MaxEditableMeshes = 1,
        MaxEditableImages = 6,
        MaxTexturePixels = 6 * 1024 * 1024,
        WorldExtent = 512,
    },
}
local batch, createError = ImposterRender.New(options)
assert(batch, createError)

local ok, loadError = batch:Register("birch-v1", {
    Color = "rbxassetid://COLOR_ATLAS_ID",
    Normal = "rbxassetid://NORMAL_ATLAS_ID",
    Roughness = "rbxassetid://ROUGHNESS_ATLAS_ID",
    Metalness = "rbxassetid://METALNESS_ATLAS_ID",
})
assert(ok, loadError)

local model = workspace:WaitForChild("Birch") :: Model
local boxCFrame, boxSize = model:GetBoundingBox()
local first, addError = batch:Add("birch-v1", boxCFrame, boxSize)
assert(first, addError)
local second, secondError = batch:Add("birch-v1", boxCFrame + Vector3.new(10, 0, 0), boxSize)
assert(second, secondError)

local connection = RunService.RenderStepped:Connect(function()
    local camera = workspace.CurrentCamera
    if camera then
        batch:Update(camera.CFrame, camera.FieldOfView)
    end
end)

-- When disposing:
-- connection:Disconnect()
-- first:Destroy()
-- second:Destroy()
-- batch:Unregister("birch-v1")
-- batch:Destroy()
```

Use the camera's **vertical** field of view in degrees. If you use a nonvertical `Camera.FieldOfViewMode`, supply the equivalent vertical FOV. Your application controls LOD switching and hiding/replacing the original model. `Update()` does not modify originals, connect frame events, or allocate editable assets.

Single BaseParts should use their `CFrame` and `Size`. Models use `GetBoundingBox()`; if changing PrimaryPart or geometry since baking, supply the original bake basis and corresponding size. Uniformly scaled copies work. A billboard cannot reproduce arbitrary nonuniform mesh deformation.

## Sources and layout

Each layer accepts a URL string, a `Content` (including `Content.fromObject(editableImage)`), or a dictionary of individual shot contents:

```lua
local colors: { [string]: ImposterRender.ImageContent } = {}
for index = 0, 7 do
    colors[ImposterRender.Util.ShotKey(index)] = uploadedShotUrls[index + 1]
end
local ok, err = batch:Register("grass-v1", { Color = colors }, {
    PanShotCount = 8,
    TiltShotCount = 1,
    MaxResolutionPx = 252,
    PaddingPx = 2,
    TiltConstraints = NumberRange.new(-180, 180),
    TiltOffset = 0,
})
```

Every individual image includes the baker's padding. Directory exports group layers by shot, such as `shot_0000/color.png` and `shot_0000/normal.png`; upload these files and keep using `shot_0000` as the runtime map key. A sheet must match `Util.AtlasSize(layout)` exactly. Each provided map dictionary must contain every `shot_####` key; missing maps use neutral defaults. Source images are streamed one at a time into the shared atlas, then destroyed. Registration yields while loading. A model becomes available to `Add()` only after all its maps succeed. Failed registration returns its atlas allocation. Concurrent registrations are rejected with a retryable message.

By default, the batch enables `color`, `normal`, `roughness`, `metalness`, and `emissive`. For lower memory use, declare `local layers: { ImposterRender.Layer } = { "color" }` and pass it as `Options.Layers`. Disabled layers are not loaded. `Emissive` consumes the grayscale emissive mask; the optional constructor `EmissiveStrength` and `EmissiveTint` apply to the entire batch. The manifest records source emission settings. Use separate batches for incompatible emission settings.

The `id` is a model-version cache key. Register it once, then call `Add` for each copy. Registering an existing ID fails rather than silently changing active resources. Destroy its handles and `Unregister` before replacing it. `Handle:Update(cf, size)` moves/resizes one instance. `Handle:Destroy()` and `Renderer:Destroy()` are idempotent.

## Nearby real models and instance caching

Register a static `Model` or `BasePart` template under the same cache key as its baked images. Existing and future handles then switch automatically: nearby handles use cached real geometry, and distant ones use their shared imposter quad. Keep templates in `ReplicatedStorage`; the renderer leaves the source instances untouched.

```lua
-- After batch:Register("birch-v1", sources, layout):
local template = game.ReplicatedStorage.Birch
local ok, message = batch:RegisterTemplate("birch-v1", template, { CanCollide = true, CanQuery = true })
assert(ok, message)
local count, warmError = batch:Prewarm("birch-v1", 16)
assert(count >= 16, warmError)

batch:SetLodOptions({
    NearDistance = 48,
    FarDistance = 64,
    MaxRealInstances = 64,
    MaxTransitionsPerFrame = 4,
    MaxCreatesPerFrame = 1,
    ReplacementMargin = 4,
})
-- The usual batch:Update(camera.CFrame, camera.FieldOfView, availableMs)
-- now performs both imposter updates and real-model swaps.
handle:SetLodEnabled(false) -- Keep a particular instance as an imposter.
local real: Model? = handle:GetRealInstance() -- Borrowed cached wrapper; nil when using an imposter.
```

`Options.Lod` accepts the same fields; the values above are defaults. Distances are measured from the camera to each model's bounds center. The nearest eligible candidates are considered first. When the real-instance cap is full, a candidate must be at least `ReplacementMargin` studs closer than the farthest active instance to replace it (the boundary itself retains the current instance). Active real models stay real until they cross `FarDistance`. This distance band and replacement margin prevent rapid oscillation. Set `MaxRealInstances = 0` to return all models to imposters over the configured frame budgets. `SetLodOptions` replaces the configuration, defaulting omitted fields.

Use `Options.InstanceCache` to bound pooled geometry separately from editable assets:

| Option | Default | Meaning |
| --- | --- | --- |
| `MaxInstances` | 128 | total active and idle cached clones; must cover `MaxRealInstances` |
| `MaxPartsPerInstance` | 128 | maximum BaseParts in any template |
| `MaxPartsPerFlush` | 256 | maximum parts submitted to one bulk move; must cover one template |
| `WorldRoot` | `workspace` | Workspace or WorldModel receiving the bulk move |
| `Parent` | `WorldRoot` | parent for the cache's active-instance Folder; must be inside that world |
| `CanCollide` / `CanQuery` | false | opt-in flags for the anchored visual parts |

`TemplateOptions.CanCollide` and `TemplateOptions.CanQuery` override the cache defaults for an individual model key. For example, enable these for trees and pillars while leaving grass and lilypads non-collidable.

Prewarming ensures the requested number of clones for a template, including active clones. It runs synchronously, so call it during loading. Idle clones remain unparented and are reused by model key; if the cache is full, an idle clone of another key can be reclaimed. Active clones are never reclaimed by the cache. Runtime growth is capped by `MaxCreatesPerFrame`; set it to zero after prewarming to prevent cloning during updates. Cache exhaustion keeps the imposter visible. Each template also has one private, sanitized snapshot, separate from the clone count.

All changed parts, across all promoted or moved models, are submitted through one [`WorldRoot:BulkMoveTo`](https://create.roblox.com/docs/reference/engine/classes/WorldRoot#BulkMoveTo) call per renderer update using `FireCFrameChanged`. Models are placed before their quads are hidden. On demotion, the quad is restored before the clone is unparented. Returning an instance to its pool does not move it to a distant parking coordinate. No texture or mesh reallocation occurs during a swap. The original imposter slot stays reserved for immediate reuse.

The scheduler shares the existing update deadline with selection and swaps, reserving time for the bulk move. Clone creation, transitions, and moved parts also have separate caps. A replacement counts as two transitions. These engine calls are atomic, so one complex clone or bulk move can overrun a soft deadline; prewarm and lower the part/transition caps for tighter frame times. `GetUsage()` includes `RealInstances`, `CachedInstances`, `BulkMovedParts`, and `LodTransitions`; `UpdateMilliseconds` includes the bulk move and visibility handoff.

Template bounds default to `Model:GetBoundingBox()` or `BasePart.CFrame/Size`. For a custom bake basis, pass `{ BoundingBoxCFrame = originalBoundsCf, BoundingBoxSize = originalBoundsSize }` as the third argument to `RegisterTemplate`. Multipart offsets, rotations, attachments, and uniform scale are preserved. `Handle:Update` moves an active real model through the same bulk queue. Nonuniformly scaled handles stay as imposters. Clones are static, anchored visuals with scripts removed and touch disabled; animated rigs and server-authoritative gameplay need a separate system. Inspect borrowed models without modifying or destroying them, since they can be reassigned to other handles.

`UnregisterTemplate(id)` frees its idle pool and snapshot; it refuses while any real instance uses that template. Disable LOD on those handles (or set the real limit to zero) and update until they have demoted first. Destroying a handle returns its clone; unregistering an unused model also removes its template. Destroying the renderer disposes of active clones, idle clones, snapshots, and the cache Folder.

For custom integrations, `ImposterRender.InstanceCache` exports a typed standalone cache with `New`, `Register`, `Prewarm`, `Acquire`, `Queue`, `Flush`, `Release`, `Unregister`, and `Destroy`. Queueing the same lease repeatedly keeps its latest transform; releasing it cancels pending placement. `Lod.Resolve`, `Lod.Distance`, and `Lod.ShouldReplace` expose the selection configuration and distance policy.

## Frame scheduling

Updates default to a 240 FPS target with one quarter of the frame interval (about 1.04 ms) available to the renderer. Configure `Options.UpdateBudget`, or change it with `batch:SetUpdateBudget({ TargetFps = 240, MaxMilliseconds = 1 })`. `batch:Update(cameraCFrame, verticalFov, availableMilliseconds)` optionally accepts the remaining CPU headroom for this frame; zero defers all work. The effective budget is the smaller of that headroom and the configured maximum.

Distance-queue construction and mesh updates both share the deadline. Each pass snapshots the camera position, builds its queue incrementally, then processes the closest model centers first. Unfinished work resumes next frame. The pass finishes before distances are refreshed, preventing distant instances from starving during continuous camera motion. Each visited instance uses the current camera and latest model bounds to choose its shot, including continuously moving handles. Removed and reused handles invalidate stale queue entries. New instances may remain hidden until their first scheduled update.

`GetUsage()` exposes `PendingInstances` (remaining queue estimate), `CheckedInstances`, `UpdatedInstances`, and `UpdateMilliseconds` for profiling. The last three describe the most recent update call. Unchanged shots skip mesh writes. This is a cooperative CPU budget: one in-progress item can finish slightly past the deadline. It cannot guarantee total game FPS or account for GPU time; reserve time for the rest of your game's frame, and share the available budget when updating multiple batches. The demo caps this work at 1 ms and reserves another 1 ms after accounting for earlier render callbacks.

## Allocation limits

`Options.Limits` configures local soft budgets. `GetUsage()` reports actual batch counts and texture pixels; `SetLimits()` can change logical limits within allocated capacity. `ImposterRender.Limits.Resolve()` validates and freezes a budget without allocating anything. Budgets are per batch; applications that create multiple batches should account for their aggregate usage.

| Limit | Default | Meaning |
| --- | --- | --- |
| `MaxTextureSize` | 1024 | square atlas dimension, at most Roblox's 1024 limit |
| `MaxTexturePixels` | 6,291,456 | sum of all atlas pixels plus transient source reserve |
| `MaxEditableImages` | 6 | five persistent layer images plus one transient source |
| `MaxEditableMeshes` | 1 | one mesh per renderer |
| `MaxInstances` | 256 | preallocated quad capacity |
| `MaxModels` | 64 | registered model keys |
| `WorldExtent` | 512 | half extent in studs around batch `Origin`, 0.001–1024 |

These limits cannot raise Roblox's engine budget. They exclude engine overhead and externally owned source objects. A conservative 1024²-pixel reserve is required for one temporary source image. Limit values must be positive; disable optional layers through `Options.Layers`.

All views for each registered model occupy one contiguous rectangle in the shared atlas. A default 768×768 bake fits once in a 1024×1024 atlas, while any number of copies up to mesh capacity share it. To fit many distinct models, bake smaller sheets or create more batches. Atlas allocations never move and adjacent free rectangles merge on unload; fragmentation can still prevent an allocation.

Texture dimensions, mesh capacity growth, and `WorldExtent` changes require a new renderer. `SetLimits()` cannot shrink below current usage. Mesh vertices stay within fixed invisible bound sentinels; `Add`/`Handle:Update` check the billboard's circumscribed radius against `WorldExtent`. Use spatial batches for large worlds. The shared MeshPart has no collision or shadow casting. Avoid resizing `batch.Part`, changing its origin after adding handles, destroying its images, or modifying `batch.Mesh` directly.

## Utilities and types

The header exports `Util`, `Atlas`, `Limits`, `Scheduler`, `Lod`, and `InstanceCache`, plus `Layout`, `LayoutInput`, `Shot`, `Solution`, `Layer`, `ImageContent`, `Source`, `Sources`, `Options`, `LimitOptions`, `Budget`, `UpdateBudgetInput`, `UpdateBudget`, `LodOptions`, `LodConfig`, `InstanceCacheOptions`, `TemplateOptions`, `Usage`, `Renderer`, and `Handle` types. `Scheduler` exposes the pure distance queue and budget validation for custom renderers and deterministic tests.

`Util` exports `Layout`, `LayoutFromAttributes`, `TileSize`, `Grid`, `AtlasSize`, `ShotKey`, `Basis`, `Shots`, `SelectShot`, and `Solve`. These functions require no editable assets. `Atlas` exports `New`, `Allocate`, and `Release` for custom packing integrations.

```lua
local layout = ImposterRender.Util.Layout()
local shots = ImposterRender.Util.Shots(layout) -- cache once per model
local result = ImposterRender.Util.Solve(cameraCFrame, verticalFovDegrees, boxCFrame, boxSize, layout, shots)
-- result.Shot.Key / Index, result.CFrame / Size, result.UVMin / UVMax
-- result.ProjectedHeight is frame height as a fraction of viewport height.
```

The solver chooses the closest sampled direction by dot product, including polar/inverted tilts, with deterministic first-index ties. The quad uses that shot's exact yaw, pitch, and roll relative to the model bounds. With eight level shots, rotation changes in 45° steps at the 22.5° midpoints. Between boundaries, geometry and normal-map lighting keep their baked orientation; single-level bakes stay upright. Mesh writes are skipped until the shot or model/batch transform changes. FOV affects projected size reporting; the physical quad remains in world units. Sampling uses nearest views, with no crossfade, parallax correction, or depth reconstruction. Orthographic capture is intended for distant objects.

For a fixed horizontal capture, bake a root with `PanShotCount = 1`, `TiltShotCount = 1`, and `TiltOffset = 90` (the default tilt range has midpoint zero). Pass its generated layout to `Register`, or use `Util.LayoutFromAttributes(root)` when the root still has the original bake settings. The selected top-down plane stays aligned to the model even as the camera orbits. `TiltOffset` defaults to zero for older layouts and is added after sampling `TiltConstraints`.

Use `Lighting.LightingStyle = Enum.LightingStyle.Realistic` and `PrioritizeLightingQuality = true` for the demo's PBR comparisons. Soft lighting can shade a normal-mapped plane differently from equivalent geometry. The package leaves the experience's Lighting settings to its owner. Texture resolution, native material roughness, shadows, and missing geometric depth can still produce differences from the original.
