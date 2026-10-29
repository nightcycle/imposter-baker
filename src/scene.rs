use crate::{
    assets::Assets,
    config::Settings,
    geometry::{self, Geometry},
};
use anyhow::{Context, Result, bail, ensure};
use glam::{Mat3, Vec2, Vec3, Vec4};
use image::{ImageReader, RgbaImage};
use rbx_dom_weak::{
    Instance, WeakDom,
    types::{CFrame, Variant, Vector3},
};
use std::{collections::HashMap, fs, io::Cursor, path::Path, sync::Arc};

#[derive(Clone)]
pub struct Texture(pub Arc<RgbaImage>);
impl Texture {
    pub fn sample(&self, uv: Vec2) -> Vec4 {
        let im = &self.0;
        let p = Vec2::new(
            uv.x.rem_euclid(1.0) * im.width() as f32 - 0.5,
            uv.y.rem_euclid(1.0) * im.height() as f32 - 0.5,
        );
        let at = |x: i32, y: i32| {
            Vec4::from_array(
                im.get_pixel(
                    x.rem_euclid(im.width() as i32) as u32,
                    y.rem_euclid(im.height() as i32) as u32,
                )
                .0
                .map(|x| x as f32 / 255.0),
            )
        };
        let x = p.x.floor() as i32;
        let y = p.y.floor() as i32;
        at(x, y)
            .lerp(at(x + 1, y), p.x.fract().rem_euclid(1.0))
            .lerp(
                at(x, y + 1).lerp(at(x + 1, y + 1), p.x.fract().rem_euclid(1.0)),
                p.y.fract().rem_euclid(1.0),
            )
    }
}
pub struct Material {
    pub color: Vec3,
    pub surface_tint: Vec3,
    pub opacity: f32,
    pub alpha_mode: u32,
    pub surface: bool,
    pub roughness: f32,
    pub metalness: f32,
    pub color_map: Option<Texture>,
    pub normal_map: Option<Texture>,
    pub roughness_map: Option<Texture>,
    pub metalness_map: Option<Texture>,
    pub emissive_map: Option<Texture>,
    pub emissive_tint: Vec3,
    pub emissive_strength: f32,
}
pub struct Object {
    pub geometry: Geometry,
    pub material: Material,
}
pub struct Scene {
    pub objects: Vec<Object>,
    pub settings: Settings,
    pub bounds_cf: CFrame,
    pub bounds_size: Vec3,
    pub warnings: Vec<String>,
}

pub fn read_dom(path: &Path) -> Result<WeakDom> {
    let data = fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    if data.starts_with(b"<roblox!") {
        Ok(rbx_binary::from_reader(Cursor::new(data))?)
    } else {
        Ok(rbx_xml::from_reader(
            Cursor::new(data),
            rbx_xml::DecodeOptions::default(),
        )?)
    }
}
pub fn vec(v: Vector3) -> Vec3 {
    Vec3::new(v.x, v.y, v.z)
}
pub fn rotation(cf: CFrame) -> Mat3 {
    // rbx_types stores matrix rows; glam's constructor takes columns.
    Mat3::from_cols(
        vec(cf.orientation.x),
        vec(cf.orientation.y),
        vec(cf.orientation.z),
    )
    .transpose()
}
pub fn cf(i: &Instance, name: &str) -> Option<CFrame> {
    match i.properties.get(&name.into()) {
        Some(Variant::CFrame(v)) => Some(*v),
        _ => None,
    }
}
pub fn v3(i: &Instance, name: &str) -> Option<Vec3> {
    match i.properties.get(&name.into()) {
        Some(Variant::Vector3(v)) => Some(vec(*v)),
        _ => None,
    }
}
pub fn number(i: &Instance, name: &str, default: f32) -> f32 {
    match i.properties.get(&name.into()) {
        Some(Variant::Float32(v)) => *v,
        Some(Variant::Float64(v)) => *v as f32,
        _ => default,
    }
}
pub fn en(i: &Instance, name: &str, default: u32) -> u32 {
    match i.properties.get(&name.into()) {
        Some(Variant::Enum(v)) => v.to_u32(),
        _ => default,
    }
}
pub fn color(i: &Instance, name: &str, default: Vec3) -> Vec3 {
    match i.properties.get(&name.into()) {
        Some(Variant::Color3(v)) => Vec3::new(v.r, v.g, v.b),
        Some(Variant::Color3uint8(v)) => Vec3::new(v.r as f32, v.g as f32, v.b as f32) / 255.0,
        _ => default,
    }
}
pub fn content(i: &Instance, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| {
        let s = match i.properties.get(&(*name).into())? {
            Variant::Content(v) => v.as_uri()?,
            Variant::ContentId(v) => v.as_str(),
            Variant::String(v) => v,
            _ => return None,
        };
        if s.is_empty() {
            None
        } else {
            Some(s.to_owned())
        }
    })
}

