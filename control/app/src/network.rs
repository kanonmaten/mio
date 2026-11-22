//! Tailscale och parning: whether the phone can reach the computer, the pairing QR code and new
//! tokens. The code is drawn in the window only, hidden after a minute or when the window loses
//! focus, and the tokens are never shown as text.

use std::time::Duration;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{ActiveTheme as _, Disableable as _, Icon, IconName, WindowExt as _, h_flex, v_flex};
use gpui_kit::{
    Bounds, Context, Entity, InteractiveElement as _, IntoElement, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Task, TestSupportExt as _, Window, black, canvas, div,
    fill, point, prelude::FluentBuilder as _, px, size, white,
};
use mio_control_core::command::{Command, Unit, UnitAction};
use mio_control_core::pairing::{Pairing, SHOW_SECONDS};
use mio_control_core::settings::SettingsFile;

use crate::model::StatusModel;
use crate::operation;
use crate::overview::tailscale_card;
use crate::parts::{page_header, section};

/// The gateway's port as `server/install.sh` sets it; `serve` must point 8443 here.
const GATEWAY_PORT: u16 = 8_787;
/// Side of the drawn code, quiet zone included.
const CODE_SIDE: f32 = 264.;

enum PairingStage {
    Hidden,
    Loading,
    Shown { pairing: Pairing, seconds_left: u64, _countdown: Task<()> },
    Failed(SharedString),
}

pub struct NetworkPage {
    status: Entity<StatusModel>,
    busy: Option<&'static str>,
    pairing: PairingStage,
    /// The token the user asked to replace, waiting for the second click.
    confirm_rotate: Option<SettingsFile>,
    _subscriptions: [Subscription; 2],
}

