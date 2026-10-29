fn main() -> anyhow::Result<()> {
    for path in std::env::args().skip(1) {
        let dom = rbx_binary::from_reader(std::fs::File::open(&path)?)?;
        println!("{path}");
        for item in dom.descendants() {
            let properties: std::collections::BTreeMap<_, _> = item
                .properties
                .iter()
                .filter(|(k, _)| {
                    matches!(
                        k.as_str(),
                        "MeshContent"
                            | "MeshId"
                            | "Size"
                            | "InitialSize"
                            | "CFrame"
                            | "Color"
                            | "Attributes"
                            | "TextureContent"
                            | "ColorMapContent"
                            | "NormalMapContent"
                            | "RoughnessMapContent"
                            | "MetalnessMapContent"
                            | "EmissiveMaskContent"
                            | "AlphaMode"
                    )
                })
                .collect();
            println!("{} {} {:?}", item.class, item.name, properties);
        }
    }
    Ok(())
}
