//! Assemble the portable Studio demo from the Rojo place and committed PNGs.
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use glam::Vec3;
use image::{RgbaImage, imageops};
use imposter_baker::{config::Settings, scene};
use rbx_dom_weak::{
    InstanceBuilder, WeakDom,
    types::{Attributes, CFrame, Color3, Enum, Matrix3, Ref, UDim, UDim2, Vector3},
};
use serde::Deserialize;
use std::{collections::BTreeMap, fs, path::Path};

const RESOLUTION: u32 = 80;
const PADDING: u32 = 2;
const MAPS: [&str; 5] = ["color", "normal", "roughness", "metalness", "emissive"];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    settings: Settings,
    bounds_c_frame: [f32; 12],
    bounds_size: [f32; 3],
    columns: u32,
    rows: u32,
    layers: BTreeMap<String, String>,
}

fn vector(v: Vec3) -> Vector3 {
    Vector3::new(v.x, v.y, v.z)
}
fn frame(position: Vec3, rotation: glam::Mat3) -> CFrame {
    let rows = rotation.transpose();
    CFrame::new(
        vector(position),
        Matrix3::new(
            vector(rows.x_axis),
            vector(rows.y_axis),
            vector(rows.z_axis),
        ),
    )
}

fn compact(source: &RgbaImage, manifest: &Manifest) -> Result<RgbaImage> {
    let source_tile = manifest.settings.tile_size();
    ensure!(
        source.dimensions() == (manifest.columns * source_tile, manifest.rows * source_tile),
        "atlas dimensions do not match its manifest"
    );
    let tile = RESOLUTION + 2 * PADDING;
    let mut result = RgbaImage::new(manifest.columns * tile, manifest.rows * tile);
    for index in 0..manifest.settings.count() {
        let column = index % manifest.columns;
        let row = index / manifest.columns;
        let capture = imageops::crop_imm(
            source,
            column * source_tile + manifest.settings.padding_px,
            row * source_tile + manifest.settings.padding_px,
            manifest.settings.max_resolution_px,
            manifest.settings.max_resolution_px,
        )
        .to_image();
        let image = imageops::resize(
            &capture,
            RESOLUTION,
            RESOLUTION,
            imageops::FilterType::Lanczos3,
        );
        for y in 0..tile {
            for x in 0..tile {
                let sx = x.saturating_sub(PADDING).min(RESOLUTION - 1);
                let sy = y.saturating_sub(PADDING).min(RESOLUTION - 1);
                let mut pixel = *image.get_pixel(sx, sy);
                if x < PADDING || y < PADDING || x >= tile - PADDING || y >= tile - PADDING {
                    pixel[3] = 0;
                }
                result.put_pixel(column * tile + x, row * tile + y, pixel);
            }
        }
    }
    Ok(result)
}

fn embed_image(dom: &mut WeakDom, parent: Ref, name: &str, image: &RgbaImage) -> Result<()> {
    let bytes = zstd::bulk::compress(image.as_raw(), 9)?;
    let encoded = STANDARD.encode(bytes);
    let texture = dom.insert(
        parent,
        InstanceBuilder::new("Folder")
            .with_name(name)
            .with_property(
                "Attributes",
                Attributes::new()
                    .with("Width", image.width() as f64)
                    .with("Height", image.height() as f64),
            ),
    );
    for (index, chunk) in encoded.as_bytes().chunks(32_000).enumerate() {
        dom.insert(
            texture,
            InstanceBuilder::new("StringValue")
                .with_name(format!("Chunk_{index:04}"))
                .with_property("Value", String::from_utf8(chunk.to_vec())?),
        );
    }
    Ok(())
}

fn part(name: &str, position: Vec3, size: Vec3, color: Color3) -> InstanceBuilder {
    InstanceBuilder::new("Part")
        .with_name(name)
        .with_property("Anchored", true)
        .with_property("CFrame", frame(position, glam::Mat3::IDENTITY))
        .with_property("Size", vector(size))
        .with_property("Color", color)
        .with_property("TopSurface", Enum::from_u32(0))
        .with_property("BottomSurface", Enum::from_u32(0))
}

fn label(dom: &mut WeakDom, parent: Ref, text: &str, position: Vec3, color: Color3) {
    let anchor = dom.insert(
        parent,
        part(
            "DisplayLabel",
            position,
            Vec3::new(8.0, 1.2, 0.2),
            Color3::new(0.067, 0.086, 0.125),
        )
        .with_property("CanCollide", false)
        .with_property("CastShadow", false),
    );
    let gui = dom.insert(
        anchor,
        InstanceBuilder::new("SurfaceGui")
            .with_property("Face", Enum::from_u32(5))
            .with_property("CanvasSize", rbx_dom_weak::types::Vector2::new(640.0, 96.0))
            .with_property("LightInfluence", 0.0_f32),
    );
    dom.insert(
        gui,
        InstanceBuilder::new("TextLabel")
            .with_property("Size", UDim2::new(UDim::new(1.0, 0), UDim::new(1.0, 0)))
            .with_property("BackgroundTransparency", 1.0_f32)
            .with_property("TextColor3", color)
            .with_property("TextSize", 36.0_f32)
            .with_property("Text", text.to_owned()),
    );
}

