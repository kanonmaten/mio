//! The tray icon (StatusNotifierItem, which KDE Plasma shows) and its menu.

use async_channel::{Receiver, Sender};
use gpui_kit::App;
use ksni::blocking::TrayMethods as _;
use mio_control_core::tray_icon::{TrayStatus, render_argb};

/// What the tray asks the app to do; sent from ksni's thread to GPUI's foreground.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayCommand {
    Show,
    Quit,
}

struct MioTray {
    status: Option<TrayStatus>,
    summary: String,
    commands: Sender<TrayCommand>,
}

impl MioTray {
    fn send(&self, command: TrayCommand) {
        // The receiver lives as long as the app; a closed channel means the app is quitting.
        let _ = self.commands.send_blocking(command);
    }
}

impl ksni::Tray for MioTray {
    fn id(&self) -> String {
        "app.mio.control".into()
    }

    fn title(&self) -> String {
        "Mio Kontroll".into()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        self.send(TrayCommand::Show);
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        [22, 32, 48, 64]
            .into_iter()
            .map(|size| ksni::Icon { width: size, height: size, data: render_argb(size as u32, self.status) })
            .collect()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: "Mio Kontroll".into(), description: self.summary.clone(), ..Default::default() }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;
        vec![
            StandardItem {
                label: "Öppna Mio Kontroll".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::Show)),
                ..Default::default()
            }
            .into(),
            ksni::MenuItem::Separator,
            StandardItem {
                label: "Avsluta".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::Quit)),
                ..Default::default()
            }
            .into(),
        ]
    }
}

/// Starts the tray service on its own thread. Without a tray host the app still runs and the
/// window can be opened with `mio-control --visa`.
pub fn spawn() -> Receiver<TrayCommand> {
    let (sender, receiver) = async_channel::unbounded();
    let tray = MioTray { status: None, summary: "Läser status …".into(), commands: sender };
    // Plasma's tray may start after the app at login; assume it is there and let ksni wait.
    match tray.assume_sni_available(true).spawn() {
        Ok(handle) => std::mem::forget(handle),
        Err(error) => eprintln!("mio-control: systemfältet gick inte att starta: {error}"),
    }
    receiver
}

/// Carries out tray commands on GPUI's foreground executor.
pub fn listen(commands: Receiver<TrayCommand>, cx: &mut App) {
    cx.spawn(async move |cx| {
        while let Ok(command) = commands.recv().await {
            cx.update(|cx| match command {
                TrayCommand::Show => crate::window::show(cx),
                TrayCommand::Quit => cx.quit(),
            });
        }
    })
    .detach();
}
