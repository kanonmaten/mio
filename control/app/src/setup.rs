//! Kom igång: a guide that sets up Mio on a new computer, one step at a time. Each step reads as
//! done from the status, so the guide starts at the first step that is not, and every step can be
//! run again.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::stepper::{Stepper, StepperItem};
use gpui_kit::component::{ActiveTheme as _, Icon, IconName, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    Context, Entity, EventEmitter, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, TestSupportExt as _, Window, div,
};
use mio_control_core::command::Command;
use mio_control_core::setup::{Step, current};
use mio_control_core::status::Overview;
use mio_control_core::updates::{Part, built_from, script};

use crate::model::StatusModel;
use crate::operation;
use crate::parts::page_header;
use crate::updates::UpdateBackend;

const GATEWAY_PORT: u16 = 8_787;

/// Asks the shell to open Tailscale och parning with the code showing.
pub struct OpenPairing;

pub struct SetupPage {
    status: Entity<StatusModel>,
    /// The step the user clicked; otherwise the first one not done.
    chosen: Option<Step>,
    _observe: Subscription,
}

impl EventEmitter<OpenPairing> for SetupPage {}

impl SetupPage {
    pub fn new(status: Entity<StatusModel>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        Self { status, chosen: None, _observe: observe }
    }

    fn install(&self, part: Part, window: &mut Window, cx: &mut Context<Self>) {
        let backend = cx.try_global::<UpdateBackend>().cloned().unwrap_or_else(UpdateBackend::system);
        let text = script(&built_from(), &[part], (backend.autostart)());
        window.push_notification(match (backend.open_terminal)(text) {
            Ok(()) => Notification::info("Installationen körs i terminalen. Guiden går vidare när statusen visar att steget är klart."),
            Err(message) => Notification::error(message),
        }, cx);
    }

    fn action(&self, step: Step, cx: &mut Context<Self>) -> impl IntoElement {
        let id = SharedString::from(format!("run-{}", Step::ALL.iter().position(|each| *each == step).unwrap_or(0)));
        let button = Button::new(id).primary();
        match step {
            Step::Tools => button.label("Kontrollera igen").icon(IconName::RefreshCw).on_click(cx.listener(|this, _, _, cx| {
                this.status.update(cx, |status, _| status.request_refresh());
            })),
            Step::Gateway => button.label("Installera gatewayen i terminalen").on_click(cx.listener(|this, _, window, cx| this.install(Part::Gateway, window, cx))),
            Step::Pianissimo => button.label("Installera Pianissimo i terminalen").on_click(cx.listener(|this, _, window, cx| this.install(Part::Pianissimo, window, cx))),
            Step::Serve => button.label("Ställ in serve").on_click(cx.listener(|this, _, window, cx| {
                let task = operation::run(Command::SetupServe, None, cx);
                let status = this.status.clone();
                cx.spawn_in(window, async move |_, cx| {
                    let result = task.await;
                    let _ = cx.update(|window, cx| {
                        window.push_notification(match result {
                            Ok(_) => Notification::success("Tailscale serve är inställt."),
                            Err(error) => Notification::error(error.to_string()),
                        }, cx);
                        status.update(cx, |status, _| status.request_refresh());
                    });
                })
                .detach();
            })),
            Step::Pair => button.label("Visa parningskod").icon(IconName::Eye).on_click(cx.listener(|_, _, _, cx| cx.emit(OpenPairing))),
        }
    }
}

fn explain(step: Step, overview: &Overview) -> Vec<String> {
    let yes_no = |done: bool, yes: &str, no: &str| if done { yes.to_owned() } else { no.to_owned() };
    match step {
        Step::Tools => vec![
            match &overview.gpu {
                Some(gpu) => format!("NVIDIA: {} svarar.", gpu.name),
                None => "NVIDIA: nvidia-smi svarar inte. Installera drivrutinen (CachyOS: chwd) och starta om datorn.".into(),
            },
            "Rust: finns, panelen är byggd med det.".into(),
            match &overview.tailscale {
                Some(tailscale) if tailscale.logged_in => "Tailscale: inloggat.".into(),
                Some(tailscale) if tailscale.installed => "Tailscale: inte inloggat. Kör sudo tailscale up i en terminal och slå på MagicDNS och HTTPS.".into(),
                _ => "Tailscale: saknas. Installera det med sudo pacman -S tailscale och sudo systemctl enable --now tailscaled.".into(),
            },
        ],
        Step::Gateway => vec![
            "Installationen bygger gatewayen och frågar efter Groq-nyckeln. Andra leverantörer väljer du sedan under AI.".into(),
            yes_no(overview.gateway_health == Some(true), "Gatewayen svarar.", "Gatewayen svarar inte än."),
        ],
        Step::Pianissimo => vec![
            "Installationen hämtar modellen (cirka 2,5 GB första gången) och väntar tills den är laddad.".into(),
            match overview.pianissimo.as_ref().map(|health| health.status.as_str()) {
                Some("ready") => "Pianissimo är redo.".into(),
                Some(status) => format!("Pianissimo: {status}."),
                None => "Pianissimo svarar inte än.".into(),
            },
        ],
        Step::Serve => vec!["Tailscale skickar port 443 till Pianissimo och 8443 till gatewayen, bara inom ditt tailnet. Funnel slås aldrig på.".into()],
        Step::Pair => vec!["Skanna koden i Mio på telefonen under Inställningar → Parning.".into()],
    }
}

impl Render for SetupPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let overview = self.status.read(cx).overview().clone();
        let first_open = current(&overview, GATEWAY_PORT);
        let step = self.chosen.unwrap_or(first_open);
        let index = Step::ALL.iter().position(|each| *each == step).unwrap_or(0);
        let items = Step::ALL.map(|each| {
            let done = each.done(&overview, GATEWAY_PORT);
            StepperItem::new().icon(if done { IconName::CircleCheck } else { IconName::Info }).child(each.title())
        });
        let done = step.done(&overview, GATEWAY_PORT);
        let state: SharedString = format!("{}: {}", step.title(), if done { "klart" } else { "inte klart" }).into();
        v_flex().id("setup").size_full().overflow_y_scrollbar().p_4().gap_4()
            .child(page_header("Kom igång", "Sätter upp Mio på en ny dator. Steg som redan är klara hoppas över, men alla går att köra igen.", cx))
            .child(Stepper::new("setup-steps").items(items).selected_index(index)
                .on_click(cx.listener(|this, index: &usize, _, cx| {
                    this.chosen = Step::ALL.get(*index).copied();
                    cx.notify();
                })))
            .child(v_flex().id("setup-step").test_support().aria_label(state.clone()).gap_2().p_4().rounded(theme.radius).border_1().border_color(theme.border)
                .child(h_flex().gap_2().child(Icon::new(if done { IconName::CircleCheck } else { IconName::Info })
                    .text_color(if done { theme.success } else { theme.muted_foreground })).child(div().text_lg().child(step.title())))
                .children(explain(step, &overview).into_iter().map(|line| div().text_sm().child(line)))
                .child(h_flex().pt_2().child(self.action(step, cx))))
    }
}
