# Downloadable Studio demo

Open [`test/demo/demo.rbxl`](../test/demo/demo.rbxl) in Roblox Studio and press **Play (F5)**. Use Play rather than Run: the renderer runs in a LocalScript and needs a player client. GitHub releases also attach it as `demo.rbxl`; CI runs provide a `demo-place` artifact.

The saved place includes a baseplate, neutral spawn point, and labeled model previews visible in Edit mode. Live imposters appear after Play starts. The character spawns with normal gravity and the standard Roblox movement and camera controls.

The demo includes the full `imposter-render` source, all four test model originals, and the baked texture pixels. There are no placeholder asset IDs, external scripts, plugins, HTTP requests, or Wally installs to configure. Original MeshParts still reference their original Roblox mesh/texture assets; the imposter maps are embedded directly in the place.

The front row compares each original against an imposter. A seeded scatter of 4,096 decorations brings the total to **4,100 instances**, with distant imposters using one EditableMesh (16,406 vertices, 8,202 triangles including bound sentinels) and five shared material maps. The baseplate is **1,536×1,536 studs**, four times its previous area. Decorations have random positions and continuous yaw, a minimum six-stud center separation, and a clear zone around spawn and the comparison row. Each model still has 1,024 field copies. Grass is one-third its previous size in originals, imposters, and cached real copies.

Change `FieldCount`, `ScatterSeed`, and `MinimumSpacing` in `ReplicatedStorage.Demo.Scene` to adjust the scatter. Keep placements within `WorldExtent` and the package's 9,999-instance mesh limit. Changes to `BaseplateSize` or `Center` also require updating the physical baseplate in `examples/build_demo.rs`. A compact 1024×1024 runtime atlas holds all four models. Each model receives up to a 504×504 atlas region: eight-view captures use 164×164 pixels per shot, while the single lilypad top view retains all 500×500 pixels. Tiles have two pixels of padding. Downsampling uses alpha-aware filtering and normalized normal vectors; full-resolution shots are copied without additional filtering.

The field automatically promotes up to **64 prioritized instances** to real geometry using a movement corridor around the character. It predicts 0.75 seconds ahead (120 studs at 160 studs/second, capped at 192 studs), with priority-distance thresholds of 48 for promotion and 64 for demotion. Movement intent and physical velocity guide the prediction independently of the camera; while stationary, camera facing supplies a 24-stud lookahead. The priority distance is distance from the travel segment plus 20% of distance along it, so immediate surroundings remain important. A shared instance cache prewarms 16 clones of each model, reuses them on subsequent swaps, and batches placement with `BulkMoveTo`. The labeled comparison-row imposters are excluded from automatic swaps. `RealNearDistance`, `RealFarDistance`, `RealLookAheadSeconds`, `RealMaxLookAheadDistance`, `RealCameraLookAheadDistance`, `MaxRealInstances`, and `RealPrewarmPerModel` in `Demo.Scene` configure the test. Active real models appear under `Workspace.ImposterRealInstances`; idle clones are unparented. Tree and pillar originals and their pooled real copies have collision enabled; grass and lilypads remain non-collidable.

Grass, pillars, and trees use eight level views. Their quads snap to the selected capture's exact 45° yaw increments and stay upright. The lilypad RBXM carries `PanShotCount = 1`, `TiltShotCount = 1`, `TiltOffset = 90`, and `MaxResolutionPx = 500`: its one top-down view stays horizontal in model space with enough detail for the narrow rims. The builder preserves each model's layout attributes on its embedded asset folder, adjusting only resolution and padding for the compact images.

The demo uses Realistic lighting with lighting quality prioritized so normal maps receive directional lighting consistent with the source geometry. Low-resolution silhouettes, missing depth/shadows, and approximate default roughness still limit the match at close range. The color maps include configurable capture-space cavity shading to retain recessed details; raw albedo and separate occlusion maps are also exported by the baker.

The update scheduler targets 240 FPS with a 1 ms CPU budget. A spatial queue prioritizes real models along the predicted route without waiting for distant decorations. It receives up to 65% of the shared work budget, with the rest available to visual updates. Unfinished work resumes on later frames, including queue construction and real-model swaps. At most four transitions and one new clone are allowed per update; returning a clone to its pool reuses the existing allocation. Priority work refreshes after significant movement or turns. Each background visual pass completes before reprioritizing, so distant entries are eventually refreshed. `TargetFps`, `UpdateBudgetMilliseconds`, and `FrameReserveMilliseconds` in `Demo.Scene` configure this behavior. The client subtracts time spent in earlier render callbacks and reserves another 1 ms before passing its remaining headroom to the renderer.

Startup resource counts and allocation failures appear in Studio Output. Use Studio's performance tools to profile camera motion and shot transitions; unchanged shots skip mesh writes. This is a stress workload, so performance depends on the device. If you publish the place as an experience, enable **Mesh / Image APIs** in its settings; Roblox's editable-asset access and device memory limits still apply.

An error from `user_Luau.rbxm.plugin` / `LoadSettings` comes from a locally installed Studio plugin. This demo does not call `loadstring` and needs no plugins; update or disable that plugin if it errors.

## Rebuild

From the repository root, with Rust and the Rokit tools installed:

```sh
rojo build demo.project.json --output test/tooling/demo-base.rbxl
cargo run --locked --example build_demo -- test/tooling/demo-base.rbxl test/demo/demo.rbxl
```

Create `test/tooling` first if it is absent. The assembler uses the committed test models and PNG bakes, so this step does not fetch Roblox asset data. Regenerate the bake PNGs first if changing a model. CI builds this file and strictly checks the demo's Luau sources.

To rebake the higher-resolution lilypad from cached assets:

```sh
cargo run --locked -- test/lilypad.rbxm test/demo/lilypad.png --offline --overwrite --max-memory-mib 2048
```

The larger memory allowance covers the baker's conservative worst-case overlap estimate; runtime atlas size and mesh count stay unchanged.

Texture payloads are standard Zstandard frames containing RGBA pixels, encoded as Base64 and split across StringValues. `Demo.Assets` decodes them into EditableImages at startup and passes `Content.fromObject(...)` into the package. Temporary source images are destroyed after registration. This avoids uploading baked maps to a particular creator account and makes the downloadable example portable.