fn stage(dom: &mut WeakDom) -> Result<Ref> {
    let workspace = dom
        .descendants()
        .find(|i| i.class == "Workspace")
        .context("base place has no Workspace")?
        .referent();
    dom.insert(
        workspace,
        part(
            "Baseplate",
            Vec3::new(0.0, -0.5, 20.0),
            Vec3::new(110.0, 1.0, 90.0),
            Color3::new(0.133, 0.161, 0.2),
        ),
    );
    dom.insert(
        workspace,
        InstanceBuilder::new("SpawnLocation")
            .with_name("SpawnLocation")
            .with_property("Anchored", true)
            .with_property("Neutral", true)
            .with_property("Enabled", true)
            .with_property("Duration", 0_i32)
            .with_property("Size", Vector3::new(8.0, 1.0, 8.0))
            .with_property(
                "CFrame",
                frame(
                    Vec3::new(0.0, 0.5, -15.0),
                    glam::Mat3::from_rotation_y(std::f32::consts::PI),
                ),
            )
            .with_property("Color", Color3::new(0.467, 0.89, 0.714)),
    );
    let scene = dom.insert(
        workspace,
        InstanceBuilder::new("Folder").with_name("DemoScene"),
    );
    let eye = Vec3::new(0.0, 28.0, -65.0);
    let back = (eye - Vec3::new(0.0, 4.0, 14.0)).normalize();
    let right = Vec3::Y.cross(back).normalize();
    let camera = dom.insert(
        workspace,
        InstanceBuilder::new("Camera")
            .with_name("Camera")
            .with_property(
                "CFrame",
                frame(eye, glam::Mat3::from_cols(right, back.cross(right), back)),
            )
            .with_property(
                "Focus",
                frame(Vec3::new(0.0, 4.0, 14.0), glam::Mat3::IDENTITY),
            )
            .with_property("FieldOfView", 60.0_f32),
    );
    dom.get_by_ref_mut(workspace)
        .unwrap()
        .properties
        .insert("CurrentCamera".into(), camera.into());
    Ok(scene)
}

fn preview(dom: &mut WeakDom, parent: Ref, template: Ref, index: usize, name: &str, size: Vec3) {
    let x = (index as f32 - 1.5) * 18.0;
    for offset in [-4.5, 4.5] {
        dom.insert(
            parent,
            part(
                "DisplayPlinth",
                Vec3::new(x + offset, 0.5, 0.0),
                Vec3::new(8.5, 1.0, 10.0),
                Color3::new(56.0 / 255.0, 66.0 / 255.0, 81.0 / 255.0),
            ),
        );
        label(
            dom,
            parent,
            &format!(
                "{}\n{}",
                name.to_uppercase(),
                if offset < 0.0 { "ORIGINAL" } else { "IMPOSTER" }
            ),
            Vec3::new(x + offset, 1.5, -6.0),
            Color3::new(0.467, 0.89, 0.714),
        );
    }
    let model = dom.clone_within(template);
    dom.transfer_within(model, parent);
    dom.get_by_ref_mut(model).unwrap().name = format!("{name}_original");
    let parts: Vec<_> = dom.descendants_of(model).map(|i| i.referent()).collect();
    let translation = Vec3::new(x - 4.5, size.y / 2.0 + 1.0, 0.0);
    for referent in parts {
        let i = dom.get_by_ref(referent).unwrap();
        if let Some(cf) = scene::cf(i, "CFrame") {
            let translated = frame(scene::vec(cf.position) + translation, scene::rotation(cf));
            dom.get_by_ref_mut(referent)
                .unwrap()
                .properties
                .insert("CFrame".into(), translated.into());
        }
    }
}

