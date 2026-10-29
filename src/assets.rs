use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::HashMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_ASSET_BYTES: u64 = 128 * 1024 * 1024;

/// Exact URL overrides take priority. Asset IDs use `<id>.bin` cache entries.
pub struct Assets {
    pub cache: PathBuf,
    pub offline: bool,
    overrides: HashMap<String, PathBuf>,
    client: reqwest::blocking::Client,
}

impl Assets {
    pub fn new(cache: PathBuf, offline: bool, mapping: Option<&Path>) -> Result<Self> {
        let overrides = if let Some(path) = mapping {
            let mappings: HashMap<String, PathBuf> = serde_json::from_slice(&fs::read(path)?)?;
            let base = path.parent().unwrap_or(Path::new("."));
            mappings
                .into_iter()
                .map(|(k, v)| (k, base.join(v)))
                .collect()
        } else {
            HashMap::new()
        };
        Ok(Self {
            cache,
            offline,
            overrides,
            client: reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(60))
                .user_agent("imposter-baker/0.1")
                .build()?,
        })
    }

    pub fn load(&self, content: &str) -> Result<Vec<u8>> {
        if let Some(path) = self.overrides.get(content) {
            return fs::read(path).with_context(|| format!("asset override {}", path.display()));
        }
        let id = asset_id(content)
            .with_context(|| format!("unsupported content {content:?}; use --asset-map"))?;
        let path = self.cache.join(format!("{id}.bin"));
        if path.is_file() {
            return Ok(fs::read(path)?);
        }
        ensure!(
            !self.offline,
            "asset {id} is missing from {}; provide --asset-map or populate the cache",
            self.cache.display()
        );
        let response = self
            .client
            .get(format!(
                "https://assetdelivery.roblox.com/v1/asset/?id={id}"
            ))
            .send()
            .with_context(|| format!("downloading asset {id}"))?
            .error_for_status()
            .with_context(|| {
                format!("asset {id} is unavailable; use --asset-map for private assets")
            })?;
        ensure!(
            response.content_length().unwrap_or(0) <= MAX_ASSET_BYTES,
            "asset {id} exceeds 128 MiB"
        );
        let mut bytes = Vec::new();
        response.take(MAX_ASSET_BYTES + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= MAX_ASSET_BYTES,
            "asset {id} exceeds 128 MiB"
        );
        if bytes.starts_with(b"{\"errors\"") || bytes.starts_with(b"<!DOCTYPE") {
            bail!("asset {id} returned an error response");
        }
        fs::create_dir_all(&self.cache)?;
        fs::write(&path, &bytes)?;
        Ok(bytes)
    }
}

pub fn asset_id(content: &str) -> Option<u64> {
    if let Some(id) = content.strip_prefix("rbxassetid://") {
        return id.parse().ok().filter(|x| *x > 0);
    }
    if content.chars().all(|c| c.is_ascii_digit()) {
        return content.parse().ok().filter(|x| *x > 0);
    }
    // Do not fetch arbitrary URLs embedded in untrusted model files.
    let url = reqwest::Url::parse(content).ok()?;
    if !matches!(
        url.host_str()?,
        "www.roblox.com" | "roblox.com" | "assetdelivery.roblox.com"
    ) {
        return None;
    }
    url.query_pairs().find_map(|(k, v)| {
        if k == "id" {
            v.parse().ok().filter(|x| *x > 0)
        } else {
            None
        }
    })
}
