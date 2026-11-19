use crate::{config::basis, scene::Scene};
use anyhow::{Result, ensure};
use glam::{Vec2, Vec3, Vec4};
use image::{Rgba, RgbaImage};
use rayon::prelude::*;

pub const LAYERS: [&str; 9] = [
    "color",
    "normal",
    "roughness",
    "metalness",
    "opacity",
    "depth",
    "emissive",
    "occlusion",
    "albedo",
];
pub type Frame = [RgbaImage; LAYERS.len()];
// Seven material channels plus the geometric normal before source normal mapping.
type CaptureSample = [Vec4; 8];

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

/// Orthographic material capture, raw albedo plus optional cavity shading, normals relative
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
    let mut sums = vec![[Vec4::ZERO; 8]; count];
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
                let mut result = [Vec4::ZERO; 8];
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
                    let mut geometric =
                        Vec3::new(normal.dot(right), normal.dot(up), normal.dot(toward));
                    if geometric.z < 0.0 {
                        geometric = -geometric;
                    }
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
                    // Color textures are sRGB, including legacy TextureID maps.
                    // Decode for compositing, then encode once for PNG output.
                    let linear_color = srgb_to_linear(c);
                    let values = [
                        linear_color,
                        encoded,
                        Vec3::splat(rough),
                        Vec3::splat(metal),
                        Vec3::ONE,
                        Vec3::splat(depth),
                        emissive,
                        geometric * 0.5 + Vec3::splat(0.5),
                    ];
                    for layer in 0..8 {
                        result[layer] =
                            values[layer].extend(1.0) * alpha + result[layer] * (1.0 - alpha);
                    }
                }
                for layer in 0..8 {
                    sum[layer] += result[layer] / samples as f32;
                }
            });
    }
    let occlusion = capture_occlusion(&sums, n, s.ambient_occlusion_radius_ratio);
    apply_depth_normals(
        &mut sums,
        n,
        s.depth_normal_strength,
        s.depth_normal_radius_ratio,
    );
    let tile = s.tile_size();
    let mut frame: Frame = std::array::from_fn(|_| RgbaImage::new(tile, tile));
    for y in 0..n {
        for x in 0..n {
            let pixel = &sums[(y * n + x) as usize];
            for layer in 0..LAYERS.len() {
                let value = pixel[if layer >= 7 { 0 } else { layer }];
                let alpha = value.w.clamp(0.0, 1.0);
                let mut rgb = if alpha > 1e-6 {
                    value.truncate() / alpha
                } else {
                    Vec3::ZERO
                };
                if layer == 0 {
                    rgb *= 1.0
                        - s.ambient_occlusion_strength * (1.0 - occlusion[(y * n + x) as usize]);
                    rgb = linear_to_srgb(rgb);
                }
                if layer == 8 {
                    rgb = linear_to_srgb(rgb);
                }
                if layer == 7 {
                    rgb = Vec3::splat(occlusion[(y * n + x) as usize]);
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

/// Add a finite-width bevel approximation at visible depth discontinuities.
/// Distances use bounds-diagonal units and depth stays floating point.
/// Subtract slope already represented by geometric normals, keeping source
/// normal-map detail separate from the height field.
fn apply_depth_normals(samples: &mut [CaptureSample], resolution: u32, strength: f32, radius: f32) {
    if strength == 0.0 || radius == 0.0 {
        return;
    }
    let n = resolution as i32;
    let radius_px = (radius * resolution as f32).round().max(1.0) as i32;
    let mut distances: Vec<i32> = [0.25, 0.5, 0.75, 1.0]
        .map(|fraction| (fraction * radius_px as f32).round().max(1.0) as i32)
        .into();
    distances.dedup();
    let unpack = |value: Vec4| (value.truncate() / value.w * 2.0 - Vec3::ONE).normalize_or(Vec3::Z);
    let normals: Vec<Vec4> = samples
        .par_iter()
        .enumerate()
        .map(|(index, center)| {
            // Coverage edges and translucent layers do not define a solid height field.
            if center[0].w < 0.999 {
                return center[1];
            }
            let geometric = unpack(center[7]);
            if geometric.z < 0.1 {
                return center[1];
            }
            let depth = center[5].x / center[5].w;
            let x = index as i32 % n;
            let y = index as i32 / n;
            let mut gradient = Vec2::ZERO;
            for axis in 0..2 {
                let mut numerator = 0.0;
                let mut denominator = 0.0;
                for distance in &distances {
                    for sign in [-1, 1] {
                        let delta_px = distance * sign;
                        let (sx, sy) = if axis == 0 {
                            (x + delta_px, y)
                        } else {
                            (x, y + delta_px)
                        };
                        if sx < 0 || sy < 0 || sx >= n || sy >= n {
                            continue;
                        }
                        let neighbor = &samples[(sy * n + sx) as usize];
                        if neighbor[0].w < 0.999 {
                            continue;
                        }
                        let neighbor_geometric = unpack(neighbor[7]);
                        if neighbor_geometric.z < 0.1 {
                            continue;
                        }
                        let delta = delta_px as f32 / resolution as f32;
                        // Depth grows away from the camera; image Y grows downward.
                        let direction = if axis == 0 { 1.0 } else { -1.0 };
                        let expected_slope = direction
                            * 0.5
                            * (geometric[axis] / geometric.z
                                + neighbor_geometric[axis] / neighbor_geometric.z);
                        let residual =
                            neighbor[5].x / neighbor[5].w - depth - expected_slope * delta;
                        let weight = 1.0 - *distance as f32 / (radius_px + 1) as f32;
                        if residual.abs() > 1e-6 {
                            numerator += weight * delta * residual;
                        }
                        denominator += weight * delta * delta;
                    }
                }
                if denominator > 0.0 {
                    gradient[axis] = numerator / denominator;
                }
            }
            if gradient == Vec2::ZERO {
                return center[1];
            }
            let relief = Vec3::new(gradient.x * strength, -gradient.y * strength, 1.0).normalize();
            // Reoriented normal mapping: rotate the existing normal by the relief.
            // https://blog.selfshadow.com/publications/blending-in-detail/
            let t = relief + Vec3::Z;
            let u = unpack(center[1]) * Vec3::new(-1.0, -1.0, 1.0);
            let combined = (t * t.dot(u) / t.z - u).normalize_or(Vec3::Z);
            (combined * 0.5 + Vec3::splat(0.5)).extend(1.0) * center[1].w
        })
        .collect();
    for (sample, normal) in samples.iter_mut().zip(normals) {
        sample[1] = normal;
    }
}

/// Horizon occlusion of visible geometry in capture space. Flat surfaces and
/// transparent background do not occlude; nearby raised surfaces darken recesses.
/// This deliberately contains no directional sun light or cast ground shadow.
fn capture_occlusion(samples: &[CaptureSample], resolution: u32, radius: f32) -> Vec<f32> {
    if radius == 0.0 {
        return vec![1.0; samples.len()];
    }
    let n = resolution as i32;
    let directions: Vec<Vec2> = (0..12)
        .map(|i| {
            let angle = i as f32 * std::f32::consts::TAU / 12.0;
            Vec2::new(angle.cos(), angle.sin())
        })
        .collect();
    samples
        .par_iter()
        .enumerate()
        .map(|(index, center)| {
            let alpha = center[0].w;
            if alpha < 1e-5 {
                return 1.0;
            }
            let normal = (center[1].truncate() / alpha * 2.0 - Vec3::ONE).normalize_or(Vec3::Z);
            let depth = center[5].x / alpha;
            let x = index as i32 % n;
            let y = index as i32 / n;
            let mut blocked = 0.0;
            for direction in &directions {
                let mut horizon = 0.0_f32;
                for step in [0.125, 0.25, 0.5, 0.75, 1.0] {
                    let offset = (*direction * (radius * n as f32 * step).max(1.0)).round();
                    let (sx, sy) = (x + offset.x as i32, y + offset.y as i32);
                    if sx < 0 || sy < 0 || sx >= n || sy >= n {
                        continue;
                    }
                    let neighbor = &samples[(sy * n + sx) as usize];
                    let coverage = neighbor[0].w;
                    if coverage < 1e-5 {
                        continue;
                    }
                    let delta = Vec3::new(
                        offset.x / n as f32,
                        -offset.y / n as f32,
                        depth - neighbor[5].x / coverage,
                    );
                    let distance = delta.length();
                    if distance < 1e-6 || distance >= radius {
                        continue;
                    }
                    let elevation = (normal.dot(delta / distance) - 0.02).max(0.0);
                    horizon = horizon.max(
                        elevation * elevation * (1.0 - (distance / radius).powi(2)) * coverage,
                    );
                }
                blocked += horizon;
            }
            (1.0 - blocked / directions.len() as f32).clamp(0.0, 1.0)
        })
        .collect()
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

#[cfg(test)]
mod tests {
    use super::*;

    fn relief_fixture(n: usize) -> Vec<CaptureSample> {
        let mut pixel = [Vec4::ZERO; 8];
        pixel[0] = Vec4::ONE;
        pixel[1] = Vec4::new(0.5, 0.5, 1.0, 1.0);
        pixel[5] = Vec4::new(0.5, 0.5, 0.5, 1.0);
        pixel[7] = pixel[1];
        vec![pixel; n * n]
    }

    #[test]
    fn relief_edges_have_opengl_directions_and_leave_flat_interiors_unchanged() {
        let n = 64;
        let mut samples = relief_fixture(n);
        for y in 20..44 {
            for x in 20..44 {
                samples[y * n + x][5].x = 0.4;
            }
        }
        let original = samples.clone();
        apply_depth_normals(&mut samples, n as u32, 0.65, 0.05);
        assert!(samples[32 * n + 20][1].x < 0.25, "left edge points left");
        assert!(samples[32 * n + 43][1].x > 0.75, "right edge points right");
        assert!(samples[20 * n + 32][1].y > 0.75, "top edge points up");
        assert!(samples[43 * n + 32][1].y < 0.25, "bottom edge points down");
        assert_eq!(samples[32 * n + 32], original[32 * n + 32]);
        for (pixel, before) in samples.iter().zip(&original) {
            for layer in [0, 2, 3, 4, 5, 6, 7] {
                assert_eq!(pixel[layer], before[layer]);
            }
            let normal = pixel[1].truncate() * 2.0 - Vec3::ONE;
            assert!(normal.is_finite() && (normal.length() - 1.0).abs() < 1e-5);
        }
        for (strength, radius) in [(0.0, 0.05), (0.65, 0.0)] {
            let mut disabled = original.clone();
            apply_depth_normals(&mut disabled, n as u32, strength, radius);
            assert_eq!(disabled, original);
        }
    }

    #[test]
    fn relief_does_not_double_tilted_planes_or_erase_source_normal_detail() {
        let n = 32;
        let mut samples = relief_fixture(n);
        let geometric = Vec3::new(0.3, -0.2, 1.0).normalize();
        let textured = Vec3::new(0.1, 0.4, 1.0).normalize();
        for (index, pixel) in samples.iter_mut().enumerate() {
            let (x, y) = ((index % n) as f32 / n as f32, (index / n) as f32 / n as f32);
            pixel[5].x = 0.3 + geometric.x / geometric.z * x - geometric.y / geometric.z * y;
            pixel[7] = (geometric * 0.5 + Vec3::splat(0.5)).extend(1.0);
            pixel[1] = (textured * 0.5 + Vec3::splat(0.5)).extend(1.0);
        }
        let original = samples.clone();
        apply_depth_normals(&mut samples, n as u32, 1.0, 0.1);
        assert_eq!(samples, original);
    }

    #[test]
    fn relief_ignores_background_and_partial_coverage() {
        let n = 32;
        for coverage in [0.0, 0.5, 0.998] {
            let mut samples = relief_fixture(n);
            for y in 0..n {
                for x in 0..16 {
                    samples[y * n + x][0].w = coverage;
                    samples[y * n + x][5].x = 0.1;
                }
            }
            let original = samples.clone();
            apply_depth_normals(&mut samples, n as u32, 1.0, 0.1);
            assert_eq!(samples, original);
        }
    }

    #[test]
    fn relief_preserves_texture_variation_along_an_edge() {
        let n = 32;
        let mut samples = relief_fixture(n);
        for y in 0..n {
            for x in 0..16 {
                samples[y * n + x][5].x = 0.4;
            }
        }
        let detail = Vec3::new(0.0, 0.4, 1.0).normalize();
        samples[16 * n + 15][1] = (detail * 0.5 + Vec3::splat(0.5)).extend(1.0);
        apply_depth_normals(&mut samples, n as u32, 0.65, 0.05);
        let textured = samples[16 * n + 15][1].truncate() * 2.0 - Vec3::ONE;
        let plain = samples[17 * n + 15][1].truncate() * 2.0 - Vec3::ONE;
        assert!(textured.x > 0.2 && plain.x > 0.2);
        assert!((textured.y - detail.y).abs() < 1e-5);
        assert_eq!(plain.y, 0.0);
    }

    #[test]
    fn occlusion_preserves_flat_surfaces_and_darkens_recesses_without_background_halos() {
        let n = 32;
        let mut pixel = [Vec4::ZERO; 8];
        pixel[0] = Vec4::ONE;
        pixel[1] = Vec4::new(0.5, 0.5, 1.0, 1.0);
        pixel[5] = Vec4::splat(0.5);
        let mut samples = vec![pixel; n * n];
        assert!(
            capture_occlusion(&samples, n as u32, 0.25)
                .iter()
                .all(|v| *v == 1.0)
        );
        // A sunken center with raised, opaque neighbors.
        for y in 0..n {
            for x in 0..n {
                if !(13..19).contains(&x) || !(13..19).contains(&y) {
                    samples[y * n + x][5].x = 0.4;
                }
            }
        }
        let ao = capture_occlusion(&samples, n as u32, 0.25);
        assert!(ao[16 * n + 16] < 0.9, "recess must retain cavity contrast");
        assert_eq!(
            ao[2 * n + 2],
            1.0,
            "raised flat surface must stay unoccluded"
        );
        // The same depth discontinuity with transparent neighbors isn't an occluder.
        for p in &mut samples {
            if p[5].x < 0.5 {
                p[0].w = 0.0;
            }
        }
        assert!(
            capture_occlusion(&samples, n as u32, 0.25)
                .iter()
                .all(|v| *v == 1.0)
        );
        assert!(
            capture_occlusion(&samples, n as u32, 0.0)
                .iter()
                .all(|v| *v == 1.0)
        );
    }
}
