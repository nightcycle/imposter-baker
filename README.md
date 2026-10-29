# imposter-baker

A Rust CLI that reads a Roblox `.rbxm` or `.rbxmx`, rasterizes its geometry, and exports orthographic imposter images with matching SurfaceAppearance maps. Runs on the CPU without Studio or a GPU. Includes the strictly typed Wally runtime in [`imposter-render`](imposter-render).

```sh
imposter-baker "path/to/model.rbxm" "path/to/output/file.png"
imposter-baker "path/to/model.rbxm" "path/to/output/directory"
```

The `.png` extension selects spritesheet output (case insensitive). Other paths select individual images. Existing generated files require `--overwrite`; unrelated files in an output directory are preserved.

Try the package in Studio: download [`demo.rbxl`](test/demo/demo.rbxl), open it, and press **Play**. Spawn and explore with the standard Roblox controls. It compares the four original models with 4,100 imposters sharing one mesh and five texture maps on a 768-stud baseplate. Baked pixels are embedded, so no spritesheet uploads or replacement asset IDs are needed. See the [demo rebuild guide](demo/README.md). Releases also include the place file.

## Build and install

Requires Rust 1.90+ and a native C/C++ toolchain for dependency builds.

```sh
cargo build --locked --release
cargo install --locked --path .
```

