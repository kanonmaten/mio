//! Datorn: keep the computer awake, start at login, and the tray icon on or off.

use std::any::Any;
use std::path::PathBuf;
use std::sync::Arc;

use gpui_kit::component::notification::Notification;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{ActiveTheme as _, WindowExt as _, v_flex};
use gpui_kit::{App, Context, Global, IntoElement, ParentElement as _, Render, Styled as _, Window, div};
use mio_control_core::computer::{Preferences, autostart_path, inhibit, preferences_path, set_autostart};

use crate::parts::{page_header, section};

pub type InhibitFn = Arc<dyn Fn() -> Result<Box<dyn Any>, String> + Send + Sync>;

/// Where Datorn reads and writes; tests point it at a temporary folder and a fake inhibition.
#[derive(Clone)]
pub struct ComputerBackend {
    pub inhibit: InhibitFn,
    pub preferences: Option<PathBuf>,
    pub autostart: Option<PathBuf>,
}

impl Global for ComputerBackend {}

impl ComputerBackend {
    pub fn system() -> Self {
        Self {
            inhibit: Arc::new(|| inhibit().map(|held| Box::new(held) as Box<dyn Any>)),
            preferences: preferences_path(),
            autostart: autostart_path(),
        }
    }
}

fn backend(cx: &App) -> ComputerBackend {
    cx.try_global::<ComputerBackend>().cloned().unwrap_or_else(ComputerBackend::system)
}

/// The held inhibition; dropping it lets the computer sleep again.
#[derive(Default)]
struct Awake(Option<Box<dyn Any>>);

impl Global for Awake {}

pub fn preferences(cx: &App) -> Preferences {
    backend(cx).preferences.map(|path| Preferences::load(&path)).unwrap_or_default()
}

/// Turns keeping awake on or off; on start too, when the preference says so.
pub fn set_awake(on: bool, cx: &mut App) -> Result<(), String> {
    let held = if on { Some((backend(cx).inhibit)()?) } else { None };
    cx.set_global(Awake(held));
    Ok(())
}

pub fn is_awake(cx: &App) -> bool {
    cx.try_global::<Awake>().is_some_and(|awake| awake.0.is_some())
}

pub struct ComputerPage;

impl ComputerPage {
    fn save(change: impl FnOnce(&mut Preferences), window: &mut Window, cx: &mut App) {
        let mut preferences = preferences(cx);
        change(&mut preferences);
        if let Some(path) = backend(cx).preferences
            && let Err(message) = preferences.save(&path)
        {
            window.push_notification(Notification::error(message), cx);
        }
    }
}

impl Render for ComputerPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let preferences = preferences(cx);
        let autostart = backend(cx).autostart.is_some_and(|path| path.exists());
        let muted = |text: &str| div().text_sm().text_color(theme.muted_foreground).child(text.to_owned());
        v_flex().size_full().p_4().gap_3()
            .child(page_header("Datorn", "Hur panelen och datorn beter sig medan Mio används.", cx))
            .child(section("Viloläge"))
            .child(Switch::new("keep-awake").label("Håll datorn vaken medan Mio Kontroll kör").checked(is_awake(cx))
                .on_change(cx.listener(|_, on: &bool, window, cx| {
                    let on = *on;
                    match set_awake(on, cx) {
                        Ok(()) => Self::save(|preferences| preferences.keep_awake = on, window, cx),
                        Err(message) => window.push_notification(Notification::error(message), cx),
                    }
                    cx.notify();
                })))
            .child(muted("KDE:s energihantering låter då bli att söva datorn, så att telefonen alltid når Pianissimo och AI. Skärmen kan fortfarande släckas."))
            .child(section("Start"))
            .child(Switch::new("autostart").label("Starta Mio Kontroll vid inloggning").checked(autostart)
                .on_change(cx.listener(|_, on: &bool, window, cx| {
                    if let Some(path) = backend(cx).autostart
                        && let Err(message) = set_autostart(&path, *on)
                    {
                        window.push_notification(Notification::error(message), cx);
                    }
                    cx.notify();
                })))
            .child(Switch::new("tray").label("Ikon i systemfältet").checked(preferences.tray)
                .on_change(cx.listener(|_, on: &bool, window, cx| {
                    let on = *on;
                    Self::save(|preferences| preferences.tray = on, window, cx);
                    cx.notify();
                })))
            .child(muted("Gäller nästa gång panelen startar. Utan ikon öppnas fönstret direkt och panelen avslutas när du stänger det, så att den aldrig kör osynligt."))
    }
}
