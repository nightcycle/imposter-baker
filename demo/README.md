# Downloadable Studio demo

Open [`test/demo/demo.rbxl`](../test/demo/demo.rbxl) in Roblox Studio and press **Play (F5)**. Use Play rather than Run: the renderer runs in a LocalScript and needs a player client. GitHub releases also attach it as `demo.rbxl`; CI runs provide a `demo-place` artifact.

The saved place includes a baseplate, neutral spawn point, and labeled model previews visible in Edit mode. Live imposters appear after Play starts. The character spawns with normal gravity and the standard Roblox movement and camera controls.

The demo includes the full `imposter-render` source, all four test model originals, and the baked texture pixels. There are no placeholder asset IDs, external scripts, plugins, HTTP requests, or Wally installs to configure. Original MeshParts still reference their original Roblox mesh/texture assets; the imposter maps are embedded directly in the place.

The front row compares each original against an imposter. Behind it, another 48 copies use the same single EditableMesh and five shared material maps. A compact 512×512 runtime atlas holds all four models. Source captures are reduced to 80×80 pixels with two pixels of padding per tile, which keeps editable-image memory use low and makes the imposter effect easy to inspect.

The supplied bakes use eight level views. They rotate around their model's up axis and stay upright as the camera moves above or below them. Thin horizontal geometry such as the lilypad is therefore captured edge-on; bake additional tilt views for that kind of asset in production.

Startup resource counts and allocation failures appear in Studio Output. If you publish the place as an experience, enable **Mesh / Image APIs** in its settings; Roblox's editable-asset access and device memory limits still apply.

An error from `user_Luau.rbxm.plugin` / `LoadSettings` comes from a locally installed Studio plugin. This demo does not call `loadstring` and needs no plugins; update or disable that plugin if it errors.

## Rebuild

From the repository root, with Rust and the Rokit tools installed:

```sh
rojo build demo.project.json --output test/tooling/demo-base.rbxl
cargo run --locked --example build_demo -- test/tooling/demo-base.rbxl test/demo/demo.rbxl
```

Create `test/tooling` first if it is absent. The assembler uses the committed test models and PNG bakes, so this step does not fetch Roblox asset data. Regenerate the bake PNGs first if changing a model. CI builds this file and strictly checks the demo's Luau sources.

Texture payloads are standard Zstandard frames containing RGBA pixels, encoded as Base64 and split across StringValues. `Demo.Assets` decodes them into EditableImages at startup and passes `Content.fromObject(...)` into the package. Temporary source images are destroyed after registration. This avoids uploading baked maps to a particular creator account and makes the downloadable example portable.