To distribute through [Rokit](https://github.com/rojo-rbx/rokit), push a version tag matching both package manifests and `Cargo.lock`, such as `v0.1.0`. The release workflow waits for full CI, then creates ZIPs containing the executable at the archive root for Windows x86_64, Linux x86_64/ARM64, and macOS Intel/ARM64. It also attaches the Wally package, a standalone runtime RBXM, and SHA-256 checksums. See the [release guide](.github/RELEASING.md) for tagging, prereleases, manual runs, and optional automatic Wally publishing.

After that GitHub release has been published, consumers can install it with:

```sh
rokit add nightcycle/imposter-baker@0.1.0
```

Or add `imposter-baker = "nightcycle/imposter-baker@0.1.0"` under `[tools]` in their `rokit.toml`. The repository's own `rokit.toml` installs development tools. Creating a local build does not publish a GitHub release or a Wally registry entry.

## Model attributes

Export exactly one root Model, Folder, or BasePart. Place attributes on that root. Invalid attributes are errors; descendants do not override them.

| Attribute | Type | Default | Allowed |
| --- | --- | --- | --- |
| `PanShotCount` | integer number | 8 | 1–256 |
| `TiltShotCount` | integer number | 1 | 1–256 |
| `MaxResolutionPx` | integer number | 252 | 1–4096 |
| `PaddingPx` | integer number | 2 | 0–64 |
| `TiltConstraints` | NumberRange, degrees | `NumberRange.new(-180, 180)` | ordered within −180…180 |
| `TiltOffset` | number, degrees | 0 | finite within −180…180; added after sampling the tilt range |
| `AmbientOcclusionStrength` | number | 0.75 | 0…1; cavity shading mixed into the runtime color map |
| `AmbientOcclusionRadiusRatio` | number | 0.08 | 0…0.5; sampling radius as a fraction of bounds diagonal |

At most 4096 shots are accepted. Raster memory estimates are checked before allocating output images. The default 512 MiB budget is deliberately conservative and includes a reserve for depth overlap; use `--max-memory-mib` to increase it. Asset decoding has separate per-asset limits.

Pan zero views the model from bounding-box local +Z. Positive pan moves toward +X. Pan samples exclude the repeated 360° endpoint. Tilt samples include both range endpoints; one tilt uses the midpoint. `TiltOffset` is added to every sampled pitch without clamping, so angles beyond ±180° wrap naturally. The default therefore gives eight level views. For views above/below an upright object, a range such as `NumberRange.new(-60, 60)` is often more useful. The full −180…180 range intentionally includes inverted views and duplicate directions.

For a fixed top-down lilypad, set these attributes on the exported root, then rebake:

```lua
model:SetAttribute("PanShotCount", 1)
model:SetAttribute("TiltShotCount", 1)
model:SetAttribute("TiltConstraints", NumberRange.new(0, 0))
model:SetAttribute("TiltOffset", 90)
```

The default tilt range also works with one tilt because its midpoint is zero. `+90` views from the model's local +Y; `-90` views from below. The runtime uses the exact capture orientation, so this one-shot image stays horizontal and does not spin with the camera. The generated Luau layout carries `TiltOffset` (the JSON manifest uses `tiltOffset`); `Util.LayoutFromAttributes(model)` reads the same attributes when using the original bake dimensions.

Shots use zero-based keys `shot_0000`, `shot_0001`, etc. Pan varies fastest: `index = tiltIndex * PanShotCount + panIndex`. Atlas columns are `ceil(sqrt(shotCount))`, rows are `ceil(shotCount / columns)`, and frames fill rows from the top left.

`MaxResolutionPx` is the square capture area. `PaddingPx` is added to every edge, so the default tile is 256×256 and the eight-shot sheet is 768×768. Individual PNGs keep the same tile size and original scale. The world-space capture square has side `boundingBoxSize.Magnitude`, keeping scale consistent across views. Mesh/texture coordinates are transformed relative to the bounding box. Models use PrimaryPart orientation when present, otherwise world axes; a single BasePart uses its own orientation. Use the same bounding-box convention at runtime.

## Layers and metadata

For `tree.png`, output includes:

| File | Meaning |
| --- | --- |
| `tree.png` | sRGB color with cavity shading and straight alpha |
| `tree.albedo.png` | raw sRGB albedo, without cavity shading |
| `tree.occlusion.png` | linear capture-space ambient visibility; white means unoccluded |
| `tree.normal.png` | linear OpenGL tangent-space normals for the imposter quad |
| `tree.roughness.png` | linear grayscale roughness |
| `tree.metalness.png` | linear grayscale metalness |
| `tree.opacity.png` | coverage in RGB; opaque alpha inside the capture area |
| `tree.depth.png` | linear opacity-weighted normalized depth, nearest = 0 |
| `tree.emissive.png` | linear grayscale SurfaceAppearance emissive mask |
| `tree.imposter.json` | settings, bounds, file names, angles, rectangles, conventions, emission settings, warnings |
| `tree.imposter.luau` | frozen typed-compatible layout table for runtime registration |

Directory output groups each snapshot's layers under its shot key: `shot_0000/color.png`, `shot_0000/normal.png`, `shot_0000/roughness.png`, etc. The output root also contains `imposter.json` and `imposter.luau`. Manifest image paths are relative to that root. All layers use identical dimensions and placement. RGB is dilated into transparent borders without increasing opacity. Four subpixel samples, linear color compositing, bilinear texture sampling, depth ordering, and transparent cutouts are enabled by default; `--samples 1` is faster.

Normals encode +R toward quad right, +G toward quad up, +B toward the capture camera. Source tangent normal maps are transformed into this frame. Roughness defaults to 0.6; metalness defaults to 0 except for basic metal material enums. Those defaults are approximations when no source map exists. Emissive strength and tint are retained per source surface in `emissiveSurfaces`; masks remain unmodified. Runtime emission strength and tint are shared per batch, so group objects with compatible emission settings.

Legacy mesh textures replace `Part.Color`; `SpecialMesh.VertexColor` supplies their optional tint. Both legacy color textures and SurfaceAppearance albedo use sRGB, decoded for compositing and encoded once on export. Untextured parts retain their part color.

Legacy TextureID samples, vertex colors, and part tint are multiplied in linear space and encoded to sRGB for SurfaceAppearance export. Source SurfaceAppearance color maps retain their sRGB interpretation. This conversion keeps native texture midtones from becoming darker when moved into PBR maps.

Cavity shading samples the floating-point capture depth and normals before PNG quantization. It adds local contrast around recesses and overlapping surfaces without baking a light direction. Transparent background pixels do not occlude silhouettes. The runtime `color` map combines albedo and this shading because SurfaceAppearance has no separate occlusion input. Set `AmbientOcclusionStrength = 0` to use raw color, or composite the exported `albedo` and `occlusion` maps yourself. This capture-space approximation cannot see hidden geometry or reproduce cast shadows.

## Asset resolution

Mesh and texture bytes usually live in referenced Roblox assets, rather than inside the RBXM. Public asset IDs download from Roblox Asset Delivery and are cached at `.imposter-cache/<id>.bin`. No scripts from the model are executed. Arbitrary embedded HTTP URLs and local file URLs are not fetched.

For private assets or reproducible offline builds, supply exact URL overrides:

```json
{
  "rbxassetid://123": "assets/model.mesh",
  "rbxassetid://456": "assets/albedo.png"
}
```

Paths are relative to the JSON file, not the working directory.

```sh
imposter-baker test/tree.rbxm output/tree.png --asset-map assets.json --offline
```

Use `--cache-dir` to change the cache. Missing/inaccessible assets and unsupported mesh formats fail explicitly. The tool never replaces a missing MeshPart with a box.

## Supported rendering scope

Supports static MeshParts with Roblox mesh formats v1–v5, file SpecialMeshes, block/sphere/cylinder Parts, WedgeParts, CornerWedgeParts, and several primitive SpecialMesh types. Reads legacy texture IDs and modern Content properties. Handles SurfaceAppearance color/normal/roughness/metalness/emissive maps and alpha modes. Skeleton meshes use their stored bind geometry.

This is a standalone material capture renderer. Roblox lighting, shadows, built-in procedural material textures, MaterialVariants, skinning, particles, terrain, GUI, and post effects are not reproduced. Decals and tiled Texture instances emit warnings. Unions/negations and trusses fail with a conversion instruction. Convert unsupported geometry to MeshParts first. Source surfaces are rasterized two-sided, which is useful for foliage but can differ from Studio backface culling. There is a checked limit of 256 overlapping surfaces per sample. Extremely close views remain an approximation because the capture is orthographic.

## Tests and demos

```sh
rokit install
cargo test --locked --all-targets
lune run test/run.luau
cargo test --locked --test baking demo_models -- --ignored
```

The normal suite is offline. The opt-in demo test resolves assets for all four supplied RBXMs and verifies every exported shot contains visible pixels. Generated atlases and all map layers are included under [`test/demo`](test/demo). To export an individual-image demo:

```sh
cargo run --locked -- test/grass.rbxm test/demo/grass-shots --offline
```

On Windows, `./test/check.ps1` runs Rust tests, Clippy, formatting, strict Roblox Luau analysis, pure runtime tests, Wally packaging, and Rojo build. It downloads Roblox type definitions if absent. CI runs the same checks on Linux and tests Rust on Windows/macOS too.

CI also checks the minimum supported Rust version, release tooling, and workflow syntax. Run `python -m unittest discover -s test -p test_release.py` locally with Python 3.11+ to validate the release helpers. Dependabot checks Rust dependencies and GitHub Actions weekly.

`test/luau/Renderer.spec.luau` is the Studio integration test for the real EditableMesh/EditableImage lifecycle. It creates an unparented test container and destroys it. With the test project synced and editable assets enabled, invoke `require(game.ReplicatedStorage.ImposterTests["Renderer.spec"])()` from Studio's command bar. It does not replace or hide the original models.

Roblox API constraints and conventions: [EditableImage](https://create.roblox.com/docs/reference/engine/classes/EditableImage), [EditableMesh](https://create.roblox.com/docs/reference/engine/classes/EditableMesh), [AssetService](https://create.roblox.com/docs/reference/engine/classes/AssetService), [SurfaceAppearance/PBR](https://create.roblox.com/docs/art/modeling/surface-appearance). RBXM parsing uses [rbx-dom](https://github.com/rojo-rbx/rbx-dom); mesh decoding uses [rbx_mesh](https://github.com/krakow10/rbx_mesh).

The runtime can also swap nearby instances to pooled real models with bounded nearest-first scheduling and bulk part movement. See [real-model caching](imposter-render/README.md#nearby-real-models-and-instance-caching) for registration, prewarming, collision overrides, and limits.
