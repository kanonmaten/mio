//! Writes the tray icon in every state as PAM images (RGBA), to look at the design:
//! `cargo run -p mio-control-core --example tray_icon_preview -- <directory>`

use mio_control_core::tray_icon::{TrayStatus, render_argb};

fn main() -> std::io::Result<()> {
    let directory = std::env::args().nth(1).unwrap_or_else(|| ".".into());
    let states = [("ingen", None), ("ok", Some(TrayStatus::Ok)), ("varning", Some(TrayStatus::Warning)), ("fel", Some(TrayStatus::Error))];
    for size in [22u32, 64] {
        for (name, status) in states {
            let argb = render_argb(size, status);
            let mut image = format!("P7\nWIDTH {size}\nHEIGHT {size}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n").into_bytes();
            for pixel in argb.as_chunks::<4>().0 {
                image.extend_from_slice(&[pixel[1], pixel[2], pixel[3], pixel[0]]);
            }
            std::fs::write(format!("{directory}/mio-tray-{name}-{size}.pam"), image)?;
        }
    }
    Ok(())
}
