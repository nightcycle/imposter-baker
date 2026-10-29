fn main() -> anyhow::Result<()> {
    let path = std::env::args().nth(1).unwrap();
    let bytes = std::fs::read(path)?;
    let m = rbx_mesh::read_mesh_versioned(std::io::Cursor::new(bytes))?;
    match m {
        rbx_mesh::mesh::Mesh::V4(m) => println!(
            "v4 verts={} faces={} lods={:?}",
            m.vertices.len(),
            m.faces.len(),
            m.lods
        ),
        rbx_mesh::mesh::Mesh::V3(m) => println!("v3 faces={} lods={:?}", m.faces.len(), m.lods),
        _ => println!("other"),
    }
    Ok(())
}
