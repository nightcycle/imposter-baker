# imposter-render

Strictly typed Luau runtime for `imposter-baker` layout version 1. One batch owns a single EditableMesh, a single MeshPart, and one shared EditableImage per enabled material layer. Every imposter has its own quad in that mesh, so independent instances can select different shots and still share geometry and textures.

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
    origin = CFrame.new(100, 0, 100),
    limits = {
        maxTextureSize = 1024,
        maxInstances = 256,
        maxEditableMeshes = 1,
        maxEditableImages = 6,
        maxTexturePixels = 6 * 1024 * 1024,
        worldExtent = 512,
    },
}
local batch, createError = ImposterRender.new(options)
assert(batch, createError)

local ok, loadError = batch:register("birch-v1", {
    color = "rbxassetid://COLOR_ATLAS_ID",
    normal = "rbxassetid://NORMAL_ATLAS_ID",
    roughness = "rbxassetid://ROUGHNESS_ATLAS_ID",
    metalness = "rbxassetid://METALNESS_ATLAS_ID",
})
assert(ok, loadError)

local model = workspace:WaitForChild("Birch") :: Model
local boxCFrame, boxSize = model:GetBoundingBox()
local first, addError = batch:add("birch-v1", boxCFrame, boxSize)
assert(first, addError)
local second, secondError = batch:add("birch-v1", boxCFrame + Vector3.new(10, 0, 0), boxSize)
assert(second, secondError)

local connection = RunService.RenderStepped:Connect(function()
    local camera = workspace.CurrentCamera
    if camera then
        batch:update(camera.CFrame, camera.FieldOfView)
    end
end)

-- When disposing:
-- connection:Disconnect()
-- first:destroy()
-- second:destroy()
-- batch:unregister("birch-v1")
-- batch:destroy()
```

Use the camera's **vertical** field of view in degrees. If you use a nonvertical `Camera.FieldOfViewMode`, supply the equivalent vertical FOV. Your application controls LOD switching and hiding/replacing the original model. `update()` does not modify originals, connect frame events, or allocate editable assets.

Single BaseParts should use their `CFrame` and `Size`. Models use `GetBoundingBox()`; if changing PrimaryPart or geometry since baking, supply the original bake basis and corresponding size. Uniformly scaled copies work. A billboard cannot reproduce arbitrary nonuniform mesh deformation.

## Sources and layout

Each layer accepts a URL string, a `Content` (including `Content.fromObject(editableImage)`), or a dictionary of individual shot contents:

```lua
local colors: { [string]: ImposterRender.ImageContent } = {}
for index = 0, 7 do
    colors[ImposterRender.Util.shotKey(index)] = uploadedShotUrls[index + 1]
end
local ok, err = batch:register("grass-v1", { color = colors }, {
    panShotCount = 8,
    tiltShotCount = 1,
    maxResolutionPx = 252,
    paddingPx = 2,
    tiltConstraints = NumberRange.new(-180, 180),
})
```

Every individual image includes the baker's padding. Directory exports group layers by shot, such as `shot_0000/color.png` and `shot_0000/normal.png`; upload these files and keep using `shot_0000` as the runtime map key. A sheet must match `Util.atlasSize(layout)` exactly. Each provided map dictionary must contain every `shot_####` key; missing maps use neutral defaults. Source images are streamed one at a time into the shared atlas, then destroyed. Registration yields while loading. A model becomes available to `add()` only after all its maps succeed. Failed registration returns its atlas allocation. Concurrent registrations are rejected with a retryable message.

By default, the batch enables `color`, `normal`, `roughness`, `metalness`, and `emissive`. For lower memory use, declare `local layers: { ImposterRender.Layer } = { "color" }` and pass it as `Options.layers`. Disabled layers are not loaded. `emissive` consumes the grayscale emissive mask; the optional constructor `emissiveStrength` and `emissiveTint` apply to the entire batch. The manifest records source emission settings. Use separate batches for incompatible emission settings.

The `id` is a model-version cache key. Register it once, then call `add` for each copy. Registering an existing ID fails rather than silently changing active resources. Destroy its handles and `unregister` before replacing it. `Handle:update(cf, size)` moves/resizes one instance. `Handle:destroy()` and `Renderer:destroy()` are idempotent.

## Limits and resource lifetime

`Options.limits` configures local soft budgets. `getUsage()` reports actual batch counts and texture pixels; `setLimits()` can change logical limits within allocated capacity. `ImposterRender.Limits.resolve()` validates and freezes a budget without allocating anything. Budgets are per batch; applications that create multiple batches should account for their aggregate usage.

| Limit | Default | Meaning |
| --- | --- | --- |
| `maxTextureSize` | 1024 | square atlas dimension, at most Roblox's 1024 limit |
| `maxTexturePixels` | 6,291,456 | sum of all atlas pixels plus transient source reserve |
| `maxEditableImages` | 6 | five persistent layer images plus one transient source |
| `maxEditableMeshes` | 1 | one mesh per renderer |
| `maxInstances` | 256 | preallocated quad capacity |
| `maxModels` | 64 | registered model keys |
| `worldExtent` | 512 | half extent in studs around batch `origin`, 0.001–1024 |

These limits cannot raise Roblox's engine budget. They exclude engine overhead and externally owned source objects. A conservative 1024²-pixel reserve is required for one temporary source image. Limit values must be positive; disable optional layers through `Options.layers`.

All views for each registered model occupy one contiguous rectangle in the shared atlas. A default 768×768 bake fits once in a 1024×1024 atlas, while any number of copies up to mesh capacity share it. To fit many distinct models, bake smaller sheets or create more batches. Atlas allocations never move and adjacent free rectangles merge on unload; fragmentation can still prevent an allocation.

Texture dimensions, mesh capacity growth, and `worldExtent` changes require a new renderer. `setLimits()` cannot shrink below current usage. Mesh vertices stay within fixed invisible bound sentinels; `add`/`Handle:update` check the billboard's circumscribed radius against `worldExtent`. Use spatial batches for large worlds. The shared MeshPart has no collision or shadow casting. Avoid resizing `batch.part`, changing its origin after adding handles, destroying its images, or modifying `batch.mesh` directly.

## Utilities and types

The header exports `Util`, `Atlas`, and `Limits`, plus `Layout`, `LayoutInput`, `Shot`, `Solution`, `Layer`, `ImageContent`, `Source`, `Sources`, `Options`, `LimitOptions`, `Budget`, `Usage`, `Renderer`, and `Handle` types.

`Util` exports `layout`, `tileSize`, `grid`, `atlasSize`, `shotKey`, `basis`, `shots`, `selectShot`, and `solve`. These functions require no editable assets. `Atlas` exports `new`, `allocate`, and `release` for custom packing integrations.

```lua
local layout = ImposterRender.Util.layout()
local shots = ImposterRender.Util.shots(layout) -- cache once per model
local result = ImposterRender.Util.solve(cameraCFrame, verticalFovDegrees, boxCFrame, boxSize, layout, shots)
-- result.shot.key / index, result.cframe / size, result.uvMin / uvMax
-- result.projectedHeight is frame height as a fraction of viewport height.
```

The solver chooses the closest sampled direction by dot product, including polar/inverted tilts, with deterministic first-index ties. Billboard roll follows the chosen capture basis. FOV affects projected size reporting; the physical quad remains in world units. Sampling uses nearest views, with no crossfade, parallax correction, or depth reconstruction. Orthographic capture is intended for distant objects.
