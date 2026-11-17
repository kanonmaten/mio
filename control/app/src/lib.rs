//! Mio Kontroll: lives in the tray and opens one window on request.

pub mod ai;
pub mod desktop;
pub mod logs;
pub mod model;
pub mod network;
pub mod operation;
pub mod overview;
pub mod parts;
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
    // The tray keeps the app alive; closing the window must never quit it (user's choice 2026-11-17).
    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .with_quit_mode(QuitMode::Explicit)
        .run(move |cx| {
            gpui_kit::init(cx);
            theme::init(cx);
            window::init(cx);
            model::init(cx);
            let commands = tray::spawn(cx);
            tray::follow_status(cx);
            tray::listen(commands, cx);
            if show_window {
                window::show(cx);
            }
        });
}
