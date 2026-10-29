use anyhow::Result;
use clap::Parser;
use imposter_baker::{BakeOptions, assets::Assets, bake, default_cache, scene};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    version,
    about = "Bake an RBXM/RBXMX into orthographic PNG imposters and PBR layers"
)]
struct Args {
    /// Source model with optional bake attributes on its single root instance.
    input: PathBuf,
    /// A .png path creates atlases; any other path creates a directory of shots.
    output: PathBuf,
    /// Asset ID cache (<id>.bin). Public missing assets are downloaded automatically.
    #[arg(long,default_value_os_t=default_cache())]
    cache_dir: PathBuf,
    /// JSON object mapping exact content URLs to local mesh/image paths (relative to JSON).
    #[arg(long)]
    asset_map: Option<PathBuf>,
    /// Require cached/local assets; never access the network.
    #[arg(long)]
    offline: bool,
    /// Anti-aliasing sample count: 1 or 4.
    #[arg(long,default_value_t=4,value_parser=clap::value_parser!(u32).range(1..=4))]
    samples: u32,
    /// Conservative peak allocation budget in MiB.
    #[arg(long, default_value_t = 512)]
    max_memory_mib: u64,
    /// Replace files previously generated at the output location.
    #[arg(long)]
    overwrite: bool,
}
fn run() -> Result<()> {
    let args = Args::parse();
    anyhow::ensure!(
        args.samples == 1 || args.samples == 4,
        "--samples must be 1 or 4"
    );
    let assets = Assets::new(args.cache_dir, args.offline, args.asset_map.as_deref())?;
    let scene = scene::load(&args.input, &assets)?;
    for warning in &scene.warnings {
        eprintln!("Warning: {warning}");
    }
    let manifest = bake(
        &scene,
        &args.output,
        &BakeOptions {
            samples: args.samples,
            max_memory_mib: args.max_memory_mib,
            overwrite: args.overwrite,
        },
    )?;
    println!(
        "Baked {} shots with {} layers to {}",
        manifest.shots.len(),
        imposter_baker::render::LAYERS.len(),
        args.output.display()
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("Error: {error:#}");
        std::process::exit(1);
    }
}
