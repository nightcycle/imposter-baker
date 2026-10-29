pub mod assets;
pub mod config;
pub mod geometry;
pub mod render;
pub mod scene;

use anyhow::{Context, Result, ensure};
use config::{Settings, shot_key};
use image::RgbaImage;
use render::LAYERS;
use serde::Serialize;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Shot {
    pub key: String,
    pub index: u32,
    pub yaw_degrees: f32,
    pub pitch_degrees: f32,
    pub rect: [u32; 4],
    pub images: BTreeMap<String, String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmissiveSurface {
    pub object_index: usize,
    pub strength: f32,
    pub tint: [f32; 3],
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub version: u32,
    pub settings: Settings,
    pub projection: &'static str,
    pub normal_convention: &'static str,
    pub bounds_c_frame: [f32; 12],
    pub bounds_size: [f32; 3],
    pub frame_world_size: f32,
    pub tile_size: u32,
    pub columns: u32,
    pub rows: u32,
    pub atlas_size: [u32; 2],
    pub layers: BTreeMap<String, String>,
    pub shots: Vec<Shot>,
    pub warnings: Vec<String>,
    pub emissive_surfaces: Vec<EmissiveSurface>,
}
pub struct BakeOptions {
    pub samples: u32,
    pub max_memory_mib: u64,
    pub overwrite: bool,
}
impl Default for BakeOptions {
    fn default() -> Self {
        Self {
            samples: 4,
            max_memory_mib: 512,
            overwrite: false,
        }
    }
}

pub fn bake(scene: &scene::Scene, output: &Path, options: &BakeOptions) -> Result<Manifest> {
    scene.settings.validate()?;
    let sheet = output
        .extension()
        .is_some_and(|s| s.eq_ignore_ascii_case("png"));
    let s = &scene.settings;
    let tile = s.tile_size();
    let [columns, rows] = s.grid();
    let width = columns * tile;
    let height = rows * tile;
    let pixels = if sheet {
        width as u64 * height as u64
    } else {
        tile as u64 * tile as u64
    };
    // Output buffers + sample accumulators + up to 256 compact depth hits per
    // pixel + triangle/geometry allowance. Checked before image allocation.
    let estimate = pixels * 28
        + s.max_resolution_px as u64 * s.max_resolution_px as u64 * (112 + 24 + 256 * 24)
        + scene
            .objects
            .iter()
            .map(|o| o.geometry.faces.len() as u64 * 128)
            .sum::<u64>();
    ensure!(
        estimate <= options.max_memory_mib.saturating_mul(1024 * 1024),
        "estimated peak memory {} MiB exceeds --max-memory-mib {}; lower resolution/shot count or raise the limit",
        estimate.div_ceil(1024 * 1024),
        options.max_memory_mib
    );
    let directory = if sheet {
        output
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."))
    } else {
        output
    };
    let stem = output
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("imposter");
    let filename = |layer: &str| {
        if layer == "color" {
            output.file_name().unwrap().to_string_lossy().into_owned()
        } else {
            format!("{stem}.{layer}.png")
        }
    };
    let manifest_name = if sheet {
        format!("{stem}.imposter.json")
    } else {
        "imposter.json".to_owned()
    };
    let mut layers = BTreeMap::new();
    let mut shots = vec![];
    let mut paths = vec![
        directory.join(&manifest_name),
        directory.join(if sheet {
            format!("{stem}.imposter.luau")
        } else {
            "imposter.luau".to_owned()
        }),
    ];
    if sheet {
        for layer in LAYERS {
            let name = filename(layer);
            paths.push(directory.join(&name));
            layers.insert(layer.to_owned(), name);
        }
    }
    for index in 0..s.count() {
        let key = shot_key(index);
        let angles = s.angles(index);
        let mut images = BTreeMap::new();
        if !sheet {
            for layer in LAYERS {
                let name = format!("{key}/{layer}.png");
                paths.push(directory.join(&name));
                images.insert(layer.to_owned(), name);
            }
        }
        shots.push(Shot {
            key,
            index,
            yaw_degrees: angles[0],
            pitch_degrees: angles[1],
            rect: [
                (index % columns) * tile,
                (index / columns) * tile,
                tile,
                tile,
            ],
            images,
        });
    }
    for p in &paths {
        ensure!(
            options.overwrite || !p.exists(),
            "{} exists; use --overwrite to replace generated files",
            p.display()
        );
    }
    fs::create_dir_all(directory)?;
    // A staging directory keeps failed captures from leaving plausible partial outputs.
    let staging = directory.join(format!(".imposter-baker-{}", std::process::id()));
    ensure!(
        !staging.exists(),
        "staging directory {} already exists",
        staging.display()
    );
    fs::create_dir(&staging)?;
    let result = (|| -> Result<Manifest> {
        let mut atlas: Option<[RgbaImage; 7]> = if sheet {
            Some(std::array::from_fn(|_| RgbaImage::new(width, height)))
        } else {
            None
        };
        for shot in &shots {
            if !sheet {
                fs::create_dir(staging.join(&shot.key))?;
            }
            eprintln!("Baking {} ({}/{})", shot.key, shot.index + 1, s.count());
            let frame = render::render(scene, shot.index, options.samples)?;
            for (layer, image) in frame.iter().enumerate() {
                if let Some(atlas) = &mut atlas {
                    image::imageops::replace(
                        &mut atlas[layer],
                        image,
                        shot.rect[0] as i64,
                        shot.rect[1] as i64,
                    );
                } else {
                    image.save(staging.join(&shot.images[LAYERS[layer]]))?;
                }
            }
        }
        if let Some(atlas) = atlas {
            for (layer, image) in atlas.iter().enumerate() {
                image.save(staging.join(&layers[LAYERS[layer]]))?;
            }
        }
        let cf = scene.bounds_cf;
        let m = cf.orientation;
        let p = cf.position;
        let manifest = Manifest {
            version: 1,
            settings: s.clone(),
            projection: "orthographic",
            normal_convention: "OpenGL; +R=quad right, +G=quad up, +B=toward camera",
            bounds_c_frame: [
                p.x, p.y, p.z, m.x.x, m.x.y, m.x.z, m.y.x, m.y.y, m.y.z, m.z.x, m.z.y, m.z.z,
            ],
            bounds_size: scene.bounds_size.to_array(),
            frame_world_size: scene.bounds_size.length(),
            tile_size: tile,
            columns,
            rows,
            atlas_size: [width, height],
            layers,
            shots,
            warnings: scene.warnings.clone(),
            emissive_surfaces: scene
                .objects
                .iter()
                .enumerate()
                .filter(|(_, o)| o.material.emissive_map.is_some())
                .map(|(index, o)| EmissiveSurface {
                    object_index: index,
                    strength: o.material.emissive_strength,
                    tint: o.material.emissive_tint.to_array(),
                })
                .collect(),
        };
        fs::write(
            staging.join(&manifest_name),
            serde_json::to_string_pretty(&manifest)?,
        )?;
        let luau_name = paths[1].file_name().unwrap();
        fs::write(
            staging.join(luau_name),
            format!(
                "--!strict\n-- Generated bake layout. Upload PNGs and supply their Content/asset URLs separately.\nreturn table.freeze({{\n\tpanShotCount = {},\n\ttiltShotCount = {},\n\tmaxResolutionPx = {},\n\tpaddingPx = {},\n\ttiltConstraints = NumberRange.new({}, {}),\n}})\n",
                s.pan_shot_count,
                s.tilt_shot_count,
                s.max_resolution_px,
                s.padding_px,
                s.tilt_constraints[0],
                s.tilt_constraints[1]
            ),
        )?;
        for target in &paths {
            let source = staging.join(target.strip_prefix(directory)?);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::rename(&source, target).with_context(|| format!("writing {}", target.display()))?;
        }
        Ok(manifest)
    })();
    // Only remove the exact staging directory created by this invocation.
    let _ = fs::remove_dir_all(&staging);
    result
}

pub fn default_cache() -> PathBuf {
    PathBuf::from(".imposter-cache")
}