impl NetworkPage {
    pub fn new(status: Entity<StatusModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&status, |_, _, cx| cx.notify());
        // Someone walking by should not get a code that unlocks the computer's services.
        let activation = cx.observe_window_activation(window, |this, window, cx| {
            if !window.is_window_active() {
                this.hide_pairing(cx);
            }
        });
        Self { status, busy: None, pairing: PairingStage::Hidden, confirm_rotate: None, _subscriptions: [observe, activation] }
    }

    pub fn show_pairing(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if matches!(self.pairing, PairingStage::Loading) {
            return;
        }
        self.pairing = PairingStage::Loading;
        cx.notify();
        let task = operation::run(Command::PairingData, None, cx);
        cx.spawn_in(window, async move |this, cx| {
            let result = task.await;
            let _ = this.update(cx, |this, cx| {
                this.pairing = match result {
                    Err(error) => PairingStage::Failed(error.to_string().into()),
                    Ok(bytes) => match Pairing::parse(&bytes) {
                        None => PairingStage::Failed("Gatewayen gav ingen giltig parningskod.".into()),
                        Some(pairing) => PairingStage::Shown { pairing, seconds_left: SHOW_SECONDS, _countdown: Self::countdown(cx) },
                    },
                };
                cx.notify();
            });
        })
        .detach();
    }

    /// Ticks once a second; dropping the task (hiding the code) stops it.
    fn countdown(cx: &mut Context<Self>) -> Task<()> {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                let Ok(done) = this.update(cx, |this, cx| {
                    let PairingStage::Shown { seconds_left, .. } = &mut this.pairing else { return true };
                    *seconds_left = seconds_left.saturating_sub(1);
                    let done = *seconds_left == 0;
                    if done {
                        this.pairing = PairingStage::Hidden;
                    }
                    cx.notify();
                    done
                }) else {
                    return;
                };
                if done {
                    return;
                }
            }
        })
    }

    /// Hides a shown code. A code still loading is kept: KDE's password dialog takes the focus
    /// while the helper asks, and the code is wanted once it closes.
    pub fn hide_pairing(&mut self, cx: &mut Context<Self>) {
        if matches!(self.pairing, PairingStage::Shown { .. } | PairingStage::Failed(_)) {
            self.pairing = PairingStage::Hidden;
            cx.notify();
        }
    }

    fn setup_serve(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.run("setup-serve", Command::SetupServe, None, "Tailscale serve är inställt.", window, cx);
    }

    fn rotate(&mut self, file: SettingsFile, window: &mut Window, cx: &mut Context<Self>) {
        self.confirm_rotate = None;
        // The old code no longer works once the token changes.
        self.hide_pairing(cx);
        let unit = match file {
            SettingsFile::Gateway => Unit::Gateway,
            SettingsFile::Transcription => Unit::Transcription,
        };
        self.run("rotate", Command::RotateToken(file), Some(unit),
            "Ny token. Para om telefonen: visa parningskoden och skanna den i Mio under Inställningar → Parning.", window, cx);
    }

    /// Runs one helper command, then restarts `restart` so the service reads the new file.
    fn run(&mut self, id: &'static str, command: Command, restart: Option<Unit>, done: &'static str, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy.is_some() {
            return;
        }
        self.busy = Some(id);
        cx.notify();
        let first = operation::run(command, None, cx);
        let status = self.status.clone();
        cx.spawn_in(window, async move |this, cx| {
            let mut result = first.await;
            if let (Ok(_), Some(unit)) = (&result, restart)
                && let Ok(task) = this.update(cx, |_, cx| operation::run(Command::Unit(UnitAction::Restart, unit), None, cx))
            {
                result = task.await;
            }
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = None;
                window.push_notification(match result {
                    Ok(_) => Notification::success(done),
                    Err(error) => Notification::error(error.to_string()),
                }, cx);
                status.update(cx, |status, cx| status.request_refresh(cx));
                cx.notify();
            });
        })
        .detach();
    }

    fn render_pairing(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let show = Button::new("show-pairing").primary().label("Visa parningskod").icon(IconName::Eye)
            .loading(matches!(self.pairing, PairingStage::Loading))
            .disabled(matches!(self.pairing, PairingStage::Loading))
            .on_click(cx.listener(|this, _, window, cx| this.show_pairing(window, cx)));
        match &self.pairing {
            PairingStage::Hidden | PairingStage::Loading => v_flex().gap_2()
                .child(muted("Koden innehåller nycklarna till datorns tjänster. Den visas en minut och döljs om fönstret tappar fokus.", &theme))
                .child(h_flex().child(show))
                .into_any_element(),
            PairingStage::Failed(message) => v_flex().gap_2()
                .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::CircleX).text_color(theme.danger)).child(message.clone()))
                .child(h_flex().child(show))
                .into_any_element(),
            PairingStage::Shown { pairing, seconds_left, .. } => {
                let label: SharedString = format!("Parningskod, döljs om {seconds_left} s").into();
                h_flex().gap_4().items_start().flex_wrap()
                    .child(div().id("pairing-code").test_support().aria_label(label.clone()).child(qr_code(pairing)))
                    .child(v_flex().gap_2().text_sm().max_w(px(320.))
                        .child("Öppna Mio på telefonen, gå till Inställningar → Parning och skanna koden.")
                        .child(muted(&format!("AI: {}", pairing.ai_url), &theme))
                        .when_some(pairing.transcription_url.as_ref(), |list, url| list.child(muted(&format!("Transkription: {url}"), &theme)))
                        .child(div().text_color(theme.muted_foreground).child(label))
                        .child(h_flex().child(Button::new("hide-pairing").label("Dölj").on_click(cx.listener(|this, _, _, cx| this.hide_pairing(cx))))))
                    .into_any_element()
            }
        }
    }

    fn render_tokens(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let busy = self.busy.is_some();
        let ask = |id: &'static str, label: &'static str, file: SettingsFile| {
            Button::new(id).label(label).icon(IconName::RotateCw).disabled(busy)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.confirm_rotate = Some(file);
                    cx.notify();
                }))
        };
        v_flex().gap_2()
            .child(muted("Byt token om en telefon har kommit bort eller koden har visats för någon annan. Alla telefoner måste paras om efteråt.", &theme))
            .child(h_flex().gap_2().flex_wrap()
                .child(ask("rotate-gateway", "Byt AI-token …", SettingsFile::Gateway))
                .child(ask("rotate-transcription", "Byt transkriptionstoken …", SettingsFile::Transcription)))
            .when_some(self.confirm_rotate, |list, file| {
                let what = match file {
                    SettingsFile::Gateway => "AI-gatewayen",
                    SettingsFile::Transcription => "Pianissimo",
                };
                list.child(v_flex().id("confirm-rotate").gap_2().p_3().rounded(theme.radius).border_1().border_color(theme.warning)
                    .child(h_flex().gap_2().text_sm().child(Icon::new(IconName::TriangleAlert).text_color(theme.warning))
                        .child(format!("{what} får en ny token och startas om. Telefonen slutar fungera tills du parar om den.")))
                    .child(h_flex().gap_2().justify_end()
                        .child(Button::new("cancel-rotate").label("Avbryt").on_click(cx.listener(|this, _, _, cx| {
                            this.confirm_rotate = None;
                            cx.notify();
                        })))
                        .child(Button::new("confirm-rotate-button").danger().label("Byt token").loading(self.busy == Some("rotate")).disabled(busy)
                            .on_click(cx.listener(move |this, _, window, cx| this.rotate(file, window, cx))))))
            })
    }
}

