//! Mio Kontroll: lives in the tray and opens one window on request.

pub mod ai;
pub mod computer;
pub mod desktop;
pub mod logs;
pub mod model;
pub mod network;
pub mod operation;
pub mod overview;
pub mod parts;
pub mod setup;
pub mod shell;
pub mod theme;
pub mod transcription;
pub mod tray;
pub mod updates;
pub mod verify;
pub mod window;
pub mod words;

use gpui_kit::QuitMode;

/// Starts the app. `show_window` opens the window at once; the login entry starts without it.
pub fn run(show_window: bool) {
    let preferences = mio_control_core::computer::preferences_path()
        .map(|path| mio_control_core::computer::Preferences::load(&path))
        .unwrap_or_default();
    // The tray keeps the app alive; closing the window must never quit it (user's choice 2026-11-17).
    // Without the tray icon (Datorn) the window is the app, so closing it quits.
    let quit_mode = if preferences.tray { QuitMode::Explicit } else { QuitMode::LastWindowClosed };
    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .with_quit_mode(quit_mode)
        .run(move |cx| {
            gpui_kit::init(cx);
            theme::init(cx);
            window::init(cx);
            model::init(cx);
            if preferences.keep_awake
                && let Err(message) = computer::set_awake(true, cx)
            {
                eprintln!("mio-control: {message}");
            }
            if preferences.tray {
                let commands = tray::spawn(cx);
                tray::listen(commands, cx);
            }
            // Desktop notifications come with or without the icon.
            tray::follow_status(cx);
            if show_window || !preferences.tray {
                window::show(cx);
            }
        });
}