pub fn load(path: &Path, assets: &Assets) -> Result<Scene> {
    let dom = read_dom(path)?;
    let roots = dom.root().children();
    ensure!(
        roots.len() == 1,
        "RBXM must contain exactly one root Model, Folder, or BasePart; group the selection before exporting"
    );
    let root = dom.get_by_ref(roots[0]).unwrap();
    let attrs = match root.properties.get(&"Attributes".into()) {
        Some(Variant::Attributes(a)) => Some(a),
        _ => None,
    };
    let settings = Settings::from_attributes(attrs)?;
    // Match Model:GetBoundingBox(): PrimaryPart orientation, otherwise world axes.
    let primary = match root.properties.get(&"PrimaryPart".into()) {
        Some(Variant::Ref(r)) => dom.get_by_ref(*r),
        _ => None,
    };
    let basis = primary
        .and_then(|p| cf(p, "CFrame"))
        .or_else(|| cf(root, "CFrame"))
        .map(rotation)
        .unwrap_or(Mat3::IDENTITY);
    let mut lo = Vec3::splat(f32::INFINITY);
    let mut hi = Vec3::splat(f32::NEG_INFINITY);
    let mut objects = vec![];
    let mut textures: HashMap<String, Texture> = HashMap::new();
    let mut meshes: HashMap<String, Geometry> = HashMap::new();
    let mut warnings = vec![];
    for i in dom.descendants_of(root.referent()) {
        let class = i.class.as_str();
        if matches!(class, "UnionOperation" | "NegateOperation" | "TrussPart") {
            bail!(
                "{} ({class}) is unsupported; convert it to MeshPart before baking",
                i.name
            );
        }
        if !matches!(
            class,
            "MeshPart"
                | "Part"
                | "WedgePart"
                | "CornerWedgePart"
                | "Seat"
                | "VehicleSeat"
                | "SpawnLocation"
        ) {
            if matches!(class, "Decal" | "Texture" | "WrapLayer" | "WrapTarget") {
                warnings.push(format!("{} ({class}) is not baked", i.name));
            }
            continue;
        }
        let part_cf = cf(i, "CFrame").unwrap_or(CFrame::identity());
        let r = basis.transpose() * rotation(part_cf);
        let translation = basis.transpose() * vec(part_cf.position);
        let size = v3(i, "Size").unwrap_or(Vec3::ONE);
        ensure!(
            size.is_finite() && size.min_element() > 0.0,
            "{} has invalid Size",
            i.name
        );
        for x in [-0.5, 0.5] {
            for y in [-0.5, 0.5] {
                for z in [-0.5, 0.5] {
                    let p = r * (size * Vec3::new(x, y, z)) + translation;
                    lo = lo.min(p);
                    hi = hi.max(p);
                }
            }
        }
        if number(i, "Transparency", 0.0) >= 1.0 {
            continue;
        }
        let children: Vec<_> = i
            .children()
            .iter()
            .filter_map(|r| dom.get_by_ref(*r))
            .collect();
        let special = children.iter().find(|c| c.class == "SpecialMesh").copied();
        let mesh_id = if class == "MeshPart" {
            content(i, &["MeshContent", "MeshId"])
        } else {
            special.and_then(|s| content(s, &["MeshContent", "MeshId"]))
        };
        let mut g = if let Some(id) = mesh_id {
            if !meshes.contains_key(&id) {
                meshes.insert(
                    id.clone(),
                    geometry::decode(&assets.load(&id)?)
                        .with_context(|| format!("decoding mesh {id} on {}", i.name))?,
                );
            }
            meshes[&id].clone()
        } else if class == "MeshPart" {
            bail!("MeshPart {} has no readable mesh content", i.name)
        } else if class == "WedgePart" {
            geometry::block(true, false)
        } else if class == "CornerWedgePart" {
            geometry::block(false, true)
        } else {
            let shape = special
                .map(|s| en(s, "MeshType", 5))
                .unwrap_or_else(|| en(i, "Shape", 1));
            if special.is_some() {
                match shape {
                    3 => geometry::round(false),
                    4 => geometry::round(true),
                    2 => geometry::block(true, false),
                    6 => geometry::block(false, false),
                    11 => geometry::block(false, true),
                    _ => bail!("unsupported SpecialMesh type {shape} on {}", i.name),
                }
            } else {
                match shape {
                    0 => geometry::round(false),
                    2 => geometry::round(true),
                    _ => geometry::block(false, false),
                }
            }
        };
        let scale = if class == "MeshPart" {
            let initial = v3(i, "InitialSize").unwrap_or_else(|| {
                let (min, max) = g.vertices.iter().fold(
                    (Vec3::splat(f32::INFINITY), Vec3::splat(f32::NEG_INFINITY)),
                    |(lo, hi), v| (lo.min(v.position), hi.max(v.position)),
                );
                max - min
            });
            size / initial.max(Vec3::splat(1e-8))
        } else if let Some(s) = special {
            let mesh_scale = v3(s, "Scale").unwrap_or(Vec3::ONE);
            if en(s, "MeshType", 5) == 5 {
                mesh_scale
            } else {
                size * mesh_scale
            }
        } else {
            size
        };
        let offset = special.and_then(|s| v3(s, "Offset")).unwrap_or(Vec3::ZERO);
        for v in &mut g.vertices {
            v.position = r * (v.position * scale + offset) + translation;
            v.normal = (r * (v.normal / scale)).normalize_or_zero();
        }
        let sa = children
            .iter()
            .find(|c| c.class == "SurfaceAppearance")
            .copied();
        let mut texture = |owner: &Instance, names: &[&str]| -> Result<Option<Texture>> {
            if let Some(id) = content(owner, names) {
                if !textures.contains_key(&id) {
                    let bytes = assets.load(&id)?;
                    let mut reader = ImageReader::new(Cursor::new(bytes)).with_guessed_format()?;
                    let mut limits = image::Limits::default();
                    limits.max_image_width = Some(8192);
                    limits.max_image_height = Some(8192);
                    limits.max_alloc = Some(256 * 1024 * 1024);
                    reader.limits(limits);
                    let image = reader
                        .decode()
                        .with_context(|| format!("decoding texture {id} on {}", owner.name))?
                        .to_rgba8();
                    textures.insert(id.clone(), Texture(Arc::new(image)));
                }
                Ok(Some(textures[&id].clone()))
            } else {
                Ok(None)
            }
        };
        let base_color = color(i, "Color", Vec3::splat(163.0 / 255.0));
        let mut m = Material {
            color: base_color,
            surface_tint: Vec3::ONE,
            opacity: 1.0 - number(i, "Transparency", 0.0),
            alpha_mode: 1,
            surface: false,
            roughness: 0.6,
            metalness: if matches!(en(i, "Material", 256), 1088 | 1040 | 1056) {
                1.0
            } else {
                0.0
            },
            color_map: None,
            normal_map: None,
            roughness_map: None,
            metalness_map: None,
            emissive_map: None,
            emissive_tint: Vec3::ONE,
            emissive_strength: 1.0,
        };
        if let Some(s) = sa {
            m.surface = true;
            m.color_map = texture(s, &["ColorMapContent", "ColorMap"])?;
            m.normal_map = texture(s, &["NormalMapContent", "NormalMap"])?;
            m.roughness_map = texture(s, &["RoughnessMapContent", "RoughnessMap"])?;
            m.metalness_map = texture(s, &["MetalnessMapContent", "MetalnessMap"])?;
            m.emissive_map = texture(s, &["EmissiveMaskContent", "EmissiveMask"])?;
            m.surface_tint = color(s, "Color", Vec3::ONE);
            m.alpha_mode = en(s, "AlphaMode", 0);
            ensure!(
                m.alpha_mode <= 3,
                "unsupported SurfaceAppearance AlphaMode {}",
                m.alpha_mode
            );
            m.emissive_tint = color(s, "EmissiveTint", Vec3::ONE);
            m.emissive_strength = number(s, "EmissiveStrength", 1.0);
        } else {
            m.color_map = texture(
                special.unwrap_or(i),
                &["TextureContent", "TextureID", "TextureId"],
            )?;
            if m.color_map.is_some() {
                // Legacy mesh textures replace Part.Color. FileMesh has its
                // own VertexColor multiplier; MeshPart has no equivalent tint.
                m.color = special
                    .and_then(|s| v3(s, "VertexColor"))
                    .unwrap_or(Vec3::ONE);
            }
        }
        objects.push(Object {
            geometry: g,
            material: m,
        });
    }
    ensure!(
        !objects.is_empty(),
        "model has no visible supported geometry"
    );
    let center = (lo + hi) * 0.5;
    for o in &mut objects {
        for v in &mut o.geometry.vertices {
            v.position -= center;
        }
    }
    let world_center = basis * center;
    let rows = basis.transpose();
    let to_v = |v: Vec3| Vector3::new(v.x, v.y, v.z);
    let bounds_cf = CFrame::new(
        to_v(world_center),
        rbx_dom_weak::types::Matrix3::new(to_v(rows.x_axis), to_v(rows.y_axis), to_v(rows.z_axis)),
    );
    ensure!(
        (hi - lo).is_finite() && (hi - lo).length() > 0.0,
        "model bounds are invalid"
    );
    Ok(Scene {
        objects,
        settings,
        bounds_cf,
        bounds_size: hi - lo,
        warnings,
    })
}
