//! The tray icon (StatusNotifierItem, which KDE Plasma shows): status dot, tooltip and menu.

use async_channel::{Receiver, Sender};
use gpui_kit::{App, Global};
use ksni::blocking::{Handle, TrayMethods as _};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::status::{Alert, UnitState};
use mio_control_core::tray_icon::{TrayStatus, render_argb};

use crate::{desktop, model, operation, window};

/// What the tray asks the app to do; sent from ksni's thread to GPUI's foreground.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayCommand {
    Show,
    Restart(Unit),
    /// Stops the gateway: the phone gets no AI until it is started again.
    PauseAi,
    ResumeAi,
    Quit,
}

pub struct MioTray {
    status: Option<TrayStatus>,
    summary: String,
    gateway: UnitState,
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
        let item = |label: &str, command: TrayCommand, enabled: bool| -> ksni::MenuItem<Self> {
            StandardItem {
                label: label.into(),
                enabled,
                activate: Box::new(move |tray: &mut Self| tray.send(command)),
                ..Default::default()
            }
            .into()
        };
        let gateway_runs = self.gateway == UnitState::Running;
        let gateway_stopped = matches!(self.gateway, UnitState::Stopped | UnitState::Failed);
        vec![
            item("Öppna Mio Kontroll", TrayCommand::Show, true),
            ksni::MenuItem::Separator,
            item("Starta om gatewayen", TrayCommand::Restart(Unit::Gateway), gateway_runs),
            item("Starta om Pianissimo", TrayCommand::Restart(Unit::Transcription), true),
            if gateway_stopped {
                item("Starta AI på datorn", TrayCommand::ResumeAi, true)
            } else {
                item("Pausa AI på datorn", TrayCommand::PauseAi, gateway_runs)
            },
            ksni::MenuItem::Separator,
            item("Avsluta", TrayCommand::Quit, true),
        ]
    }
}

struct TrayHandle(Handle<MioTray>);

impl Global for TrayHandle {}

/// Starts the tray service on its own thread. Without a tray host the app still runs and the
/// window can be opened with `mio-control --visa`.
pub fn spawn(cx: &mut App) -> Receiver<TrayCommand> {
    let (sender, receiver) = async_channel::unbounded();
    let tray = MioTray { status: None, summary: "Läser status …".into(), gateway: UnitState::Unknown, commands: sender };
    // Plasma's tray may start after the app at login; assume it is there and let ksni wait.
    match tray.assume_sni_available(true).spawn() {
        Ok(handle) => cx.set_global(TrayHandle(handle)),
        Err(error) => eprintln!("mio-control: systemfältet gick inte att starta: {error}"),
    }
    receiver
}

/// Keeps the dot, tooltip and menu in step with the status, and turns alerts into notifications.
pub fn follow_status(cx: &mut App) {
    let status = model::status(cx);
    cx.observe(&status, |status, cx| {
        let overview = status.read(cx).overview().clone();
        if let Some(handle) = cx.try_global::<TrayHandle>() {
            handle.0.update(|tray| {
                tray.status = overview.tray_status();
                tray.summary = overview.summary();
                tray.gateway = overview.gateway_unit.clone();
            });
        }
    })
    .detach();
    cx.subscribe(&status, |_, alerts: &model::StatusAlerts, _| alerts.0.iter().for_each(desktop::notify)).detach();
}

/// Carries out tray commands on GPUI's foreground executor.
pub fn listen(commands: Receiver<TrayCommand>, cx: &mut App) {
    cx.spawn(async move |cx| {
        while let Ok(command) = commands.recv().await {
            let helper = match command {
                TrayCommand::Show => {
                    cx.update(window::show);
                    continue;
                }
                TrayCommand::Quit => {
                    cx.update(|cx| cx.quit());
                    continue;
                }
                TrayCommand::Restart(unit) => (Command::Unit(UnitAction::Restart, unit), "startades om"),
                TrayCommand::PauseAi => (Command::Unit(UnitAction::Stop, Unit::Gateway), "pausades"),
                TrayCommand::ResumeAi => (Command::Unit(UnitAction::Start, Unit::Gateway), "startades"),
            };
            let (command, done) = helper;
            let task = cx.update(|cx| operation::run(command.clone(), None, cx));
            let result = task.await;
            let name = match command {
                Command::Unit(_, Unit::Transcription) => "Pianissimo",
                Command::Unit(UnitAction::Restart, _) => "AI-gatewayen",
                _ => "AI på datorn",
            };
            match result {
                Ok(_) => desktop::notify(&Alert { title: format!("{name} {done}"), body: String::new() }),
                Err(error) => desktop::notify(&Alert { title: format!("{name} gick inte att ändra"), body: error.to_string() }),
            }
            cx.update(|cx| model::status(cx).update(cx, |status, _| status.request_refresh()));
        }
    })
    .detach();
}