impl Render for NetworkPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let overview = self.status.read(cx).overview().clone();
        let tailscale = overview.tailscale.clone().unwrap_or_default();
        let serve_ok = tailscale.serve_is_correct(GATEWAY_PORT);
        v_flex().id("network").size_full().overflow_y_scrollbar().p_4().gap_4()
            .child(page_header("Tailscale och parning", "Telefonen når datorn genom Tailscale. Här ser du att vägen är rätt uppsatt och parar telefonen.", cx))
            .child(tailscale_card(&overview, GATEWAY_PORT))
            .when(tailscale.funnel, |page| page.child(h_flex().id("funnel-warning").gap_2().p_3().rounded(theme.radius)
                .border_1().border_color(theme.danger).text_sm()
                .child(Icon::new(IconName::CircleX).text_color(theme.danger))
                .child("Funnel är på och gör en port nåbar från hela internet. Mio behöver det aldrig. Stäng av det med `tailscale funnel reset` i en terminal.")))
            .when(tailscale.logged_in && !serve_ok, |page| page.child(v_flex().gap_2()
                .child(muted("Serve ska skicka port 443 till Pianissimo och 8443 till AI-gatewayen. Knappen gör samma inställning som installationen och ändrar inget som används för annat.", &theme))
                .child(h_flex().child(Button::new("setup-serve").label("Ställ in serve").icon(IconName::Settings)
                    .loading(self.busy == Some("setup-serve")).disabled(self.busy.is_some())
                    .on_click(cx.listener(|this, _, window, cx| this.setup_serve(window, cx)))))))
            .when(tailscale.installed && !tailscale.logged_in, |page| page.child(muted("Logga in med `sudo tailscale up` i en terminal och slå på MagicDNS och HTTPS i Tailscales adminpanel.", &theme)))
            .child(section("Parning"))
            .child(self.render_pairing(cx))
            .child(section("Token"))
            .child(self.render_tokens(cx))
    }
}

fn muted(text: &str, theme: &gpui_kit::component::Theme) -> impl IntoElement {
    div().text_sm().text_color(theme.muted_foreground).child(text.to_owned())
}

/// Black modules on white with a four-module quiet zone, whatever the theme, so phones read it.
fn qr_code(pairing: &Pairing) -> impl IntoElement {
    let modules = pairing.modules.clone();
    let width = pairing.width;
    let cell = (CODE_SIDE / (width + 8) as f32).floor().max(1.);
    let side = cell * (width + 8) as f32;
    canvas(|_, _, _| {}, move |bounds, _, window, _| {
        let origin = bounds.origin;
        window.paint_quad(fill(Bounds::new(origin, size(px(side), px(side))), white()));
        for row in 0..width {
            let mut column = 0;
            while column < width {
                if !modules[row * width + column] {
                    column += 1;
                    continue;
                }
                let start = column;
                while column < width && modules[row * width + column] {
                    column += 1;
                }
                let x = origin.x + px((start + 4) as f32 * cell);
                let y = origin.y + px((row + 4) as f32 * cell);
                window.paint_quad(fill(Bounds::new(point(x, y), size(px((column - start) as f32 * cell), px(cell))), black()));
            }
        }
    })
    .size(px(side))
}
