//! Översikt: one card per part Mio runs on the computer, read from [`StatusModel`].

use gpui_kit::component::button::Button;
use gpui_kit::component::tag::Tag;
use gpui_kit::component::{
    ActiveTheme as _, Disableable as _, Icon, IconName, Sizable as _, StyledExt as _, WindowExt as _, h_flex, v_flex,
};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::{
    AnyElement, App, Context, ElementId, Entity, InteractiveElement as _, IntoElement, ParentElement as _, Render,
    StatefulInteractiveElement as _,
    RenderOnce, SharedString, Styled as _, Subscription, Window, div, prelude::FluentBuilder as _,
};
use gpui_kit::TestSupportExt as _;
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::format::{ago, count, now_seconds};
use mio_control_core::status::{Overview, UnitState};
use mio_control_core::verification::Receipt;

use crate::model::StatusModel;
use crate::operation;

/// How a card's state reads at a glance. The tag always carries an icon and words too.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tone {
    Ok,
    Warning,
    Error,
    Neutral,
}

/// One card: a title with its state, a few detail rows and an optional action.
#[derive(IntoElement)]
pub struct StatusCard {
    id: SharedString,
    icon: IconName,
    title: SharedString,
    tone: Tone,
    state: SharedString,
    rows: Vec<(SharedString, SharedString)>,
    action: Option<AnyElement>,
}

impl StatusCard {
    pub fn new(id: &str, icon: IconName, title: &str, tone: Tone, state: impl Into<SharedString>) -> Self {
        Self { id: id.to_owned().into(), icon, title: title.to_owned().into(), tone, state: state.into(), rows: Vec::new(), action: None }
    }

    pub fn row(mut self, label: &str, value: impl Into<SharedString>) -> Self {
        self.rows.push((label.to_owned().into(), value.into()));
        self
    }

    pub fn action(mut self, action: impl IntoElement) -> Self {
        self.action = Some(action.into_any_element());
        self
    }
}

impl RenderOnce for StatusCard {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let (tag, icon) = match self.tone {
            Tone::Ok => (Tag::success(), IconName::CircleCheck),
            Tone::Warning => (Tag::warning(), IconName::TriangleAlert),
            Tone::Error => (Tag::danger(), IconName::CircleX),
            Tone::Neutral => (Tag::secondary(), IconName::Info),
        };
        let state_id = ElementId::Name(format!("{}-state", self.id).into());
        v_flex()
            .id(ElementId::Name(self.id.clone()))
            .gap_3()
            .p_4()
            .rounded(cx.theme().radius_lg)
            .border_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().group_box)
            .child(
                h_flex()
                    .gap_2()
                    .child(Icon::new(self.icon).text_color(cx.theme().muted_foreground))
                    .child(div().flex_1().min_w_0().font_semibold().child(self.title))
                    .child(
                        div().id(state_id).test_support().aria_label(self.state.clone()).child(
                            tag.small().child(h_flex().gap_1().child(Icon::new(icon).xsmall()).child(self.state)),
                        ),
                    ),
            )
            .when(!self.rows.is_empty(), |card| {
                card.child(v_flex().gap_1().text_sm().children(self.rows.into_iter().map(|(label, value)| {
                    h_flex()
                        .gap_3()
                        .justify_between()
                        .child(div().text_color(cx.theme().muted_foreground).child(label))
                        .child(div().min_w_0().truncate().child(value))
                })))
            })
            .when_some(self.action, |card, action| card.child(h_flex().justify_end().child(action)))
    }
}

pub struct OverviewPage {
    status: Entity<StatusModel>,
    /// The unit a start or restart is running for; its button shows that it is working.
    busy: Option<Unit>,
    _observe: Subscription,
}

impl OverviewPage {
    pub fn new(status: Entity<StatusModel>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        Self { status, busy: None, _observe: observe }
    }

    fn run_unit(&mut self, action: UnitAction, unit: Unit, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy.is_some() {
            return;
        }
        self.busy = Some(unit);
        cx.notify();
        let task = operation::run(Command::Unit(action, unit), None, cx);
        let status = self.status.clone();
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = None;
                let name = unit_name(unit);
                let notification = match result {
                    Ok(_) if action == UnitAction::Start => Notification::success(format!("{name} startades.")),
                    Ok(_) => Notification::success(format!("{name} startades om.")),
                    Err(error) => Notification::error(error.to_string()),
                };
                window.push_notification(notification, cx);
                status.update(cx, |status, _| status.request_refresh());
                cx.notify();
            });
        })
        .detach();
    }

    fn unit_button(&self, unit: Unit, state: &UnitState, cx: &mut Context<Self>) -> Button {
        let id = match unit {
            Unit::Gateway => "restart-gateway",
            Unit::Transcription => "restart-pianissimo",
        };
        let action = if matches!(state, UnitState::Stopped | UnitState::Failed) { UnitAction::Start } else { UnitAction::Restart };
        let label = if action == UnitAction::Start { "Starta" } else { "Starta om" };
        Button::new(id)
            .small()
            .icon(IconName::RotateCw)
            .label(label)
            .loading(self.busy == Some(unit))
            .disabled(self.busy.is_some() || matches!(state, UnitState::NotInstalled | UnitState::Unknown))
            .on_click(cx.listener(move |this, _, window, cx| this.run_unit(action, unit, window, cx)))
    }
}