fn build(base: &Path, output: &Path) -> Result<()> {
    let mut place = scene::read_dom(base)?;
    let stage = stage(&mut place)?;
    let storage = place
        .descendants()
        .find(|i| i.class == "ReplicatedStorage")
        .context("base place has no ReplicatedStorage")?
        .referent();
    let assets = place.insert(
        storage,
        InstanceBuilder::new("Folder")
            .with_name("DemoAssets")
            .with_property(
                "Attributes",
                Attributes::new().with("MaxResolutionPx", RESOLUTION as f64),
            ),
    );
    for (index, name) in ["grass", "pillar", "lilypad", "tree"]
        .into_iter()
        .enumerate()
    {
        let manifest: Manifest =
            serde_json::from_slice(&fs::read(format!("test/demo/{name}.imposter.json"))?)?;
        ensure!(
            manifest.settings.pan_shot_count == 8
                && manifest.settings.tilt_shot_count == 1
                && manifest.settings.tilt_constraints == [-180.0, 180.0],
            "demo assumes eight level captures"
        );
        let bounds = Vec3::from_array(manifest.bounds_size);
        let scale = 10.0 / bounds.length();
        let folder = place.insert(
            assets,
            InstanceBuilder::new("Folder")
                .with_name(name)
                .with_property(
                    "Attributes",
                    Attributes::new().with("BoundsSize", vector(bounds * scale)),
                ),
        );
        let template = place.insert(folder, InstanceBuilder::new("Model").with_name("Original"));
        let mut original = scene::read_dom(Path::new(&format!("test/{name}.rbxm")))?;
        let root = original.root().children()[0];
        let values = manifest.bounds_c_frame;
        let bounds_cf = CFrame::new(
            Vector3::new(values[0], values[1], values[2]),
            Matrix3::new(
                Vector3::new(values[3], values[4], values[5]),
                Vector3::new(values[6], values[7], values[8]),
                Vector3::new(values[9], values[10], values[11]),
            ),
        );
        let inverse = scene::rotation(bounds_cf).transpose();
        let instances: Vec<_> = original
            .descendants_of(root)
            .map(|i| i.referent())
            .collect();
        for referent in instances {
            let i = original.get_by_ref(referent).unwrap();
            if let (Some(cf), Some(size)) = (scene::cf(i, "CFrame"), scene::v3(i, "Size")) {
                let position =
                    inverse * (scene::vec(cf.position) - scene::vec(bounds_cf.position)) * scale;
                let cf = frame(position, inverse * scene::rotation(cf));
                let i = original.get_by_ref_mut(referent).unwrap();
                i.properties.insert("CFrame".into(), cf.into());
                i.properties
                    .insert("Size".into(), vector(size * scale).into());
                i.properties.insert("Anchored".into(), true.into());
                i.properties.insert("CanCollide".into(), false.into());
            }
        }
        original.transfer(root, &mut place, template);
        preview(&mut place, stage, template, index, name, bounds * scale);
        for map in MAPS {
            let path = Path::new("test/demo").join(&manifest.layers[map]);
            let image = compact(&image::open(path)?.to_rgba8(), &manifest)?;
            embed_image(&mut place, folder, map, &image)?;
        }
    }
    // The place remains readable in edit mode before its runtime scripts run.
    place.insert(storage,InstanceBuilder::new("ModuleScript").with_name("READ_ME")
        .with_property("Source","--!strict\n-- IMPOSTER BAKER DEMO\n-- Press Play (F5), not Run. Walk and look around with normal Roblox controls.\n-- The front row compares original models with imposters; 48 more copies sit behind it.\n-- Texture pixels are embedded: no uploads, HTTP service, Wally install, or plugins are needed.\n-- Published experiences require Mesh / Image APIs enabled in their settings.\n-- Package source: ReplicatedStorage.ImposterRender\nreturn nil\n"));
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    rbx_binary::to_writer(fs::File::create(output)?, &place, place.root().children())?;
    let loaded = scene::read_dom(output)?;
    ensure!(
        loaded
            .descendants()
            .filter(|i| i.class == "StringValue")
            .count()
            >= 20,
        "missing embedded image payloads"
    );
    println!(
        "Built {} ({} bytes)",
        output.display(),
        fs::metadata(output)?.len()
    );
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    ensure!(
        args.len() == 2,
        "usage: cargo run --example build_demo -- BASE.rbxl OUTPUT.rbxl"
    );
    build(Path::new(&args[0]), Path::new(&args[1]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgba;
    #[test]
    fn compact_capture_preserves_tile_layout_and_transparent_padding() {
        let settings = Settings::default();
        let manifest = Manifest {
            settings,
            bounds_c_frame: [0.0; 12],
            bounds_size: [1.0; 3],
            columns: 3,
            rows: 3,
            layers: BTreeMap::new(),
        };
        let image = RgbaImage::from_pixel(768, 768, Rgba([23, 45, 67, 255]));
        let compact = compact(&image, &manifest).unwrap();
        assert_eq!(compact.dimensions(), (252, 252));
        for index in 0..8 {
            let x = (index % 3) * 84;
            let y = (index / 3) * 84;
            assert_eq!(compact.get_pixel(x, y).0, [23, 45, 67, 0]);
            assert_eq!(compact.get_pixel(x + 2, y + 2).0, [23, 45, 67, 255]);
        }
        assert_eq!(compact.get_pixel(200, 200).0, [0, 0, 0, 0]);
    }
}
