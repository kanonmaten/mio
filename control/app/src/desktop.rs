//! Desktop notifications (freedesktop, which KDE Plasma shows) for alerts while the window is closed.

use mio_control_core::status::Alert;

pub fn notify(alert: &Alert) {
    // A missing notification daemon is not worth interrupting anything for.
    let _ = notify_rust::Notification::new()
        .appname("Mio Kontroll")
        .icon("app.mio.control")
        .summary(&alert.title)
        .body(&alert.body)
        .show();
}

/// The login entry `control/install.sh` writes, `$XDG_CONFIG_HOME/autostart/app.mio.control.desktop`.
pub fn autostart_path() -> Option<std::path::PathBuf> {
    mio_control_core::computer::autostart_path()
}
