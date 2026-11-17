//! Mio Kontroll: lives in the tray and opens one window on request.

mod shell;
mod theme;
mod tray;
mod window;

use gpui_kit::QuitMode;

fn main() {
    // The tray keeps the app alive; closing the window must never quit it (user's choice 2026-11-17).
    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .with_quit_mode(QuitMode::Explicit)
        .run(|cx| {
            gpui_kit::init(cx);
            theme::init(cx);
            window::init(cx);
            let commands = tray::spawn();
            tray::listen(commands, cx);
            // `--visa` opens the window at start; the login entry starts without it.
            if std::env::args().any(|argument| argument == "--visa") {
                window::show(cx);
            }
        });
}
