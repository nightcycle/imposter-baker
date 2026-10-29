use crate::{config::basis, scene::Scene};
use anyhow::{Result, ensure};
use glam::{Vec2, Vec3, Vec4};
use image::{Rgba, RgbaImage};
use rayon::prelude::*;

pub const LAYERS: [&str; 7] = [
    "color",
    "normal",
    "roughness",
    "metalness",
    "opacity",
    "depth",
    "emissive",
];
pub type Frame = [RgbaImage; 7];

#[derive(Clone, Copy)]
struct Hit {
    depth: f32,
    triangle: usize,
    weights: Vec3,
}
struct Triangle {
    object: usize,
    vertices: [usize; 3],
    screen: [Vec2; 3],
    depth: [f32; 3],
    tangent: Vec3,
    bitangent: Vec3,
}

fn edge(a: Vec2, b: Vec2, p: Vec2) -> f32 {
    (b - a).perp_dot(p - a)
}
fn srgb_to_linear(v: Vec3) -> Vec3 {
    v.map(|v| {
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    })
}
fn linear_to_srgb(v: Vec3) -> Vec3 {
    v.map(|v| {
        if v <= 0.0031308 {
            12.92 * v
        } else {
            1.055 * v.max(0.0).powf(1.0 / 2.4) - 0.055
        }
    })
}