fn unit_name(unit: Unit) -> &'static str {
    match unit {
        Unit::Gateway => "AI-gatewayen",
        Unit::Transcription => "Pianissimo",
    }
}

fn unit_tone(state: &UnitState) -> Tone {
    match state {
        UnitState::Running => Tone::Ok,
        UnitState::Starting | UnitState::Stopping => Tone::Warning,
        UnitState::Stopped | UnitState::Failed => Tone::Error,
        UnitState::NotInstalled | UnitState::Unknown => Tone::Neutral,
    }
}

/// The cards, built from one reading. Separate from rendering so each card's wording is plain data.
pub fn gateway_card(overview: &Overview) -> StatusCard {
    let mut tone = unit_tone(&overview.gateway_unit);
    let mut state = SharedString::from(overview.gateway_unit.label());
    if overview.gateway_unit == UnitState::Running && overview.gateway_health == Some(false) {
        (tone, state) = (Tone::Error, "Svarar inte".into());
    }
    let mut card = StatusCard::new("gateway", IconName::Bot, "AI-gatewayen", tone, state);
    if let Some(gateway) = &overview.gateway {
        if let Some(task) = gateway.tasks.first() {
            card = card.row("Modell", format!("{} ({})", task.model, task.provider));
        }
        match &gateway.quota {
            Some((limit, remaining, unit)) => {
                let unit = if unit == "tokens" { "token" } else { "anrop" };
                card = card.row("Kvar i dag", format!("{} av {} {unit}", count(*remaining), count(*limit)));
                if gateway.quota_is_low() {
                    card.tone = Tone::Warning;
                    card.state = "Kvoten nästan slut".into();
                }
            }
            None => card = card.row("Kvar i dag", "Ingen dagsgräns"),
        }
        if let Some(revision) = &gateway.revision {
            card = card.row("Konfiguration", revision.chars().take(12).collect::<String>());
        }
    }
    card
}

pub fn pianissimo_card(overview: &Overview) -> StatusCard {
    let unit = &overview.transcription_unit;
    let (tone, state) = match (unit, &overview.pianissimo) {
        (UnitState::Running, Some(health)) if health.is_ready() => (Tone::Ok, "Redo".into()),
        (UnitState::Running, Some(health)) if health.status == "failed" => (Tone::Error, "Fel".into()),
        (UnitState::Running, _) => (Tone::Warning, "Laddar".into()),
        (state, _) => (unit_tone(state), SharedString::from(state.label())),
    };
    let mut card = StatusCard::new("pianissimo", IconName::Mic, "Pianissimo", tone, state);
    if let Some(health) = &overview.pianissimo {
        if let Some(revision) = &health.revision {
            card = card.row("Modellversion", revision.chars().take(12).collect::<String>());
        }
        if let Some(precision) = &health.precision {
            card = card.row("Precision", precision.to_uppercase());
        }
        let speakers = match health.speaker_labels.as_deref() {
            Some("ready") => "På",
            Some("loading") => "Laddar",
            _ => "Av",
        };
        card = card.row("Talarmärkning", speakers);
        if let Some(words) = health.vocabulary {
            card = card.row("Egna ord", count(words));
        }
    }
    card
}

pub fn tailscale_card(overview: &Overview, gateway_port: u16) -> StatusCard {
    let Some(tailscale) = &overview.tailscale else {
        return StatusCard::new("tailscale", IconName::Network, "Tailscale", Tone::Neutral, "Läser …");
    };
    let (tone, state) = if !tailscale.installed {
        (Tone::Error, "Inte installerat")
    } else if !tailscale.logged_in {
        (Tone::Error, "Inte inloggad")
    } else if tailscale.funnel {
        (Tone::Error, "Funnel är på")
    } else if !tailscale.serve_is_correct(gateway_port) {
        (Tone::Warning, "Serve saknas")
    } else {
        (Tone::Ok, "Ansluten")
    };
    let mut card = StatusCard::new("tailscale", IconName::Network, "Tailscale", tone, state);
    if let Some(host) = &tailscale.host {
        card = card.row("Namn", host.clone());
    }
    if let Some(address) = &tailscale.address {
        card = card.row("Adress", address.clone());
    }
    if tailscale.logged_in {
        let serve = |target: &Option<String>| target.clone().unwrap_or_else(|| "Inte uppsatt".into());
        card = card.row("Port 443", serve(&tailscale.serve_443)).row("Port 8443", serve(&tailscale.serve_8443));
    }
    card
}

