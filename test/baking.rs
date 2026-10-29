use glam::{Vec3, Vec4};
use image::GenericImageView;
use imposter_baker::{
    BakeOptions,
    assets::{Assets, asset_id},
    bake,
    config::{Settings, basis},
    geometry, render,
    scene::{self, Material, Object, Scene},
};
use rbx_dom_weak::{
    InstanceBuilder, WeakDom,
    types::{Attributes, CFrame, NumberRange, Variant, Vector3},
};
use std::{fs, path::Path};

fn cube() -> Scene {
    Scene {
        objects: vec![Object {
            geometry: geometry::block(false, false),
            material: Material {
                color: Vec3::new(0.8, 0.2, 0.1),
                surface_tint: Vec3::ONE,
                opacity: 1.0,
                alpha_mode: 1,
                surface: false,
                roughness: 0.7,
                metalness: 0.2,
                color_map: None,
                normal_map: None,
                roughness_map: None,
                metalness_map: None,
                emissive_map: None,
                emissive_tint: Vec3::ONE,
                emissive_strength: 1.0,
            },
        }],
        settings: Settings {
            pan_shot_count: 4,
            max_resolution_px: 24,
            ..Settings::default()
        },
        bounds_cf: CFrame::identity(),
        bounds_size: Vec3::ONE,
        warnings: vec![],
    }
}

#[test]
fn attributes_defaults_overrides_and_invalid_values() {
    assert_eq!(
        Settings::from_attributes(None).unwrap(),
        Settings::default()
    );
    let a = Attributes::new()
        .with("PanShotCount", 12.0)
        .with("TiltShotCount", 3.0)
        .with("TiltConstraints", NumberRange::new(-45.0, 45.0))
        .with("PaddingPx", 0.0);
    let s = Settings::from_attributes(Some(&a)).unwrap();
    assert_eq!(s.count(), 36);
    assert_eq!(s.angles(12), [0.0, 0.0]);
    assert_eq!(s.angles(35), [330.0, 45.0]);
    for n in [0.0, -1.0, 1.5, f64::NAN, f64::INFINITY] {
        assert!(
            Settings::from_attributes(Some(&Attributes::new().with("PanShotCount", n))).is_err()
        );
    }
    assert!(
        Settings::from_attributes(Some(&Attributes::new().with("TiltConstraints", "wrong")))
            .is_err()
    );
}

#[test]
fn layout_and_camera_basis_contract() {
    let s = Settings::default();
    assert_eq!(s.tile_size(), 256);
    assert_eq!(s.grid(), [3, 3]);
    assert_eq!(s.angles(0), [0.0, 0.0]);
    assert_eq!(s.angles(7), [315.0, 0.0]);
    for yaw in [0.0, 45.0, 90.0, 180.0, 315.0] {
        for tilt in [-180.0, -90.0, 0.0, 90.0, 180.0] {
            let [r, u, t] = basis(yaw, tilt);
            assert!((r.length() - 1.0).abs() < 1e-5);
            assert!(r.dot(u).abs() < 1e-5);
            assert!((r.cross(u) - t).length() < 1e-5);
        }
    }
}

#[test]
fn binary_attributes_and_transforms_are_loaded() {
    let tmp = tempfile::tempdir().unwrap();
    let part = InstanceBuilder::new("Part")
        .with_property("Size", Vector3::new(2.0, 4.0, 6.0))
        .with_property(
            "CFrame",
            CFrame::new(
                Vector3::new(10.0, 20.0, 30.0),
                rbx_dom_weak::types::Matrix3::identity(),
            ),
        )
        .with_property(
            "Attributes",
            Attributes::new()
                .with("PanShotCount", 3.0)
                .with("MaxResolutionPx", 32.0),
        );
    let dom = WeakDom::new(InstanceBuilder::new("DataModel").with_child(part));
    let path = tmp.path().join("cube.rbxm");
    rbx_binary::to_writer(
        fs::File::create(&path).unwrap(),
        &dom,
        dom.root().children(),
    )
    .unwrap();
    let assets = Assets::new(tmp.path().join("cache"), true, None).unwrap();
    let loaded = scene::load(&path, &assets).unwrap();
    assert_eq!(loaded.settings.pan_shot_count, 3);
    assert_eq!(loaded.bounds_size, Vec3::new(2.0, 4.0, 6.0));
    assert_eq!(loaded.bounds_cf.position, Vector3::new(10.0, 20.0, 30.0));
    let vertices = &loaded.objects[0].geometry.vertices;
    assert!(
        vertices
            .iter()
            .all(|v| v.position.abs().cmple(Vec3::new(1.0, 2.0, 3.0)).all())
    );
}

