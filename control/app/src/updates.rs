//! Uppdateringar: one row per part with what is installed and what the repo has, "Uppdatera allt",
//! and Konsole for the work itself (the installers ask for sudo; see `mio_control_core::updates`).

use std::sync::Arc;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    App, Context, Global, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    Styled as _, Task, TestSupportExt as _, Window, div, prelude::FluentBuilder as _,
};
use mio_control_core::updates::{Part, PartState, UpdateState, built_from, probe, script};

use crate::parts::page_header;

pub type ProbeFn = Arc<dyn Fn() -> UpdateState + Send + Sync>;
pub type TerminalFn = Arc<dyn Fn(String) -> Result<(), String> + Send + Sync>;

/// Where the update page reads from and what runs the script; tests replace both.
#[derive(Clone)]
pub struct UpdateBackend {
    pub probe: ProbeFn,
    pub open_terminal: TerminalFn,
    /// Whether the panel starts at login, so its own update keeps that choice.
    pub autostart: Arc<dyn Fn() -> bool + Send + Sync>,
}

impl Global for UpdateBackend {}

impl UpdateBackend {
    pub fn system() -> Self {
        Self {
            probe: Arc::new(|| probe(&built_from(), std::path::Path::new("/"), true)),
            open_terminal: Arc::new(|script| {
                std::process::Command::new("konsole")
                    .args(["--hold", "-e", "bash", "-c", &script])
                    .spawn()
                    .map(|_| ())
                    .map_err(|_| "Konsole saknas. Installera konsole eller kör stegen i en egen terminal.".to_owned())
            }),
            autostart: Arc::new(|| crate::desktop::autostart_path().is_some_and(|path| path.exists())),
        }
    }
}

fn backend(cx: &App) -> UpdateBackend {
    cx.try_global::<UpdateBackend>().cloned().unwrap_or_else(UpdateBackend::system)
}

pub struct UpdatesPage {
    state: Option<UpdateState>,
    checking: Option<Task<()>>,
}

impl UpdatesPage {
    pub fn new() -> Self {
        Self { state: None, checking: None }
    }

    /// Reads the state the first time the page is shown; later only on "Sök igen".
    pub fn check_once(&mut self, cx: &mut Context<Self>) {
        if self.state.is_none() && self.checking.is_none() {
            self.check(cx);
        }
    }

    fn check(&mut self, cx: &mut Context<Self>) {
        let probe = backend(cx).probe;
        let read = cx.background_executor().spawn(async move { probe() });
        self.checking = Some(cx.spawn(async move |this, cx| {
            let state = read.await;
            let _ = this.update(cx, |this, cx| {
                this.state = Some(state);
                this.checking = None;
                cx.notify();
            });
        }));
        cx.notify();
    }

    fn run(&mut self, steps: Vec<Part>, window: &mut Window, cx: &mut Context<Self>) {
        let backend = backend(cx);
        let text = script(&built_from(), &steps, (backend.autostart)());
        window.push_notification(match (backend.open_terminal)(text) {
            Ok(()) => Notification::info("Uppdateringen körs i Konsole och stannar vid första fel. Tryck Sök igen när den är klar."),
            Err(message) => Notification::error(message),
        }, cx);
    }