pub fn gpu_card(overview: &Overview) -> StatusCard {
    let Some(gpu) = &overview.gpu else {
        return StatusCard::new("gpu", IconName::Cpu, "Grafikkort", Tone::Neutral, "Hittas inte").row("Kräver", "NVIDIA-drivrutinen (nvidia-smi)");
    };
    let hot = gpu.temperature_c >= 85;
    let card = StatusCard::new("gpu", IconName::Cpu, "Grafikkort", if hot { Tone::Warning } else { Tone::Ok }, if hot { "Varmt" } else { "Ok" });
    card.row("Kort", gpu.name.clone())
        .row("Minne", format!("{} av {} MiB", count(gpu.memory_used_mib), count(gpu.memory_total_mib)))
        .row("Temperatur", format!("{} °C", gpu.temperature_c))
        .row("Användning", format!("{} %", gpu.utilization_percent))
}

pub fn update_card(overview: &Overview, now: u64) -> StatusCard {
    let Some(timer) = &overview.update_timer else {
        return StatusCard::new("nightly", IconName::Calendar, "Nattuppdatering", Tone::Neutral, "Inte installerad");
    };
    let failed = timer.last_result.as_deref().is_some_and(|result| result != "success");
    let (tone, state) = match (timer.enabled, failed) {
        (false, _) => (Tone::Neutral, "Avstängd"),
        (true, true) => (Tone::Error, "Misslyckades"),
        (true, false) => (Tone::Ok, "På"),
    };
    let last = timer.last_run_usec.map_or_else(|| "Aldrig".to_owned(), |usec| ago(usec / 1_000_000, now));
    StatusCard::new("nightly", IconName::Calendar, "Nattuppdatering", tone, state).row("Senast", last)
}

pub fn verification_card(receipt: Option<&Receipt>, now: u64) -> StatusCard {
    let Some(receipt) = receipt else {
        return StatusCard::new("verification", IconName::CircleCheck, "Verifiering", Tone::Neutral, "Inte körd");
    };
    let (tone, state) = if receipt.passed() { (Tone::Ok, "Godkänd") } else { (Tone::Error, "Underkänd") };
    let mut card = StatusCard::new("verification", IconName::CircleCheck, "Verifiering", tone, state);
    if let Some(finished) = receipt.finished_at.as_deref().and_then(mio_control_core::format::iso_seconds) {
        card = card.row("Senast", ago(finished, now));
    }
    if let Some(commit) = &receipt.commit {
        let short: String = commit.chars().take(7).collect();
        card = card.row("Revision", if receipt.dirty { format!("{short} med ändringar") } else { short });
    }
    card
}

impl Render for OverviewPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let (overview, has_read) = {
            let status = self.status.read(cx);
            (status.overview().clone(), status.has_read())
        };
        let now = now_seconds();
        let receipt = Receipt::latest();
        // Two columns when the content area has room; one in a narrow window.
        let columns = if window.viewport_size().width > gpui_kit::px(820.) { 2 } else { 1 };
        // A service that is not installed has nothing to restart; the card says why instead.
        let installed = |state: &UnitState| !matches!(state, UnitState::NotInstalled | UnitState::Unknown);
        let mut gateway = gateway_card(&overview);
        if installed(&overview.gateway_unit) {
            gateway = gateway.action(self.unit_button(Unit::Gateway, &overview.gateway_unit, cx));
        } else if overview.gateway_unit == UnitState::NotInstalled {
            gateway = gateway.row("Installera", "./server/install.sh");
        }
        let mut pianissimo = pianissimo_card(&overview);
        if installed(&overview.transcription_unit) {
            pianissimo = pianissimo.action(self.unit_button(Unit::Transcription, &overview.transcription_unit, cx));
        } else if overview.transcription_unit == UnitState::NotInstalled {
            pianissimo = pianissimo.row("Installera", "./transcription-server/install.sh");
        }
        let summary = if has_read { overview.summary() } else { "Läser status …".to_owned() };
        v_flex()
            .id("overview")
            .size_full()
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .p_4()
                    .gap_4()
                    .child(
                        v_flex()
                            .gap_1()
                            .child(div().text_xl().font_semibold().child("Översikt"))
                            .child(div().id("overview-summary").test_support().aria_label(summary.clone()).text_sm().text_color(cx.theme().muted_foreground).child(summary)),
                    )
                    .child(
                        div()
                            .grid()
                            .grid_cols(columns)
                            .gap_3()
                            .child(gateway)
                            .child(pianissimo)
                            .child(tailscale_card(&overview, 8_787))
                            .child(gpu_card(&overview))
                            .child(update_card(&overview, now))
                            .child(verification_card(receipt.as_ref(), now)),
                    ),
            )
    }
}