#[test]
fn layers_have_correct_coverage_and_material_values() {
    let s = cube();
    let frame = render::render(&s, 0, 4).unwrap();
    let center = 14;
    assert_eq!(frame[0].dimensions(), (28, 28));
    let p = frame[0].get_pixel(center, center);
    assert_eq!(p.0, [204, 51, 26, 255]);
    assert_eq!(frame[1].get_pixel(center, center).0, [128, 128, 255, 255]);
    assert_eq!(frame[2].get_pixel(center, center).0[0], 179);
    assert_eq!(frame[3].get_pixel(center, center).0[0], 51);
    assert_eq!(frame[4].get_pixel(center, center).0, [255, 255, 255, 255]);
    assert_eq!(frame[0].get_pixel(0, 0).0[3], 0);
    assert!(frame[5].get_pixel(center, center).0[0] < 128);
}

#[test]
fn alpha_composites_front_to_back_without_shared_edge_double_blending() {
    let mut s = cube();
    s.objects[0].material.opacity = 0.5;
    // At the center two cube surfaces contribute 0.5 each: 0.75 coverage.
    let frame = render::render(&s, 0, 1).unwrap();
    assert!((frame[0].get_pixel(14, 14).0[3] as i32 - 191).abs() <= 1);
}

#[test]
fn sheet_and_individual_exports_match_pixel_for_pixel_and_guard_overwrite() {
    let tmp = tempfile::tempdir().unwrap();
    let s = cube();
    let options = BakeOptions::default();
    let atlas = tmp.path().join("cube.PNG");
    let shots = tmp.path().join("shots");
    let m = bake(&s, &atlas, &options).unwrap();
    let individual = bake(&s, &shots, &options).unwrap();
    assert!(bake(&s, &atlas, &options).is_err());
    assert!(bake(&s, &shots, &options).is_err());
    fs::write(shots.join("shot_0000/notes.txt"), "keep this file").unwrap();
    bake(
        &s,
        &shots,
        &BakeOptions {
            overwrite: true,
            ..BakeOptions::default()
        },
    )
    .unwrap();
    assert_eq!(
        fs::read_to_string(shots.join("shot_0000/notes.txt")).unwrap(),
        "keep this file"
    );
    for layer in render::LAYERS {
        let sheet = image::open(tmp.path().join(&m.layers[layer]))
            .unwrap()
            .to_rgba8();
        for shot in &m.shots {
            let file = format!("{}/{layer}.png", shot.key);
            assert_eq!(individual.shots[shot.index as usize].images[layer], file);
            assert!(!shots.join(format!("{}.png", shot.key)).exists());
            let one = image::open(shots.join(&file)).unwrap().to_rgba8();
            assert_eq!(
                one,
                image::imageops::crop_imm(
                    &sheet,
                    shot.rect[0],
                    shot.rect[1],
                    shot.rect[2],
                    shot.rect[3]
                )
                .to_image()
            );
        }
    }
    assert!(
        bake(
            &s,
            &tmp.path().join("low.png"),
            &BakeOptions {
                max_memory_mib: 0,
                ..options
            }
        )
        .is_err()
    );
    assert!(!tmp.path().join("low.png").exists());
}

