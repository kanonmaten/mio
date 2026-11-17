//! The one window: about 720 × 520, resizable, maximizable and fullscreen, with its own title bar.

use gpui_kit::component::{Theme, TitleBar};
use gpui_kit::{
    App, AppContext as _, Bounds, KeyBinding, TitlebarOptions, WindowBounds, WindowDecorations, WindowOptions, actions, px, size,
};

use crate::shell::Shell;

actions!(mio_control, [ToggleFullscreen, CloseWindow]);

pub fn init(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("f11", ToggleFullscreen, None),
        KeyBinding::new("ctrl-w", CloseWindow, None),
    ]);
}

/// Brings the window forward, or opens it if it is closed.
pub fn show(cx: &mut App) {
    if let Some(window) = cx.windows().into_iter().next() {
        let _ = window.update(cx, |_, window, _| window.activate_window());
        return;
    }
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, size(px(720.), px(520.)), cx))),
        window_min_size: Some(size(px(560.), px(400.))),
        // Client-side decorations so the frame and title bar get the theme's rounded corners under KWin.
        window_decorations: Some(WindowDecorations::Client),
        app_id: Some("app.mio.control".into()),
        // The title KWin's task manager and Alt+Tab show; the title bar itself is drawn by the app.
        titlebar: Some(TitlebarOptions { title: Some("Mio Kontroll".into()), ..TitleBar::title_bar_options() }),
        ..TitleBar::window_options()
    };
    let opened = gpui_kit::open_window(options, cx, |window, cx| {
        // Follow the desktop's light/dark switch for as long as the window is open.
        window
            .observe_window_appearance(|window, cx| Theme::sync_system_appearance(Some(window), cx))
            .detach();
        let status = crate::model::status(cx);
        cx.new(|cx| Shell::new(status, window, cx))
    });
    if let Err(error) = opened {
        eprintln!("mio-control: fönstret gick inte att öppna: {error}");
    }
}