/// Orthographic material capture, unlit albedo, tangent-space normals relative
/// to the output quad (+U right, +V down, normal toward capture camera).
pub fn render(scene: &Scene, index: u32, samples: u32) -> Result<Frame> {
    ensure!(samples == 1 || samples == 4, "samples must be 1 or 4");
    let s = &scene.settings;
    let n = s.max_resolution_px;
    let side = scene.bounds_size.length();
    let angles = s.angles(index);
    let [right, up, toward] = basis(angles[0], angles[1]);
    let project = |p: Vec3| {
        Vec2::new(
            (p.dot(right) / side + 0.5) * n as f32,
            (0.5 - p.dot(up) / side) * n as f32,
        )
    };
    let mut triangles = vec![];
    for (oi, o) in scene.objects.iter().enumerate() {
        for face in &o.geometry.faces {
            let v = face.map(|i| o.geometry.vertices[i]);
            let e1 = v[1].position - v[0].position;
            let e2 = v[2].position - v[0].position;
            let duv1 = v[1].uv - v[0].uv;
            let duv2 = v[2].uv - v[0].uv;
            let det = duv1.perp_dot(duv2);
            let (t, b) = if det.abs() > 1e-10 {
                (
                    (e1 * duv2.y - e2 * duv1.y) / det,
                    (e2 * duv1.x - e1 * duv2.x) / det,
                )
            } else {
                (right, -up)
            };
            triangles.push(Triangle {
                object: oi,
                vertices: *face,
                screen: v.map(|v| project(v.position)),
                depth: v.map(|v| v.position.dot(toward)),
                tangent: t,
                bitangent: b,
            });
        }
    }
    let count = (n * n) as usize;
    let mut sums = vec![[Vec4::ZERO; 7]; count];
    let offsets: &[Vec2] = if samples == 1 {
        &[Vec2::new(0.5, 0.5)]
    } else {
        &[
            Vec2::new(0.25, 0.25),
            Vec2::new(0.75, 0.25),
            Vec2::new(0.25, 0.75),
            Vec2::new(0.75, 0.75),
        ]
    };
    for offset in offsets {
        let mut hits: Vec<Vec<Hit>> = vec![vec![]; count];
        for (ti, t) in triangles.iter().enumerate() {
            let [a, b, c] = t.screen;
            let area = edge(a, b, c);
            if area.abs() < 1e-9 {
                continue;
            }
            let min = a.min(b).min(c).floor().max(Vec2::ZERO);
            let max = a.max(b).max(c).ceil().min(Vec2::splat(n as f32 - 1.0));
            for y in min.y as u32..=max.y.max(-1.0) as u32 {
                if y >= n {
                    continue;
                }
                for x in min.x as u32..=max.x.max(-1.0) as u32 {
                    if x >= n {
                        continue;
                    }
                    let p = Vec2::new(x as f32, y as f32) + *offset;
                    let w = Vec3::new(edge(b, c, p), edge(c, a, p), edge(a, b, p)) / area;
                    // Half-open ownership avoids double blending shared edges.
                    let owns = |(p0, p1): (Vec2, Vec2)| {
                        let d = if area > 0.0 { p1 - p0 } else { p0 - p1 };
                        d.y < 0.0 || (d.y == 0.0 && d.x > 0.0)
                    };
                    if w.min_element() < -1e-6
                        || (w.x.abs() < 1e-6 && !owns((b, c)))
                        || (w.y.abs() < 1e-6 && !owns((c, a)))
                        || (w.z.abs() < 1e-6 && !owns((a, b)))
                    {
                        continue;
                    }
                    let depth = Vec3::from_array(t.depth).dot(w);
                    let pixel = &mut hits[(y * n + x) as usize];
                    ensure!(
                        pixel.len() < 256,
                        "more than 256 overlapping surfaces at one pixel; simplify the model"
                    );
                    pixel.push(Hit {
                        depth,
                        triangle: ti,
                        weights: w,
                    });
                }
            }
        }
        sums.par_iter_mut()
            .zip(hits.par_iter_mut())
            .for_each(|(sum, hits)| {
                hits.sort_by(|a, b| a.depth.total_cmp(&b.depth));
                let mut result = [Vec4::ZERO; 7];
                for hit in hits.iter() {
                    let tri = &triangles[hit.triangle];
                    let o = &scene.objects[tri.object];
                    let m = &o.material;
                    let v = tri.vertices.map(|i| o.geometry.vertices[i]);
                    let w = hit.weights;
                    let uv = v[0].uv * w.x + v[1].uv * w.y + v[2].uv * w.z;
                    let vc = v[0].color * w.x + v[1].color * w.y + v[2].color * w.z;
                    let tex = m.color_map.as_ref().map_or(Vec4::ONE, |t| t.sample(uv));
                    let alpha = m.opacity * vc.w * if m.alpha_mode == 1 { tex.w } else { 1.0 };
                    if alpha < 1e-5 {
                        continue;
                    }
                    let c = (if !m.surface {
                        tex.truncate() * m.color
                    } else if m.color_map.is_none() {
                        m.color * m.surface_tint
                    } else {
                        match m.alpha_mode {
                            0 => m.color.lerp(tex.truncate() * m.surface_tint, tex.w),
                            2 => tex.truncate() * Vec3::ONE.lerp(m.surface_tint, tex.w),
                            _ => tex.truncate() * m.surface_tint,
                        }
                    }) * vc.truncate();
                    let mut normal = (v[0].normal * w.x + v[1].normal * w.y + v[2].normal * w.z)
                        .normalize_or_zero();
                    if let Some(map) = &m.normal_map {
                        let nt = map.sample(uv).truncate() * 2.0 - Vec3::ONE;
                        let tangent =
                            (tri.tangent - normal * normal.dot(tri.tangent)).normalize_or_zero();
                        // Roblox uses OpenGL tangent normals: green points up in texture space.
                        let bitangent = normal.cross(tangent)
                            * if normal.cross(tangent).dot(tri.bitangent) < 0.0 {
                                -1.0
                            } else {
                                1.0
                            };
                        normal =
                            (tangent * nt.x - bitangent * nt.y + normal * nt.z).normalize_or_zero();
                    }
                    if normal.dot(toward) < 0.0 {
                        normal = -normal;
                    }
                    let encoded = Vec3::new(normal.dot(right), normal.dot(up), normal.dot(toward))
                        * 0.5
                        + Vec3::splat(0.5);
                    let rough = m
                        .roughness_map
                        .as_ref()
                        .map_or(m.roughness, |t| t.sample(uv).x);
                    let metal = m
                        .metalness_map
                        .as_ref()
                        .map_or(m.metalness, |t| t.sample(uv).x);
                    let depth = (0.5 - hit.depth / side).clamp(0.0, 1.0);
                    let emissive =
                        Vec3::splat(m.emissive_map.as_ref().map_or(0.0, |t| t.sample(uv).x));
                    let values = [
                        srgb_to_linear(c),
                        encoded,
                        Vec3::splat(rough),
                        Vec3::splat(metal),
                        Vec3::ONE,
                        Vec3::splat(depth),
                        emissive,
                    ];
                    for layer in 0..7 {
                        result[layer] =
                            values[layer].extend(1.0) * alpha + result[layer] * (1.0 - alpha);
                    }
                }
                for layer in 0..7 {
                    sum[layer] += result[layer] / samples as f32;
                }
            });
    }
    let tile = s.tile_size();
    let mut frame: Frame = std::array::from_fn(|_| RgbaImage::new(tile, tile));
    for y in 0..n {
        for x in 0..n {
            let pixel = &sums[(y * n + x) as usize];
            for layer in 0..7 {
                let value = pixel[layer];
                let alpha = value.w.clamp(0.0, 1.0);
                let mut rgb = if alpha > 1e-6 {
                    value.truncate() / alpha
                } else {
                    Vec3::ZERO
                };
                if layer == 0 {
                    rgb = linear_to_srgb(rgb);
                }
                if layer == 4 {
                    rgb = Vec3::splat(alpha);
                }
                if layer == 1 && alpha > 1e-6 {
                    rgb = ((rgb * 2.0 - Vec3::ONE).normalize_or_zero() + Vec3::ONE) * 0.5;
                }
                let out_alpha = if layer == 4 { 1.0 } else { alpha };
                frame[layer].put_pixel(
                    x + s.padding_px,
                    y + s.padding_px,
                    Rgba([
                        (rgb.x.clamp(0.0, 1.0) * 255.0).round() as u8,
                        (rgb.y.clamp(0.0, 1.0) * 255.0).round() as u8,
                        (rgb.z.clamp(0.0, 1.0) * 255.0).round() as u8,
                        (out_alpha * 255.0).round() as u8,
                    ]),
                );
            }
        }
    }
    // Extend RGB into transparent texels without changing alpha. Each layer and
    // tile is independent, so filtering never picks up a neighboring shot.
    for (layer, im) in frame.iter_mut().enumerate() {
        if layer != 4 {
            dilate(im, s.padding_px.max(1));
        }
    }
    Ok(frame)
}

fn dilate(im: &mut RgbaImage, passes: u32) {
    let w = im.width();
    let h = im.height();
    let mut filled: Vec<bool> = im.pixels().map(|p| p.0[3] > 0).collect();
    for _ in 0..passes {
        let prev = im.clone();
        let old = filled.clone();
        for y in 0..h {
            for x in 0..w {
                let idx = (y * w + x) as usize;
                if old[idx] {
                    continue;
                }
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x as i32 + dx;
                    let ny = y as i32 + dy;
                    if nx >= 0
                        && ny >= 0
                        && nx < w as i32
                        && ny < h as i32
                        && old[(ny as u32 * w + nx as u32) as usize]
                    {
                        let p = prev.get_pixel(nx as u32, ny as u32);
                        im.put_pixel(x, y, Rgba([p[0], p[1], p[2], 0]));
                        filled[idx] = true;
                        break;
                    }
                }
            }
        }
    }
}
