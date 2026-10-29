use anyhow::{Result, bail, ensure};
use glam::Vec3;
use rbx_dom_weak::types::{Attributes, Variant};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub pan_shot_count: u32,
    pub tilt_shot_count: u32,
    pub max_resolution_px: u32,
    pub padding_px: u32,
    pub tilt_constraints: [f32; 2],
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            pan_shot_count: 8,
            tilt_shot_count: 1,
            max_resolution_px: 252,
            padding_px: 2,
            tilt_constraints: [-180.0, 180.0],
        }
    }
}

impl Settings {
    pub fn from_attributes(attrs: Option<&Attributes>) -> Result<Self> {
        let mut s = Self::default();
        if let Some(a) = attrs {
            for (name, target) in [
                ("PanShotCount", &mut s.pan_shot_count),
                ("TiltShotCount", &mut s.tilt_shot_count),
                ("MaxResolutionPx", &mut s.max_resolution_px),
                ("PaddingPx", &mut s.padding_px),
            ] {
                if let Some(value) = a.get(name) {
                    let n = match value {
                        Variant::Float64(n) => *n,
                        Variant::Float32(n) => *n as f64,
                        Variant::Int32(n) => *n as f64,
                        Variant::Int64(n) => *n as f64,
                        _ => bail!("{name} must be an integer number"),
                    };
                    ensure!(
                        n.is_finite() && n >= 0.0 && n <= u32::MAX as f64 && n.fract() == 0.0,
                        "{name} must be a nonnegative integer"
                    );
                    *target = n as u32;
                }
            }
            if let Some(value) = a.get("TiltConstraints") {
                if let Variant::NumberRange(r) = value {
                    s.tilt_constraints = [r.min, r.max];
                } else {
                    bail!("TiltConstraints must be a NumberRange in degrees");
                }
            }
        }
        s.validate()?;
        Ok(s)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            (1..=256).contains(&self.pan_shot_count),
            "PanShotCount must be 1..256"
        );
        ensure!(
            (1..=256).contains(&self.tilt_shot_count),
            "TiltShotCount must be 1..256"
        );
        ensure!(self.count() <= 4096, "at most 4096 shots are supported");
        ensure!(
            (1..=4096).contains(&self.max_resolution_px),
            "MaxResolutionPx must be 1..4096"
        );
        ensure!(self.padding_px <= 64, "PaddingPx must be 0..64");
        let [lo, hi] = self.tilt_constraints;
        ensure!(
            lo.is_finite() && hi.is_finite() && lo >= -180.0 && hi <= 180.0 && lo <= hi,
            "TiltConstraints must be ordered, finite, and within -180..180 degrees"
        );
        Ok(())
    }
    pub fn count(&self) -> u32 {
        self.pan_shot_count * self.tilt_shot_count
    }
    pub fn tile_size(&self) -> u32 {
        self.max_resolution_px + 2 * self.padding_px
    }
    pub fn grid(&self) -> [u32; 2] {
        let columns = (self.count() as f32).sqrt().ceil() as u32;
        [columns, self.count().div_ceil(columns)]
    }
    pub fn angles(&self, index: u32) -> [f32; 2] {
        let pan = index % self.pan_shot_count;
        let tilt = index / self.pan_shot_count;
        let [lo, hi] = self.tilt_constraints;
        let pitch = if self.tilt_shot_count == 1 {
            (lo + hi) / 2.0
        } else {
            lo + (hi - lo) * tilt as f32 / (self.tilt_shot_count - 1) as f32
        };
        [360.0 * pan as f32 / self.pan_shot_count as f32, pitch]
    }
}

/// Shot zero is viewed from local +Z, pan increases toward +X.
/// Analytic basis remains defined at the poles and through inverted tilts.
pub fn basis(yaw_degrees: f32, pitch_degrees: f32) -> [Vec3; 3] {
    let (sy, cy) = yaw_degrees.to_radians().sin_cos();
    let (sp, cp) = pitch_degrees.to_radians().sin_cos();
    let right = Vec3::new(cy, 0.0, -sy);
    let toward = Vec3::new(sy * cp, sp, cy * cp);
    [right, toward.cross(right), toward]
}

pub fn shot_key(index: u32) -> String {
    format!("shot_{index:04}")
}