    fn row(&self, part: Part, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let state = self.state.as_ref();
        let blocked = state.and_then(UpdateState::blocked).is_some();
        let (tag, detail): (Tag, String) = match (part, state) {
            (_, None) => (Tag::secondary().child("Läser"), String::new()),
            (Part::Repo, Some(state)) => match &state.repo {
                Err(message) => (Tag::danger().child("Saknas"), message.clone()),
                Ok(repo) if repo.dirty => (Tag::warning().child("Ändrat lokalt"), "Har ändringar som inte är sparade i git.".into()),
                Ok(repo) if repo.behind > 0 => (Tag::warning().child("Nytt finns"), format!("{} nya ändringar att hämta.", repo.behind)),
                Ok(repo) => (Tag::success().child("Senaste"), if repo.fetch_failed { "Kunde inte nå GitHub; visar senaste kända läge.".into() } else { String::new() }),
            },
            (Part::Model, Some(_)) => (Tag::secondary().child("Varje natt"), "Modellen kollas varje natt; Uppdatera kollar nu.".into()),
            (Part::System, Some(state)) => match &state.system {
                Err(message) => (Tag::secondary().child("Okänt"), message.clone()),
                Ok(0) => (Tag::success().child("Senaste"), String::new()),
                Ok(count) => (Tag::warning().child("Nytt finns"), format!("{count} paket kan uppdateras. Körs med sudo pacman -Syu i Konsole.")),
            },
            (_, Some(state)) => match state.part(part) {
                Some(PartState::UpToDate) => (Tag::success().child("Senaste"), String::new()),
                Some(PartState::Behind) => (Tag::warning().child("Nytt finns"), String::new()),
                Some(PartState::NotInstalled) => (Tag::secondary().child("Inte installerad"), String::new()),
                Some(PartState::Unknown(reason)) => (Tag::secondary().child("Okänt"), format!("Version {reason}.")),
                None => (Tag::secondary().child("Okänt"), String::new()),
            },
        };
        let installed = !matches!(state.and_then(|state| state.part(part)), Some(PartState::NotInstalled));
        let runnable = state.is_some() && installed && (part == Part::System || !blocked);
        h_flex()
            .id(SharedString::from(format!("part-{}", part.id())))
            .test_support()
            .gap_3()
            .py_2()
            .border_b_1()
            .border_color(theme.border)
            .child(v_flex().flex_1().min_w_0().gap_0p5()
                .child(h_flex().gap_2().child(div().font_semibold().child(part.title())).child(tag.small()))
                .when(!detail.is_empty(), |column| column.child(div().text_sm().text_color(theme.muted_foreground).child(detail))))
            .child(Button::new(SharedString::from(format!("update-{}", part.id()))).small().label("Uppdatera").disabled(!runnable)
                .on_click(cx.listener(move |this, _, window, cx| {
                    // Every part is built from the repo, so it is pulled first.
                    let steps = match part {
                        Part::Repo | Part::Model | Part::System => vec![part],
                        _ => vec![Part::Repo, part],
                    };
                    this.run(steps, window, cx);
                })))
    }
}

impl Default for UpdatesPage {
    fn default() -> Self {
        Self::new()
    }
}

impl Render for UpdatesPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let blocked = self.state.as_ref().and_then(UpdateState::blocked);
        let everything = self.state.as_ref().map(UpdateState::everything).unwrap_or_default();
        let rows: Vec<_> = Part::ALL.into_iter().map(|part| self.row(part, cx).into_any_element()).collect();
        v_flex().id("updates").size_full().overflow_y_scrollbar().p_4().gap_4()
            .child(page_header("Uppdateringar", "Hämtar Mio från GitHub och installerar om det som ändrats. Stegen körs i Konsole, där sudo frågar efter lösenordet, och stannar vid första fel.", cx))
            .child(h_flex().gap_2()
                .child(Button::new("update-all").primary().label("Uppdatera allt").icon(IconName::RefreshCw)
                    .disabled(self.state.is_none() || blocked.is_some())
                    .on_click(cx.listener(move |this, _, window, cx| this.run(everything.clone(), window, cx))))
                .child(Button::new("check-updates").label("Sök igen").loading(self.checking.is_some()).disabled(self.checking.is_some())
                    .on_click(cx.listener(|this, _, _, cx| this.check(cx)))))
            .when_some(blocked, |page, message| page.child(h_flex().id("updates-blocked").test_support().gap_2().text_sm()
                .child(Icon::new(IconName::TriangleAlert).text_color(theme.warning)).child(message)))
            .child(v_flex().children(rows))
    }
}
