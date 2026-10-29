use anyhow::{Result, ensure};
use glam::{Vec2, Vec3, Vec4};
use rbx_mesh::mesh::{Face2, Mesh, Vertex2, Vertices2};
use std::io::Cursor;

#[derive(Clone, Copy, Debug)]
pub struct Vertex {
    pub position: Vec3,
    pub normal: Vec3,
    pub uv: Vec2,
    pub color: Vec4,
}

#[derive(Clone)]
pub struct Geometry {
    pub vertices: Vec<Vertex>,
    pub faces: Vec<[usize; 3]>,
}

fn vertex(v: Vertex2) -> Vertex {
    Vertex {
        position: Vec3::from_array(v.pos),
        normal: Vec3::from_array(v.norm),
        uv: Vec2::from_array(v.tex),
        color: Vec4::from_array(v.color.map(|x| x as f32 / 255.0)),
    }
}
fn vertices(v: Vertices2) -> Vec<Vertex> {
    match v {
        Vertices2::Full(v) => v.into_iter().map(vertex).collect(),
        Vertices2::Truncated(v) => v
            .into_iter()
            .map(|v| Vertex {
                position: Vec3::from_array(v.pos),
                normal: Vec3::from_array(v.norm),
                uv: Vec2::from_array(v.tex),
                color: Vec4::ONE,
            })
            .collect(),
    }
}
fn faces(v: Vec<Face2>, end: Option<u32>) -> Vec<[usize; 3]> {
    v.into_iter()
        .take(end.map_or(usize::MAX, |x| x as usize))
        .map(|f| f.0.map(|v| v.0 as usize))
        .collect()
}

pub fn decode(bytes: &[u8]) -> Result<Geometry> {
    let mesh = rbx_mesh::read_mesh_versioned(Cursor::new(bytes))?;
    let g = match mesh {
        Mesh::V1(m) => {
            let vertices: Vec<_> = m
                .vertices
                .into_iter()
                .map(|v| Vertex {
                    position: v.pos.into(),
                    normal: v.norm.into(),
                    uv: Vec2::new(v.tex[0], v.tex[1]),
                    color: Vec4::ONE,
                })
                .collect();
            let faces = (0..vertices.len() / 3)
                .map(|i| [3 * i, 3 * i + 1, 3 * i + 2])
                .collect();
            Geometry { vertices, faces }
        }
        Mesh::V2(m) => Geometry {
            vertices: vertices(m.vertices),
            faces: faces(m.faces, None),
        },
        Mesh::V3(m) => Geometry {
            vertices: vertices(m.vertices),
            faces: faces(m.faces, m.lods.get(1).map(|x| x.0).filter(|x| *x > 0)),
        },
        Mesh::V4(m) => Geometry {
            vertices: m.vertices.into_iter().map(vertex).collect(),
            faces: faces(m.faces, m.lods.get(1).map(|x| x.0).filter(|x| *x > 0)),
        },
        Mesh::V5(m) => Geometry {
            vertices: m.vertices.into_iter().map(vertex).collect(),
            faces: faces(m.faces, m.lods.get(1).map(|x| x.0).filter(|x| *x > 0)),
        },
    };
    ensure!(
        !g.vertices.is_empty() && !g.faces.is_empty(),
        "mesh has no geometry"
    );
    ensure!(
        g.vertices
            .iter()
            .all(|v| v.position.is_finite() && v.normal.is_finite() && v.uv.is_finite()),
        "mesh has nonfinite vertex data"
    );
    ensure!(
        g.faces.iter().flatten().all(|i| *i < g.vertices.len()),
        "mesh face index out of bounds"
    );
    Ok(g)
}

/// Primitive geometry in a centered unit box. Flat UVs per face.
pub fn block(wedge: bool, corner: bool) -> Geometry {
    let p: Vec<Vec3> = [
        [-0.5, -0.5, -0.5],
        [0.5, -0.5, -0.5],
        [0.5, -0.5, 0.5],
        [-0.5, -0.5, 0.5],
        [-0.5, 0.5, -0.5],
        [0.5, 0.5, -0.5],
        [0.5, 0.5, 0.5],
        [-0.5, 0.5, 0.5],
    ]
    .map(Vec3::from_array)
    .to_vec();
    let triangles: Vec<[usize; 3]> = if corner {
        vec![
            [0, 2, 1],
            [0, 3, 2],
            [0, 1, 4],
            [1, 2, 4],
            [2, 3, 4],
            [3, 0, 4],
        ]
    } else if wedge {
        vec![
            [0, 2, 1],
            [0, 3, 2],
            [0, 1, 5],
            [0, 5, 4],
            [3, 4, 5],
            [3, 5, 2],
            [0, 4, 3],
            [1, 2, 5],
        ]
    } else {
        vec![
            [0, 2, 1],
            [0, 3, 2],
            [4, 5, 6],
            [4, 6, 7],
            [0, 1, 5],
            [0, 5, 4],
            [3, 7, 6],
            [3, 6, 2],
            [0, 4, 7],
            [0, 7, 3],
            [1, 2, 6],
            [1, 6, 5],
        ]
    };
    let mut g = Geometry {
        vertices: vec![],
        faces: vec![],
    };
    for f in triangles {
        let n = (p[f[1]] - p[f[0]]).cross(p[f[2]] - p[f[0]]).normalize();
        let base = g.vertices.len();
        for (i, idx) in f.into_iter().enumerate() {
            g.vertices.push(Vertex {
                position: p[idx],
                normal: n,
                uv: [Vec2::ZERO, Vec2::X, Vec2::ONE][i],
                color: Vec4::ONE,
            });
        }
        g.faces.push([base, base + 1, base + 2]);
    }
    g
}

pub fn round(cylinder: bool) -> Geometry {
    let mut g = Geometry {
        vertices: vec![],
        faces: vec![],
    };
    let rings = if cylinder { 1 } else { 16 };
    let segments = 32;
    for y in 0..=rings {
        for x in 0..=segments {
            let u = x as f32 / segments as f32;
            let v = y as f32 / rings as f32;
            let a = u * std::f32::consts::TAU;
            let b = v * std::f32::consts::PI;
            let normal = if cylinder {
                Vec3::new(0.0, a.cos(), a.sin())
            } else {
                Vec3::new(a.sin() * b.sin(), b.cos(), a.cos() * b.sin())
            };
            let position = if cylinder {
                Vec3::new(v - 0.5, 0.5 * a.cos(), 0.5 * a.sin())
            } else {
                normal * 0.5
            };
            g.vertices.push(Vertex {
                position,
                normal,
                uv: Vec2::new(u, v),
                color: Vec4::ONE,
            });
        }
    }
    for y in 0..rings {
        for x in 0..segments {
            let a = y * (segments + 1) + x;
            g.faces.extend([
                [a, a + 1, a + segments + 1],
                [a + 1, a + segments + 2, a + segments + 1],
            ]);
        }
    }
    if cylinder {
        for end in [0usize, 1] {
            let center = g.vertices.len();
            let normal = if end == 0 { -Vec3::X } else { Vec3::X };
            g.vertices.push(Vertex {
                position: normal * 0.5,
                normal,
                uv: Vec2::splat(0.5),
                color: Vec4::ONE,
            });
            for x in 0..segments {
                let base = end * (segments + 1) + x;
                g.faces.push([center, base, base + 1]);
            }
        }
    }
    g
}