#[test]
fn provided_models_parse_without_fetching_assets() {
    for name in ["grass", "pillar", "lilypad", "tree"] {
        let dom = scene::read_dom(Path::new(&format!("test/{name}.rbxm"))).unwrap();
        assert_eq!(dom.root().children().len(), 1);
        assert!(dom.descendants().any(|i| i.class == "MeshPart"));
    }
}

#[test]
fn asset_ids_are_restricted_and_overrides_are_relative_to_the_mapping() {
    assert_eq!(asset_id("rbxassetid://42"), Some(42));
    assert_eq!(asset_id("https://www.roblox.com/asset/?id=42"), Some(42));
    assert_eq!(asset_id("https://evil.example/?id=42"), None);
    assert_eq!(asset_id("file:///secret"), None);
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("mesh.bin"), b"mesh").unwrap();
    fs::write(
        tmp.path().join("map.json"),
        r#"{"rbxassetid://42":"mesh.bin"}"#,
    )
    .unwrap();
    let assets = Assets::new(
        tmp.path().join("cache"),
        true,
        Some(&tmp.path().join("map.json")),
    )
    .unwrap();
    assert_eq!(assets.load("rbxassetid://42").unwrap(), b"mesh");
    assert!(assets.load("rbxassetid://43").is_err());
}

#[test]
fn surface_maps_and_normals_use_uvs() {
    let mut s = cube();
    let tex = |rgba| {
        scene::Texture(std::sync::Arc::new(image::RgbaImage::from_pixel(
            2,
            2,
            image::Rgba(rgba),
        )))
    };
    s.objects[0].material.roughness_map = Some(tex([64, 0, 0, 255]));
    s.objects[0].material.metalness_map = Some(tex([200, 0, 0, 255]));
    s.objects[0].material.color_map = Some(tex([255, 255, 255, 128]));
    let frame = render::render(&s, 0, 1).unwrap();
    assert_eq!(frame[2].get_pixel(14, 14).0[0], 64);
    assert_eq!(frame[3].get_pixel(14, 14).0[0], 200);
    assert!(frame[0].get_pixel(14, 14).0[3] < 255);
    let p = s.objects[0]
        .material
        .color_map
        .as_ref()
        .unwrap()
        .sample(glam::Vec2::new(-0.25, 1.25));
    assert!((p - Vec4::new(1.0, 1.0, 1.0, 128.0 / 255.0)).length() < 1e-5);
}

#[test]
fn legacy_texture_tint_matches_linear_multiplication_without_changing_surface_tints() {
    let mut s = cube();
    s.objects[0].material.color = Vec3::splat(0.5);
    let untextured = render::render(&s, 0, 1).unwrap();
    assert_eq!(untextured[0].get_pixel(14, 14).0, [128, 128, 128, 255]);
    for (texture_value, expected) in [(255, 188), (128, 92)] {
        s.objects[0].material.color_map = Some(scene::Texture(std::sync::Arc::new(
            image::RgbaImage::from_pixel(
                1,
                1,
                image::Rgba([texture_value, texture_value, texture_value, 255]),
            ),
        )));
        let textured = render::render(&s, 0, 1).unwrap();
        assert_eq!(
            textured[0].get_pixel(14, 14).0,
            [expected, expected, expected, 255]
        );
    }
    let m = &mut s.objects[0].material;
    m.surface = true;
    m.surface_tint = Vec3::splat(0.5);
    m.color_map = Some(scene::Texture(std::sync::Arc::new(
        image::RgbaImage::from_pixel(1, 1, image::Rgba([255, 255, 255, 255])),
    )));
    let surface = render::render(&s, 0, 1).unwrap();
    assert_eq!(surface[0].get_pixel(14, 14).0, [128, 128, 128, 255]);
}

#[test]
fn malformed_mesh_fails_instead_of_producing_blank_images() {
    assert!(geometry::decode(b"not a mesh").is_err());
    let bad = Attributes::new().with("MaxResolutionPx", Variant::Bool(true));
    assert!(Settings::from_attributes(Some(&bad)).is_err());
}

