//! The tray icon, drawn in code so it needs no image files or libraries.
//!
//! The mark is an ember orange rounded square with a graphite "M"; a status dot sits in the
//! bottom-right corner with a graphite ring that keeps it apart from the orange at 22 px.
//! Colors here are the icon's own raster data (see control/DESIGN.md), not UI theme values.

/// What the dot says. The tooltip always says the same thing in words.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrayStatus {
    /// Everything runs.
    Ok,
    /// Something is loading or the quota is running low.
    Warning,
    /// A service is down.
    Error,
}

const EMBER: [u8; 3] = [0xF0, 0x70, 0x2E];
const GRAPHITE: [u8; 3] = [0x1C, 0x1B, 0x1A];
const GREEN: [u8; 3] = [0x6B, 0xBF, 0x59];
const AMBER: [u8; 3] = [0xE8, 0xB9, 0x3C];
const RED: [u8; 3] = [0xE5, 0x48, 0x4D];

impl TrayStatus {
    fn color(self) -> [u8; 3] {
        match self {
            TrayStatus::Ok => GREEN,
            TrayStatus::Warning => AMBER,
            TrayStatus::Error => RED,
        }
    }
}

/// Distance from `p` to the segment `a`–`b`.
fn segment_distance(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    let (cx, cy) = (a.0 + t * dx - p.0, a.1 + t * dy - p.1);
    (cx * cx + cy * cy).sqrt()
}

/// Signed distance to a rounded square spanning 0..1 with corner radius `r` (negative inside).
fn rounded_square(p: (f32, f32), inset: f32, r: f32) -> f32 {
    let half = 0.5 - inset;
    let qx = (p.0 - 0.5).abs() - (half - r);
    let qy = (p.1 - 0.5).abs() - (half - r);
    let outside = (qx.max(0.0).powi(2) + qy.max(0.0).powi(2)).sqrt();
    outside + qx.max(qy).min(0.0) - r
}

/// The color of one sample in unit coordinates (0..1), or `None` where it is transparent.
fn sample(p: (f32, f32), status: Option<TrayStatus>) -> Option<[u8; 3]> {
    // Status dot with a graphite ring, on top of everything.
    if let Some(status) = status {
        let center = (0.80, 0.80);
        let distance = ((p.0 - center.0).powi(2) + (p.1 - center.1).powi(2)).sqrt();
        if distance <= 0.16 {
            return Some(status.color());
        }
        if distance <= 0.22 {
            return Some(GRAPHITE);
        }
    }
    if rounded_square(p, 0.04, 0.24) > 0.0 {
        return None;
    }
    // The M: two stems and a V that meets at the middle, as round-capped strokes.
    // Drawn up and left of center so the status dot clips only the foot of the right stem.
    let stroke = 0.08;
    let strokes = [
        ((0.24, 0.66), (0.24, 0.26)),
        ((0.24, 0.26), (0.45, 0.50)),
        ((0.45, 0.50), (0.66, 0.26)),
        ((0.66, 0.26), (0.66, 0.66)),
    ];
    if strokes.iter().any(|(a, b)| segment_distance(p, *a, *b) <= stroke) {
        return Some(GRAPHITE);
    }
    Some(EMBER)
}

/// Renders a `size`×`size` icon as ARGB32 in network byte order, as StatusNotifierItem wants.
///
/// Each pixel averages a 4×4 grid of samples, which gives smooth edges without a rasterizer.
pub fn render_argb(size: u32, status: Option<TrayStatus>) -> Vec<u8> {
    const GRID: u32 = 4;
    let mut pixels = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let (mut red, mut green, mut blue, mut covered) = (0u32, 0u32, 0u32, 0u32);
            for sy in 0..GRID {
                for sx in 0..GRID {
                    let p = (
                        (x as f32 + (sx as f32 + 0.5) / GRID as f32) / size as f32,
                        (y as f32 + (sy as f32 + 0.5) / GRID as f32) / size as f32,
                    );
                    if let Some([r, g, b]) = sample(p, status) {
                        red += u32::from(r);
                        green += u32::from(g);
                        blue += u32::from(b);
                        covered += 1;
                    }
                }
            }
            if covered == 0 {
                pixels.extend_from_slice(&[0, 0, 0, 0]);
            } else {
                let alpha = covered * 255 / (GRID * GRID);
                // Straight (not premultiplied) alpha, as the specification expects.
                pixels.extend_from_slice(&[
                    alpha as u8,
                    (red / covered) as u8,
                    (green / covered) as u8,
                    (blue / covered) as u8,
                ]);
            }
        }
    }
    pixels
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pixel(icon: &[u8], size: u32, x: u32, y: u32) -> [u8; 4] {
        let index = ((y * size + x) * 4) as usize;
        icon[index..index + 4].try_into().unwrap()
    }

    #[test]
    fn icon_has_the_requested_size() {
        for size in [16, 22, 24, 32, 48, 64] {
            assert_eq!(render_argb(size, Some(TrayStatus::Ok)).len(), (size * size * 4) as usize);
        }
    }

    #[test]
    fn corners_are_transparent_and_center_is_opaque() {
        let icon = render_argb(64, None);
        assert_eq!(pixel(&icon, 64, 0, 0)[0], 0);
        assert_eq!(pixel(&icon, 64, 32, 10)[0], 255);
    }

    #[test]
    fn dot_carries_the_status_color() {
        for (status, rgb) in [(TrayStatus::Ok, GREEN), (TrayStatus::Warning, AMBER), (TrayStatus::Error, RED)] {
            let icon = render_argb(64, Some(status));
            let [alpha, r, g, b] = pixel(&icon, 64, 51, 51);
            assert_eq!((alpha, [r, g, b]), (255, rgb), "{status:?}");
        }
    }

    #[test]
    fn statuses_differ_at_tray_size() {
        let ok = render_argb(22, Some(TrayStatus::Ok));
        let error = render_argb(22, Some(TrayStatus::Error));
        assert_ne!(ok, error);
    }
}