#[test]
fn mesh_v4_zero_lod_markers_use_full_geometry() {
    let mut bytes = b"version 4.00\n".to_vec();
    bytes.extend(24u16.to_le_bytes());
    bytes.extend(0u16.to_le_bytes());
    bytes.extend(3u32.to_le_bytes());
    bytes.extend(1u32.to_le_bytes());
    bytes.extend(2u16.to_le_bytes());
    bytes.extend(0u16.to_le_bytes());
    bytes.extend(0u32.to_le_bytes());
    bytes.extend(0u16.to_le_bytes());
    bytes.extend([1, 0]);
    for position in [[-0.5f32, 0.0, 0.0], [0.5, 0.0, 0.0], [0.0, 1.0, 0.0]] {
        for v in position.into_iter().chain([0.0, 0.0, 1.0, 0.5, 0.5]) {
            bytes.extend(v.to_le_bytes());
        }
        bytes.extend([127, 0, 0, 127, 255, 255, 255, 255]);
    }
    for index in [0u32, 1, 2, 0, 0] {
        bytes.extend(index.to_le_bytes());
    }
    let decoded = geometry::decode(&bytes).unwrap();
    assert_eq!(decoded.vertices.len(), 3);
    assert_eq!(decoded.faces, vec![[0, 1, 2]]);
    assert!(geometry::decode(&bytes[..40]).is_err());
}

#[test]
fn surface_alpha_modes_and_emissive_masks_match_channel_semantics() {
    let texture = |rgba| {
        scene::Texture(std::sync::Arc::new(image::RgbaImage::from_pixel(
            1,
            1,
            image::Rgba(rgba),
        )))
    };
    let mut s = cube();
    let m = &mut s.objects[0].material;
    m.surface = true;
    m.color = Vec3::X;
    m.surface_tint = Vec3::Y;
    m.color_map = Some(texture([255, 255, 255, 0]));
    m.alpha_mode = 0;
    assert_eq!(
        render::render(&s, 0, 1).unwrap()[0].get_pixel(14, 14).0,
        [255, 0, 0, 255]
    );
    s.objects[0].material.alpha_mode = 2;
    assert_eq!(
        render::render(&s, 0, 1).unwrap()[0].get_pixel(14, 14).0,
        [255, 255, 255, 255]
    );
    s.objects[0].material.alpha_mode = 3;
    s.objects[0].material.emissive_map = Some(texture([64, 200, 255, 255]));
    let frame = render::render(&s, 0, 1).unwrap();
    assert_eq!(frame[0].get_pixel(14, 14).0, [0, 255, 0, 255]);
    assert_eq!(frame[6].get_pixel(14, 14).0, [64, 64, 64, 255]);
    s.objects[0].material.alpha_mode = 1;
    assert_eq!(
        render::render(&s, 0, 1).unwrap()[0].get_pixel(14, 14).0[3],
        0
    );
}

#[test]
#[ignore = "requires public asset downloads; run cargo test --test baking demo_models -- --ignored"]
fn demo_models() {
    let assets = Assets::new(imposter_baker::default_cache(), false, None).unwrap();
    for name in ["grass", "pillar", "lilypad", "tree"] {
        let s = scene::load(Path::new(&format!("test/{name}.rbxm")), &assets).unwrap();
        let manifest = bake(
            &s,
            Path::new(&format!("test/demo/{name}.png")),
            &BakeOptions {
                overwrite: true,
                ..BakeOptions::default()
            },
        )
        .unwrap();
        assert_eq!(manifest.shots.len(), 8);
        let image = image::open(format!("test/demo/{name}.png"))
            .unwrap()
            .to_rgba8();
        for shot in manifest.shots {
            assert!(
                image::imageops::crop_imm(
                    &image,
                    shot.rect[0],
                    shot.rect[1],
                    shot.rect[2],
                    shot.rect[3]
                )
                .pixels()
                .any(|p| p.2.0[3] > 0)
            );
        }
    }
}
